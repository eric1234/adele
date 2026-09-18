@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/approval_gated_tool_policy.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _searchId = 'dev.adele.plugin.search-tools';
const _filesystemId = 'dev.adele.plugin.filesystem-tools';
const _gitId = 'dev.adele.plugin.git-environment';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File searchArtifact;
  late File filesystemArtifact;
  late File gitArtifact;
  late String aotRuntime;

  setUpAll(() async {
    final repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp('adele-remote-search-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    searchArtifact = File.fromUri(artifacts.uri.resolve('search.aot'));
    filesystemArtifact = File.fromUri(artifacts.uri.resolve('filesystem.aot'));
    gitArtifact = File.fromUri(artifacts.uri.resolve('git.aot'));
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            'plugins/search_tools/packages/backend/bin/search_tools_backend.dart',
        artifact: searchArtifact,
      ),
      (
        entrypoint:
            'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart',
        artifact: filesystemArtifact,
      ),
      (
        entrypoint:
            'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
        artifact: gitArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-search-integration',
      );
    }
  });

  late PluginBackendHost host;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;
  late _Files files;
  late _Context context;

  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(host.close);
    capabilities = CapabilityRegistry();
    extensions = ExtensionRegistry();
    files = _Files();
    context = _Context(files);
  });

  Future<PluginBackendActivation> start(File artifact, String pluginId) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: artifact.uri,
    );
    addTearDown(connection.close);
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: capabilities,
      extensions: extensions,
      adapters: createRemoteExtensionAdapters(),
    );
    addTearDown(activation.close);
    return activation;
  }

  Future<MaterializedToolSet> compose() async =>
      (await ModelToolComposer(extensions).materialize(context)).materialize();

  test('real Filesystem AOT composes four policy-compatible routes, preserves '
      'conditional mutations, and retires independently of Search', () async {
    final authority = _FilesystemAuthority();
    final activation = await start(filesystemArtifact, _filesystemId);
    expect(activation.connection.capabilityExposures, isEmpty);
    final exposure = activation.connection.extensionExposures.single;
    expect(exposure.extensionId, '$_filesystemId.model-tools');
    expect(exposure.serviceId, remoteModelToolServiceId);
    expect(exposure.metadata, {
      'hostServices': [
        authorizedEnvironmentReadServiceId,
        authorizedEnvironmentMutationServiceId,
      ],
    });
    final tools = (await ModelToolComposer(
      extensions,
    ).materialize(authority)).materialize();
    expect(tools.tools.map((tool) => tool.modelDefinition.alias), [
      'read_file',
      'apply_patch',
      'create_file',
      'delete_file',
    ]);
    expect(authority.calls, isEmpty);
    final execution = ToolExecutionContext(
      sessionId: authority.sessionId,
      runId: RunId('filesystem-run'),
    );
    Future<ToolOutcome> invoke(
      String alias,
      Map<String, Object?> arguments,
    ) async {
      final resolved = await const ToolInvocationResolver().resolve(
        invocationId: ToolInvocationId('filesystem-$alias'),
        proposal: ProviderToolProposal(
          providerCallId: 'call-$alias',
          alias: alias,
          arguments: arguments,
        ),
        tools: tools,
        context: execution,
      );
      expect(resolved, isA<ResolvedToolProposal>());
      final invocation = (resolved as ResolvedToolProposal).invocation;
      final before = authority.calls.toList();
      final effects = await invocation.tool.executable.describe(
        invocation.arguments,
        execution,
      );
      expect(authority.calls, before);
      expect(
        effects.targets.single.uri.toString(),
        'adele-environment:/filesystem-environment/${invocation.canonicalArguments['relativePath']}',
      );
      expect(
        const ApprovalGatedToolPolicy().evaluate(
          ToolPolicyInput(
            invocation: invocation,
            effects: effects,
            context: execution,
          ),
        ),
        alias == 'read_file'
            ? ToolPolicyDecision.allow
            : ToolPolicyDecision.ask,
      );
      return (await collectToolExecution(
        invocation.tool.executable.execute(invocation.arguments, execution),
      )).outcome;
    }

    final invalid = await const ToolInvocationResolver().resolve(
      invocationId: ToolInvocationId('invalid'),
      proposal: ProviderToolProposal(
        providerCallId: 'invalid',
        alias: 'create_file',
        arguments: {'relativePath': '../outside', 'content': 'no'},
      ),
      tools: tools,
      context: execution,
    );
    expect(
      (invalid as RejectedToolProposal).failure.kind,
      ToolProposalFailureKind.invalidArguments,
    );
    expect(authority.calls, isEmpty);
    final read = await invoke('read_file', {'relativePath': './source.txt'});
    expect(read.hostData['revision'], 'R1');
    final patch = {
      'relativePath': 'source.txt',
      'expectedRevision': read.hostData['revision'],
      'edits': [
        {'search': 'old', 'replace': 'intermediate'},
        {'search': 'intermediate', 'replace': 'new'},
      ],
    };
    authority.conflict = true;
    final conflict = await invoke('apply_patch', patch);
    expect(conflict.failureKind, ToolFailureKind.domain);
    expect(conflict.hostData['code'], environmentRevisionConflictCode);
    expect(conflict.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(authority.text['source.txt'], 'old\n');
    authority.conflict = false;
    final changed = await invoke('apply_patch', patch);
    expect(changed.effectCertainty, EffectCertainty.knownOccurred);
    expect(authority.text['source.txt'], 'new\n');
    expect(authority.calls, [
      'read:source.txt',
      'read:source.txt',
      'replace:source.txt:R1',
      'read:source.txt',
      'replace:source.txt:R1',
    ]);

    final exists = await invoke('create_file', {
      'relativePath': 'source.txt',
      'content': 'overwrite',
    });
    expect(exists.hostData['code'], environmentFileAlreadyExistsCode);
    expect(authority.text['source.txt'], 'new\n');
    final created = await invoke('create_file', {
      'relativePath': 'new.txt',
      'content': 'new file\n',
    });
    expect(created.disposition, ToolOutcomeDisposition.success);
    final observed = await invoke('read_file', {'relativePath': 'new.txt'});
    expect(observed.hostData['revision'], created.hostData['revision']);
    final deleting = {
      'relativePath': 'new.txt',
      'expectedRevision': observed.hostData['revision'],
    };
    authority.conflict = true;
    final rejected = await invoke('delete_file', deleting);
    expect(rejected.hostData['code'], environmentRevisionConflictCode);
    expect(rejected.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(authority.text, contains('new.txt'));
    authority.conflict = false;
    expect(
      (await invoke('delete_file', deleting)).disposition,
      ToolOutcomeDisposition.success,
    );
    expect(authority.text, isNot(contains('new.txt')));
    expect(activation.connection.isClosed, isFalse);
    final sibling = await start(searchArtifact, _searchId);
    await activation.close();
    for (final tool in tools.tools) {
      expect(
        tool.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
    }
    expect((await compose()).byAlias('search'), isNotNull);
    expect(sibling.connection.isClosed, isFalse);
    expect(host.isClosed, isFalse);
  });

  test('real Search readiness advertises and composes without file access; '
      'generated canonicalization and effects feed host policy', () async {
    expect((await compose()).tools, isEmpty);
    final activation = await start(searchArtifact, _searchId);
    expect(activation.connection.pluginId, _searchId);
    expect(activation.connection.capabilityExposures, isEmpty);
    final exposure = activation.connection.extensionExposures.single;
    expect(exposure.extensionPointId, modelToolContributions.value);
    expect(exposure.extensionId, '$_searchId.model-tools');
    expect(exposure.serviceId, remoteModelToolServiceId);
    expect(exposure.metadata, {
      'hostServices': [authorizedEnvironmentReadServiceId],
    });
    expect(context.requested, isEmpty);
    expect(files.calls, isEmpty);

    final tools = await compose();
    expect(tools.tools, hasLength(1));
    final search = tools.byAlias('search')!;
    expect(search.definition.id.value, '$_searchId.search');
    expect(search.modelDefinition.argumentsSchema, {
      'type': 'object',
      'required': ['query'],
      'properties': {
        'query': {'type': 'string', 'minLength': 1, 'maxLength': 256},
        'path': {'type': 'string'},
      },
      'additionalProperties': false,
    });
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    expect(files.calls, isEmpty);

    final proposed = <String, Object?>{
      'query': 'needle.*',
      'path': './src//nested/./',
    };
    final invocation = await _resolve(tools, context.sessionId, proposed);
    expect(invocation.canonicalArguments, {
      'query': 'needle.*',
      'path': 'src/nested',
    });
    expect(invocation.proposal.arguments, proposed);
    expect(() => invocation.canonicalArguments.clear(), throwsUnsupportedError);
    final effects = await search.executable.describe(
      invocation.arguments,
      invocation.context,
    );
    expect(effects.effects, {ToolEffect.sourceRead});
    expect(effects.uncertainty, EffectUncertainty.none);
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/${files.environmentId.value}/src/nested',
    );
    expect(
      effects.summary,
      'Search the authorized Environment scope "src/nested".',
    );
    expect(
      const ApprovalGatedToolPolicy().evaluate(
        ToolPolicyInput(
          invocation: invocation,
          effects: effects,
          context: invocation.context,
        ),
      ),
      ToolPolicyDecision.allow,
    );
    final root = await _resolve(tools, context.sessionId, {
      'query': ' spaced ',
    });
    expect(root.canonicalArguments, {'query': ' spaced ', 'path': ''});
    expect(
      files.calls,
      isEmpty,
      reason: 'Validation and policy do not read source.',
    );
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
  });

  test('plugin query/path validation becomes resolver invalidArguments; '
      'model-supplied authority identifiers are rejected', () async {
    await start(searchArtifact, _searchId);
    final tools = await compose();
    for (final invalid in <Map<String, Object?>>[
      {},
      {'query': ''},
      {'query': 'a\nb'},
      {'query': 'a\u0000b'},
      {'query': 'a\u2028b'},
      {'query': 'x' * 257},
      {'query': 'needle', 'path': '/outside'},
      {'query': 'needle', 'path': 'src/../outside'},
      {'query': 'needle', 'path': 'bad\u0000path'},
      {'query': 'needle', 'path': 'bad\ud800'},
      {'query': 'needle', 'path': null},
      for (final key in ['sessionId', 'runId', 'environmentId'])
        {'query': 'needle', key: 'forged-authority'},
    ]) {
      final result = await _resolution(tools, context.sessionId, invalid);
      expect(result, isA<RejectedToolProposal>(), reason: '$invalid');
      final failure = (result as RejectedToolProposal).failure;
      expect(failure.kind, ToolProposalFailureKind.invalidArguments);
      expect(failure.cause, isA<ToolArgumentValidationException>());
      expect(failure.message, isNotEmpty);
    }
    expect(files.calls, isEmpty);
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    expect(
      (await _execute(tools, context.sessionId)).disposition,
      ToolOutcomeDisposition.success,
    );
  });

  test(
    'server stream composes nested reads in sorted order with exact '
    'literal matches, exclusions, line numbers and bounded snippets',
    () async {
      await start(searchArtifact, _searchId);
      files.text['src/z.txt'] = '${'x' * 600}needle.*${'y' * 600}\n';
      files.directories['src'] = [
        _entry('src/z.txt'),
        _entry('src/nested', directory: true),
        _entry('src/NODE_MODULES', directory: true),
        _entry('src/a.txt'),
        _entry('src/.GiT', directory: true),
        _entry('src/.DART_TOOL', directory: true),
        _entry('src/BuIlD', directory: true),
        const EnvironmentDirectoryEntry(
          name: 'link',
          relativePath: 'src/link',
          kind: EnvironmentDirectoryEntryKind.other,
        ),
      ];
      final tools = await compose();
      final invocation = await _resolve(tools, context.sessionId, {
        'query': 'needle.*',
        'path': './src//',
      });
      final events = await invocation.tool.executable
          .execute(invocation.arguments, invocation.context)
          .toList()
          .timeout(_bound);
      expect(events, hasLength(1));
      expect(events.single, isA<ToolExecutionTerminal>());
      final outcome = (events.single as ToolExecutionTerminal).outcome;
      final matches = [
        {
          'relativePath': 'src/a.txt',
          'lineNumber': 2,
          'snippet': 'needle.* first',
        },
        {
          'relativePath': 'src/nested/b.txt',
          'lineNumber': 1,
          'snippet': 'prefix needle.* nested',
        },
        {
          'relativePath': 'src/z.txt',
          'lineNumber': 1,
          'snippet': '${'x' * 246}needle.*${'y' * 246}',
        },
      ];
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(outcome.failureKind, isNull);
      expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(outcome.hostData, {
        'query': 'needle.*',
        'path': 'src',
        'matches': matches,
        'truncated': false,
        'incomplete': false,
        'stopReason': null,
        'stopLimit': null,
        'entriesVisited': 9,
        'searchedBytes': files.text.values.fold<int>(
          0,
          (n, s) => n + utf8.encode(s).length,
        ),
        'failedFileReads': 0,
        'failedDirectoryReads': 0,
        'environmentId': files.environmentId.value,
      });
      expect(
        outcome.modelContent,
        'Search results:\nScope: "src"\n${matches.map(jsonEncode).join('\n')}',
      );
      expect(files.calls, [
        'directory:src',
        'file:src/a.txt',
        'directory:src/nested',
        'file:src/nested/b.txt',
        'file:src/z.txt',
      ]);
      expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
      expect(() => outcome.hostData.clear(), throwsUnsupportedError);
    },
  );

  test(
    'file scope fallback, missing scope and excluded scope retain Search semantics',
    () async {
      await start(searchArtifact, _searchId);
      final tools = await compose();
      final file = await _execute(tools, context.sessionId, path: 'src/a.txt');
      expect(file.disposition, ToolOutcomeDisposition.success);
      expect(file.hostData['matches'], [
        {
          'relativePath': 'src/a.txt',
          'lineNumber': 2,
          'snippet': 'needle.* first',
        },
      ]);
      expect(file.hostData['entriesVisited'], 0);
      expect(
        file.hostData['searchedBytes'],
        utf8.encode(files.text['src/a.txt']!).length,
      );
      expect(files.calls, ['directory:src/a.txt', 'file:src/a.txt']);
      files.calls.clear();
      final missing = await _execute(tools, context.sessionId, path: 'missing');
      expect(missing.disposition, ToolOutcomeDisposition.failure);
      expect(missing.failureKind, ToolFailureKind.domain);
      expect(missing.hostData['code'], 'not_found');
      expect(missing.hostData['environmentId'], files.environmentId.value);
      expect(missing.hostData['matches'], isEmpty);
      expect(files.calls, ['directory:missing']);
      files.calls.clear();
      final excluded = await _execute(
        tools,
        context.sessionId,
        path: 'src/BuIlD',
      );
      expect(excluded.disposition, ToolOutcomeDisposition.failure);
      expect(excluded.failureKind, ToolFailureKind.domain);
      expect(excluded.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(
        excluded.modelContent,
        contains('excluded by stock Search defaults'),
      );
      expect(files.calls, isEmpty);
    },
  );

  test(
    'remote outcomes distinguish match bounds from skipped failed reads',
    () async {
      await start(searchArtifact, _searchId);
      files.text['many.txt'] = List.filled(101, 'needle.*').join('\n');
      final tools = await compose();
      final bounded = await _execute(
        tools,
        context.sessionId,
        path: 'many.txt',
      );
      expect(bounded.disposition, ToolOutcomeDisposition.success);
      expect(bounded.hostData['truncated'], isTrue);
      expect(bounded.hostData['incomplete'], isFalse);
      expect(bounded.hostData['stopReason'], 'max_matches');
      expect(bounded.hostData['stopLimit'], 100);
      expect(bounded.hostData['matches'], [
        for (var line = 1; line <= 100; line++)
          {
            'relativePath': 'many.txt',
            'lineNumber': line,
            'snippet': 'needle.*',
          },
      ]);
      expect(
        bounded.modelContent,
        contains('Search truncated: max_matches limit (100) reached.'),
      );
      files.calls.clear();
      files.directories['src']!.add(_entry('src/unreadable.txt'));
      final partial = await _execute(tools, context.sessionId);
      expect(partial.disposition, ToolOutcomeDisposition.success);
      expect(partial.hostData['truncated'], isFalse);
      expect(partial.hostData['incomplete'], isTrue);
      expect(partial.hostData['stopReason'], isNull);
      expect(partial.hostData['failedFileReads'], 1);
      expect(partial.hostData['matches'], hasLength(2));
      expect(partial.modelContent, contains('Search incomplete:'));
      expect(
        partial.modelContent,
        contains('no search resource limit stopped it.'),
      );
    },
  );

  test('materialized Search captures exact Session authority, not later host '
      'resolution or caller Run identity', () async {
    await start(searchArtifact, _searchId);
    final tools = await compose();
    final decoy = _Files(environment: 'forged-environment')
      ..text['src/a.txt'] = 'needle.* forbidden replacement';
    context.files = decoy;
    final invocation = await _resolve(tools, context.sessionId, {
      'query': 'needle.*',
      'path': 'src/a.txt',
    }, runId: RunId('forged-run'));
    final effects = await invocation.tool.executable.describe(
      invocation.arguments,
      invocation.context,
    );
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/${files.environmentId.value}/src/a.txt',
    );
    final result = await collectToolExecution(
      invocation.tool.executable.execute(
        invocation.arguments,
        invocation.context,
      ),
    ).timeout(_bound);
    expect(result.outcome.hostData['environmentId'], files.environmentId.value);
    expect(result.outcome.modelContent, contains('needle.* first'));
    expect(
      result.outcome.modelContent,
      isNot(contains('forbidden replacement')),
    );
    expect(decoy.calls, isEmpty);
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);

    final wrongSession = ToolExecutionContext(
      sessionId: SessionId('forged-session'),
      runId: invocation.context.runId,
    );
    final callsBefore = files.calls.toList();
    await expectLater(
      () => invocation.tool.executable.describe(
        invocation.arguments,
        wrongSession,
      ),
      throwsStateError,
    );
    await expectLater(
      invocation.tool.executable
          .execute(invocation.arguments, wrongSession)
          .toList()
          .timeout(_bound),
      throwsStateError,
    );
    expect(files.calls, callsBefore);
    expect(decoy.calls, isEmpty);
  });

  test(
    'a read facet from another Session fails materialization before file access',
    () async {
      await start(searchArtifact, _searchId);
      context.files = _Files(session: 'another-session');
      await expectLater(compose(), throwsStateError);
      expect(context.files.calls, isEmpty);
      expect(files.calls, isEmpty);
      expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
      context.files = files;
      expect(
        (await _execute(await compose(), context.sessionId)).disposition,
        ToolOutcomeDisposition.success,
      );
    },
  );

  test(
    'stale Environment fails old tools; only fresh materialization captures replacement',
    () async {
      await start(searchArtifact, _searchId);
      final oldTools = await compose();
      files.stale = true;
      expect(
        oldTools.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      final rejected = await _resolution(oldTools, context.sessionId, {
        'query': 'needle.*',
      });
      expect(
        (rejected as RejectedToolProposal).failure.kind,
        ToolProposalFailureKind.staleBinding,
      );
      final replacement = _Files()..text['src/a.txt'] = 'needle.* replacement';
      context.files = replacement;
      final fresh = await compose();
      final outcome = await _execute(
        fresh,
        context.sessionId,
        path: 'src/a.txt',
      );
      expect(outcome.modelContent, contains('needle.* replacement'));
      expect(files.calls, isEmpty);
      expect(
        oldTools.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(context.requested, [
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileReadFacet,
      ]);
    },
  );

  test(
    'Environment retirement during a nested read rejects late Search results',
    () async {
      await start(searchArtifact, _searchId);
      final tools = await compose();
      files.blockPath = 'src/nested/b.txt';
      files.release = Completer<void>();
      addTearDown(files.unblock);
      final failed = expectLater(
        _execute(tools, context.sessionId),
        throwsA(isA<StaleToolBindingException>()),
      );
      await files.entered.future.timeout(_bound);
      files.stale = true;
      files.unblock();
      await failed;
      expect(files.calls, [
        'directory:src',
        'file:src/a.txt',
        'directory:src/nested',
        'file:src/nested/b.txt',
      ]);
      expect(
        tools.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
    },
  );

  test(
    'Environment retirement after terminal delivery rejects Search stream completion',
    () async {
      await start(searchArtifact, _searchId);
      final tools = await compose();
      final invocation = await _resolve(tools, context.sessionId, {
        'query': 'needle.*',
        'path': 'src',
      });
      final received = <ToolExecutionEvent>[];
      final events = invocation.tool.executable
          .execute(invocation.arguments, invocation.context)
          .map((event) {
            received.add(event);
            if (event is ToolExecutionTerminal) {
              // The adapter already validated and delivered this event. Retire
              // before done, without cancelling or validating from the consumer.
              files.stale = true;
            }
            return event;
          });

      await expectLater(
        collectToolExecution(events).timeout(_bound),
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(received, hasLength(1));
      expect(received.single, isA<ToolExecutionTerminal>());
      final terminal = received.single as ToolExecutionTerminal;
      expect(terminal.outcome.disposition, ToolOutcomeDisposition.success);
      expect(terminal.outcome.hostData['matches'], hasLength(2));
      expect(files.stale, isTrue);
    },
  );

  test('cancelling Search with a pending nested read settles before provider '
      'release and late completion cannot poison the next operation', () async {
    await start(searchArtifact, _searchId);
    final tools = await compose();
    files.blockPath = 'src/nested/b.txt';
    files.release = Completer<void>();
    addTearDown(files.unblock);
    final invocation = await _resolve(tools, context.sessionId, {
      'query': 'needle.*',
    });
    final events = <ToolExecutionEvent>[];
    final errors = <Object>[];
    final subscription = invocation.tool.executable
        .execute(invocation.arguments, invocation.context)
        .listen(events.add, onError: errors.add);
    addTearDown(subscription.cancel);
    await files.entered.future.timeout(_bound);
    expect(files.calls.last, 'file:src/nested/b.txt');
    await subscription.cancel().timeout(_bound);
    expect(files.release!.isCompleted, isFalse);
    expect(events, isEmpty);
    expect(errors, isEmpty);
    files.unblock();
    await files.settled.future.timeout(_bound);
    final next = await _execute(tools, context.sessionId);
    expect(next.disposition, ToolOutcomeDisposition.success);
    expect(next.hostData['matches'], hasLength(2));
    expect(events, isEmpty);
    expect(errors, isEmpty);
    expect(host.isClosed, isFalse);
  });

  test(
    'real Git lifecycle confines remote Search to the authorized Task worktree; '
    'Search and Environment generations retire independently',
    () async {
      final container = await Directory.systemTemp.createTemp(
        'adele-search-git-',
      );
      addTearDown(() => container.delete(recursive: true));
      final source = Directory.fromUri(container.uri.resolve('source/'));
      await source.create();
      final sourceFile = File.fromUri(source.uri.resolve('src/fixture.txt'));
      await sourceFile.parent.create();
      await sourceFile.writeAsString('needle.* committed Project source\n');
      await _git(source, ['init']);
      await _git(source, ['add', '.']);
      await _git(source, [
        '-c',
        'user.name=ADELE Test',
        '-c',
        'user.email=adele@example.invalid',
        'commit',
        '-m',
        'Search fixture',
      ]);

      final gitA = await start(gitArtifact, _gitId);
      final searchA = await start(searchArtifact, _searchId);
      final chat = ChatStrategyPlugin();
      addTearDown(chat.activate(extensions).close);
      final store = InMemoryProductStore();
      final lifecycle = ProductLifecycleCoordinator.generated(
        store: store,
        registry: capabilities,
        extensions: extensions,
        ids: MonotonicProductIdSource(seed: 'remote-search'),
      );
      final project = lifecycle.createProject(source.uri);
      final created = await lifecycle.createTask(
        projectId: project.id,
        title: 'Search Task source',
      );
      final session = lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      final authority = store.requireSessionAuthority(session.id);
      final materializationA = lifecycle.environmentRuntime
          .currentMaterialization(created.environment.id)!;
      expect(authority.environmentId, created.environment.id);
      final worktree = Directory(
        created.environment.providerState!['worktreePath']! as String,
      );
      expect(worktree.path, isNot(source.path));
      final taskFile = File.fromUri(worktree.uri.resolve('src/fixture.txt'));
      await taskFile.writeAsString(
        'Task-only header\nneedle.* authorized Task source\n',
      );
      await sourceFile.writeAsString('needle.* unauthorized Project source\n');

      Future<MaterializedToolSet> sessionTools() async =>
          (await buildModelToolCatalogForSession(
            sessionId: session.id,
            environmentRuntime: lifecycle.environmentRuntime,
            extensions: extensions,
          )).materialize();
      final toolsA = await sessionTools();
      final result = await _execute(toolsA, session.id);
      expect(result.disposition, ToolOutcomeDisposition.success);
      expect(result.hostData['environmentId'], created.environment.id.value);
      expect(result.hostData['matches'], [
        {
          'relativePath': 'src/fixture.txt',
          'lineNumber': 2,
          'snippet': 'needle.* authorized Task source',
        },
      ]);
      expect(result.modelContent, isNot(contains('unauthorized Project')));

      await host.stopPlugin(_searchId);
      await searchA.connection.terminated.timeout(_bound);
      expect(extensions.discover(modelToolContributions), isEmpty);
      expect(
        toolsA.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect((await sessionTools()).tools, isEmpty);
      expect(gitA.connection.isClosed, isFalse);
      expect(materializationA.validateBinding, returnsNormally);
      expect(
        (await materializationA.provider.readFile(
          created.environment.id,
          'src/fixture.txt',
        )).text,
        'Task-only header\nneedle.* authorized Task source\n',
      );
      final searchB = await start(searchArtifact, _searchId);
      await searchA.close();
      expect(searchB.connection.isClosed, isFalse);
      final toolsB = await sessionTools();
      expect(
        (await _execute(toolsB, session.id)).hostData['matches'],
        result.hostData['matches'],
      );
      expect(
        toolsA.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );

      await gitA.close();
      expect(
        toolsB.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(searchB.connection.isClosed, isFalse);
      final gitB = await start(gitArtifact, _gitId);
      final toolsC = await sessionTools();
      final materializationB = lifecycle.environmentRuntime
          .currentMaterialization(created.environment.id)!;
      expect(materializationB, isNot(same(materializationA)));
      expect(materializationB.environment.id, materializationA.environment.id);
      expect(
        (await _execute(toolsC, session.id)).hostData['matches'],
        result.hostData['matches'],
      );
      expect(
        toolsB.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        toolsA.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        await sourceFile.readAsString(),
        'needle.* unauthorized Project source\n',
      );
      expect(
        await taskFile.readAsString(),
        'Task-only header\nneedle.* authorized Task source\n',
      );
      expect(gitB.connection.isClosed, isFalse);
      expect(host.isClosed, isFalse);
    },
  );
}

Future<ToolProposalResolution> _resolution(
  MaterializedToolSet tools,
  SessionId sessionId,
  Map<String, Object?> arguments, {
  RunId? runId,
}) => const ToolInvocationResolver()
    .resolve(
      invocationId: ToolInvocationId('search-invocation'),
      proposal: ProviderToolProposal(
        providerCallId: 'search-call',
        alias: 'search',
        arguments: arguments,
      ),
      tools: tools,
      context: ToolExecutionContext(
        sessionId: sessionId,
        runId: runId ?? RunId('search-run'),
      ),
    )
    .timeout(_bound);

Future<ToolInvocation> _resolve(
  MaterializedToolSet tools,
  SessionId sessionId,
  Map<String, Object?> arguments, {
  RunId? runId,
}) async {
  final result = await _resolution(tools, sessionId, arguments, runId: runId);
  expect(result, isA<ResolvedToolProposal>());
  return (result as ResolvedToolProposal).invocation;
}

Future<ToolOutcome> _execute(
  MaterializedToolSet tools,
  SessionId sessionId, {
  String path = 'src',
}) async {
  final invocation = await _resolve(tools, sessionId, {
    'query': 'needle.*',
    'path': path,
  });
  final observation = await collectToolExecution(
    invocation.tool.executable.execute(
      invocation.arguments,
      invocation.context,
    ),
  ).timeout(_bound);
  expect(observation.progress, isEmpty);
  return observation.outcome;
}

final class _FilesystemAuthority
    implements
        ModelToolHostContext,
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileMutationFacet {
  @override
  final sessionId = SessionId('filesystem-session');
  @override
  final environmentId = EnvironmentId('filesystem-environment');
  final text = <String, String>{'source.txt': 'old\n'};
  final revisions = <String, String>{'source.txt': 'R1'};
  final calls = <String>[];
  bool conflict = false;
  int nextRevision = 2;

  @override
  Future<T> requireHostService<T extends Object>() async {
    if (T == AuthorizedEnvironmentFileReadFacet ||
        T == AuthorizedEnvironmentFileMutationFacet) {
      return this as T;
    }
    throw StateError('Unsupported authority $T.');
  }

  @override
  void validateBinding() {}

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    calls.add('read:$relativePath');
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text[relativePath]!,
      sizeBytes: utf8.encode(text[relativePath]!).length,
      revision: revisions[relativePath]!,
    );
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      throw StateError('Filesystem tools must not traverse.');

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String content,
  ) async {
    calls.add('create:$relativePath');
    if (text.containsKey(relativePath)) {
      throw const EnvironmentFailure(
        code: environmentFileAlreadyExistsCode,
        message: 'Already exists.',
        details: {},
      );
    }
    text[relativePath] = content;
    final revision = revisions[relativePath] = 'R${nextRevision++}';
    return EnvironmentTextFileCreation(revision: revision);
  }

  void checkRevision(String path, String expected) {
    if (conflict || revisions[path] != expected) {
      throw const EnvironmentFailure(
        code: environmentRevisionConflictCode,
        message: 'Concurrent edit.',
        details: {},
      );
    }
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    calls.add('replace:$relativePath:$expectedRevision');
    checkRevision(relativePath, expectedRevision);
    text[relativePath] = replacementText;
    final revision = revisions[relativePath] = 'R${nextRevision++}';
    return EnvironmentTextFileReplacement(revision: revision);
  }

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    calls.add('delete:$relativePath:$expectedRevision');
    checkRevision(relativePath, expectedRevision);
    text.remove(relativePath);
    revisions.remove(relativePath);
  }
}

final class _Context implements ModelToolHostContext {
  _Context(this.files);
  _Files files;
  final requested = <Type>[];
  @override
  final sessionId = SessionId('authoritative-session');

  @override
  Future<T> requireHostService<T extends Object>() async {
    requested.add(T);
    if (T == AuthorizedEnvironmentFileReadFacet) return files as T;
    throw StateError('No authority granted for $T.');
  }
}

final class _Files implements AuthorizedEnvironmentFileReadFacet {
  _Files({
    String environment = 'authoritative-environment',
    String session = 'authoritative-session',
  }) : environmentId = EnvironmentId(environment),
       sessionId = SessionId(session);

  @override
  final SessionId sessionId;
  @override
  final EnvironmentId environmentId;
  bool stale = false;
  final calls = <String>[];
  final text = <String, String>{
    'src/a.txt': 'Needle.* is different\nneedle.* first\n',
    'src/nested/b.txt': 'prefix needle.* nested\n',
  };
  final directories = <String, List<EnvironmentDirectoryEntry>>{
    '': [_entry('src', directory: true)],
    'src': [_entry('src/nested', directory: true), _entry('src/a.txt')],
    'src/nested': [_entry('src/nested/b.txt')],
  };
  String? blockPath;
  Completer<void>? release;
  final entered = Completer<void>();
  final settled = Completer<void>();

  @override
  void validateBinding() {
    if (stale) {
      throw const AuthorizedEnvironmentBindingStale('Provider retired.');
    }
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    calls.add('directory:$relativePath');
    final entries = directories[relativePath];
    if (entries == null) {
      throw EnvironmentFailure(
        code: text.containsKey(relativePath) ? 'not_directory' : 'not_found',
        message: 'No directory at this authorized path.',
        details: {'relativePath': relativePath},
      );
    }
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: entries,
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    calls.add('file:$relativePath');
    if (relativePath == blockPath) {
      if (!entered.isCompleted) entered.complete();
      await release?.future;
      if (!settled.isCompleted) settled.complete();
    }
    final content = text[relativePath];
    if (content == null) {
      throw EnvironmentFailure(
        code: 'not_found',
        message: 'No file at this authorized path.',
        details: {'relativePath': relativePath},
      );
    }
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: content,
      sizeBytes: utf8.encode(content).length,
      revision: 'opaque-$relativePath',
    );
  }

  void unblock() {
    final barrier = release;
    if (barrier != null && !barrier.isCompleted) barrier.complete();
  }
}

EnvironmentDirectoryEntry _entry(String path, {bool directory = false}) =>
    EnvironmentDirectoryEntry(
      name: path.split('/').last,
      relativePath: path,
      kind: directory
          ? EnvironmentDirectoryEntryKind.directory
          : EnvironmentDirectoryEntryKind.file,
    );

Future<void> _git(Directory source, List<String> arguments) async {
  final result = await Process.run('git', ['-C', source.path, ...arguments]);
  expect(result.exitCode, 0, reason: 'git $arguments: ${result.stderr}');
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
