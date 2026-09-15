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
import 'package:adele_desktop/plugins/stock_chat_execution_status.dart';
import 'package:adele_desktop/plugins/stock_chat_frontend.dart';
import 'package:adele_desktop/plugins/stock_git_environment.dart';
import 'package:adele_desktop/plugins/stock_openai.dart';
import 'package:adele_desktop/plugins/stock_openai_activity_frontend.dart';
import 'package:adele_desktop/plugins/stock_tool_inspection_frontends.dart';
import 'package:adele_desktop/ui/activity/model_native_activity_compact_host.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_desktop/ui/execution/pending_tool_approval.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/inspection/model_native_activity_inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_contract/openai_contract.dart';
import 'package:plugin_builder/plugin_builder.dart';

import '../../tool/chat_frontend_compiler.dart';
import '../../tool/openai_activity_frontend_compiler.dart';
import '../../tool/tool_inspection_frontend_compiler.dart';

const String _sourcePath = 'lib/task_answer.dart';
const String _taskText = 'const taskAnswer = "task-worktree-only";\n';
const String _patchedText = 'const taskAnswer = "approved-task-value";\n';
const String _agentsText =
    'C2 Task guidance: inspect source before proposing an edit and validation.\n';
const String _projectText = 'const projectAnswer = "project-source-only"; \t\n';
const String _projectAgentsText = 'Project-only guidance must not be used.\n';
const String _prompt =
    'Read lib/task_answer.dart, change taskAnswer to "approved-task-value", '
    'and validate with git diff --check after each operation is approved.';
const String _answer =
    'Patched lib/task_answer.dart to declare taskAnswer as "approved-task-value". '
    'The separately approved git diff --check exited with code 0 in the Task. '
    'E4 real-EVC canonical final reply.';
const String _narration = 'Updating the test file and validating the change.';
const String _reasoningA = 'Checking the exact file revision before the patch.';
const String _reasoningB = 'Checking the validation command after the patch.';
const String _initialPrompt = 'Explain the approval workflow without tools.';
const String _initialSummary = 'Reviewing the approval workflow without tools.';
const String _initialAnswer =
    'Source edits and validation commands require separate approvals. No tools ran.';
const String _encryptedA = 'e4-encrypted-replay-A-never-present';
const String _encryptedB = 'e4-encrypted-replay-B-never-present';
const String _encryptedInitial = 'e4-encrypted-initial-never-present';
const String _privateReasoning = 'e4-private-reasoning-content-never-present';
const String _providerExtra = 'e4-provider-extra-field-never-present';
const List<String> _presentationSecrets = [
  _encryptedA,
  _encryptedB,
  _encryptedInitial,
  _privateReasoning,
  _providerExtra,
  'encrypted_content',
  'reasoning_text',
  'provider_extra',
  'compatibility',
];
const Map<String, Object?> _commandArguments = {
  'program': 'git',
  'arguments': ['diff', '--check'],
  'workingDirectory': '',
  'timeoutSeconds': 5,
};

