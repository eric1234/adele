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
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_desktop/ui/execution/pending_tool_approval.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';

import '../../tool/chat_frontend_compiler.dart';

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
    'D1 real-EVC canonical final reply.';
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
    await compileChatFrontend(repositoryRoot: repository, artifact: evc);
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
    'normal real-EVC ChatGPT Run separately approves a patch and command in its Task',
    (tester) => tester.runAsync(() async {
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
                  _call('read', 'read_file', {'relativePath': _sourcePath}),
                );
              case 2:
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
                  _call('patch', 'apply_patch', patchArguments),
                );
                _output(
                  request.response,
                  _call('command', 'run_command', _commandArguments),
                );
              case 3:
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
      final ChatController controller = ChatController(
        runtime: runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: 'gpt-6-astra',
        runIds: MonotonicRunIdSource(seed: 'c2-fixture'),
        onChanged: () {
          refreshFrontend();
          updatePresentation?.call(() {});
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
      );
      refreshFrontend = frontend.refresh;
      addTearDown(frontend.close);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              updatePresentation = setState;
              return Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SessionPresentationHost(
                        session: session,
                        extensions: runtime.extensions,
                      ),
                      StockChatExecutionStatus(controller: controller),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder sessionHost = find.byType(SessionPresentationHost);
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
      expect(promptField, findsOneWidget);
      expect(send, findsOneWidget);
      expect(allowOnce, findsNothing);
      expect(tester.widget<TextField>(promptField).controller!.text, isEmpty);
      expect(tester.widget<TextField>(promptField).enabled, isTrue);
      expect(outbound, isEmpty);
      expect(controller.snapshot.entries, isEmpty);
      expect(controller.currentRun, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      // Keep process/socket work in real async, including the interpreted Send
      // callback. Pump UI only after each start/resume operation has settled.
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

      expect(endpointFailures, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isTrue);
      final execution = controller.currentRun!;
      final AgentRun run = execution.run;
      expect(run.id, RunId('run-c2-fixture-1'));
      expect(run.sessionId, session.id);
      expect(run.state, RunState.waiting);
      expect(outbound, hasLength(2));
      expect(controller.snapshot.entries.single.content, _prompt);
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

      expect(endpointFailures, isEmpty);
      expect(controller.failure, isNull);
      expect(controller.currentRun, same(execution));
      expect(controller.activeRunFuture, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isTrue);
      expect(run.state, RunState.waiting);
      expect(outbound, hasLength(2));
      expect(controller.snapshot.entries.single.content, _prompt);
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

      expect(controller.failure, isNull);
      expect(controller.currentRun, same(execution));
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(controller.isRunning, isFalse);
      expect(run.state, RunState.completed);
      expect(run.failure, isNull);
      expect(run.interruptions, isEmpty);
      expect(outbound, hasLength(3));
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

      await controller.close();
      updatePresentation = null;
      await tester.pumpWidget(const SizedBox.shrink());
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
