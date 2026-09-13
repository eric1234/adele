@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/plugins/stock_backend_plugins.dart';
import 'package:adele_desktop/plugins/stock_git_environment.dart';
import 'package:adele_desktop/plugins/stock_openai.dart';
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';

const String _sourcePath = 'lib/task_answer.dart';
const String _taskText = 'const taskAnswer = "task-worktree-only";\n';
const String _agentsText =
    'C1 Task guidance: report the inspected value and never change source.\n';
const String _projectText = 'const projectAnswer = "project-source-only";\n';
const String _projectAgentsText = 'Project-only guidance must not be used.\n';
const String _prompt =
    'Find taskAnswer using search, read the discovered file, and report its value.';
const String _answer =
    'lib/task_answer.dart declares taskAnswer as "task-worktree-only". '
    'The proposed mutation and command were denied; no source was changed.';

void main() {
  late Directory artifacts;
  late String dartaotruntime;
  late File hostArtifact;
  late File gitArtifact;
  late File openAiArtifact;

  setUpAll(() async {
    final Directory repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp(
      'adele-normal-chatgpt-aot-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    final String dart = _dartExecutable();
    dartaotruntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File('${artifacts.path}/host.aot');
    gitArtifact = File('${artifacts.path}/git-environment.aot');
    openAiArtifact = File('${artifacts.path}/openai.aot');
    // Use the normal artifact boundary, compiling each real backend just once.
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
        stage: 'normal-chatgpt-host',
      ),
      (
        entrypoint:
            'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
        artifact: gitArtifact,
        stage: 'normal-chatgpt-git',
      ),
      (
        entrypoint:
            'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        artifact: openAiArtifact,
        stage: 'normal-chatgpt-openai',
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: target.stage,
      );
    }
  });

  test(
    'normal ChatGPT Run reads its Task, denies writes and commands, and retains Chat',
    () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-normal-chatgpt-run-',
      );
      addTearDown(() => container.delete(recursive: true));
      final Directory source = Directory('${container.path}/project');
      await Directory('${source.path}/lib').create(recursive: true);
      final File sourceFile = File('${source.path}/$_sourcePath');
      await sourceFile.writeAsString(_taskText);
      await File('${source.path}/AGENTS.md').writeAsString(_agentsText);
      await _git(source, ['init', '--initial-branch=main']);
      await _git(source, ['add', '.']);
      await _git(source, ['commit', '-m', 'Fixture baseline']);

      // This is a private, non-expiring fake credential, never a user credential.
      final File credentials = File('${container.path}/credentials.json');
      final String credentialText = jsonEncode({
        'version': 1,
        'instances': {
          'fixture': {
            'revision': 1,
            'credential': {
              'idToken': _idToken('c1-fixture-account'),
              'accessToken': 'c1-fixture-chatgpt-access-token',
              'refreshToken': 'c1-fixture-refresh-never-used',
              'accountId': 'c1-fixture-account',
              'fedRamp': false,
            },
          },
        },
      });
      await credentials.writeAsString(credentialText, flush: true);

      final List<Map<String, Object?>> outbound = [];
      final List<(Object, StackTrace)> endpointFailures = [];
      String? discoveredPath;
      String? observedRevision;
      final HttpServer responses = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final StreamSubscription<HttpRequest> subscription = responses.listen((
        HttpRequest request,
      ) {
        unawaited(() async {
          try {
            expect(request.method, 'POST');
            expect(request.uri.path, '/backend-api/codex/responses');
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer c1-fixture-chatgpt-access-token',
            );
            expect(
              request.headers.value('ChatGPT-Account-ID'),
              'c1-fixture-account',
            );
            expect(request.headers.value('X-OpenAI-Fedramp'), isNull);
            expect(
              request.headers.value(HttpHeaders.acceptHeader),
              'text/event-stream',
            );
            final Map<String, Object?> body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, Object?>;
            outbound.add(body);
            expect(body['model'], 'gpt-6-astra');
            expect(body['store'], isFalse);
            expect(body['stream'], isTrue);
            expect(body['parallel_tool_calls'], isTrue);
            expect(body['include'], ['reasoning.encrypted_content']);
            expect(body, isNot(contains('max_output_tokens')));
            expect(body, isNot(contains('previous_response_id')));
            expect(body['instructions'], contains(_agentsText));
            expect(body['instructions'], isNot(contains(_projectAgentsText)));
            final List<Map<String, Object?>> tools =
                (body['tools']! as List<Object?>).cast<Map<String, Object?>>();
            expect(
              tools.map((tool) => tool['name']),
              unorderedEquals([
                'search',
                'read_file',
                'apply_patch',
                'create_file',
                'delete_file',
                'run_command',
              ]),
            );
            for (final String forbidden in [
              'environmentId',
              'taskId',
              'providerId',
              'worktreePath',
            ]) {
              expect(jsonEncode(tools), isNot(contains(forbidden)));
            }
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            switch (outbound.length) {
              case 1:
                expect(body['input'], [
                  {
                    'type': 'message',
                    'role': 'user',
                    'content': [
                      {'type': 'input_text', 'text': _prompt},
                    ],
                  },
                ]);
                _output(
                  request.response,
                  _call('search', 'search', {'query': 'const taskAnswer'}),
                );
              case 2:
                final String searchOutput = _toolOutput(body, 'search');
                final Map<String, Object?> match =
                    jsonDecode(
                          searchOutput
                              .split('\n')
                              .singleWhere((line) => line.startsWith('{')),
                        )
                        as Map<String, Object?>;
                discoveredPath = match['relativePath']! as String;
                expect(discoveredPath, _sourcePath);
                expect(searchOutput, contains('task-worktree-only'));
                expect(searchOutput, isNot(contains('project-source-only')));
                _output(
                  request.response,
                  _call('read', 'read_file', {'relativePath': discoveredPath}),
                );
              case 3:
                final String readOutput = _toolOutput(body, 'read');
                expect(
                  readOutput,
                  startsWith('File: ${jsonEncode(_sourcePath)}'),
                );
                expect(readOutput, contains(_taskText));
                expect(readOutput, isNot(contains('project-source-only')));
                observedRevision =
                    jsonDecode(
                          readOutput
                              .split('\n')
                              .singleWhere(
                                (line) => line.startsWith('Revision: '),
                              )
                              .substring('Revision: '.length),
                        )
                        as String;
                expect(observedRevision, isNotEmpty);
                // Both proposals are valid; denial must come from normal policy,
                // not malformed arguments, missing tools, or failed execution.
                _output(
                  request.response,
                  _call('patch', 'apply_patch', {
                    'relativePath': discoveredPath,
                    'expectedRevision': observedRevision,
                    'edits': [
                      {
                        'search': 'task-worktree-only',
                        'replace': 'must-not-change',
                      },
                    ],
                  }),
                );
                _output(
                  request.response,
                  _call('command', 'run_command', {
                    'program': 'touch',
                    'arguments': ['run-command-marker'],
                    'timeoutSeconds': 5,
                  }),
                );
              case 4:
                expect(
                  _toolOutput(body, 'patch').toLowerCase(),
                  contains('denied'),
                );
                expect(
                  _toolOutput(body, 'command').toLowerCase(),
                  contains('denied'),
                );
                _output(request.response, {
                  'type': 'message',
                  'id': 'message-final',
                  'role': 'assistant',
                  'status': 'completed',
                  'content': [
                    {
                      'type': 'output_text',
                      'text': _answer,
                      'annotations': <Object?>[],
                    },
                  ],
                });
              default:
                fail('Unexpected Responses invocation ${outbound.length}.');
            }
            _sse(request.response, {
              'type': 'response.completed',
              'response': {
                'id': 'response-${outbound.length}',
                'model': 'gpt-6-astra',
              },
            });
          } on Object catch (error, stack) {
            endpointFailures.add((error, stack));
          } finally {
            await request.response.close();
          }
        }());
      });
      addTearDown(() async {
        await subscription.cancel();
        await responses.close(force: true);
      });

      final AdeleRuntime runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'c1-fixture'),
      );
      addTearDown(runtime.close);
      await bootstrapStockBackendPlugins(
        runtime.plugins,
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        gitEnvironmentArtifactPath: gitArtifact.path,
        openaiArtifactPath: openAiArtifact.path,
        chatGptConfiguration: StockChatGptConfiguration(
          credentialFile: credentials.path,
          model: 'gpt-6-astra',
          clientId: 'fixture',
          instanceId: 'fixture',
          issuer: Uri.parse(
            'http://${responses.address.address}:${responses.port}',
          ),
          endpoint: Uri.parse(
            'http://${responses.address.address}:${responses.port}/backend-api/codex/responses',
          ),
        ),
        onModelActivationFailure: Error.throwWithStackTrace,
      );
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.plugins.registry, same(runtime.registry));
      expect(
        runtime.registry.providersFor(modelProviderCapability).single.id,
        stockChatGptProviderId,
      );
      expect(
        runtime.registry.providersFor(environmentProviderCapability).single.id,
        stockGitEnvironmentProviderId,
      );
      expect(outbound, isEmpty);
      final Project project = runtime.lifecycle.createProject(source.uri);
      final TaskCreationResult created = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Inspect the Task without mutation',
      );
      expect(runtime.store.project(project.id), same(project));
      expect(runtime.store.task(created.task.id), same(created.task));
      expect(created.task.projectId, project.id);
      expect(
        runtime.store.primaryEnvironmentFor(created.task.id),
        same(created.environment),
      );
      final Session session = runtime.lifecycle.createSession(
        taskId: created.task.id,
        strategyId: chatStrategyId,
      );
      expect(runtime.store.session(session.id), same(session));
      expect(session.taskId, created.task.id);
      expect(session.strategyId, chatStrategyId);
      final SessionEnvironmentAuthority authority = runtime.store
          .requireSessionAuthority(session.id);
      expect(authority.taskId, created.task.id);
      expect(authority.environmentId, created.environment.id);

      // Only fixture corroboration inspects stock-owned provider state. The
      // controller and tools receive the canonical Session, never this path.
      final Directory worktree = Directory(
        created.environment.providerState!['worktreePath']! as String,
      );
      expect(await File('${worktree.path}/.git').exists(), isTrue);
      expect(worktree.path, isNot(source.path));
      expect(
        await File('${worktree.path}/$_sourcePath').readAsString(),
        _taskText,
      );
      // Establish distinct staged, unstaged, and untracked Project data after
      // Task creation, plus a dirty Task fixture that must also survive the Run.
      await sourceFile.writeAsString('const projectStaged = 1;\n');
      await _git(source, ['add', _sourcePath]);
      await sourceFile.writeAsString(_projectText);
      await File('${source.path}/AGENTS.md').writeAsString(_projectAgentsText);
      await File(
        '${source.path}/scratch.txt',
      ).writeAsString('Project scratch.\n');
      await File(
        '${worktree.path}/scratch.txt',
      ).writeAsString('Task scratch.\n');
      final Map<String, Object?> projectBefore = await _sourceSnapshot(source);
      final Map<String, Object?> taskBefore = await _sourceSnapshot(worktree);
      expect(projectBefore['status'], isNotEmpty);
      expect(projectBefore['staged'], isNotEmpty);
      expect(taskBefore['status'], isNotEmpty);

      final ChatController controller = ChatController(
        runtime: runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: 'gpt-6-astra',
        runIds: MonotonicRunIdSource(seed: 'c1-fixture'),
      );
      addTearDown(controller.close);
      expect(controller.snapshot.entries, isEmpty);
      expect(controller.currentRun, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.submit(_prompt), isTrue);
      final Future<void>? running = controller.activeRunFuture;
      expect(running, isNotNull);
      expect(controller.submit('Duplicate must not enter history.'), isFalse);
      await running!;
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }

      expect(controller.failure, isNull);
      expect(controller.activeRunFuture, isNull);
      final AgentRun run = controller.currentRun!.run;
      expect(run.id, RunId('run-c1-fixture-1'));
      expect(run.sessionId, session.id);
      expect(run.state, RunState.completed);
      expect(run.failure, isNull);
      expect(run.interruptions, isEmpty);
      expect(outbound, hasLength(4));
      final ChatSessionSnapshot snapshot = controller.snapshot;
      expect(snapshot.id, session.id);
      expect(snapshot.entries, [
        isA<ChatUserMessage>(),
        isA<ChatAssistantMessage>(),
      ]);
      expect(snapshot.entries.map((entry) => entry.content), [
        _prompt,
        _answer,
      ]);
      expect(
        runtime.chat.sessions.obtain(session.id).snapshot().entries,
        snapshot.entries,
      );
      final events = run.journal.records.map((record) => record.event).toList();
      expect(events.whereType<ModelInvocationStarted>(), hasLength(4));
      final settlements = events.whereType<ModelInvocationSettled>().toList();
      expect(settlements, hasLength(4));
      for (final settlement in settlements) {
        expect(settlement.settlement, ModelSettlement.completed);
        expect(settlement.metadata.effectiveModel, 'gpt-6-astra');
      }
      final prepared = events.whereType<ToolInvocationPrepared>().toList();
      expect(
        prepared.map((event) => event.invocation.tool.modelDefinition.alias),
        ['search', 'read_file', 'apply_patch', 'run_command'],
      );
      expect(
        prepared[1].invocation.canonicalArguments['relativePath'],
        discoveredPath,
      );
      expect(
        prepared[2].invocation.canonicalArguments['expectedRevision'],
        observedRevision,
      );
      final policies = events.whereType<ToolPolicyEvaluated>().toList();
      expect(
        policies.map((event) => event.invocationId),
        prepared.map((event) => event.invocation.id),
      );
      expect(policies.map((event) => event.decision), [
        ToolPolicyDecision.allow,
        ToolPolicyDecision.allow,
        ToolPolicyDecision.deny,
        ToolPolicyDecision.deny,
      ]);
      final completed = events.whereType<ToolExecutionCompleted>().toList();
      expect(
        completed.map((event) => event.invocationId),
        prepared.take(2).map((event) => event.invocation.id),
      );
      expect(
        events.whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId,
        ),
        prepared.take(2).map((event) => event.invocation.id),
      );
      for (final completion in completed) {
        expect(completion.outcome.disposition, ToolOutcomeDisposition.success);
        expect(
          completion.outcome.hostData['environmentId'],
          authority.environmentId.value,
        );
      }
      expect(completed[1].outcome.hostData['relativePath'], _sourcePath);
      expect(completed[1].outcome.hostData['text'], _taskText);
      expect(completed[1].outcome.hostData['revision'], observedRevision);
      final denied = events.whereType<ToolInvocationCompleted>().toList();
      expect(
        denied.map((event) => event.invocationId),
        prepared.skip(2).map((event) => event.invocation.id),
      );
      for (final terminal in denied) {
        expect(
          terminal.outcome.disposition,
          ToolOutcomeDisposition.policyDenied,
        );
        expect(
          terminal.outcome.effectCertainty,
          EffectCertainty.knownNotOccurred,
        );
      }

      await controller.close();
      await runtime.close();
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskBefore);
      expect(await File('${source.path}/run-command-marker').exists(), isFalse);
      expect(
        await File('${worktree.path}/run-command-marker').exists(),
        isFalse,
      );
      expect(await credentials.readAsString(), credentialText);
      expect(
        runtime.store.requireSessionAuthority(session.id),
        same(authority),
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

String _toolOutput(Map<String, Object?> body, String callId) =>
    (body['input']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
          (item) =>
              item['type'] == 'function_call_output' &&
              item['call_id'] == callId,
        )['output']!
        as String;

Map<String, Object?> _call(
  String callId,
  String name,
  Map<String, Object?> arguments,
) => {
  'type': 'function_call',
  'id': 'fc_$callId',
  'call_id': callId,
  'name': name,
  'arguments': jsonEncode(arguments),
  'status': 'completed',
};

void _output(HttpResponse response, Map<String, Object?> item) =>
    _sse(response, {'type': 'response.output_item.done', 'item': item});

void _sse(HttpResponse response, Map<String, Object?> event) {
  response.write('data: ${jsonEncode(event)}\n\n');
}

String _idToken(String accountId) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'none'})}.${encode({
    'https://api.openai.com/auth': {'chatgpt_account_id': accountId},
  })}.';
}

Future<Map<String, Object?>> _sourceSnapshot(Directory repository) async {
  final Map<String, Object?> files = {};
  Future<void> visit(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity.path == '${repository.path}/.git') continue;
      if (entity is Directory) {
        await visit(entity);
      } else if (entity is File) {
        files[entity.path.substring(repository.path.length + 1)] = await entity
            .readAsBytes();
      } else {
        throw StateError('Unexpected source fixture entity ${entity.path}.');
      }
    }
  }

  await visit(repository);
  return {
    'files': files,
    'head': await _git(repository, ['rev-parse', 'HEAD']),
    'branch': await _git(repository, ['branch', '--show-current']),
    'status': await _git(repository, ['status', '--porcelain=v1', '-z']),
    'diff': await _git(repository, ['diff', '--binary', 'HEAD']),
    'staged': await _git(repository, ['diff', '--cached', '--binary']),
  };
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final ProcessResult result = await Process.run('git', [
    '-c',
    'user.name=ADELE Test',
    '-c',
    'user.email=adele-test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    ...arguments,
  ], workingDirectory: directory.path);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString();
}

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final File executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final File executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