void main() {
  late Directory artifacts;
  late String dartaotruntime;
  late File hostArtifact;
  late File gitArtifact;
  late File openAiArtifact;
  late File evc;
  late File filesystemEvc;
  late File commandEvc;
  late File openAiEvc;

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
    evc = File('${artifacts.path}/chat.evc');
    filesystemEvc = File('${artifacts.path}/filesystem.evc');
    commandEvc = File('${artifacts.path}/command.evc');
    openAiEvc = File('${artifacts.path}/openai-activity.evc');
    await compileChatFrontend(repositoryRoot: repository, artifact: evc);
    await openAiEvc.writeAsBytes(
      await compileOpenAiActivityFrontend(repositoryRoot: repository),
    );
    for (final target in [
      (frontend: ToolInspectionFrontend.filesystem, artifact: filesystemEvc),
      (frontend: ToolInspectionFrontend.command, artifact: commandEvc),
    ]) {
      await compileToolInspectionFrontend(
        repositoryRoot: repository,
        artifact: target.artifact,
        frontend: target.frontend,
      );
    }
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

  testWidgets(
    'E4 real artifacts retain individual and compact group Inspection cards',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
              'idToken': _idToken('c2-fixture-account'),
              'accessToken': 'c2-fixture-chatgpt-access-token',
              'refreshToken': 'c2-fixture-refresh-never-used',
              'accountId': 'c2-fixture-account',
              'fedRamp': false,
            },
          },
        },
      });
      await credentials.writeAsString(credentialText, flush: true);

      final List<Map<String, Object?>> outbound = [];
      final List<(Object, StackTrace)> endpointFailures = [];
      final Completer<void> continuationArrived = Completer<void>();
      final Completer<void> releaseFinal = Completer<void>();
      addTearDown(() {
        if (!releaseFinal.isCompleted) releaseFinal.complete();
      });
      String? observedPath;
      String? observedRevision;
      String? patchedRevision;
      late final Map<String, Object?> patchArguments;
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
              'Bearer c2-fixture-chatgpt-access-token',
            );
            expect(
              request.headers.value('ChatGPT-Account-ID'),
              'c2-fixture-account',
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
            expect(body['reasoning'], {'summary': 'auto'});
            expect(body['include'], ['reasoning.encrypted_content']);
            expect(body, isNot(contains('max_output_tokens')));
            expect(body, isNot(contains('previous_response_id')));
            expect(body['instructions'], contains(_agentsText));
            expect(body['instructions'], contains(chatToolNarrationGuidance));
            expect(body['instructions'], isNot(contains(_projectAgentsText)));
            // Raw supplied summaries replay normally; their separate safe
            // presentation DTO must never become model input.
            final String replay = jsonEncode(body['input']);
            for (final String presentationOnly in [
              openAiReasoningSummaryPresentationKind,
              '"nativePresentation"',
              '"presentation"',
              '"compactText"',
              '"summaryParts"',
              '"truncated"',
            ]) {
              expect(replay, isNot(contains(presentationOnly)));
            }
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
                      {'type': 'input_text', 'text': _initialPrompt},
                    ],
                  },
                ]);
                _output(
                  request.response,
                  _reasoning(
                    'reasoning-initial',
                    _initialSummary,
                    _encryptedInitial,
                  ),
                );
                _output(
                  request.response,
                  _message('message-initial-final', _initialAnswer),
                );
              case 2:
                // The later Run reuses canonical history, never prior native
                // output, its encrypted replay, or presentation metadata.
                expect(body['input'], [
                  ...(outbound.first['input']! as List<Object?>),
                  {
                    'type': 'message',
                    'role': 'assistant',
                    'content': [
                      {
                        'type': 'output_text',
                        'text': _initialAnswer,
                        'annotations': <Object?>[],
                      },
                    ],
                    'status': 'completed',
                  },
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
                  _call('read', 'read_file', {'relativePath': _sourcePath}),
                );
              case 3:
                final String readOutput = _toolOutput(body, 'read');
                expect(
                  readOutput,
                  startsWith('File: ${jsonEncode(_sourcePath)}'),
                );
                observedPath =
                    jsonDecode(
                          readOutput
                              .split('\n')
                              .first
                              .substring('File: '.length),
                        )
                        as String;
                expect(readOutput, contains(_taskText));
                expect(readOutput, isNot(contains('project-source-only')));
                observedRevision = _revision(readOutput);
                expect(observedRevision, isNotEmpty);
                final String observedLine = readOutput
                    .split('\n')
                    .singleWhere(
                      (line) => line.startsWith('const taskAnswer = '),
                    );
                patchArguments = {
                  'relativePath': observedPath,
                  'expectedRevision': observedRevision,
                  'edits': [
                    {
                      'search': observedLine,
                      'replace': observedLine.replaceFirst(
                        'task-worktree-only',
                        'approved-task-value',
                      ),
                    },
                  ],
                };
                // One completed model turn proposes both operations. Each must
                // wait for its own approval before the next inference occurs.
                _output(
                  request.response,
                  _reasoning('reasoning-a', _reasoningA, _encryptedA),
                );
                _output(
                  request.response,
                  _message('batch-purpose', _narration),
                );
                _output(
                  request.response,
                  _call('patch', 'apply_patch', patchArguments),
                );
                _output(
                  request.response,
                  _reasoning('reasoning-b', _reasoningB, _encryptedB),
                );
                _output(
                  request.response,
                  _call('command', 'run_command', _commandArguments),
                );
              case 4:
                final String patchOutput = _toolOutput(body, 'patch');
                patchedRevision = _revision(patchOutput);
                expect(patchedRevision, isNotEmpty);
                expect(patchedRevision, isNot(observedRevision));
                expect(
                  patchOutput,
                  'Patched: ${jsonEncode(observedPath)}\n'
                  'Edits applied: 1\n'
                  'Revision: ${jsonEncode(patchedRevision)}',
                );
                final String commandOutput = _toolOutput(body, 'command');
                expect(
                  commandOutput,
                  allOf(
                    contains('Program: "git"'),
                    contains('Arguments: ["diff","--check"]'),
                    contains('Termination: exited'),
                    contains('Exit code: 0'),
                  ),
                );
                expect(
                  (body['input']! as List<Object?>)
                      .cast<Map<String, Object?>>()
                      .where((item) => item['type'] == 'function_call_output')
                      .map((item) => item['call_id']),
                  ['read', 'patch', 'command'],
                );
                // Native items retain exact ciphertext and opaque fields in
                // replay, in output order, not in a separate native-first group.
                expect(body['input'], [
                  ...(outbound[2]['input']! as List<Object?>),
                  _reasoning('reasoning-a', _reasoningA, _encryptedA),
                  _message('batch-purpose', _narration),
                  _call('patch', 'apply_patch', patchArguments),
                  _reasoning('reasoning-b', _reasoningB, _encryptedB),
                  _call('command', 'run_command', _commandArguments),
                  {
                    'type': 'function_call_output',
                    'call_id': 'patch',
                    'output': patchOutput,
                  },
                  {
                    'type': 'function_call_output',
                    'call_id': 'command',
                    'output': commandOutput,
                  },
                ]);
                continuationArrived.complete();
                await releaseFinal.future;
                _output(request.response, _message('message-final', _answer));
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
            if (!continuationArrived.isCompleted && outbound.length == 4) {
              continuationArrived.complete();
            }
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
        ids: MonotonicProductIdSource(seed: 'c2-fixture'),
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
        title: 'Approve a Task source edit and validation',
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
      // A successful check cannot come from accidentally validating the Project:
      // its deliberately dirty source contains a whitespace error absent in Task.
      final ProcessResult projectCheck = await Process.run('git', [
        'diff',
        '--check',
      ], workingDirectory: source.path);
      expect(projectCheck.exitCode, isNot(0));
      expect(projectCheck.stdout, contains(_sourcePath));

      late final VoidCallback refreshFrontend;
      StateSetter? updatePresentation;
      bool presentationScheduled = false;
      void refreshPresentation() {
        if (updatePresentation == null || presentationScheduled) return;
        presentationScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          presentationScheduled = false;
          updatePresentation?.call(() {});
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }

      final WindowInspection inspection = WindowInspection()
        ..presentSession(session)
        ..addListener(refreshPresentation);
      addTearDown(() {
        inspection.removeListener(refreshPresentation);
        inspection.dispose();
      });
      final ChatController controller = ChatController(
        runtime: runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: 'gpt-6-astra',
        runIds: MonotonicRunIdSource(seed: 'c2-fixture'),
        onChanged: () {
          refreshFrontend();
          refreshPresentation();
        },
        onActivityChanged: () {
          if (inspection.cards.isNotEmpty) refreshPresentation();
        },
      );
      addTearDown(controller.close);
      final frontend = await StockChatFrontend.activate(
        extensions: runtime.extensions,
        artifactPath: evc.path,
        controllerForSession: (presentedSession) {
          expect(presentedSession, same(session));
          return controller;
        },
        inspectActivity: (presentedSession, runId, modelInvocationId) {
          final ChatActivitySummary? summary = controller.activitySummary(
            runId,
            modelInvocationId,
          );
          if (!identical(presentedSession, session) ||
              controller.isClosed ||
              summary == null) {
            return false;
          }
          final RunActivitySnapshot? activity = controller.activityForRun(
            runId,
          );
          if (activity == null) return false;
          if (summary.outputSequence case final int sequence) {
            return inspection.inspectOutput(
              session: presentedSession,
              activity: activity,
              modelInvocationId: modelInvocationId,
              outputSequence: sequence,
            );
          }
          return inspection.inspectActivity(
            session: presentedSession,
            activity: activity,
            modelInvocationId: modelInvocationId,
          );
        },
      );
      refreshFrontend = frontend.refresh;
      addTearDown(frontend.close);
      final filesystemFrontend =
          await StockToolInspectionFrontend.activateFilesystem(
            extensions: runtime.extensions,
            artifactPath: filesystemEvc.path,
          );
      addTearDown(filesystemFrontend.close);
      final commandFrontend = await StockToolInspectionFrontend.activateCommand(
        extensions: runtime.extensions,
        artifactPath: commandEvc.path,
      );
      addTearDown(commandFrontend.close);
      addTearDown(() async {
        updatePresentation = null;
        if (!releaseFinal.isCompleted) releaseFinal.complete();
        await controller.close();
        await tester.pumpWidget(const SizedBox.shrink());
      });
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updatePresentation = setState;
              return AdeleShell(
                project: project,
                task: created.task,
                environment: created.environment,
                environmentReady:
                    runtime.lifecycle.environmentRuntime.currentMaterialization(
                      created.environment.id,
                    ) !=
                    null,
                selectors: const [],
                onSelectProject: (_) =>
                    fail('Project selection is not part of this Run.'),
                sessionControls: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SessionPresentationHost(
                      session: session,
                      extensions: runtime.extensions,
                    ),
                    StockChatExecutionStatus(controller: controller),
                  ],
                ),
                inspection: inspection.cards.isEmpty
                    ? null
                    : InspectionStackHost(
                        key: const ValueKey('inspection-stack'),
                        cards: inspection.cards,
                        cardBuilder: (context, card) => InspectionHost(
                          card: card,
                          activity: controller.activityForRun(
                            card.target.runId,
                          ),
                          heading: controller
                              .activitySummary(
                                card.target.runId,
                                card.target.modelInvocationId,
                              )!
                              .content,
                          extensions: runtime.extensions,
                          onCollapse: () => inspection.collapse(card.id),
                          onExpand: () => inspection.expand(card.id),
                          onDismiss: () => inspection.dismiss(card.id),
                          onInspectOutput: (target) {
                            final activity = controller.activityForRun(
                              target.runId,
                            );
                            if (activity == null) return;
                            inspection.inspectOutput(
                              session: session,
                              activity: activity,
                              modelInvocationId: target.modelInvocationId,
                              outputSequence: target.outputSequence,
                              originCardId: card.id,
                            );
                          },
                        ),
                      ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder sessionHost = find.byType(SessionPresentationHost);
      final Finder inspectionHost = find.byKey(
        const ValueKey('inspection-stack'),
      );
      final Finder narratedActivity = find.descendant(
        of: sessionHost,
        matching: find.textContaining(_narration),
      );
      final Finder fallbackActivity = find.descendant(
        of: sessionHost,
        matching: find.text('Tool: read_file'),
      );
      final Finder promptField = find.descendant(
        of: sessionHost,
        matching: find.byType(TextField),
      );
      final Finder send = find.descendant(
        of: sessionHost,
        matching: find.text('Send'),
      );
      final Finder allowOnce = find.descendant(
        of: find.byType(StockChatExecutionStatus),
        matching: find.widgetWithText(FilledButton, 'Allow once'),
      );
      expect(sessionHost, findsOneWidget);
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).project,
        same(project),
      );
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).task,
        same(created.task),
      );
      expect(
        tester.widget<AdeleShell>(find.byType(AdeleShell)).environment,
        same(created.environment),
      );
      expect(inspection.cards, isEmpty);
      expect(inspectionHost, findsNothing);
      expect(promptField, findsOneWidget);
      expect(send, findsOneWidget);
      expect(allowOnce, findsNothing);
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(promptField).enabled, isTrue);
      final Finder chatPresentation = find.descendant(
        of: sessionHost,
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatefulWidget$bridge,
        ),
      );
      final chatWidget = tester.widget<$StatefulWidget$bridge>(
        chatPresentation,
      );
      final chatState = tester.state(chatPresentation);
      final chatRuntime = chatWidget.$runtime;
      expect(outbound, isEmpty);
      expect(controller.snapshot.entries, isEmpty);
      expect(controller.currentRun, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      Finder nativeHost(ModelNativePresentation presentation) =>
          find.descendant(
            of: inspectionHost,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ModelNativeActivityInspectionHost &&
                  identical(widget.presentation, presentation),
            ),
          );

      // A single safe native output opens an individual card directly from Chat.
      // Final assistant text is canonical history, not a second activity.
      await tester.enterText(promptField, _initialPrompt);
      await tester.ensureVisible(send);
      await tester.tap(send);
      final Future<void>? starting = controller.activeRunFuture;
      expect(starting, isNotNull);
      await starting!;
      await tester.pumpAndSettle();
      expect(endpointFailures, isEmpty);
      final initialExecution = controller.currentRun!;
      final AgentRun initialRun = initialExecution.run;
      expect(initialRun.id, RunId('run-c2-fixture-1'));
      expect(initialRun.sessionId, session.id);
      expect(initialRun.state, RunState.completed);
      expect(initialRun.failure, isNull);
      expect(initialRun.interruptions, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      expect(allowOnce, findsNothing);
      expect(tester.widget<TextField>(promptField).enabled, isTrue);
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(outbound, hasLength(1));
      final RunActivitySnapshot initialActivity = controller.activityForRun(
        initialRun.id,
      )!;
      expect(controller.activitySnapshots, [initialActivity]);
      expect(initialActivity.models, hasLength(1));
      expect(initialActivity.tools, isEmpty);
      expect(initialActivity.rejectedProposals, isEmpty);
      final ModelInvocationActivity initialModel =
          initialActivity.models.single;
      expect(initialModel.settlement, ModelSettlement.completed);
      expect(initialModel.failure, isNull);
      expect(initialModel.outputs.map((output) => output.item), [
        isA<ModelNativeOutput>(),
        isA<ModelTextOutput>(),
      ]);
      final ModelNativeOutput initialNative =
          initialModel.outputs.first.item as ModelNativeOutput;
      _expectSafePresentation(
        initialNative,
        id: 'reasoning-initial',
        summary: _initialSummary,
        encrypted: _encryptedInitial,
      );
      final ChatActivitySummary initialSummary = controller.timeline
          .whereType<ChatActivitySummary>()
          .single;
      expect(initialSummary.invocationId, initialModel.id);
      expect(initialSummary.content, _initialSummary);
      expect(initialSummary.activityCount, 1);
      expect(initialSummary.isGroup, isFalse);
      expect(
        initialSummary.outputSequence,
        initialModel.outputs.first.sequence,
      );
      expect(controller.timeline.map((entry) => entry.content), [
        _initialPrompt,
        _initialSummary,
        _initialAnswer,
      ]);
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        _initialPrompt,
        _initialAnswer,
      ]);
      final initialEvents = initialRun.journal.records
          .map((record) => record.event)
          .toList();
      expect(initialEvents.whereType<ModelInvocationStarted>(), hasLength(1));
      final initialSettlement = initialEvents
          .whereType<ModelInvocationSettled>()
          .single;
      expect(initialSettlement.settlement, ModelSettlement.completed);
      expect(initialSettlement.metadata.effectiveModel, 'gpt-6-astra');
      expect(initialEvents.whereType<ToolInvocationPrepared>(), isEmpty);
      expect(initialEvents.whereType<ToolPolicyEvaluated>(), isEmpty);
      expect(initialEvents.whereType<ToolExecutionStarted>(), isEmpty);
      expect(initialEvents.whereType<RunInterrupted>(), isEmpty);
      final Finder initialActivityLink = find.descendant(
        of: sessionHost,
        matching: find.textContaining(_initialSummary),
      );
      _expectVerticalOrder(tester, [
        find.descendant(of: sessionHost, matching: find.text(_initialPrompt)),
        initialActivityLink,
        find.descendant(of: sessionHost, matching: find.text(_initialAnswer)),
      ]);

      // Real AOT classification and Chat activity precede frontend activation.
      final nativeResolver = ModelNativeActivityPresentationResolver(
        runtime.extensions,
      );
      expect(
        () => nativeResolver.resolve(openAiReasoningSummaryPresentationKind),
        throwsA(isA<ModelNativeActivityPresentationUnavailable>()),
      );
      final openAiFrontend = await activateStockOpenAiActivityFrontend(
        extensions: runtime.extensions,
        artifactPath: openAiEvc.path,
      );
      addTearDown(openAiFrontend.close);
      expect(
        nativeResolver
            .resolve(initialNative.presentation!.kind)
            .value
            .presentationKind,
        openAiReasoningSummaryPresentationKind,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(initialActivityLink);
      await tester.tap(
        find.ancestor(
          of: initialActivityLink,
          matching: find.byType(TextButton),
        ),
      );
      await tester.pumpAndSettle();
      final InspectionCard cardA = inspection.cards.single;
      final ModelOutputInspectionTarget targetA =
          cardA.target as ModelOutputInspectionTarget;
      expect(targetA.sessionId, session.id);
      expect(targetA.runId, initialRun.id);
      expect(targetA.modelInvocationId, initialModel.id);
      expect(targetA.outputSequence, initialModel.outputs.first.sequence);
      expect(cardA.isCollapsed, isFalse);
      final Finder initialNativeHost = nativeHost(initialNative.presentation!);
      final initialNativeState = tester.state(initialNativeHost);
      expect(find.byType(ModelNativeActivityInspectionHost), findsOneWidget);
      expect(find.byType(ToolActivityInspectionHost), findsNothing);
      expect(
        find.descendant(
          of: inspectionHost,
          matching: find.byType(ModelNativeActivityCompactHost),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: sessionHost,
          matching: find.byType(ModelNativeActivityCompactHost),
        ),
        findsOneWidget,
      );
      expect(find.byType(ToolActivityCompactHost), findsNothing);
      for (final String label in ['Reasoning summary', _initialSummary]) {
        expect(
          find.descendant(of: initialNativeHost, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(
        initialRun.journal.records.map((record) => record.event),
        initialEvents,
      );
      expect(outbound, hasLength(1));
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskBefore);
      _expectNoPresentationSecrets(tester, controller);
      expect(tester.takeException(), isNull);

      // Process/socket work, including interpreted submission, uses real async.
      await tester.enterText(promptField, _prompt);
      await tester.ensureVisible(send);
      await tester.tap(send);
      final Future<void>? running = controller.activeRunFuture;
      expect(running, isNotNull);
      expect(controller.isAdvancing, isTrue);
      expect(controller.submit('Duplicate must not enter history.'), isFalse);
      await running!;
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: sessionHost, matching: find.text(_prompt)),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(promptField).enabled, isFalse);
      expect(find.text('Tool: apply_patch'), findsOneWidget);
      expect(allowOnce, findsOneWidget);

      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(
        find.descendant(of: sessionHost, matching: find.text('Allow once')),
        findsNothing,
      );

      expect(endpointFailures, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isTrue);
      final execution = controller.currentRun!;
      final AgentRun run = execution.run;
      expect(execution, isNot(same(initialExecution)));
      expect(run.id, RunId('run-c2-fixture-2'));
      expect(run.sessionId, session.id);
      expect(run.state, RunState.waiting);
      expect(outbound, hasLength(3));
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        _initialPrompt,
        _initialAnswer,
        _prompt,
      ]);
      final ChatActivitySummary batch = controller.timeline
          .whereType<ChatActivitySummary>()
          .last;
      expect(batch.content, _narration);
      expect(batch.activityCount, 4);
      expect(batch.isGroup, isTrue);
      expect(batch.outputSequence, isNull);
      expect(
        controller.timeline.whereType<ChatActivitySummary>(),
        hasLength(3),
      );
      final ChatActivitySummary readSummary = controller.timeline
          .whereType<ChatActivitySummary>()
          .where((entry) => entry.runId == run.id)
          .first;
      expect(readSummary.activityCount, 1);
      expect(readSummary.isGroup, isFalse);
      expect(
        readSummary.outputSequence,
        execution.activity.snapshot.models.first.outputs.single.sequence,
      );
      final RunActivitySnapshot waitingEvidence = execution.activity.snapshot;
      expect(waitingEvidence.models.last.outputs.map((output) => output.item), [
        isA<ModelNativeOutput>(),
        isA<ModelTextOutput>(),
        isA<ModelToolProposalOutput>(),
        isA<ModelNativeOutput>(),
        isA<ModelToolProposalOutput>(),
      ]);
      final ModelNativeOutput nativeA =
          waitingEvidence.models.last.outputs[0].item as ModelNativeOutput;
      final ModelNativeOutput nativeB =
          waitingEvidence.models.last.outputs[3].item as ModelNativeOutput;
      _expectSafePresentation(
        nativeA,
        id: 'reasoning-a',
        summary: _reasoningA,
        encrypted: _encryptedA,
      );
      _expectSafePresentation(
        nativeB,
        id: 'reasoning-b',
        summary: _reasoningB,
        encrypted: _encryptedB,
      );
      _expectNoPresentationSecrets(tester, controller);
      final PendingToolApproval patchApproval = controller.pendingApproval!;
      final ToolApprovalInterruption patchInterruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      expect(patchApproval.toolAlias, 'apply_patch');
      expect(patchApproval.effects, {ToolEffect.sourceMutation});
      expect(patchApproval.uncertainty, EffectUncertainty.none);
      expect(patchApproval.targets, [
        'adele-environment:/${authority.environmentId.value}/$_sourcePath',
      ]);
      expect(jsonDecode(patchApproval.canonicalArgumentsJson), patchArguments);
      expect(
        patchInterruption.toolInvocationId,
        ToolInvocationId('${run.id.value}-tool-2'),
      );
      expect(patchInterruption.invocation.proposal.providerCallId, 'patch');
      final beforePatch = run.journal.records
          .map((record) => record.event)
          .toList();
      final readInvocation = beforePatch
          .whereType<ToolInvocationPrepared>()
          .first
          .invocation;
      expect(readInvocation.id, ToolInvocationId('${run.id.value}-tool-1'));
      expect(beforePatch.whereType<ToolInvocationPrepared>(), hasLength(2));
      expect(
        beforePatch.whereType<ToolInvocationPrepared>().last.invocation,
        same(patchInterruption.invocation),
      );
      expect(
        beforePatch.whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id],
      );
      expect(
        beforePatch.whereType<ToolExecutionCompleted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id],
      );
      expect(beforePatch.whereType<RunInterruptionResolved>(), isEmpty);
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskBefore);

      // B is one compact group above the retained individual card A. Narration
      // is its heading, not an activity row or an extra counted output.
      expect(inspection.cards, [cardA]);
      await tester.ensureVisible(narratedActivity);
      await tester.tap(narratedActivity);
      await tester.pumpAndSettle();
      final InspectionCard cardB = inspection.cards.first;
      final ActivityGroupInspectionTarget targetB =
          cardB.target as ActivityGroupInspectionTarget;
      expect(targetB.sessionId, session.id);
      expect(targetB.runId, run.id);
      expect(targetB.modelInvocationId, batch.invocationId);
      expect(inspection.cards, [cardB, cardA]);
      Finder cardHost(InspectionCard card) => find.byWidgetPredicate(
        (widget) =>
            widget is InspectionHost && identical(widget.card.id, card.id),
      );
      final Finder groupCard = cardHost(cardB);
      expect(inspectionHost, findsOneWidget);
      expect(
        tester.getTopLeft(inspectionHost).dx,
        greaterThan(tester.getBottomRight(sessionHost).dx),
      );
      expect(narratedActivity, findsOneWidget);
      expect(
        find.descendant(of: groupCard, matching: find.text(_narration)),
        findsOneWidget,
      );
      _expectVerticalOrder(tester, [groupCard, cardHost(cardA)]);
      expect(tester.state(initialNativeHost), same(initialNativeState));
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityInspectionHost),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ModelNativeActivityInspectionHost),
        ),
        findsNothing,
      );

      Finder toolHost(ToolInvocationId id) => find.descendant(
        of: inspectionHost,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ToolActivityInspectionHost &&
              widget.source.snapshot.id == id,
        ),
      );
      Finder nativeCompactHost(ModelNativePresentation presentation) =>
          find.descendant(
            of: groupCard,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ModelNativeActivityCompactHost &&
                  identical(widget.presentation, presentation),
            ),
          );
      Finder toolCompactHost(ToolInvocationId id) => find.descendant(
        of: groupCard,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ToolActivityCompactHost &&
              widget.source.snapshot.id == id,
        ),
      );
      final Finder reasoningAHost = nativeCompactHost(nativeA.presentation!);
      final Finder reasoningBHost = nativeCompactHost(nativeB.presentation!);
      final reasoningAState = tester.state(reasoningAHost);
      final reasoningBState = tester.state(reasoningBHost);
      final Finder patchCompactHost = toolCompactHost(
        patchInterruption.toolInvocationId,
      );
      for (final (host, summary) in [
        (reasoningAHost, _reasoningA),
        (reasoningBHost, _reasoningB),
      ]) {
        expect(host, findsOneWidget);
        expect(
          find.descendant(of: host, matching: find.text('Reasoning: $summary')),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ModelNativeActivityCompactHost),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityCompactHost),
        ),
        findsOneWidget,
      );
      expect(find.byType(ModelNativeActivityInspectionHost), findsOneWidget);
      expect(find.byType(ToolActivityInspectionHost), findsNothing);
      final Finder unresolvedCommand = find.descendant(
        of: groupCard,
        matching: find.text('Proposal: run_command'),
      );
      expect(unresolvedCommand, findsOneWidget);
      final groupRows = tester.widgetList<TextButton>(
        find.descendant(of: groupCard, matching: find.byType(TextButton)),
      );
      expect(groupRows.map((row) => row.key), [
        for (final index in [0, 2, 3, 4])
          ValueKey((
            session.id,
            run.id,
            batch.invocationId,
            waitingEvidence.models.last.outputs[index].sequence,
          )),
      ]);
      expect(
        find.descendant(
          of: patchCompactHost,
          matching: find.text('Apply Patch: "$_sourcePath" / 1 edit'),
        ),
        findsOneWidget,
      );
      _expectVerticalOrder(tester, [
        reasoningAHost,
        patchCompactHost,
        reasoningBHost,
        unresolvedCommand,
      ]);
      expect(
        tester
            .widget<ToolActivityCompactHost>(patchCompactHost)
            .source
            .snapshot
            .proposalSequence,
        waitingEvidence.models.last.outputs[2].sequence,
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.text('Waiting to be processed.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.text('Relative path: "$_sourcePath"'),
        ),
        findsNothing,
      );

      // Clicking the prepared patch row opens C above B/A without replacing B.
      await tester.ensureVisible(patchCompactHost);
      await tester.tap(
        find.ancestor(of: patchCompactHost, matching: find.byType(TextButton)),
      );
      await tester.pumpAndSettle();
      final InspectionCard cardC = inspection.cards.first;
      final ModelOutputInspectionTarget targetC =
          cardC.target as ModelOutputInspectionTarget;
      expect(targetC.sessionId, session.id);
      expect(targetC.runId, run.id);
      expect(targetC.modelInvocationId, batch.invocationId);
      expect(
        targetC.outputSequence,
        waitingEvidence.models.last.outputs[2].sequence,
      );
      expect({cardA.id, cardB.id, cardC.id}, hasLength(3));
      expect(inspection.cards, [cardC, cardB, cardA]);
      _expectVerticalOrder(tester, [
        cardHost(cardC),
        groupCard,
        cardHost(cardA),
      ]);
      Finder toolPresentation(ToolInvocationId id) => find.descendant(
        of: toolHost(id),
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatefulWidget$bridge,
        ),
      );
      final Finder patchPresentation = toolPresentation(
        patchInterruption.toolInvocationId,
      );
      final patchWidget = tester.widget<$StatefulWidget$bridge>(
        patchPresentation,
      );
      final patchState = tester.state(patchPresentation);
      final patchRuntime = patchWidget.$runtime;
      final patchSource = tester
          .widget<ToolActivityInspectionHost>(
            toolHost(patchInterruption.toolInvocationId),
          )
          .source;
      final ToolInvocationActivity waitingPatch = patchSource.snapshot;
      expect(waitingPatch.id, patchInterruption.toolInvocationId);
      expect(waitingPatch.toolId, patchInterruption.toolId);
      expect(waitingPatch.modelInvocationId, batch.invocationId);
      expect(
        waitingPatch.proposalSequence,
        waitingEvidence.models.last.outputs[2].sequence,
      );
      expect(
        waitingPatch.changes.last.kind,
        ToolActivityKind.approvalRequested,
      );
      expect(waitingPatch.outcome, isNull);
      expect(patchRuntime, isNot(same(chatRuntime)));
      for (final String label in [
        'Apply Patch',
        'Relative path: "$_sourcePath"',
        'Edit count: 1',
        'Status: Waiting for approval',
        'Tool delivery: Pending',
      ]) {
        expect(
          find.descendant(of: patchPresentation, matching: find.text(label)),
          findsOneWidget,
        );
      }
      expect(find.byType(ToolActivityInspectionHost), findsOneWidget);
      final Finder collapseGroup = find.descendant(
        of: groupCard,
        matching: find.byTooltip('Collapse Inspection'),
      );
      await tester.ensureVisible(collapseGroup);
      await tester.tap(collapseGroup);
      await tester.pumpAndSettle();
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspection.cards[1].isCollapsed, isTrue);
      expect(reasoningAHost, findsNothing);
      expect(reasoningBHost, findsNothing);
      expect(patchCompactHost, findsNothing);
      expect(unresolvedCommand, findsNothing);
      expect(tester.state(patchPresentation), same(patchState));
      expect(tester.state(initialNativeHost), same(initialNativeState));
      _expectVerticalOrder(tester, [
        cardHost(cardC),
        groupCard,
        cardHost(cardA),
      ]);
      _expectNoPresentationSecrets(tester, controller);
      expect(
        find.descendant(of: inspectionHost, matching: find.text('Allow once')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: inspectionHost,
          matching: find.text('Program: "git"'),
        ),
        findsNothing,
      );
      expect(controller.currentRun, same(execution));
      expect(controller.pendingApproval, same(patchApproval));
      expect(controller.snapshot.entries.last.content, _prompt);
      expect(run.journal.records.map((record) => record.event), beforePatch);
      expect(outbound, hasLength(3));
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(allowOnce);
      await tester.tap(allowOnce);
      final Future<void>? patching = controller.activeRunFuture;
      expect(patching, isNotNull);
      expect(controller.isAdvancing, isTrue);
      await patching!;
      await tester.pumpAndSettle();
      expect(find.text('Tool: apply_patch'), findsNothing);
      expect(find.text('Tool: run_command'), findsOneWidget);
      expect(
        find.text('Effects may extend beyond the listed target.'),
        findsOneWidget,
      );
      expect(allowOnce, findsOneWidget);
      expect(tester.widget<TextField>(promptField).enabled, isFalse);
      expect(narratedActivity, findsOneWidget);

      expect(endpointFailures, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.currentRun, same(execution));
      expect(controller.activeRunFuture, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isTrue);
      expect(run.state, RunState.waiting);
      expect(outbound, hasLength(3));
      expect(controller.snapshot.entries.last.content, _prompt);
      final PendingToolApproval commandApproval = controller.pendingApproval!;
      final ToolApprovalInterruption commandInterruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      expect(commandApproval, isNot(same(patchApproval)));
      expect(commandApproval.toolAlias, 'run_command');
      expect(commandApproval.effects, {ToolEffect.processExecution});
      expect(commandApproval.uncertainty, EffectUncertainty.uncertain);
      expect(commandApproval.targets, [
        'adele-environment:/${authority.environmentId.value}/',
      ]);
      expect(
        jsonDecode(commandApproval.canonicalArgumentsJson),
        _commandArguments,
      );
      expect(
        commandInterruption.toolInvocationId,
        ToolInvocationId('${run.id.value}-tool-3'),
      );
      expect(commandInterruption.invocation.proposal.providerCallId, 'command');
      expect(commandInterruption.id, isNot(patchInterruption.id));
      final List<ToolInvocationActivity> batchTools = execution
          .activity
          .snapshot
          .tools
          .where((tool) => tool.modelInvocationId == batch.invocationId)
          .toList();
      expect(batchTools.map((tool) => tool.id), [
        patchInterruption.toolInvocationId,
        commandInterruption.toolInvocationId,
      ]);
      expect(
        batchTools.first.outcome!.disposition,
        ToolOutcomeDisposition.success,
      );
      expect(batchTools.last.outcome, isNull);
      expect(
        batchTools.last.changes.last.kind,
        ToolActivityKind.approvalRequested,
      );
      expect(inspection.cards.first, same(cardC));
      expect(inspection.cards[1].id, cardB.id);
      expect(inspection.cards[1].isCollapsed, isTrue);
      expect(inspection.cards.last, same(cardA));
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation),
        same(patchWidget),
      );
      expect(tester.state(patchPresentation), same(patchState));
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation).$runtime,
        same(patchRuntime),
      );
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              toolHost(patchInterruption.toolInvocationId),
            )
            .source,
        same(patchSource),
      );
      expect(patchSource.snapshot.id, waitingPatch.id);
      expect(patchSource.snapshot.toolId, waitingPatch.toolId);
      expect(
        patchSource.snapshot.proposalSequence,
        waitingPatch.proposalSequence,
      );
      expect(
        patchSource.snapshot.outcome!.disposition,
        ToolOutcomeDisposition.success,
      );
      final String inspectionRevision =
          patchSource.snapshot.outcome!.hostData['newRevision']! as String;
      expect(inspectionRevision, isNotEmpty);
      expect(inspectionRevision, isNot(observedRevision));
      expect(waitingPatch.outcome, isNull);
      for (final String label in [
        'Status: Succeeded',
        'Tool delivery: success',
        'New revision: $inspectionRevision',
      ]) {
        expect(
          find.descendant(of: patchPresentation, matching: find.text(label)),
          findsOneWidget,
        );
      }
      // The collapsed group keeps receiving evidence. Expanding upgrades only
      // its original command occurrence from placeholder to compact tool view.
      final Finder expandGroup = find.descendant(
        of: groupCard,
        matching: find.byTooltip('Expand Inspection'),
      );
      await tester.ensureVisible(expandGroup);
      await tester.tap(expandGroup);
      await tester.pumpAndSettle();
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspection.cards[1].isCollapsed, isFalse);
      expect(unresolvedCommand, findsNothing);
      expect(find.byType(ToolActivityInspectionHost), findsOneWidget);
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityCompactHost),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: groupCard,
          matching: find.byType(ToolActivityInspectionHost),
        ),
        findsNothing,
      );
      final Finder commandCompactHost = toolCompactHost(
        commandInterruption.toolInvocationId,
      );
      final Finder commandPresentation = find.descendant(
        of: commandCompactHost,
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatefulWidget$bridge,
        ),
      );
      final commandWidget = tester.widget<$StatefulWidget$bridge>(
        commandPresentation,
      );
      final commandState = tester.state(commandPresentation);
      final commandRuntime = commandWidget.$runtime;
      final commandSource = tester
          .widget<ToolActivityCompactHost>(commandCompactHost)
          .source;
      expect(commandSource.snapshot.id, commandInterruption.toolInvocationId);
      expect(commandSource.snapshot.modelInvocationId, batch.invocationId);
      expect(
        commandSource.snapshot.proposalSequence,
        waitingEvidence.models.last.outputs[4].sequence,
      );
      expect(
        commandSource.snapshot.changes.last.kind,
        ToolActivityKind.approvalRequested,
      );
      expect(commandSource.snapshot.outcome, isNull);
      expect(commandRuntime, isNot(same(patchRuntime)));
      expect(commandRuntime, isNot(same(chatRuntime)));
      expect(tester.state(reasoningAHost), same(reasoningAState));
      expect(tester.state(reasoningBHost), same(reasoningBState));
      _expectVerticalOrder(tester, [
        reasoningAHost,
        patchCompactHost,
        reasoningBHost,
        commandCompactHost,
      ]);
      _expectNoPresentationSecrets(tester, controller);
      expect(
        find.descendant(
          of: commandPresentation,
          matching: find.text('Run Command: "git" ["diff", "--check"]'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: groupCard, matching: find.text('Program: "git"')),
        findsNothing,
      );
      expect(
        find.descendant(of: inspectionHost, matching: find.text('Allow once')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      expect(
        controller.timeline.whereType<ChatActivitySummary>().last.invocationId,
        batch.invocationId,
      );
      final beforeCommand = run.journal.records
          .map((record) => record.event)
          .toList();
      expect(beforeCommand.whereType<ModelInvocationStarted>(), hasLength(2));
      expect(beforeCommand.whereType<ToolInvocationPrepared>(), hasLength(3));
      expect(
        beforeCommand.whereType<ToolInvocationPrepared>().last.invocation,
        same(commandInterruption.invocation),
      );
      expect(
        beforeCommand.whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id, patchInterruption.toolInvocationId],
      );
      expect(
        beforeCommand.whereType<ToolExecutionCompleted>().map(
          (event) => event.invocationId,
        ),
        [readInvocation.id, patchInterruption.toolInvocationId],
      );
      expect(
        beforeCommand.whereType<RunInterruptionResolved>().single.interruption,
        same(patchInterruption),
      );
      for (final (approval, interruption) in [
        (patchApproval, patchInterruption),
        (commandApproval, commandInterruption),
      ]) {
        expect(approval.toolId, interruption.toolId.value);
        expect(approval.hasUnsafeAuthorityText, isFalse);
        expect(approval.summary, interruption.effects.summary);
        expect(approval.summary, isNotEmpty);
        expect(approval.effects, interruption.effects.effects);
        expect(approval.uncertainty, interruption.effects.uncertainty);
        expect(
          approval.targets,
          interruption.effects.targets.map((target) => target.uri.toString()),
        );
        expect(
          jsonDecode(approval.canonicalArgumentsJson),
          interruption.canonicalArguments,
        );
      }
      final Map<String, Object?> taskAfterPatch = await _sourceSnapshot(
        worktree,
      );
      expect(taskAfterPatch['files'], {
        ...taskBefore['files']! as Map<String, Object?>,
        _sourcePath: utf8.encode(_patchedText),
      });
      for (final String key in ['head', 'branch', 'staged']) {
        expect(taskAfterPatch[key], taskBefore[key], reason: key);
      }
      expect(await _git(worktree, ['diff', '--name-only']), '$_sourcePath\n');
      expect(await _sourceSnapshot(source), projectBefore);

      await tester.ensureVisible(allowOnce);
      await tester.tap(allowOnce);
      final Future<void>? validating = controller.activeRunFuture;
      expect(validating, isNotNull);
      expect(controller.isAdvancing, isTrue);
      await continuationArrived.future;
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }
      await tester.pumpAndSettle();
      expect(controller.isAdvancing, isTrue);
      expect(controller.activeRunFuture, same(validating));
      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(find.text(_answer), findsNothing);
      expect(controller.snapshot.entries, hasLength(3));
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspectionHost, findsOneWidget);
      expect(patchedRevision, inspectionRevision);
      expect(
        commandSource.snapshot.outcome!.disposition,
        ToolOutcomeDisposition.success,
      );
      expect(commandSource.snapshot.outcome!.hostData['exitCode'], 0);
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation),
        same(commandWidget),
      );
      expect(tester.state(commandPresentation), same(commandState));
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation).$runtime,
        same(commandRuntime),
      );
      expect(
        find.descendant(
          of: commandPresentation,
          matching: find.text('Run Command: "git" ["diff", "--check"]'),
        ),
        findsOneWidget,
      );
      releaseFinal.complete();
      await validating!;
      await tester.pumpAndSettle();
      if (endpointFailures.isNotEmpty) {
        final (error, stack) = endpointFailures.first;
        Error.throwWithStackTrace(error, stack);
      }
      expect(
        find.descendant(of: sessionHost, matching: find.text(_answer)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sessionHost, matching: find.text(_prompt)),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(promptField).enabled, isTrue);
      expect(allowOnce, findsNothing);
      expect(find.text('Approval required'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_prompt)).dy,
        lessThan(tester.getTopLeft(fallbackActivity).dy),
      );
      expect(
        tester.getTopLeft(fallbackActivity).dy,
        lessThan(tester.getTopLeft(narratedActivity).dy),
      );
      expect(
        tester.getTopLeft(narratedActivity).dy,
        lessThan(tester.getTopLeft(find.text(_answer)).dy),
      );

      expect(controller.failure, isNull);
      expect(controller.currentRun, same(execution));
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isFalse);
      expect(run.state, RunState.completed);
      expect(run.failure, isNull);
      expect(run.interruptions, isEmpty);
      expect(outbound, hasLength(4));
      final RunActivitySnapshot activity = controller.activityForRun(run.id)!;
      expect(controller.activitySnapshots, [initialActivity, activity]);
      expect(activity.state, RunState.completed);
      expect(activity.models, hasLength(3));
      expect(activity.tools, hasLength(3));
      expect(
        activity.tools.where(
          (tool) => tool.modelInvocationId == batch.invocationId,
        ),
        hasLength(2),
      );
      expect(
        controller.timeline.whereType<ChatActivitySummary>(),
        hasLength(3),
      );
      expect(controller.timeline.map((entry) => entry.content), [
        _initialPrompt,
        _initialSummary,
        _initialAnswer,
        _prompt,
        'read_file',
        _narration,
        _answer,
      ]);
      final ChatSessionSnapshot snapshot = controller.snapshot;
      expect(snapshot.id, session.id);
      expect(snapshot.entries, [
        isA<ChatUserMessage>(),
        isA<ChatAssistantMessage>(),
        isA<ChatUserMessage>(),
        isA<ChatAssistantMessage>(),
      ]);
      expect(snapshot.entries.map((entry) => entry.content), [
        _initialPrompt,
        _initialAnswer,
        _prompt,
        _answer,
      ]);
      expect(
        runtime.chat.sessions.obtain(session.id).snapshot().entries,
        snapshot.entries,
      );
      final events = run.journal.records.map((record) => record.event).toList();
      expect(events.whereType<ModelInvocationStarted>(), hasLength(3));
      final settlements = events.whereType<ModelInvocationSettled>().toList();
      expect(settlements, hasLength(3));
      for (final settlement in settlements) {
        expect(settlement.settlement, ModelSettlement.completed);
        expect(settlement.metadata.effectiveModel, 'gpt-6-astra');
      }
      final prepared = events.whereType<ToolInvocationPrepared>().toList();
      expect(
        prepared.map((event) => event.invocation.tool.modelDefinition.alias),
        ['read_file', 'apply_patch', 'run_command'],
      );
      expect(
        prepared.first.invocation.canonicalArguments['relativePath'],
        observedPath,
      );
      expect(prepared[1].invocation.canonicalArguments, patchArguments);
      expect(prepared.last.invocation.canonicalArguments, _commandArguments);
      final proposals = events
          .whereType<ModelOutputObserved>()
          .where((event) => event.item is ModelToolProposalOutput)
          .toList();
      expect(proposals, hasLength(3));
      expect(proposals[1].invocationId, proposals[2].invocationId);
      expect(proposals[1].invocationId, settlements[1].invocationId);
      expect(
        proposals.map(
          (event) =>
              (event.item as ModelToolProposalOutput).proposal.providerCallId,
        ),
        ['read', 'patch', 'command'],
      );
      final policies = events.whereType<ToolPolicyEvaluated>().toList();
      expect(
        policies.map((event) => event.invocationId),
        prepared.map((event) => event.invocation.id),
      );
      expect(policies.map((event) => event.decision), [
        ToolPolicyDecision.allow,
        ToolPolicyDecision.ask,
        ToolPolicyDecision.ask,
      ]);
      final completed = events.whereType<ToolExecutionCompleted>().toList();
      expect(
        completed.map((event) => event.invocationId),
        prepared.map((event) => event.invocation.id),
      );
      expect(
        events.whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId,
        ),
        prepared.map((event) => event.invocation.id),
      );
      for (final completion in completed) {
        expect(completion.outcome.disposition, ToolOutcomeDisposition.success);
        expect(
          completion.outcome.hostData['environmentId'],
          authority.environmentId.value,
        );
      }
      expect(completed.first.outcome.hostData['relativePath'], _sourcePath);
      expect(completed.first.outcome.hostData['text'], _taskText);
      expect(completed.first.outcome.hostData['revision'], observedRevision);
      expect(completed[1].outcome.hostData, {
        'environmentId': authority.environmentId.value,
        'relativePath': _sourcePath,
        'editCount': 1,
        'newRevision': patchedRevision,
      });
      expect(
        completed[1].outcome.effectCertainty,
        EffectCertainty.knownOccurred,
      );
      final ToolOutcome commandOutcome = completed.last.outcome;
      expect(commandOutcome.effectCertainty, EffectCertainty.knownOccurred);
      expect(commandOutcome.hostData, {
        'environmentId': authority.environmentId.value,
        ..._commandArguments,
        'termination': 'exited',
        'exitCode': 0,
        'stdout': '',
        'stderr': '',
        'stdoutTruncated': false,
        'stderrTruncated': false,
      });
      expect(
        commandOutcome.modelContent,
        _toolOutput(outbound.last, 'command'),
      );
      expect(
        completed[1].outcome.modelContent,
        _toolOutput(outbound.last, 'patch'),
      );
      expect(events.whereType<ToolInvocationCompleted>(), isEmpty);
      expect(
        events.whereType<RunInterrupted>().map((event) => event.interruption),
        [patchInterruption, commandInterruption],
      );
      final resolutions = events.whereType<RunInterruptionResolved>().toList();
      expect(resolutions.map((event) => event.interruption), [
        patchInterruption,
        commandInterruption,
      ]);
      for (final resolved in resolutions) {
        final ToolApprovalInterruption interruption =
            resolved.interruption as ToolApprovalInterruption;
        final ToolApprovalResolution resolution =
            resolved.resolution as ToolApprovalResolution;
        expect(resolution.interruptionId, interruption.id);
        expect(resolution.toolInvocationId, interruption.toolInvocationId);
        expect(resolution.approved, isTrue);
        final int resolvedIndex = events.indexOf(resolved);
        final int startedIndex = events.indexWhere(
          (event) =>
              event is ToolExecutionStarted &&
              event.invocationId == interruption.toolInvocationId,
        );
        final int completedIndex = events.indexWhere(
          (event) =>
              event is ToolExecutionCompleted &&
              event.invocationId == interruption.toolInvocationId,
        );
        expect(resolvedIndex, lessThan(startedIndex));
        expect(startedIndex, lessThan(completedIndex));
        expect(
          completedIndex,
          lessThan(
            events.lastIndexWhere((event) => event is ModelInvocationStarted),
          ),
        );
      }
      final EnvironmentTextFile resultingFile = await runtime
          .lifecycle
          .environmentRuntime
          .currentMaterialization(authority.environmentId)!
          .provider
          .readFile(authority.environmentId, _sourcePath);
      expect(resultingFile.text, _patchedText);
      expect(resultingFile.revision, patchedRevision);

      await tester.ensureVisible(
        find.descendant(of: sessionHost, matching: find.text(_answer)),
      );
      expect(inspection.cards.first, same(cardC));
      expect(inspection.cards.map((card) => card.id), [
        cardC.id,
        cardB.id,
        cardA.id,
      ]);
      expect(inspectionHost, findsOneWidget);
      expect(
        tester.widget<InspectionHost>(cardHost(cardC)).activity,
        same(activity),
      );
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation),
        same(patchWidget),
      );
      expect(tester.state(patchPresentation), same(patchState));
      expect(
        tester.widget<$StatefulWidget$bridge>(patchPresentation).$runtime,
        same(patchRuntime),
      );
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              toolHost(patchInterruption.toolInvocationId),
            )
            .source,
        same(patchSource),
      );
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation),
        same(commandWidget),
      );
      expect(tester.state(commandPresentation), same(commandState));
      expect(
        tester.widget<$StatefulWidget$bridge>(commandPresentation).$runtime,
        same(commandRuntime),
      );
      expect(
        tester.widget<ToolActivityCompactHost>(commandCompactHost).source,
        same(commandSource),
      );
      expect(
        patchSource.snapshot.outcome!.hostData['newRevision'],
        patchedRevision,
      );
      expect(commandSource.snapshot.outcome!.hostData, commandOutcome.hostData);
      _expectVerticalOrder(tester, [
        reasoningAHost,
        patchCompactHost,
        reasoningBHost,
        commandCompactHost,
      ]);
      _expectNoPresentationSecrets(tester, controller);
      expect(
        tester.widget<$StatefulWidget$bridge>(chatPresentation),
        same(chatWidget),
      );
      expect(tester.state(chatPresentation), same(chatState));
      expect(
        tester.widget<$StatefulWidget$bridge>(chatPresentation).$runtime,
        same(chatRuntime),
      );

      // Dismissing C leaves B and A, including their live presentation resources.
      final Finder closeInspection = find.descendant(
        of: cardHost(cardC),
        matching: find.byTooltip('Dismiss Inspection'),
      );
      await tester.ensureVisible(closeInspection);
      await tester.tap(closeInspection);
      await tester.pumpAndSettle();
      expect(inspection.cards.map((card) => card.id), [cardB.id, cardA.id]);
      expect(cardHost(cardC), findsNothing);
      expect(inspectionHost, findsOneWidget);
      expect(find.byType(ToolActivityInspectionHost), findsNothing);
      expect(find.byType(ModelNativeActivityInspectionHost), findsOneWidget);
      expect(patchState.mounted, isFalse);
      expect(tester.state(commandPresentation), same(commandState));
      expect(tester.state(reasoningAHost), same(reasoningAState));
      expect(tester.state(reasoningBHost), same(reasoningBState));
      expect(tester.state(initialNativeHost), same(initialNativeState));
      _expectVerticalOrder(tester, [groupCard, cardHost(cardA)]);
      expect(tester.state(chatPresentation), same(chatState));
      expect(
        tester.widget<$StatefulWidget$bridge>(chatPresentation).$runtime,
        same(chatRuntime),
      );
      expect(controller.currentRun, same(execution));
      expect(run.state, RunState.completed);
      expect(run.journal.records.map((record) => record.event), events);
      expect(controller.snapshot, same(snapshot));
      expect(controller.activityForRun(run.id), same(activity));
      expect(
        controller.activitySummary(run.id, batch.invocationId)!.content,
        _narration,
      );
      expect(controller.activitySnapshots, [initialActivity, activity]);
      expect(
        runtime.chat.sessions.obtain(session.id).snapshot().entries,
        snapshot.entries,
      );
      expect(narratedActivity, findsOneWidget);
      expect(fallbackActivity, findsOneWidget);
      expect(
        find.descendant(of: sessionHost, matching: find.text(_answer)),
        findsOneWidget,
      );
      expect(controller.pendingApproval, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(outbound, hasLength(4));
      expect(tester.takeException(), isNull);

      expect(initialActivityLink, findsOneWidget);
      expect(controller.activityForRun(initialRun.id), same(initialActivity));
      expect(
        initialRun.journal.records.map((record) => record.event),
        initialEvents,
      );
      expect(run.journal.records.map((record) => record.event), events);
      expect(outbound, hasLength(4));
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskAfterPatch);
      expect(tester.state(chatPresentation), same(chatState));
      _expectNoPresentationSecrets(tester, controller);
      expect(tester.takeException(), isNull);

      await controller.close();
      updatePresentation = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await openAiFrontend.close();
      await commandFrontend.close();
      await filesystemFrontend.close();
      await frontend.close();
      await runtime.close();
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(await _sourceSnapshot(source), projectBefore);
      expect(await _sourceSnapshot(worktree), taskAfterPatch);
      expect(await credentials.readAsString(), credentialText);
      expect(
        runtime.store.requireSessionAuthority(session.id),
        same(authority),
      );
    }),
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

