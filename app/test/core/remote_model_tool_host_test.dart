@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/approval_gated_tool_policy.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart'
    show
        AgentRun,
        MaterializedToolSet,
        ModelToolComposer,
        ProviderToolProposal,
        RejectedToolProposal,
        ResolvedToolProposal,
        RunInterruptionId,
        RunState,
        ToolApprovalRequired,
        ToolApprovalResolution,
        ToolInvocationId,
        ToolInvocationResolver,
        ToolMaterializationException,
        ToolPolicyGate,
        ToolProposalFailureKind,
        ToolProposalResolution;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _probeId = 'dev.adele.test.remote-model-tool';
const _extensionId = 'dev.adele.test.remote-model-tool.tools';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File probeArtifact;
  late File commandArtifact;
  late String aotRuntime;

  setUpAll(() async {
    final repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp('adele-remote-tool-');
    addTearDown(() => artifacts.delete(recursive: true));
    final dart = _dartExecutable();
    aotRuntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    probeArtifact = File.fromUri(artifacts.uri.resolve('probe.aot'));
    commandArtifact = File.fromUri(artifacts.uri.resolve('command.aot'));
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/remote_model_tool_probe.dart',
        artifact: probeArtifact,
      ),
      (
        entrypoint:
            'plugins/command_tools/packages/backend/bin/command_tools_backend.dart',
        artifact: commandArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'remote-model-tool-test',
      );
    }
  });

  late PluginBackendHost host;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;
  late _Files files;
  late _Files mutations;
  late _Context context;
  late ToolExecutionContext execution;

  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(host.close);
    capabilities = CapabilityRegistry();
    extensions = ExtensionRegistry();
    files = _Files();
    mutations = _Files();
    context = _Context(files, mutations);
    execution = ToolExecutionContext(
      sessionId: context.sessionId,
      runId: RunId('tool-run'),
    );
  });

  Future<PluginBackendActivation> start({
    String pluginId = _probeId,
    String extensionId = _extensionId,
    Map<String, Object?> options = const {},
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: probeArtifact.uri,
      arguments: [extensionId, jsonEncode(options)],
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

  Future<List<ToolRegistration>> materialize() async =>
      (await extensions
              .discover(modelToolContributions)
              .first
              .value
              .materialize(context))
          .toList();

  Future<MaterializedToolSet> compose() async =>
      (await ModelToolComposer(extensions).materialize(context)).materialize();

  for (final count in [0, 1, 3]) {
    test('generated remote contribution materializes $count tools without '
        'requiring Environment authority', () async {
      final probe = await start(options: {'count': count, 'read': false});
      expect(context.requested, isEmpty);
      final tools = await compose();
      expect(tools.tools, hasLength(count));
      expect(
        tools.tools.map((tool) => tool.definition.id.value),
        List.generate(count, (index) => 'probe-tool-$index'),
      );
      expect(
        tools.tools.map((tool) => tool.modelDefinition.alias),
        List.generate(count, (index) => 'probe_$index'),
      );
      if (count > 0) {
        final tool = tools.tools.first;
        expect(tool.definition.description, 'Host probe tool 0');
        expect(tool.modelDefinition.description, 'Model probe tool 0');
        expect(tool.modelDefinition.argumentsSchema, {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
          'required': ['value'],
          'additionalProperties': false,
        });
        final arguments = await tool.executable.validateAndNormalize({
          'value': '  canonical  ',
        });
        expect(arguments.snapshot, {'value': 'canonical'});
        tool.executable.validateBinding();
        await tool.executable.describe(arguments, execution);
        await collectToolExecution(
          tool.executable.execute(arguments, execution),
        );
      }
      expect(context.requested, isEmpty);
      expect(files.reads, isEmpty);
      expect(mutations.mutations, isEmpty);
      final records = await _records(probe.connection);
      expect(
        records.where((record) => record.containsKey('token')),
        everyElement(containsPair('token', isNull)),
      );
      for (final record in records) {
        if (record['operation'] != 'execute') _expectPrePolicyDenied(record);
        if (record.containsKey('environmentId')) {
          expect(record['environmentId'], isNull);
        }
      }
    });
  }

  for (final collision in ['id', 'alias']) {
    test(
      '$collision collisions remain composer-owned, not adapter policy',
      () async {
        await start(
          options: {'count': 2, 'collision': collision, 'read': false},
        );
        expect(await materialize(), hasLength(2));
        await expectLater(
          compose(),
          throwsA(isA<ToolMaterializationException>()),
        );
        expect(extensions.discover(modelToolContributions), hasLength(1));
      },
    );
  }

  for (final invalid in <String, Map<String, Object?>>{
    'missing hostServices': {'metadata': <String, Object?>{}},
    'extra metadata': {
      'metadata': {'hostServices': <String>[], 'extra': true},
    },
    'null services': {
      'metadata': {'hostServices': null},
    },
    'non-list services': {
      'metadata': {'hostServices': 'authorizedEnvironmentRead'},
    },
    'non-string service': {
      'metadata': {
        'hostServices': [1],
      },
    },
    'duplicate service': {
      'metadata': {
        'hostServices': [
          'authorizedEnvironmentRead',
          'authorizedEnvironmentRead',
        ],
      },
    },
    'unsupported service': {
      'metadata': {
        'hostServices': ['unknownHostService'],
      },
    },
    'wrong service route': {'serviceId': 'notModelTools'},
  }.entries) {
    test('rejects ${invalid.key} before granting authority', () async {
      await expectLater(
        start(options: invalid.value),
        throwsA(isA<ExtensionContractException>()),
      );
      expect(extensions.discover(modelToolContributions), isEmpty);
      expect(context.requested, isEmpty);
      expect(files.reads, isEmpty);
      expect(host.isClosed, isFalse);
      await start(options: {'read': false});
      expect((await compose()).tools, hasLength(1));
    });
  }

  test('captures the read facet once and maps generated values without cause; '
      'only execution has fresh, short-lived authority', () async {
    final probe = await start();
    expect(context.requested, isEmpty);
    final tool = (await materialize()).single;
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    final replacementFiles = _Files()..text = 'A later authority';
    context.files = replacementFiles;

    final arguments = await tool.executable.validateAndNormalize({
      'value': ' data ',
    });
    expect(arguments.snapshot, {'value': 'data'});
    expect(
      () => arguments.snapshot['value'] = 'changed',
      throwsUnsupportedError,
    );
    expect(tool.executable.validateBinding, returnsNormally);
    final effect = await tool.executable.describe(arguments, execution);
    expect(effect.effects, {
      ToolEffect.resourceInspection,
      ToolEffect.sourceRead,
    });
    expect(effect.targets.map((target) => target.uri.toString()), [
      'adele-environment://tool-environment/probe.txt',
    ]);
    expect(effect.summary, 'Inspect the captured probe authority');
    expect(effect.uncertainty, EffectUncertainty.uncertain);
    expect(files.reads, isEmpty);
    final unlistened = tool.executable.execute(arguments, execution);
    expect(
      (await _records(probe.connection)).map((record) => record['operation']),
      ['materialize', 'validate', 'describe'],
    );
    final observation = await collectToolExecution(unlistened);
    expect(
      observation.progress.map((progress) => progress.kind),
      ToolProgressKind.values,
    );
    expect(observation.progress.map((progress) => progress.content), [
      'Working',
      'out\n',
      'err\n',
    ]);
    final outcome = observation.outcome;
    expect(outcome.disposition, ToolOutcomeDisposition.failure);
    expect(outcome.failureKind, ToolFailureKind.domain);
    expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
    expect(outcome.modelContent, 'Probe result');
    expect(outcome.hostData, {
      'nested': {
        'values': [1, true, null],
      },
    });
    expect(outcome.hostDiagnostic, 'Probe diagnostic');
    expect(
      outcome.cause,
      isNull,
      reason: 'In-process diagnostics are not wire data.',
    );
    expect(context.requested, [AuthorizedEnvironmentFileReadFacet]);
    expect(replacementFiles.reads, isEmpty);
    expect(files.reads, ['directory:', 'file:probe.txt']);

    final records = await _records(probe.connection);
    expect(records.map((record) => record['operation']), [
      'materialize',
      'validate',
      'describe',
      'execute',
    ]);
    final operations = records
        .where((record) => record.containsKey('token'))
        .toList();
    final tokens = operations.map((record) => record['token']).toSet();
    expect(tokens, hasLength(1));
    expect(tokens, everyElement(isA<String>()));
    for (final record in operations) {
      expect(record['authority'], {
        'sessionId': 'tool-session',
        'environmentId': 'tool-environment',
      });
      expect(record['text'], 'Captured authority');
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': record['token']}),
      );
    }
    for (final record in records.take(3)) {
      _expectPrePolicyDenied(record);
    }
    expect(records.first['routes'], hasLength(1));
    final route = (records.first['routes']! as List).single;
    for (final record in records.skip(2)) {
      expect(record['sessionId'], 'tool-session');
      expect(record['runId'], 'tool-run');
      expect(record['environmentId'], 'tool-environment');
      expect(record['arguments'], arguments.snapshot);
      expect(record['routeId'], route);
    }
    await tool.executable.validateAndNormalize({'value': 'again'});
    await tool.executable.describe(arguments, execution);
    final repeated = (await _records(probe.connection)).skip(4);
    for (final record in repeated) {
      _expectPrePolicyDenied(record);
    }
    await collectToolExecution(tool.executable.execute(arguments, execution));
    final repeatedToken = (await _records(probe.connection)).last['token'];
    expect(tokens, isNot(contains(repeatedToken)));
    final fresh = (await materialize()).single;
    _expectPrePolicyDenied((await _records(probe.connection)).last);
    await collectToolExecution(fresh.executable.execute(arguments, execution));
    final next = (await _records(probe.connection)).last;
    expect(tokens, isNot(contains(next['token'])));
    expect(next['token'], isNot(repeatedToken));
    expect(next['text'], replacementFiles.text);
    expect(context.requested, [
      AuthorizedEnvironmentFileReadFacet,
      AuthorizedEnvironmentFileReadFacet,
    ]);
  });

  test('only declared argument failure becomes invalidArguments; protocol and '
      'backend failures are not model argument errors', () async {
    final probe = await start(options: {'read': false});
    final tools = await compose();
    Future<ToolProposalResolution> resolve(String value) =>
        const ToolInvocationResolver().resolve(
          invocationId: ToolInvocationId('invocation-$value'),
          proposal: ProviderToolProposal(
            providerCallId: 'call-$value',
            alias: 'probe_0',
            arguments: {'value': value},
          ),
          tools: tools,
          context: execution,
        );
    final rejected = await resolve('invalid') as RejectedToolProposal;
    expect(rejected.failure.kind, ToolProposalFailureKind.invalidArguments);
    expect(rejected.failure.message, 'The probe rejects this value.');
    expect(rejected.failure.cause, isA<ToolArgumentValidationException>());
    await expectLater(resolve('crash'), throwsA(isA<PluginRemoteFailure>()));
    await _control(probe.connection, 'malform', {'operation': 'validate'});
    await expectLater(
      resolve('valid'),
      throwsA(
        isA<PluginRemoteFailure>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(context.requested, isEmpty);
  });

  for (final operation in ['materialize', 'describe', 'execute']) {
    test(
      'malformed $operation response is rejected without leaking authority',
      () async {
        final probe = await start(options: {'mutation': true});
        final tools = operation == 'materialize' ? null : await materialize();
        await _control(probe.connection, 'malform', {'operation': operation});
        final arguments = CanonicalToolArguments({'value': 'data'});
        final Future<Object?> pending = switch (operation) {
          'materialize' => materialize(),
          'describe' => tools!.single.executable.describe(arguments, execution),
          _ => tools!.single.executable.execute(arguments, execution).toList(),
        };
        await expectLater(pending, throwsA(isA<AdeleProtocolException>()));
        final token = (await _records(probe.connection)).last['token'];
        _expectDenied(
          await _control(probe.connection, 'replay', {'token': token}),
        );
        _expectDenied(await _mutationReplay(probe.connection, token));
        expect(probe.connection.isClosed, isFalse);
        await _control(probe.connection, 'malform', {'operation': null});
        expect(await materialize(), hasLength(1));
      },
    );
  }

  for (final invalid in <String, Map<String, Object?>>{
    'missing': {'omitExecutionServices': true},
    'unknown': {
      'wireServices': ['unknownHostService'],
    },
    'duplicate': {
      'wireServices': [
        authorizedEnvironmentReadServiceId,
        authorizedEnvironmentReadServiceId,
      ],
    },
    'undeclared': {
      'wireServices': [authorizedEnvironmentMutationServiceId],
    },
  }.entries) {
    test(
      'rejects ${invalid.key} descriptor execution services without invoking '
      'captured authority',
      () async {
        final probe = await start(options: invalid.value);
        await expectLater(
          materialize(),
          throwsA(
            invalid.key == 'missing'
                ? isA<AdeleProtocolException>()
                : isA<ExtensionContractException>(),
          ),
        );
        expect(files.reads, isEmpty);
        expect(mutations.mutations, isEmpty);
        _expectPrePolicyDenied((await _records(probe.connection)).single);
      },
    );
  }

  test('descriptor allowlists narrow maximum captured services to none, read, '
      'mutation or both, with exact generated mutation values', () async {
    final serviceSets = [
      <String>[],
      [authorizedEnvironmentReadServiceId],
      [authorizedEnvironmentMutationServiceId],
      [
        authorizedEnvironmentReadServiceId,
        authorizedEnvironmentMutationServiceId,
      ],
    ];
    final probe = await start(
      options: {
        'count': serviceSets.length,
        'mutation': true,
        'executionServices': serviceSets,
      },
    );
    final tools = await materialize();
    final capturedFiles = files;
    final capturedMutations = mutations;
    context.files = _Files();
    context.mutations = _Files();
    expect(context.requested, [
      AuthorizedEnvironmentFileReadFacet,
      AuthorizedEnvironmentFileMutationFacet,
    ]);
    for (var index = 0; index < tools.length; index++) {
      final tool = tools[index].executable;
      final arguments = await tool.validateAndNormalize({'value': 'data'});
      await tool.describe(arguments, execution);
      await tool.execute(arguments, execution).toList();
      final record = (await _records(probe.connection)).last;
      expect(record['environmentId'], 'tool-environment');
      expect(record['token'], index == 0 ? isNull : isA<String>());
      expect(
        record.containsKey('authority'),
        serviceSets[index].contains(authorizedEnvironmentReadServiceId),
      );
      expect(
        record.containsKey('mutations'),
        serviceSets[index].contains(authorizedEnvironmentMutationServiceId),
      );
      if (record.containsKey('mutations')) {
        expect(record['mutations'], ['created-revision', 'replaced-revision']);
      }
      _expectDenied(await _mutationReplay(probe.connection, record['token']));
    }
    expect(capturedFiles.reads, [
      'directory:',
      'file:probe.txt',
      'directory:',
      'file:probe.txt',
    ]);
    expect(capturedMutations.mutations, [
      for (var index = 0; index < 2; index++) ...[
        {
          'operation': 'create',
          'relativePath': 'created.txt',
          'text': 'new text',
        },
        {
          'operation': 'replace',
          'relativePath': 'created.txt',
          'text': 'replacement text',
          'expectedRevision': 'created-revision',
        },
        {
          'operation': 'delete',
          'relativePath': 'created.txt',
          'expectedRevision': 'replaced-revision',
        },
      ],
    ]);
    expect(context.files.reads, isEmpty);
    expect(context.mutations.mutations, isEmpty);
    expect(context.requested, hasLength(2));
    for (final record in await _records(probe.connection)) {
      if (record['operation'] != 'execute') _expectPrePolicyDenied(record);
    }
  });

  test('approval gate grants mutation only when the exact approved execution '
      'stream is listened to', () async {
    final probe = await start(options: {'read': false, 'mutation': true});
    final tools = await compose();
    final resolved =
        await const ToolInvocationResolver().resolve(
              invocationId: ToolInvocationId('mutation-invocation'),
              proposal: ProviderToolProposal(
                providerCallId: 'mutation-call',
                alias: 'probe_0',
                arguments: {'value': 'data'},
              ),
              tools: tools,
              context: execution,
            )
            as ResolvedToolProposal;
    final required =
        await const ToolPolicyGate().evaluate(
              invocation: resolved.invocation,
              policy: const ApprovalGatedToolPolicy(),
              interruptionId: RunInterruptionId('mutation-approval'),
            )
            as ToolApprovalRequired;
    final run = AgentRun(id: execution.runId, sessionId: execution.sessionId)
      ..start();
    run.interrupt(required.interruption);
    expect(run.state, RunState.waiting);
    expect(required.effects.effects, {ToolEffect.sourceMutation});
    expect(mutations.mutations, isEmpty);
    expect(files.reads, isEmpty);
    for (final record in await _records(probe.connection)) {
      _expectPrePolicyDenied(record);
    }
    _expectDenied(await _mutationReplay(probe.connection, 'unapproved'));
    final allowed = const ToolPolicyGate().approve(
      run.resolveInterruption(
        ToolApprovalResolution(
          interruptionId: required.interruption.id,
          toolInvocationId: resolved.invocation.id,
          approved: true,
        ),
      ),
    );
    expect(allowed.invocation, same(resolved.invocation));
    final stream = run.startToolExecution(allowed).events();
    expect(mutations.mutations, isEmpty);
    expect(
      (await _records(probe.connection)).map((record) => record['operation']),
      ['materialize', 'validate', 'describe'],
    );
    await collectToolExecution(stream);
    expect(mutations.mutations, hasLength(3));
    final token = (await _records(probe.connection)).last['token'];
    expect(token, isA<String>());
    _expectDenied(await _mutationReplay(probe.connection, token));
    expect(mutations.mutations, hasLength(3));
    expect(context.requested, [AuthorizedEnvironmentFileMutationFacet]);
  });

  for (final mismatch in [
    'read Session',
    'mutation Session',
    'Environment',
    'absent read',
    'absent mutation',
  ]) {
    test('$mismatch authority fails before remote materialization', () async {
      final probe = await start(options: {'mutation': true});
      switch (mismatch) {
        case 'read Session':
          files.sessionId = SessionId('foreign-session');
        case 'mutation Session':
          mutations.sessionId = SessionId('foreign-session');
        case 'Environment':
          mutations.environmentId = EnvironmentId('foreign-environment');
        case 'absent read':
          context.unavailable = AuthorizedEnvironmentFileReadFacet;
        case 'absent mutation':
          context.unavailable = AuthorizedEnvironmentFileMutationFacet;
      }
      await expectLater(materialize(), throwsStateError);
      expect(files.reads, isEmpty);
      expect(mutations.mutations, isEmpty);
      expect(await _records(probe.connection), isEmpty);
    });
  }

  for (final facet in ['read', 'mutation']) {
    test(
      'synchronous validation checks captured $facet even for a tool with no '
      'execution services; only fresh materialization reacquires',
      () async {
        final probe = await start(
          options: {
            'mutation': true,
            'executionServices': [<String>[]],
          },
        );
        final tool = (await materialize()).single.executable;
        final captured = facet == 'read' ? files : mutations;
        context.files = _Files();
        context.mutations = _Files();
        captured.bindingFailure = const AuthorizedEnvironmentBindingStale(
          'Retired',
        );
        expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
        captured.bindingFailure = const AuthorizedEnvironmentBindingUnavailable(
          'Unavailable',
        );
        expect(
          tool.validateBinding,
          throwsA(isA<ToolBindingUnavailableException>()),
        );
        expect(context.requested, [
          AuthorizedEnvironmentFileReadFacet,
          AuthorizedEnvironmentFileMutationFacet,
        ]);
        expect(files.reads, isEmpty);
        expect(mutations.mutations, isEmpty);
        final fresh = (await materialize()).single.executable;
        expect(fresh.validateBinding, returnsNormally);
        expect(
          tool.validateBinding,
          throwsA(isA<ToolBindingUnavailableException>()),
        );
        expect(context.requested, [
          AuthorizedEnvironmentFileReadFacet,
          AuthorizedEnvironmentFileMutationFacet,
          AuthorizedEnvironmentFileReadFacet,
          AuthorizedEnvironmentFileMutationFacet,
        ]);
        for (final record in await _records(probe.connection)) {
          _expectPrePolicyDenied(record);
        }
      },
    );
  }

  test(
    'execution cannot substitute another Session for captured authority',
    () async {
      final probe = await start(options: {'mutation': true});
      final tool = (await materialize()).single.executable;
      final arguments = CanonicalToolArguments({'value': 'data'});
      final foreign = ToolExecutionContext(
        sessionId: SessionId('foreign-session'),
        runId: RunId('foreign-run'),
      );
      await expectLater(
        Future.sync(() => tool.describe(arguments, foreign)),
        throwsStateError,
      );
      await expectLater(
        tool.execute(arguments, foreign).toList(),
        throwsStateError,
      );
      expect(
        (await _records(probe.connection)).map((record) => record['operation']),
        ['materialize'],
      );
      expect(files.reads, isEmpty);
      expect(mutations.mutations, isEmpty);
      expect(context.requested, [
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileMutationFacet,
      ]);
      expect(tool.validateBinding, returnsNormally);
    },
  );

  for (final services in [
    [authorizedEnvironmentReadServiceId],
    [authorizedEnvironmentMutationServiceId],
    [
      authorizedEnvironmentReadServiceId,
      authorizedEnvironmentMutationServiceId,
    ],
  ]) {
    test(
      '$services live execution token rejects invented authority, forged IDs, '
      'unapproved services and foreign generation',
      () async {
        final probe = await start(
          options: {
            'hold': 'execute',
            'mutation': true,
            'executionServices': [services],
          },
        );
        final tool = (await materialize()).single.executable;
        final sibling = await start(
          pluginId: 'dev.adele.test.sibling-tool',
          extensionId: 'dev.adele.test.sibling-tool.tools',
        );
        final executing = tool
            .execute(CanonicalToolArguments({'value': 'data'}), execution)
            .toList();
        await _control(probe.connection, 'ready', {'operation': 'execute'});
        final token = (await _records(probe.connection)).last['token'];
        _expectDenied(
          await _control(probe.connection, 'replay', {'token': 'invented'}),
        );
        _expectDenied(
          await _control(sibling.connection, 'replay', {'token': token}),
        );
        _expectDenied(await _mutationReplay(probe.connection, 'invented'));
        _expectDenied(await _mutationReplay(sibling.connection, token));
        for (final id in ['sessionId', 'environmentId', 'runId']) {
          if (services.contains(authorizedEnvironmentReadServiceId)) {
            _expectDenied(
              await _control(probe.connection, 'replay', {
                'token': token,
                'payload': {'relativePath': 'probe.txt', id: 'forged'},
              }),
              'invalid_request',
            );
          }
          if (services.contains(authorizedEnvironmentMutationServiceId)) {
            _expectDenied(
              await _mutationReplay(
                probe.connection,
                token,
                extra: {id: 'forged'},
              ),
              'invalid_request',
            );
          }
        }
        for (final service in [
          if (!services.contains(authorizedEnvironmentReadServiceId))
            authorizedEnvironmentReadServiceId,
          if (!services.contains(authorizedEnvironmentMutationServiceId))
            authorizedEnvironmentMutationServiceId,
          'authorizedEnvironmentProcess',
        ]) {
          _expectDenied(
            service == authorizedEnvironmentMutationServiceId
                ? await _mutationReplay(probe.connection, token)
                : await _control(probe.connection, 'replay', {
                    'token': token,
                    'service': service,
                  }),
            'service_unavailable',
          );
        }
        if (services.contains(authorizedEnvironmentReadServiceId)) {
          _expectDenied(
            await _control(probe.connection, 'replay', {
              'token': token,
              'method': 'authorizedEnvironmentRead.createTextFile',
            }),
            'unknown_method',
          );
          final identity =
              await _control(probe.connection, 'replay', {
                    'token': token,
                    'method': 'authorizedEnvironmentRead.authority',
                    'payload': <String, Object?>{},
                  })
                  as Map;
          expect(identity['payload'], {
            'sessionId': 'tool-session',
            'environmentId': 'tool-environment',
          });
          final read =
              await _control(probe.connection, 'replay', {'token': token})
                  as Map;
          expect(read['ok'], isTrue);
          expect((read['payload'] as Map)['text'], files.text);
        }
        if (services.contains(authorizedEnvironmentMutationServiceId)) {
          final created = await _mutationReplay(probe.connection, token) as Map;
          expect(created['ok'], isTrue);
          expect(created['payload'], {'revision': 'created-revision'});
          _expectDenied(
            await _control(probe.connection, 'replay', {
              'token': token,
              'service': authorizedEnvironmentMutationServiceId,
              'method': 'authorizedEnvironmentMutation.readFile',
            }),
            'unknown_method',
          );
        }
        expect(context.requested, [
          AuthorizedEnvironmentFileReadFacet,
          AuthorizedEnvironmentFileMutationFacet,
        ]);
        await _control(probe.connection, 'release', {'operation': 'execute'});
        await executing;
        _expectDenied(
          await _control(probe.connection, 'replay', {'token': token}),
        );
        _expectDenied(await _mutationReplay(probe.connection, token));
      },
    );
  }

  for (final facet in ['read', 'mutation']) {
    for (final operation in ['materialize', 'describe', 'execute']) {
      test('$facet retirement before $operation settlement rejects late '
          'success and revokes the token', () async {
        final probe = await start(
          options: {'hold': operation, 'mutation': true},
        );
        final tools = operation == 'materialize' ? null : await materialize();
        final arguments = CanonicalToolArguments({'value': 'data'});
        final Future<Object?> pending = switch (operation) {
          'materialize' => materialize(),
          'describe' => tools!.single.executable.describe(arguments, execution),
          _ => tools!.single.executable.execute(arguments, execution).toList(),
        };
        final failed = expectLater(
          pending,
          throwsA(isA<StaleToolBindingException>()),
        );
        await _control(probe.connection, 'ready', {'operation': operation});
        (facet == 'read' ? files : mutations).bindingFailure =
            const AuthorizedEnvironmentBindingStale('Retired during operation');
        await _control(probe.connection, 'release', {'operation': operation});
        await failed;
        final token = (await _records(probe.connection)).last['token'];
        _expectDenied(
          await _control(probe.connection, 'replay', {'token': token}),
        );
        _expectDenied(await _mutationReplay(probe.connection, token));
      });
    }
  }

  for (final operation in ['materialize', 'describe']) {
    test('exact retirement rejects authority-free held $operation '
        'late result', () async {
      final probe = await start(options: {'hold': operation});
      final tools = operation == 'materialize' ? null : await materialize();
      final Future<Object?> pending = operation == 'materialize'
          ? materialize()
          : tools!.single.executable.describe(
              CanonicalToolArguments({'value': 'data'}),
              execution,
            );
      final failed = expectLater(
        pending,
        throwsA(isA<StaleToolBindingException>()),
      );
      await _control(probe.connection, 'ready', {'operation': operation});
      final token = (await _records(probe.connection)).last['token'];
      await probe.retire();
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': token}),
      );
      await _control(probe.connection, 'release', {'operation': operation});
      await failed;
      expect(extensions.discover(modelToolContributions), isEmpty);
      expect(probe.connection.isClosed, isFalse);
    });
  }

  for (final facet in ['read', 'mutation']) {
    test('$facet retirement after terminal but before stream done rejects '
        'settlement and revokes execution authority', () async {
      final probe = await start(options: {'hold': 'done', 'mutation': true});
      final tool = (await materialize()).single.executable;
      final terminal = Completer<void>();
      final received = <ToolExecutionEvent>[];
      final failed = expectLater(
        collectToolExecution(
          tool
              .execute(CanonicalToolArguments({'value': 'data'}), execution)
              .map((event) {
                received.add(event);
                if (event is ToolExecutionTerminal) terminal.complete();
                return event;
              }),
        ),
        throwsA(isA<StaleToolBindingException>()),
      );
      await terminal.future.timeout(_bound);
      await _control(probe.connection, 'ready', {'operation': 'done'});
      expect(received, hasLength(4));
      expect(received.last, isA<ToolExecutionTerminal>());
      final token = (await _records(probe.connection)).last['token'];
      final liveMutation =
          await _mutationReplay(probe.connection, token) as Map;
      expect(
        liveMutation['ok'],
        isTrue,
        reason: 'Terminal is not stream done.',
      );
      (facet == 'read' ? files : mutations).bindingFailure =
          const AuthorizedEnvironmentBindingStale(
            'Retired between terminal and stream done',
          );
      await _control(probe.connection, 'release', {'operation': 'done'});
      await failed;
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': token}),
      );
      _expectDenied(await _mutationReplay(probe.connection, token));
      expect(received, hasLength(4));
      expect(probe.connection.isClosed, isFalse);
    });
  }

  for (final facet in ['read', 'mutation']) {
    test('stream cancellation immediately revokes pending $facet calls without '
        'waiting for arbitrary provider work', () async {
      final probe = await start(options: {'hold': 'execute', 'mutation': true});
      final tool = (await materialize()).single.executable;
      final subscription = tool
          .execute(CanonicalToolArguments({'value': 'data'}), execution)
          .listen((_) {});
      addTearDown(subscription.cancel);
      await _control(probe.connection, 'ready', {'operation': 'execute'});
      final token = (await _records(probe.connection)).last['token'];
      final sibling = tool
          .execute(CanonicalToolArguments({'value': 'sibling'}), execution)
          .toList();
      await _control(probe.connection, 'ready', {'operation': 'execute:2'});
      final siblingToken = (await _records(probe.connection)).last['token'];
      expect(siblingToken, isNot(token));
      final captured = facet == 'read' ? files : mutations;
      captured.release = Completer<void>();
      captured.entered = Completer<void>();
      addTearDown(captured.unblock);
      final pendingCall = facet == 'read'
          ? _control(probe.connection, 'replay', {'token': token})
          : _mutationReplay(probe.connection, token);
      await captured.entered.future.timeout(_bound);
      final cancelling = subscription.cancel();
      _expectDenied(await pendingCall);
      _expectDenied(
        await _control(probe.connection, 'replay', {'token': token}),
      );
      _expectDenied(await _mutationReplay(probe.connection, token));
      expect(captured.release!.isCompleted, isFalse);
      captured.unblock();
      final siblingMutation =
          await _mutationReplay(probe.connection, siblingToken) as Map;
      expect(
        siblingMutation['ok'],
        isTrue,
        reason: 'Cancellation revokes only the exact execute invocation.',
      );
      await _control(probe.connection, 'release', {'operation': 'execute'});
      await cancelling.timeout(_bound);
      await sibling.timeout(_bound);
      _expectDenied(await _mutationReplay(probe.connection, siblingToken));
      await _control(probe.connection, 'records');
      expect(tool.validateBinding, returnsNormally);
      expect(await materialize(), hasLength(1));
    });
  }

  const allServices = [
    authorizedEnvironmentReadServiceId,
    authorizedEnvironmentMutationServiceId,
    authorizedEnvironmentProcessServiceId,
  ];

  for (final services in [
    [authorizedEnvironmentProcessServiceId],
    [authorizedEnvironmentReadServiceId, authorizedEnvironmentProcessServiceId],
    [
      authorizedEnvironmentMutationServiceId,
      authorizedEnvironmentProcessServiceId,
    ],
    allServices,
  ]) {
    for (final mismatch in ['Session', 'Environment', 'absent']) {
      if (mismatch == 'Environment' && services.length == 1) continue;
      test(
        '$services rejects process $mismatch before remote materialization',
        () async {
          final probe = await start(
            options: {
              'metadata': {'hostServices': services},
              'executionServices': [<String>[]],
            },
          );
          switch (mismatch) {
            case 'Session':
              context.process.sessionId = SessionId('foreign-session');
            case 'Environment':
              context.process.environmentId = EnvironmentId(
                'foreign-environment',
              );
            case 'absent':
              context.unavailable = AuthorizedEnvironmentProcessFacet;
          }
          await expectLater(materialize(), throwsStateError);
          expect(await _records(probe.connection), isEmpty);
          expect(context.process.processRequests, isEmpty);
        },
      );
    }
  }

  for (final facet in ['read', 'mutation', 'process']) {
    test(
      'all three captured bindings validate synchronously, including $facet unused by route',
      () async {
        await start(
          options: {
            'metadata': {'hostServices': allServices},
            'executionServices': [<String>[]],
          },
        );
        final tool = (await materialize()).single.executable;
        final captured = switch (facet) {
          'read' => context.files,
          'mutation' => context.mutations,
          _ => context.process,
        };
        context.files = _Files();
        context.mutations = _Files();
        context.process = _Files();
        captured.bindingFailure = const AuthorizedEnvironmentBindingStale(
          'Retired',
        );
        expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
        captured.bindingFailure = const AuthorizedEnvironmentBindingUnavailable(
          'Unavailable',
        );
        expect(
          tool.validateBinding,
          throwsA(isA<ToolBindingUnavailableException>()),
        );
        expect(context.requested, [
          AuthorizedEnvironmentFileReadFacet,
          AuthorizedEnvironmentFileMutationFacet,
          AuthorizedEnvironmentProcessFacet,
        ]);
        expect(
          (await materialize()).single.executable.validateBinding,
          returnsNormally,
        );
        expect(
          tool.validateBinding,
          throwsA(isA<ToolBindingUnavailableException>()),
        );
      },
    );
  }

  test(
    'process capture grants no pre-policy authority and each route narrows the full dependency set',
    () async {
      for (final services in [
        <String>[],
        [authorizedEnvironmentReadServiceId],
      ]) {
        final probe = await start(
          options: {
            'metadata': {'hostServices': allServices},
            'hold': 'execute',
            'executionServices': [services],
          },
        );
        final tool = (await materialize()).single;
        final arguments = await tool.executable.validateAndNormalize({
          'value': 'data',
        });
        await tool.executable.describe(arguments, execution);
        _expectDenied(await _processReplay(probe.connection, 'invented'));
        final pending = tool.executable.execute(arguments, execution).toList();
        await _control(probe.connection, 'ready', {'operation': 'execute'});
        final token = (await _records(probe.connection)).last['token'];
        _expectDenied(
          await _processReplay(probe.connection, token),
          token == null ? 'host_invocation_unavailable' : 'service_unavailable',
        );
        await _control(probe.connection, 'release', {'operation': 'execute'});
        await pending;
        await probe.close();
      }
      expect(context.process.processRequests, isEmpty);
      expect(context.requested, [
        for (var index = 0; index < 2; index++) ...[
          AuthorizedEnvironmentFileReadFacet,
          AuthorizedEnvironmentFileMutationFacet,
          AuthorizedEnvironmentProcessFacet,
        ],
      ]);
    },
  );

  test(
    'process binding retirement rejects late authority-free materialization and description',
    () async {
      for (final operation in ['materialize', 'describe']) {
        final probe = await start(
          options: {
            'metadata': {
              'hostServices': [authorizedEnvironmentProcessServiceId],
            },
            'executionServices': [<String>[]],
            'hold': operation,
          },
        );
        final tool = operation == 'describe'
            ? (await materialize()).single.executable
            : null;
        final pending = operation == 'materialize'
            ? materialize()
            : tool!.describe(
                CanonicalToolArguments({'value': 'data'}),
                execution,
              );
        final failed = expectLater(
          pending,
          throwsA(isA<StaleToolBindingException>()),
        );
        await _control(probe.connection, 'ready', {'operation': operation});
        context.process.bindingFailure =
            const AuthorizedEnvironmentBindingStale('Retired during operation');
        await _control(probe.connection, 'release', {'operation': operation});
        await failed;
        expect(context.process.processRequests, isEmpty);
        await probe.close();
        context.process = _Files();
      }
    },
  );

  test(
    'Command AOT uses only captured process authority after approval and forwards progress',
    () async {
      final connection = await host.startPlugin(
        pluginId: 'dev.adele.plugin.command-tools',
        artifactUri: commandArtifact.uri,
      );
      addTearDown(connection.close);
      final activation = await PluginBackendActivation.registerAdvertised(
        connection: connection,
        capabilities: capabilities,
        extensions: extensions,
        adapters: createRemoteExtensionAdapters(),
      );
      addTearDown(activation.close);
      final tools = await compose();
      final captured = context.process;
      context.process = _Files();
      expect(context.requested, [AuthorizedEnvironmentProcessFacet]);
      final resolved =
          await const ToolInvocationResolver().resolve(
                invocationId: ToolInvocationId('process-invocation'),
                proposal: ProviderToolProposal(
                  providerCallId: 'process-call',
                  alias: 'run_command',
                  arguments: {
                    'program': 'git',
                    'arguments': ['diff', '--check'],
                  },
                ),
                tools: tools,
                context: execution,
              )
              as ResolvedToolProposal;
      final required =
          await const ToolPolicyGate().evaluate(
                invocation: resolved.invocation,
                policy: const ApprovalGatedToolPolicy(),
                interruptionId: RunInterruptionId('process-approval'),
              )
              as ToolApprovalRequired;
      expect(required.effects.effects, {ToolEffect.processExecution});
      expect(captured.processRequests, isEmpty);
      expect(files.reads, isEmpty);
      expect(mutations.mutations, isEmpty);
      final run = AgentRun(id: execution.runId, sessionId: execution.sessionId)
        ..start();
      run.interrupt(required.interruption);
      final allowed = const ToolPolicyGate().approve(
        run.resolveInterruption(
          ToolApprovalResolution(
            interruptionId: required.interruption.id,
            toolInvocationId: resolved.invocation.id,
            approved: true,
          ),
        ),
      );
      final events = run.startToolExecution(allowed).events();
      expect(captured.processRequests, isEmpty);
      final observed = await collectToolExecution(events);
      expect(observed.progress.map((event) => event.kind), [
        ToolProgressKind.stdout,
        ToolProgressKind.stderr,
      ]);
      expect(observed.outcome.disposition, ToolOutcomeDisposition.success);
      expect(observed.outcome.hostData['exitCode'], 7);
      expect(observed.outcome.hostData['environmentId'], 'tool-environment');
      expect(captured.processRequests.single.arguments, ['diff', '--check']);
      expect(context.process.processRequests, isEmpty);
      expect(context.requested, [AuthorizedEnvironmentProcessFacet]);
      captured.bindingFailure = const AuthorizedEnvironmentBindingStale(
        'Retired process',
      );
      expect(
        tools.tools.single.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
    },
  );

  for (final cleanupMode in ['hangs', 'throws', 'fails asynchronously']) {
    test(
      'Command generated process failure settles when producer cleanup $cleanupMode',
      () async {
        final connection = await host.startPlugin(
          pluginId: 'dev.adele.plugin.command-tools',
          artifactUri: commandArtifact.uri,
        );
        addTearDown(connection.close);
        final activation = await PluginBackendActivation.registerAdvertised(
          connection: connection,
          capabilities: capabilities,
          extensions: extensions,
          adapters: createRemoteExtensionAdapters(),
        );
        addTearDown(activation.close);
        final started = Completer<void>();
        final cleanup = Completer<void>();
        var cancellations = 0;
        final source = StreamController<EnvironmentProcessEvent>(
          sync: true,
          onListen: started.complete,
          onCancel: () {
            cancellations++;
            if (cleanupMode == 'throws') {
              throw StateError('private cleanup failure');
            }
            if (cleanupMode == 'fails asynchronously') {
              return Future<void>.error(StateError('private cleanup failure'));
            }
            return cleanup.future;
          },
        );
        addTearDown(() async {
          if (!cleanup.isCompleted) cleanup.complete();
          await source.close();
        });
        context.process.processStream = source.stream;
        final tool = (await materialize()).single.executable;
        final arguments = await tool.validateAndNormalize({'program': 'fails'});
        final pending = collectToolExecution(
          tool.execute(arguments, execution),
        );
        await started.future.timeout(_bound);
        source.addError(
          const EnvironmentFailure(
            code: 'process_failed',
            message: 'Primary failure.',
            details: {'evidence': 'preserved'},
          ),
        );
        final observed = await pending.timeout(_bound);
        expect(observed.outcome.disposition, ToolOutcomeDisposition.failure);
        expect(observed.outcome.failureKind, ToolFailureKind.domain);
        expect(observed.outcome.effectCertainty, EffectCertainty.uncertain);
        expect(observed.outcome.hostData['code'], 'process_failed');
        expect(observed.outcome.hostData['message'], 'Primary failure.');
        expect(observed.outcome.hostData['details'], {'evidence': 'preserved'});
        expect(
          observed.outcome.hostDiagnostic,
          isNot(contains('cleanup failure')),
        );
        expect(cancellations, 1);
        expect(cleanup.isCompleted, isFalse);
        expect(connection.isClosed, isFalse);
        expect(tool.validateBinding, returnsNormally);
        // A fresh operation settles on the same connection while old cleanup hangs.
        context.process.processStream = null;
        final next = await collectToolExecution(
          tool.execute(arguments, execution),
        ).timeout(_bound);
        expect(next.outcome.disposition, ToolOutcomeDisposition.success);
        expect(context.process.processRequests, hasLength(2));
        expect(cancellations, 1);
      },
    );
  }

  for (final retire in [false, true]) {
    test(
      'Command ${retire ? 'retirement' : 'consumer cancellation'} cancels an idle process facet',
      () async {
        final connection = await host.startPlugin(
          pluginId: 'dev.adele.plugin.command-tools',
          artifactUri: commandArtifact.uri,
        );
        addTearDown(connection.close);
        final activation = await PluginBackendActivation.registerAdvertised(
          connection: connection,
          capabilities: capabilities,
          extensions: extensions,
          adapters: createRemoteExtensionAdapters(),
        );
        addTearDown(activation.close);
        final started = Completer<void>();
        final cancelled = Completer<void>();
        final source = StreamController<EnvironmentProcessEvent>(
          sync: true,
          onListen: started.complete,
          onCancel: cancelled.complete,
        );
        addTearDown(source.close);
        context.process.processStream = source.stream;
        final tool = (await materialize()).single.executable;
        final arguments = await tool.validateAndNormalize({'program': 'idle'});
        final errors = <Object>[];
        final done = Completer<void>();
        final subscription = tool
            .execute(arguments, execution)
            .listen(
              (_) => fail('Idle process must not emit output.'),
              onError: errors.add,
              onDone: done.complete,
            );
        addTearDown(subscription.cancel);
        await started.future.timeout(_bound);
        if (retire) {
          await activation.retire().timeout(_bound);
          await done.future.timeout(_bound);
          expect(errors, [isA<StaleToolBindingException>()]);
        } else {
          await subscription.cancel().timeout(_bound);
          expect(errors, isEmpty);
        }
        await cancelled.future.timeout(_bound);
        expect(context.process.processRequests, hasLength(1));
      },
    );
  }

  for (final terminate in [false, true]) {
    test(
      '${terminate ? 'connection termination' : 'exact retirement'} makes '
      'retained proxies stale without affecting sibling or replacement',
      () async {
        final original = await start(
          options: {'hold': 'execute', 'mutation': true},
        );
        final binding = extensions.discover(modelToolContributions).single;
        final retained = binding.value;
        final tool = (await materialize()).single.executable;
        final sibling = await start(
          pluginId: 'dev.adele.test.sibling-tool',
          extensionId: 'dev.adele.test.sibling-tool.tools',
        );
        final failed = expectLater(
          tool
              .execute(CanonicalToolArguments({'value': 'data'}), execution)
              .toList(),
          throwsA(isA<StaleToolBindingException>()),
        );
        await _control(original.connection, 'ready', {'operation': 'execute'});
        final token = (await _records(original.connection)).last['token'];
        if (terminate) {
          final terminated = original.connection.terminated.timeout(_bound);
          await expectLater(
            _control(original.connection, 'terminate'),
            throwsA(isA<PluginRemoteFailure>()),
          );
          await terminated;
        } else {
          await original.retire().timeout(_bound);
          _expectDenied(
            await _control(original.connection, 'replay', {'token': token}),
          );
          _expectDenied(await _mutationReplay(original.connection, token));
          await _control(original.connection, 'release', {
            'operation': 'execute',
          });
        }
        await failed;
        expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
        await expectLater(
          retained.materialize(context),
          throwsA(isA<StaleExtensionBinding>()),
        );
        expect(
          extensions
              .discover(modelToolContributions)
              .map((binding) => binding.id.value),
          ['dev.adele.test.sibling-tool.tools'],
        );
        await original.connection.close();
        final replacement = await start(options: {'mutation': true});
        final freshBinding = extensions.discover(modelToolContributions).last;
        final fresh = (await freshBinding.value.materialize(context)).single;
        expect(fresh.executable.validateBinding, returnsNormally);
        _expectDenied(
          await _control(replacement.connection, 'replay', {'token': token}),
        );
        _expectDenied(await _mutationReplay(replacement.connection, token));
        await original.close();
        expect(replacement.connection.isClosed, isFalse);
        expect(sibling.connection.isClosed, isFalse);
        expect(tool.validateBinding, throwsA(isA<StaleToolBindingException>()));
        expect(host.isClosed, isFalse);
      },
    );
  }
}

Future<Object?> _control(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);

Future<List<Map<String, Object?>>> _records(
  PluginBackendConnection connection,
) async => [
  for (final record in (await _control(connection, 'records'))! as List)
    Map<String, Object?>.from(record as Map),
];

Future<Object?> _mutationReplay(
  PluginBackendConnection connection,
  Object? token, {
  Map<String, Object?> extra = const {},
}) => _control(connection, 'replay', {
  'token': token,
  'service': authorizedEnvironmentMutationServiceId,
  'method': authorizedEnvironmentMutationServiceCreateTextFileId,
  'payload': {
    'relativePath': 'manual.txt',
    'text': 'manual mutation',
    ...extra,
  },
});

Future<Object?> _processReplay(
  PluginBackendConnection connection,
  Object? token,
) => _control(connection, 'replay', {
  'token': token,
  'service': authorizedEnvironmentProcessServiceId,
  'method': authorizedEnvironmentProcessServiceRunForegroundProcessId,
  'payload': {
    'request': {
      'program': 'forbidden',
      'arguments': <String>[],
      'relativeWorkingDirectory': '',
      'timeoutSeconds': 1,
    },
  },
});

void _expectPrePolicyDenied(Map<String, Object?> record) {
  expect(record.containsKey('token'), isFalse);
  final attempts = record['attempts']! as Map;
  _expectDenied(attempts['read']);
  _expectDenied(attempts['mutation']);
}

void _expectDenied(
  Object? response, [
  String code = 'host_invocation_unavailable',
]) {
  final envelope = response! as Map;
  expect(envelope['ok'], isFalse);
  expect((envelope['error'] as Map)['code'], code);
  expect(envelope.containsKey('payload'), isFalse);
}

final class _Context implements ModelToolHostContext {
  _Context(this.files, this.mutations);

  _Files files;
  _Files mutations;
  _Files process = _Files();
  Type? unavailable;
  final requested = <Type>[];

  @override
  final sessionId = SessionId('tool-session');

  @override
  Future<T> requireHostService<T extends Object>() async {
    requested.add(T);
    if (T != unavailable) {
      if (T == AuthorizedEnvironmentFileReadFacet) return files as T;
      if (T == AuthorizedEnvironmentFileMutationFacet) return mutations as T;
      if (T == AuthorizedEnvironmentProcessFacet) return process as T;
    }
    throw StateError('No authority granted for $T.');
  }
}

final class _Files
    implements
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileMutationFacet,
        AuthorizedEnvironmentProcessFacet {
  String text = 'Captured authority';
  Object? bindingFailure;
  final reads = <String>[];
  final mutations = <Map<String, Object?>>[];
  final processRequests = <EnvironmentForegroundProcessRequest>[];
  Stream<EnvironmentProcessEvent>? processStream;
  Completer<void> entered = Completer<void>();
  Completer<void>? release;

  @override
  SessionId sessionId = SessionId('tool-session');
  @override
  EnvironmentId environmentId = EnvironmentId('tool-environment');

  @override
  void validateBinding() {
    if (bindingFailure case final Object error) throw error;
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    reads.add('file:$relativePath');
    if (!entered.isCompleted) entered.complete();
    await release?.future;
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: utf8.encode(text).length,
      revision: 'opaque-revision',
    );
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    reads.add('directory:$relativePath');
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: const [
        EnvironmentDirectoryEntry(
          name: 'probe.txt',
          relativePath: 'probe.txt',
          kind: EnvironmentDirectoryEntryKind.file,
        ),
      ],
    );
  }

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) async {
    mutations.add({
      'operation': 'create',
      'relativePath': relativePath,
      'text': text,
    });
    if (!entered.isCompleted) entered.complete();
    await release?.future;
    return EnvironmentTextFileCreation(revision: 'created-revision');
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    mutations.add({
      'operation': 'replace',
      'relativePath': relativePath,
      'text': replacementText,
      'expectedRevision': expectedRevision,
    });
    return const EnvironmentTextFileReplacement(revision: 'replaced-revision');
  }

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    mutations.add({
      'operation': 'delete',
      'relativePath': relativePath,
      'expectedRevision': expectedRevision,
    });
  }

  void unblock() {
    if (release != null && !release!.isCompleted) release!.complete();
  }

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) {
    processRequests.add(request);
    return processStream ??
        Stream.fromIterable([
          for (final stream in EnvironmentProcessOutputStream.values)
            EnvironmentProcessEvent(
              kind: EnvironmentProcessEventKind.output,
              output: EnvironmentProcessOutput(
                stream: stream,
                text: stream == EnvironmentProcessOutputStream.stdout
                    ? 'out\n'
                    : 'err\n',
              ),
              completed: null,
            ),
          EnvironmentProcessEvent(
            kind: EnvironmentProcessEventKind.completed,
            output: null,
            completed: EnvironmentProcessCompleted(
              termination: EnvironmentProcessTermination.exited,
              exitCode: 7,
              stdoutTruncated: false,
              stderrTruncated: false,
            ),
          ),
        ]);
  }
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