void _expectSafePresentation(
  ModelNativeOutput output, {
  required String id,
  required String summary,
  required String encrypted,
}) {
  expect(output.providerItemId, id);
  expect(output.providerNativeMetadata.kind, openAiResponsesItemKind);
  expect(output.providerNativeMetadata.compatibility, {
    'version': openAiResponsesItemVersion,
  });
  expect(output.providerNativeMetadata.data, {
    'item': _reasoning(id, summary, encrypted),
  });
  final ModelNativePresentation? presentation = output.presentation;
  expect(presentation, isNotNull);
  expect(presentation!.kind, openAiReasoningSummaryPresentationKind);
  expect(presentation.compactText, summary);
  // Exact recursive allowlist at the provider-to-host boundary, not merely that
  // an encrypted sentinel happens not to be rendered by this particular widget.
  expect(presentation.data, {
    'summaryParts': [summary],
    'truncated': false,
  });
  final String encoded = jsonEncode({
    'kind': presentation.kind,
    'compactText': presentation.compactText,
    'data': presentation.data,
  });
  for (final String secret in _presentationSecrets) {
    expect(encoded, isNot(contains(secret)));
  }
  expect(presentation.data.clear, throwsUnsupportedError);
  expect(
    (presentation.data['summaryParts']! as List<Object?>).clear,
    throwsUnsupportedError,
  );
}

void _expectNoPresentationSecrets(
  WidgetTester tester,
  ChatController controller,
) {
  final String timeline = controller.timeline
      .map((entry) => entry.content)
      .join('\n');
  final String rendered = tester
      .widgetList<Text>(find.byType(Text, skipOffstage: false))
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
      .join('\n');
  // Check the inputs to both rich and compact frontend bridges, including
  // retained collapsed bodies, not just the text those frontends choose to show.
  final List<Object?> bridgeInputs = [];
  for (final Widget widget in tester.allWidgets) {
    final ModelNativePresentation? presentation = switch (widget) {
      ModelNativeActivityCompactHost(:final presentation) => presentation,
      ModelNativeActivityInspectionHost(:final presentation) => presentation,
      _ => null,
    };
    if (presentation != null) {
      bridgeInputs.add({
        'kind': presentation.kind,
        'compactText': presentation.compactText,
        'data': presentation.data,
      });
    }
    final ToolActivityInspectionSource? source = switch (widget) {
      ToolActivityCompactHost(:final source) => source,
      ToolActivityInspectionHost(:final source) => source,
      _ => null,
    };
    if (source != null) {
      bridgeInputs.add({
        'canonicalArguments': source.snapshot.canonicalArguments,
        'hostData': source.snapshot.outcome?.hostData,
        'modelContent': source.snapshot.outcome?.modelContent,
      });
    }
  }
  final String bridgeData = jsonEncode(bridgeInputs);
  for (final String secret in _presentationSecrets) {
    expect(timeline, isNot(contains(secret)));
    expect(rendered, isNot(contains(secret)));
    expect(bridgeData, isNot(contains(secret)));
  }
  expect(find.text('Frontend unavailable.'), findsNothing);
  expect(find.text('Reasoning summary unavailable.'), findsNothing);
}

void _expectVerticalOrder(WidgetTester tester, List<Finder> items) {
  for (final item in items) {
    expect(item, findsOneWidget);
  }
  for (int index = 1; index < items.length; index++) {
    expect(
      tester.getBottomLeft(items[index - 1]).dy,
      lessThanOrEqualTo(tester.getTopLeft(items[index]).dy),
      reason: 'Inspection/timeline item $index must follow item ${index - 1}.',
    );
  }
}

String _revision(String output) =>
    jsonDecode(
          output
              .split('\n')
              .singleWhere((line) => line.startsWith('Revision: '))
              .substring('Revision: '.length),
        )
        as String;

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

Map<String, Object?> _message(String id, String text) => {
  'type': 'message',
  'id': id,
  'role': 'assistant',
  'status': 'completed',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
  ],
};

Map<String, Object?> _reasoning(String id, String summary, String encrypted) =>
    {
      'type': 'reasoning',
      'id': id,
      'status': 'completed',
      'summary': [
        {'type': 'summary_text', 'text': summary},
      ],
      'encrypted_content': encrypted,
      'content': [
        {'type': 'reasoning_text', 'text': _privateReasoning},
      ],
      'provider_extra': {'text': _providerExtra},
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
