@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/prepared_main_content_host.dart';
import 'package:adele_desktop/plugins/temporary_chatgpt_selection.dart';
import 'package:adele_desktop/terminal/environment_terminal_owner.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/console/console_controller.dart';
import 'package:adele_desktop/ui/console/workbench_console.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:code_forge/code_forge.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:xterm2/xterm.dart';

import '../../../tools/git_pty_artifact.dart';
import '../../../tools/stock_frontend_descriptors.dart';
import '../../tool/chat_frontend_compiler.dart';
import '../../tool/local_directory_project_frontend_compiler.dart';
import '../../tool/main_content_fixture.dart';
import '../../tool/main_content_frontend_compiler.dart';
import '../../tool/openai_activity_frontend_compiler.dart';
import '../../tool/self_hosting/development_self_hosting.dart';
import '../../tool/task_browser_frontend_compiler.dart';
import '../../tool/terminal_frontend_compiler.dart';
import '../../tool/tool_inspection_frontend_compiler.dart';

const _gitPluginId = 'dev.adele.plugin.git-environment';
const _agentsMdPluginId = 'dev.adele.plugin.agents-md';
const _searchPluginId = 'dev.adele.plugin.search-tools';
const _filesystemPluginId = 'dev.adele.plugin.filesystem-tools';
const _commandPluginId = 'dev.adele.plugin.command-tools';
const _openAiPluginId = 'dev.adele.openai';
const _chatPluginId = 'dev.adele.plugin.chat-strategy';
const _localDirectoryProjectPluginId =
    'dev.adele.plugin.local-directory-project';
const _taskBrowserPluginId = 'dev.adele.plugin.task-browser';
const _terminalPluginId = 'dev.adele.plugin.terminal';
const _sourcePath = 'lib/task_answer.dart';
const _taskText = 'const taskAnswer = "task-worktree-only";\n';
const _patchedText = 'const taskAnswer = "approved-task-value";\n';
const _agentsText = 'Inspect source before proposing an edit and validation.\n';
const _projectText = 'const projectAnswer = "project-source-only"; \t\n';
const _projectAgentsText = 'Project-only guidance must not be used.\n';
const _initialPrompt = '  Explain the approval workflow\twithout tools.  ';
const _initialAnswer =
    'Source edits and validation commands require separate approvals.';
const _siblingPrompt = 'A separate conversation in the same Task.';
const _siblingAnswer = 'Only the sibling Session owns this answer.';
const _otherPrompt = 'A conversation in another Task.';
const _otherAnswer = 'Only the other Task Session owns this answer.';
const _prompt =
    'Read lib/task_answer.dart, change taskAnswer to "approved-task-value", '
    'and propose git diff --check. Wait for each approval.';
const _narration = 'Updating the test file and validating the change.';
const _reasoning = 'Checking the exact revision before the patch.';
const _encrypted = 'f3g-encrypted-replay-never-present';
const _privateReasoning = 'f3g-private-reasoning-never-present';
const _commandArguments = <String, Object?>{
  'program': 'git',
  'arguments': ['diff', '--check'],
  'workingDirectory': '',
  'timeoutSeconds': 5,
};

void main() {
  late _PreparedProduct prepared;
  setUpAll(() async {
    try {
      prepared = await _PreparedProduct.prepare();
    } on PluginBuildFailure catch (error) {
      fail(
        '$error\n${error.diagnostic?.stdoutText}\n${error.diagnostic?.stderrText}',
      );
    }
  });

  for (final cleanupFailure in [false, true]) {
    testWidgets(
      cleanupFailure
          ? 'normal navigation completes after a contributed pane cleanup failure'
          : 'normal catalog editor panes preserve the stock Chat draft and active Run',
      (tester) => tester.runAsync(() async {
        await tester.binding.setSurfaceSize(const Size(1800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = await _ProductFixture.create();
        final root = await prepared.copyInstallations(fixture.directory);
        await installMainContentFixture(
          installationRoot: root,
          artifact: await prepared.mainContentFixture(),
        );
        final resources = MainContentFixtureResources();
        addTearDown(resources.dispose);
        final cleanupError = StateError('fixture editor A release failed');
        final cleanupStack = StackTrace.fromString(
          'fixture editor A release stack',
        );
        final released = <String>[];
        final accesses = <bool Function()>[];
        var failRelease = false;
        final mainContentHost = cleanupFailure
            ? PreparedMainContentHost(
                createBinding:
                    ({
                      required installation,
                      required descriptor,
                      required session,
                      required paneId,
                    }) {
                      final binding = resources.host.createBinding!(
                        installation: installation,
                        descriptor: descriptor,
                        session: session,
                        paneId: paneId,
                      );
                      if (binding == null) return null;
                      return PreparedMainContentPaneBinding(
                        ready: binding.ready,
                        requestFocus: binding.requestFocus,
                        createBridge: (isActive) {
                          accesses.add(isActive);
                          return binding.createBridge(isActive);
                        },
                        release: () {
                          released.add(paneId);
                          binding.release?.call();
                          if (failRelease && paneId == 'editor-a') {
                            failRelease = false;
                            Error.throwWithStackTrace(
                              cleanupError,
                              cleanupStack,
                            );
                          }
                        },
                      );
                    },
              )
            : resources.host;
        final releaseResponse = Completer<void>();
        final outbound = <Map<String, Object?>>[];
        final endpointFailures = <(Object, StackTrace)>[];
        const draft = '  Retain this exact draft\twhile editor panes change.  ';
        const answer = 'The original Chat Run completed without replacement.';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          try {
            expect(request.method, 'POST');
            expect(request.uri.path, '/backend-api/codex/responses');
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, Object?>;
            outbound.add(body);
            expect(
              (body['input']! as List).where((item) => item['role'] == 'user'),
              [_userInput(draft)],
            );
            await releaseResponse.future;
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            _output(request.response, _message('main-content-answer', answer));
            _sse(request.response, {
              'type': 'response.completed',
              'response': {'id': 'main-content-run', 'model': 'gpt-6-astra'},
            });
          } on Object catch (error, stack) {
            endpointFailures.add((error, stack));
          } finally {
            await request.response.close();
          }
        });
        addTearDown(() async {
          await server.close(force: true);
          await subscription.cancel();
        });
        try {
          await fixture.launch(
            tester,
            prepared,
            root: root,
            endpoint: server,
            mainContentHost: mainContentHost,
          );
          final runtime = fixture.runtime;
          expect(runtime.plugins.catalog!.issues, isEmpty);
          final installation = runtime.plugins.catalog!.installations
              .singleWhere(
                (entry) =>
                    entry.metadata.id.value == mainContentFixturePluginId,
              );
          expect(installation.backendArtifactUri, isNull);
          await _terminalUntil(
            tester,
            () => runtime.extensions
                .discover(mainContentContributions)
                .any(
                  (entry) =>
                      entry.id == mainContentFixtureDescriptor.extensionId,
                ),
            'synthetic catalog contribution activation',
          );
          expect(
            runtime.extensions
                .discover(mainContentContributions)
                .map((entry) => entry.id),
            unorderedEquals([
              ExtensionId('$_chatPluginId.presentation'),
              mainContentFixtureDescriptor.extensionId,
            ]),
          );
          expect(resources.editors, isEmpty);
          await fixture.openTask(tester);
          await _terminalTap(tester, find.text('New Chat Session'));
          await _terminalUntil(
            tester,
            () =>
                _composer().evaluate().isNotEmpty &&
                find.byType(CodeForge).evaluate().length == 1,
            'stock Chat and initialized prepared editor A',
          );
          final session = _session(tester);
          final chat = _chatClient(
            runtime.plugins.backends
                .singleWhere(
                  (backend) =>
                      backend.installation.metadata.id.value == _chatPluginId,
                )
                .connection!,
          );
          final chatView = _chatView();
          final chatElement = tester.element(chatView);
          final chatWidget = tester.widget<$StatefulWidget$bridge>(chatView);
          final chatState = tester.state(chatView);
          final chatRuntime = chatWidget.$runtime;
          final composerController = tester
              .widget<TextField>(_composer())
              .controller!;
          final editorA = resources.editor(session.id, 'editor-a')!;
          final nativeA = tester.widget<CodeForge>(find.byType(CodeForge));
          final editorElementA = tester.element(find.byType(CodeForge));

          void retainedChat() {
            expect(_session(tester), same(session));
            expect(runtime.store.session(session.id), same(session));
            expect(tester.element(chatView), same(chatElement));
            expect(tester.widget(chatView), same(chatWidget));
            expect(tester.state(chatView), same(chatState));
            expect(
              tester.widget<$StatefulWidget$bridge>(chatView).$runtime,
              same(chatRuntime),
            );
            expect(
              tester.widget<TextField>(_composer()).controller,
              same(composerController),
            );
            expect(resources.editor(session.id, 'editor-a'), same(editorA));
            expect(editorA.isDisposed, isFalse);
            final a = find.byWidgetPredicate(
              (widget) =>
                  widget is CodeForge &&
                  identical(widget.controller, nativeA.controller),
            );
            expect(tester.element(a), same(editorElementA));
          }

          Future<void> action(String label) async {
            await _terminalTap(tester, find.widgetWithText(TextButton, label));
            retainedChat();
          }

          Future<void> edit(String label) async {
            await action(label);
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.home);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump();
            // Ordinary native editing, not an interpreted text-mutation backdoor.
            await tester.sendKeyEvent(LogicalKeyboardKey.delete);
            await tester.pump();
          }

          await tester.enterText(_composer(), draft);
          await _terminalUntil(
            tester,
            () async =>
                (await chat.snapshot(session.id.value)).draftRequest == draft,
            'exact backend draft save',
          );
          await action('Open B');
          await _terminalUntil(
            tester,
            () => find.byType(CodeForge).evaluate().length == 2,
            'prepared editor B',
          );
          final editorB = resources.editor(session.id, 'editor-b')!;
          expect(editorB, isNot(same(editorA)));
          final nativeB = tester
              .widgetList<CodeForge>(find.byType(CodeForge))
              .singleWhere(
                (widget) => !identical(widget.controller, nativeA.controller),
              );
          final editorElementB = tester.element(
            find.byWidgetPredicate(
              (widget) =>
                  widget is CodeForge &&
                  identical(widget.controller, nativeB.controller),
            ),
          );
          await action('Rename B');
          expect(find.text('Renamed B'), findsOneWidget);
          await action('Reverse editors');
          expect(
            tester.getTopLeft(find.text('Renamed B')).dx,
            lessThan(tester.getTopLeft(find.text('Editor A')).dx),
          );
          await edit('Focus A');
          expect(editorB.snapshot()['text'], mainContentFixtureTextB);
          await edit('Focus B');
          expect(
            editorA.snapshot()['text'],
            mainContentFixtureTextA.substring(1),
          );
          expect(
            editorB.snapshot()['text'],
            mainContentFixtureTextB.substring(1),
          );
          expect(
            tester.element(
              find.byWidgetPredicate(
                (widget) =>
                    widget is CodeForge &&
                    identical(widget.controller, nativeB.controller),
              ),
            ),
            same(editorElementB),
          );
          // Existing B is focused, not replaced or retitled.
          await action('Open B');
          expect(resources.editor(session.id, 'editor-b'), same(editorB));
          expect(find.text('Renamed B'), findsOneWidget);
          await action('Focus A');
          await action('Remove B');
          expect(editorB.isDisposed, isTrue);
          expect(resources.editor(session.id, 'editor-b'), isNull);
          retainedChat();
          expect(composerController.text, draft);
          expect((await chat.snapshot(session.id.value)).draftRequest, draft);
          expect((await chat.snapshot(session.id.value)).entries, isEmpty);
          expect(fixture.runIds.values, isEmpty);
          expect(outbound, isEmpty);

          await _terminalTap(tester, find.widgetWithText(TextButton, 'Send'));
          await _terminalUntil(
            tester,
            () => outbound.isNotEmpty && fixture.status(tester).isAdvancing,
            'original gated Responses invocation',
          );
          final runId = fixture.runIds.values.single;
          final submitted = await chat.snapshot(session.id.value);
          expect(submitted.entries.single.content, draft);
          expect(submitted.entries.single.runId, runId.value);
          expect(runtime.store.runRecord(runId), isNull);
          await action('Open B');
          await _terminalUntil(
            tester,
            () => find.byType(CodeForge).evaluate().length == 2,
            'fresh B during active Run',
          );
          final reopenedB = resources.editor(session.id, 'editor-b')!;
          expect(reopenedB, isNot(same(editorB)));
          expect(reopenedB.snapshot()['text'], mainContentFixtureTextB);
          await action('Rename B');
          await action('Reverse editors');
          await edit('Focus B');
          await action('Focus A');
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          expect(editorA.snapshot()['text'], mainContentFixtureTextA);
          expect(
            reopenedB.snapshot()['text'],
            mainContentFixtureTextB.substring(1),
          );
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await action('Remove B');
          retainedChat();
          final stillRunning = await chat.snapshot(session.id.value);
          expect(stillRunning.entries.single.id, submitted.entries.single.id);
          expect(stillRunning.entries.single.runId, runId.value);
          expect(runtime.store.runRecord(runId), isNull);
          expect(fixture.runIds.values, [runId]);
          expect(fixture.status(tester).isAdvancing, isTrue);
          expect(fixture.status(tester).failureMessage, isNull);
          expect(outbound, hasLength(1));
          expect(composerController.text, '');
          expect((await chat.snapshot(session.id.value)).draftRequest, '');
          expect(
            editorA.snapshot()['text'],
            mainContentFixtureTextA.substring(1),
          );

          if (cleanupFailure) {
            await action('Open B');
            await _terminalUntil(
              tester,
              () => find.byType(CodeForge).evaluate().length == 2,
              'second pane before failing departure',
            );
            final departingB = resources.editor(session.id, 'editor-b')!;
            final oldAccesses = accesses.toList();
            final releasedBefore = released.length;
            final oldRename = tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Rename B'))
                .onPressed!;
            final diagnostics = <FlutterErrorDetails>[];
            final originalOnError = FlutterError.onError;
            FlutterError.onError = (details) {
              if (identical(details.exception, cleanupError)) {
                diagnostics.add(details);
              } else {
                originalOnError?.call(details);
              }
            };
            try {
              failRelease = true;
              await _terminalTap(
                tester,
                find.byKey(const ValueKey('task-breadcrumb')),
              );
              await _terminalUntil(
                tester,
                () =>
                    find.byType(MainContentHost).evaluate().isEmpty &&
                    find.text('New Chat Session').evaluate().isNotEmpty,
                'usable Task Browser after accepted departure cleanup fails',
              );
            } finally {
              FlutterError.onError = originalOnError;
            }
            final shell = tester.widget<AdeleShell>(find.byType(AdeleShell));
            expect(shell.sessionPresented, isFalse);
            expect(shell.sessionContent, isNull);
            expect(shell.inspection, isNull);
            expect(shell.console, isNull);
            expect(
              find.text(
                'Left the Session, but some presentation resources could not be released.',
              ),
              findsOneWidget,
            );
            expect(
              find.textContaining('Save pending changes and try again'),
              findsNothing,
            );
            expect(diagnostics, hasLength(1));
            expect(diagnostics.single.exception, same(cleanupError));
            expect(
              diagnostics.single.stack.toString(),
              cleanupStack.toString(),
            );
            expect(released.sublist(releasedBefore), ['editor-a', 'editor-b']);
            expect(oldAccesses.every((isActive) => !isActive()), isTrue);
            expect(editorA.isDisposed, isTrue);
            expect(departingB.isDisposed, isTrue);
            expect(resources.editors, isEmpty);
            expect(runtime.store.session(session.id), same(session));
            expect(runtime.store.runRecord(runId), isNull);
            expect(fixture.runIds.values, [runId]);
            expect(outbound, hasLength(1));

            // A deliberate return obtains fresh views of the original running owner.
            await _terminalTap(tester, find.text('Open'));
            await _terminalUntil(
              tester,
              () =>
                  _composer().evaluate().isNotEmpty &&
                  find.byType(CodeForge).evaluate().length == 1,
              'fresh Chat and editor access on return',
            );
            expect(_session(tester), same(session));
            expect(tester.state(_chatView()), isNot(same(chatState)));
            expect(
              resources.editor(session.id, 'editor-a'),
              isNot(same(editorA)),
            );
            expect(fixture.status(tester).isAdvancing, isTrue);
            expect(oldAccesses.every((isActive) => !isActive()), isTrue);
            await _terminalTap(
              tester,
              find.widgetWithText(TextButton, 'Open B'),
            );
            await _terminalUntil(
              tester,
              () => find.byType(CodeForge).evaluate().length == 2,
              'fresh second editor on return',
            );
            expect(oldRename, returnsNormally);
            expect(find.text('Editor B'), findsOneWidget);
            expect(find.text('Renamed B'), findsNothing);
            expect(released.length, releasedBefore + 2);
            expect(fixture.runIds.values, [runId]);
            expect(outbound, hasLength(1));
          }

          releaseResponse.complete();
          await _terminalUntil(
            tester,
            () =>
                find.text(answer).evaluate().isNotEmpty &&
                !fixture.status(tester).isAdvancing,
            'original Chat Run completion',
          );
          _rethrowEndpointFailure(endpointFailures);
          if (!cleanupFailure) retainedChat();
          expect(
            runtime.store.runRecord(runId)!.state,
            RunTerminalState.completed,
          );
          expect(fixture.runIds.values, [runId]);
          expect(outbound, hasLength(1));
          final snapshot = await chat.snapshot(session.id.value);
          expect(snapshot.entries.map((entry) => (entry.role, entry.content)), [
            ('user', draft),
            ('assistant', answer),
          ]);
          expect(snapshot.entries.first.runId, runId.value);
          expect(find.text('Frontend unavailable.'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          failRelease = false;
          // Finish real backend I/O before Flutter's automatic fake-async disposal.
          // Also unblock the model if a preceding assertion failed while gated.
          if (!releaseResponse.isCompleted) releaseResponse.complete();
          await tester.binding.handleRequestAppExit().timeout(
            const Duration(seconds: 30),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
        expect(resources.editors, isEmpty);
      }),
    );
  }

  testWidgets(
    'normal application concurrently runs separate Sessions and retains hidden approvals and output',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _ProductFixture.create();
      final processServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final children = <_PresentationProcess>[];
      final processSubscription = processServer.listen((socket) {
        children.add(_PresentationProcess(socket));
      });
      Map<String, Object?> arguments(String label) => {
        'program': prepared.dartaotruntime,
        'arguments': [
          prepared.commandProcess.path,
          '${processServer.port}',
          'concurrent',
          label,
        ],
        'workingDirectory': '',
        'timeoutSeconds': 180,
      };
      const prompts = {
        'A':
            'Session A: run my two controlled commands with separate approvals.',
        'B': 'Session B: run my controlled command independently of Session A.',
      };
      const answers = {
        'A': 'Session A completed both commands in its own worktree.',
        'B': 'Session B completed its command in its separate worktree.',
      };
      final outbound = <String, List<Map<String, Object?>>>{'A': [], 'B': []};
      final endpointFailures = <(Object, StackTrace)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        try {
          expect(request.method, 'POST');
          expect(request.uri.path, '/backend-api/codex/responses');
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, Object?>;
          final input = (body['input']! as List<Object?>)
              .cast<Map<String, Object?>>();
          final users = input.where((item) => item['role'] == 'user').toList();
          expect(users, hasLength(1));
          // Route by this Session's own conversation and tool replay. Neither
          // interleaving nor a global request count selects the response.
          final prompt =
              ((users.single['content']! as List).single as Map)['text'];
          final label = prompts.entries
              .singleWhere((entry) => entry.value == prompt)
              .key;
          final other = label == 'A' ? 'B' : 'A';
          expect(users.single, _userInput(prompts[label]!));
          expect(
            body['instructions'],
            contains('CONCURRENT_${label}_INSTRUCTIONS'),
          );
          expect(
            body['instructions'],
            isNot(contains('CONCURRENT_${other}_INSTRUCTIONS')),
          );
          expect(jsonEncode(input), isNot(contains('CONCURRENT_${other}1_')));
          outbound[label]!.add(body);
          final results = input
              .where((item) => item['type'] == 'function_call_output')
              .map((item) => item['call_id'])
              .toSet();
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          final first = '${label}1';
          if (!results.contains(first)) {
            expect(results, isEmpty);
            _output(
              request.response,
              _call(first, 'run_command', arguments(first)),
            );
          } else {
            expect(
              _toolOutput(body, first),
              contains('CONCURRENT_${first}_END'),
            );
            expect(_toolOutput(body, first), contains('Exit code: 0'));
            if (label == 'A' && !results.contains('A2')) {
              expect(results, {'A1'});
              _output(
                request.response,
                _call('A2', 'run_command', arguments('A2')),
              );
            } else {
              expect(results, label == 'A' ? {'A1', 'A2'} : {'B1'});
              if (label == 'A') {
                expect(_toolOutput(body, 'A2'), contains('CONCURRENT_A2_END'));
              }
              _output(
                request.response,
                _message('$label-final', answers[label]!),
              );
            }
          }
          _sse(request.response, {
            'type': 'response.completed',
            'response': {
              'id': '$label-${results.length}',
              'model': 'gpt-6-astra',
            },
          });
        } on Object catch (error, stack) {
          endpointFailures.add((error, stack));
        } finally {
          await request.response.close();
        }
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
        await processSubscription.cancel();
        await processServer.close();
      });
      await fixture.launch(tester, prepared, endpoint: server);
      // Registered after launch so failed assertions unblock owned Run drainage
      // before application/backend teardown. Socket EOF also releases an as-yet
      // unobserved child whose PID has not reached the first handshake.
      addTearDown(() async {
        for (final child in children) {
          if (!child.exited && child.pid != null) {
            Process.killPid(child.pid!, ProcessSignal.sigterm);
          }
          child.socket.destroy();
          await child.lines.cancel();
        }
      });
      final runtime = fixture.runtime;
      expect(runtime.plugins.catalog!.issues, isEmpty);
      expect(runtime.plugins.host, isA<PluginBackendHost>());
      for (final id in [_chatPluginId, _commandPluginId, _gitPluginId]) {
        final backend = runtime.plugins.backends.singleWhere(
          (backend) => backend.installation.metadata.id.value == id,
        );
        expect(backend.state, InstalledBackendState.active);
        expect(
          backend.installation.backendArtifactUri,
          prepared.backend(id).uri,
        );
      }
      final chat = _chatClient(
        runtime.plugins.backends
            .singleWhere(
              (backend) =>
                  backend.installation.metadata.id.value == _chatPluginId,
            )
            .connection!,
      );
      final commandConnection = runtime.plugins.backends
          .singleWhere(
            (backend) =>
                backend.installation.metadata.id.value == _commandPluginId,
          )
          .connection!;
      final command = CommandOutputServiceClient(
        commandConnection.channelFor(
          commandConnection.defaultConfigurationContext,
          commandOutputServiceId,
        ),
      );
      final inspection = find.byType(ToolActivityInspectionHost).first;
      final consoleHost = find.byType(WorkbenchConsole);

      Future<void> browse() async {
        await _breadcrumb(tester, 'project-breadcrumb');
        await _terminalUntil(
          tester,
          () => find.byType(MainContentHost).evaluate().isEmpty,
          'leave the active Session without draining execution',
        );
        expect(fixture.shell(tester).navigationError, isNull);
        expect(find.byType(InspectionHost), findsNothing);
        expect(consoleHost, findsNothing);
      }

      Future<void> open(Task task, Session session) async {
        await _terminalTap(tester, find.text(task.title));
        await _terminalTap(tester, _sessionRow(session.id));
        await _terminalUntil(
          tester,
          () => _composer().evaluate().isNotEmpty,
          'fresh Chat presentation for ${session.id.value}',
        );
        expect(_session(tester), same(session));
      }

      Future<_PresentedCapture> inspect(
        Session session,
        RunId runId,
        int index,
      ) async {
        final compact = find.descendant(
          of: _chatView(),
          matching: find.textContaining('Run Command:'),
        );
        await _terminalUntil(
          tester,
          () => compact.evaluate().length > index,
          'reattached Chat command activity',
        );
        await _terminalTap(
          tester,
          find
              .ancestor(
                of: compact.at(index),
                matching: find.byType(TextButton),
              )
              .first,
        );
        await _terminalUntil(
          tester,
          () => inspection.evaluate().isNotEmpty,
          'stock Command Inspection',
        );
        final source = tester
            .widget<ToolActivityInspectionHost>(inspection)
            .source;
        expect(source.sessionId, session.id);
        expect(source.runId, runId);
        return _PresentedCapture(
          command,
          session.id.value,
          runId.value,
          source.snapshot.id.value,
        );
      }

      Future<void> expand() => _terminalTap(
        tester,
        find.descendant(of: inspection, matching: find.text('Show more')),
      );

      await fixture.openTask(tester);
      final project = fixture.shell(tester).project!;
      final taskA = fixture.shell(tester).task!;
      final environmentA = fixture.shell(tester).environment!;
      final worktreeA = await Directory(
        developmentGitWorktreePath(project, environmentA),
      ).resolveSymbolicLinks();
      await File(
        '$worktreeA/AGENTS.md',
      ).writeAsString('CONCURRENT_A_INSTRUCTIONS\n');
      await _tap(tester, 'New Chat Session');
      await _send(tester, prompts['A']!);
      await _terminalUntil(
        tester,
        () => fixture.status(tester).pendingApproval != null,
        'A first approval',
      );
      final sessionA = _session(tester);
      final runA = fixture.runIds.values.single;
      final statusA = fixture.status(tester);
      final approvalA1 = statusA.pendingApproval!;
      expect(jsonDecode(approvalA1.canonicalArgumentsJson), arguments('A1'));
      final captureA1 = await inspect(sessionA, runA, 0);
      expect((await captureA1.state()).state, 'absent');
      await _terminalTap(tester, find.text('Allow once'));
      await _terminalUntil(
        tester,
        () => children.length == 1,
        'A command started',
      );
      final childA1 = children.single;
      await childA1.stage('connected');
      expect(childA1.workingDirectory, worktreeA);
      childA1.release('produce');
      await childA1.stage('started');
      await _projectionText(tester, inspection, 'CONCURRENT_A1_START');
      await expand();
      await _projectionText(tester, consoleHost, 'CONCURRENT_A1_START');
      final console = tester.widget<WorkbenchConsole>(consoleHost).controller;
      final tabA1 = console.selectedTab!;
      expect(console.eligibleTabs, [tabA1]);
      await browse();
      expect(find.textContaining('1 running'), findsWidgets);
      expect(await childA1.isAlive(), isTrue);
      expect((await captureA1.state()).state, 'capturing');

      // A is still blocked in a real process, not an approval or fabricated
      // controller state, while B establishes a different Environment and runs.
      await fixture.createTask(tester, 'Concurrent Task B');
      final taskB = fixture.shell(tester).task!;
      final environmentB = fixture.shell(tester).environment!;
      final worktreeB = await Directory(
        developmentGitWorktreePath(project, environmentB),
      ).resolveSymbolicLinks();
      expect(worktreeB, isNot(worktreeA));
      expect(environmentB.id, isNot(environmentA.id));
      await File(
        '$worktreeB/AGENTS.md',
      ).writeAsString('CONCURRENT_B_INSTRUCTIONS\n');
      await _tap(tester, 'New Chat Session');
      await _send(tester, prompts['B']!);
      await _terminalUntil(
        tester,
        () => fixture.status(tester).pendingApproval != null,
        'B independent approval',
      );
      final sessionB = _session(tester);
      final runB = fixture.runIds.values.last;
      final statusB = fixture.status(tester);
      expect(sessionB.id, isNot(sessionA.id));
      expect(runB, isNot(runA));
      expect(runtime.lifecycle.databaseForSession(sessionA.id), isNotNull);
      expect(
        runtime.lifecycle.databaseForSession(sessionB.id),
        same(runtime.lifecycle.databaseForSession(sessionA.id)),
      );
      expect(console.eligibleTabs, isEmpty);
      expect(
        jsonDecode(statusB.pendingApproval!.canonicalArgumentsJson),
        arguments('B1'),
      );
      final captureB1 = await inspect(sessionB, runB, 0);
      await _terminalTap(tester, find.text('Allow once'));
      await _terminalUntil(
        tester,
        () => children.length == 2,
        'B command started while A lives',
      );
      final childB1 = children.last;
      await childB1.stage('connected');
      expect(childB1.workingDirectory, worktreeB);
      expect(childB1.pid, isNot(childA1.pid));
      childB1.release('produce');
      await childB1.stage('started');
      await _projectionText(tester, inspection, 'CONCURRENT_B1_START');
      await expand();
      await _projectionText(tester, consoleHost, 'CONCURRENT_B1_START');
      final tabB1 = console.selectedTab!;
      expect(console.eligibleTabs, [tabB1]);
      childB1.release('progress');
      await childB1.stage('progress');
      await _projectionText(tester, consoleHost, 'CONCURRENT_B1_PROGRESS');
      expect(
        _terminalBuffer(_projectionEngine(tester, consoleHost)),
        isNot(contains('CONCURRENT_A')),
      );
      childA1.release('progress');
      await childA1.stage('progress');
      await _terminalUntil(
        tester,
        () async => (await captureA1.tail()).contains('CONCURRENT_A1_PROGRESS'),
        'hidden A continues capture',
      );
      for (final (capture, child, environment) in [
        (captureA1, childA1, environmentA),
        (captureB1, childB1, environmentB),
      ]) {
        final state = await capture.state();
        expect(state.state, 'capturing');
        expect(state.environmentId, environment.id.value);
        expect(state.totalCodeUnits, greaterThan(0));
        expect(await child.isAlive(), isTrue);
        expect(runtime.store.runRecord(RunId(capture.runId)), isNull);
      }
      expect(outbound['A'], hasLength(1));
      expect(outbound['B'], hasLength(1));
      expect(fixture.runIds.values, [runA, runB]);
      await expectLater(
        command.getState(sessionB.id.value, runA.value, captureA1.invocationId),
        throwsA(
          isA<CommandOutputFailure>().having(
            (error) => error.code,
            'code',
            'association_mismatch',
          ),
        ),
      );

      await browse();
      expect(find.textContaining('1 running'), findsNWidgets(2));
      await open(taskA, sessionA);
      await _projectionText(tester, consoleHost, 'CONCURRENT_A1_PROGRESS');
      expect(console.selectedTab, same(tabA1));
      expect(console.eligibleTabs, [tabA1]);
      final reattachedA1 = await inspect(sessionA, runA, 0);
      expect(reattachedA1.invocationId, captureA1.invocationId);
      await _projectionText(tester, inspection, 'CONCURRENT_A1_PROGRESS');
      expect(fixture.status(tester).isAdvancing, isTrue);
      expect(children, hasLength(2));
      expect(await childA1.isAlive(), isTrue);
      expect(await childB1.isAlive(), isTrue);
      expect(
        _terminalBuffer(_projectionEngine(tester, consoleHost)),
        isNot(contains('CONCURRENT_B')),
      );
      await browse();
      await open(taskB, sessionB);
      await _projectionText(tester, consoleHost, 'CONCURRENT_B1_PROGRESS');
      expect(console.selectedTab, same(tabB1));

      childA1.release('exit');
      await _terminalUntil(
        tester,
        () async =>
            (await captureA1.state()).state == 'complete' &&
            outbound['A']!.length == 2,
        'hidden A finishes its first command and proposes another',
      );
      childA1.exited = true;
      expect(fixture.status(tester).pendingApproval, isNot(same(approvalA1)));
      expect(fixture.status(tester).isAdvancing, isTrue);
      expect(
        children,
        hasLength(2),
        reason: 'The second A command has not been approved.',
      );
      // B makes independent model/tool/output progress and completes while A is
      // hidden waiting for its next approval. Its composer remains usable.
      childB1.release('exit');
      await _terminalUntil(
        tester,
        () => find.text(answers['B']!).evaluate().isNotEmpty,
        'B finishes while A awaits approval',
      );
      childB1.exited = true;
      await _projectionText(tester, consoleHost, 'CONCURRENT_B1_END');
      expect(tester.widget<TextField>(_composer()).enabled, isTrue);
      const draftB = 'B remains usable while A needs attention.';
      await tester.enterText(_composer(), draftB);
      await browse();
      expect(find.textContaining('1 waiting'), findsOneWidget);
      await _terminalTap(tester, find.text(taskA.title));
      expect(
        find.descendant(
          of: _sessionRow(sessionA.id),
          matching: find.textContaining('Waiting for approval'),
        ),
        findsOneWidget,
      );
      await _terminalTap(tester, _sessionRow(sessionA.id));
      await _terminalUntil(
        tester,
        () =>
            find.byType(RunExecutionStatus).evaluate().isNotEmpty &&
            fixture.status(tester).pendingApproval != null,
        'reattached exact second A approval',
      );
      final approvalA2 = fixture.status(tester).pendingApproval!;
      expect(approvalA2, isNot(same(approvalA1)));
      expect(jsonDecode(approvalA2.canonicalArgumentsJson), arguments('A2'));
      expect(runtime.store.runRecord(runA), isNull);
      expect(
        (await chat.snapshot(
          sessionA.id.value,
        )).entries.map((entry) => (entry.role, entry.content, entry.runId)),
        [('user', prompts['A'], runA.value)],
      );
      // Old A and foreign B view callbacks have no current presentation authority.
      statusA.onDecision(approvalA1, true);
      statusA.onDecision(approvalA2, true);
      statusB.onDecision(approvalA2, true);
      await tester.pump();
      expect(fixture.status(tester).pendingApproval, same(approvalA2));
      expect(fixture.status(tester).isAdvancing, isFalse);
      expect(children, hasLength(2));
      final captureA2 = await inspect(sessionA, runA, 1);
      expect(captureA2.invocationId, isNot(captureA1.invocationId));
      expect((await captureA2.state()).state, 'absent');
      await _terminalTap(tester, find.text('Allow once'));
      await _terminalUntil(
        tester,
        () => children.length == 3,
        'only the exact second A command admitted',
      );
      final childA2 = children.last;
      await childA2.stage('connected');
      expect(childA2.workingDirectory, worktreeA);
      childA2.release('produce');
      await childA2.stage('started');
      await _projectionText(tester, inspection, 'CONCURRENT_A2_START');
      await expand();
      await _projectionText(tester, consoleHost, 'CONCURRENT_A2_START');
      expect(console.eligibleTabs, hasLength(2));
      final tabA2 = console.selectedTab!;
      childA2.release('progress');
      await childA2.stage('progress');
      await browse();
      await open(taskB, sessionB);
      await _projectionText(tester, consoleHost, 'CONCURRENT_B1_END');
      expect(console.selectedTab, same(tabB1));
      expect(console.eligibleTabs, [tabB1]);
      expect(tester.widget<TextField>(_composer()).controller!.text, draftB);
      childA2.release('exit');
      await _terminalUntil(
        tester,
        () async =>
            (await chat.snapshot(sessionA.id.value)).entries.last.content ==
            answers['A'],
        'hidden A persists canonical final answer',
      );
      childA2.exited = true;
      expect(_session(tester), same(sessionB));
      expect(find.text(answers['A']!), findsNothing);
      expect(find.text(answers['B']!), findsOneWidget);
      _rethrowEndpointFailure(endpointFailures);
      expect(outbound['A'], hasLength(3));
      expect(outbound['B'], hasLength(2));
      expect(fixture.runIds.values, [runA, runB]);
      expect(children, hasLength(3));

      for (final (session, runId, label, toolCount) in [
        (sessionA, runA, 'A', 2),
        (sessionB, runB, 'B', 1),
      ]) {
        final canonical = await chat.snapshot(session.id.value);
        expect(
          canonical.entries.map(
            (entry) => (entry.role, entry.content, entry.runId),
          ),
          [
            ('user', prompts[label], runId.value),
            ('assistant', answers[label], null),
          ],
        );
        final activity = runtime.lifecycle.runActivity(runId)!;
        expect(activity.sessionId, session.id);
        expect(activity.state, RunState.completed);
        expect(activity.tools, hasLength(toolCount));
        expect(activity.models, hasLength(toolCount + 1));
        expect(
          activity.tools.map((tool) => tool.providerCallId),
          label == 'A' ? ['A1', 'A2'] : ['B1'],
        );
        for (final tool in activity.tools) {
          expect(
            tool.changes.where(
              (change) => change.kind == ToolActivityKind.approvalRequested,
            ),
            hasLength(1),
          );
          expect(
            tool.changes
                .where(
                  (change) => change.kind == ToolActivityKind.approvalResolved,
                )
                .map((change) => change.approved),
            [true],
          );
          expect(
            tool.changes.where(
              (change) => change.kind == ToolActivityKind.executionStarted,
            ),
            hasLength(1),
          );
          expect(tool.outcome!.hostData['exitCode'], 0);
        }
        expect(runtime.store.runsForSession(session.id).single.id, runId);
      }
      for (final (capture, label, worktree, otherWorktree) in [
        (captureA1, 'A1', worktreeA, worktreeB),
        (captureA2, 'A2', worktreeA, worktreeB),
        (captureB1, 'B1', worktreeB, worktreeA),
      ]) {
        final state = await capture.state();
        expect(
          (state.state, state.exitCode, state.failure),
          ('complete', 0, null),
        );
        final output = await capture.tail();
        for (final stage in ['START', 'PROGRESS', 'STDERR', 'END']) {
          expect(output, contains('CONCURRENT_${label}_$stage'));
        }
        for (final other in ['A1', 'A2', 'B1']) {
          if (other != label) {
            expect(output, isNot(contains('CONCURRENT_${other}_')));
          }
        }
        expect(await File('$worktree/concurrent-$label.txt').exists(), isTrue);
        expect(
          await File('$otherWorktree/concurrent-$label.txt').exists(),
          isFalse,
        );
        expect(
          await File('${fixture.source.path}/concurrent-$label.txt').exists(),
          isFalse,
        );
      }
      expect(
        await File('${fixture.source.path}/AGENTS.md').readAsString(),
        _agentsText,
      );
      expect(await _git(fixture.source, ['diff', '--binary', 'HEAD']), '');
      await browse();
      expect(find.textContaining('1 waiting'), findsNothing);
      await open(taskA, sessionA);
      await _terminalUntil(
        tester,
        () => find.text(answers['A']!).evaluate().isNotEmpty,
        'reopened hidden completion',
      );
      expect(find.text(answers['B']!), findsNothing);
      await _projectionText(tester, consoleHost, 'CONCURRENT_A2_END');
      expect(console.selectedTab, same(tabA2));
      final historicalA1 = await inspect(sessionA, runA, 0);
      expect(historicalA1.invocationId, captureA1.invocationId);
      await _projectionText(tester, inspection, 'CONCURRENT_A1_END');
      await expand();
      expect(console.selectedTab, same(tabA1));
      expect(console.eligibleTabs, hasLength(2));
      await _projectionText(tester, consoleHost, 'CONCURRENT_A1_END');
      expect(fixture.status(tester).pendingApproval, isNull);
      expect(fixture.status(tester).failureMessage, isNull);
      expect(tester.widget<TextField>(_composer()).enabled, isTrue);
      expect(fixture.runIds.values, [runA, runB]);
      await _terminalReaped(
        tester,
        children.map((child) => child.pid!).toList(),
      );
      expect(tester.takeException(), isNull);
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      expect(commandConnection.isClosed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    }),
    skip: !Platform.isLinux || Abi.current() != Abi.linuxX64,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'T3b normal Chat keeps stock output tabs warm and restores cold Session history',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _ProductFixture.create();
      final root = await prepared.copyInstallations(fixture.directory);
      final helper = await prepared.installTerminal(root);
      final processServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final children = <_PresentationProcess>[];
      final processSubscription = processServer.listen((socket) {
        children.add(_PresentationProcess(socket));
      });
      final arguments = <String, Object?>{
        'program': prepared.dartaotruntime,
        'arguments': [
          prepared.commandProcess.path,
          '${processServer.port}',
          'presentation',
        ],
        'workingDirectory': '',
        'timeoutSeconds': 180,
      };
      final outbound = <Map<String, Object?>>[];
      final endpointFailures = <(Object, StackTrace)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        try {
          expect(request.method, 'POST');
          expect(request.uri.path, '/backend-api/codex/responses');
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, Object?>;
          outbound.add(body);
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          if (outbound.length <= 2) {
            if (outbound.length == 2) {
              expect(
                _toolOutput(body, 'presentation-1'),
                contains('Exit code: 23'),
              );
            }
            _output(
              request.response,
              _call(
                'presentation-${outbound.length}',
                'run_command',
                arguments,
              ),
            );
          } else {
            expect(outbound, hasLength(3));
            expect(
              _toolOutput(body, 'presentation-2'),
              contains('Exit code: 23'),
            );
            _output(
              request.response,
              _message(
                'presentation-final',
                'Both commands exited with code 23.',
              ),
            );
          }
          _sse(request.response, {
            'type': 'response.completed',
            'response': {
              'id': 't3b-${outbound.length}',
              'model': 'gpt-6-astra',
            },
          });
        } on Object catch (error, stack) {
          endpointFailures.add((error, stack));
        } finally {
          await request.response.close();
        }
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
        await processSubscription.cancel();
        await processServer.close();
      });
      await fixture.launch(
        tester,
        prepared,
        root: root,
        dartaotruntimeExecutable: await fixture.isolatedRuntime(prepared),
        endpoint: server,
        startupArguments: {
          _gitPluginId: ['--pty-helper=${helper.path}'],
        },
      );
      // Kill only fixture children on failed assertions, before application exit
      // drains an accepted Run. Observation must never be its cancellation route.
      addTearDown(() async {
        for (final child in children) {
          if (!child.exited && child.pid != null) {
            Process.killPid(child.pid!, ProcessSignal.sigterm);
          }
          child.socket.destroy();
          await child.lines.cancel();
        }
      });
      final runtime = fixture.runtime;
      expect(runtime.plugins.catalog!.issues, isEmpty);
      expect(runtime.plugins.host, isA<PluginBackendHost>());
      final commandBackend = runtime.plugins.backends.singleWhere(
        (backend) => backend.installation.metadata.id.value == _commandPluginId,
      );
      expect(commandBackend.state, InstalledBackendState.active);
      final command = CommandOutputServiceClient(
        commandBackend.connection!.channelFor(
          commandBackend.connection!.defaultConfigurationContext,
          commandOutputServiceId,
        ),
      );
      await fixture.openTask(tester);
      final project = fixture.shell(tester).project!;
      final task = fixture.shell(tester).task!;
      final environment = fixture.shell(tester).environment!;
      final worktree = developmentGitWorktreePath(project, environment);
      expect(
        runtime.lifecycle.environmentRuntime
            .currentMaterialization(environment.id)!
            .provider,
        isA<GeneratedEnvironmentProvider>(),
      );
      await _tap(tester, 'New Chat Session');
      await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
      final session = _session(tester);
      final console = tester
          .widget<WorkbenchConsole>(find.byType(WorkbenchConsole))
          .controller;
      expect(console.eligibleTabs, isEmpty);
      await _send(
        tester,
        'Run the same controlled command twice and report both exit codes.',
      );
      final captures = <_PresentedCapture>[];
      final completed = <CommandCaptureState>[];
      final outputTabs = <ConsoleTab>[];
      final outputEngines = <Terminal>[];
      final outputMounts = <TerminalViewState>[];
      late ConsoleTab shellTab;
      Object? previousApproval;

      Future<void> selectTab(ConsoleTab tab) => _terminalTap(
        tester,
        find.descendant(
          of: find.byKey(ObjectKey(tab)),
          matching: find.byType(TextButton),
        ),
      );

      for (var index = 0; index < 2; index++) {
        await _terminalUntil(
          tester,
          () =>
              fixture.status(tester).pendingApproval != null &&
              !identical(
                fixture.status(tester).pendingApproval,
                previousApproval,
              ),
          'ordinary command approval',
        );
        previousApproval = fixture.status(tester).pendingApproval;
        expect(
          jsonDecode(
            fixture.status(tester).pendingApproval!.canonicalArgumentsJson,
          ),
          arguments,
        );
        _rethrowEndpointFailure(endpointFailures);
        final compactText = find
            .descendant(
              of: _chatView(),
              matching: find.textContaining('Run Command:'),
            )
            .last;
        final compact = find
            .ancestor(of: compactText, matching: find.byType(TextButton))
            .first;
        await _terminalTap(tester, compact);
        await _terminalUntil(
          tester,
          () => find.byType(ToolActivityInspectionHost).evaluate().isNotEmpty,
          'stock rich Command Inspection',
        );
        final inspection = find.byType(ToolActivityInspectionHost).first;
        final source = tester
            .widget<ToolActivityInspectionHost>(inspection)
            .source;
        final capture = _PresentedCapture(
          command,
          session.id.value,
          fixture.runIds.values.single.value,
          source.snapshot.id.value,
        );
        captures.add(capture);
        expect(source.sessionId, session.id);
        expect(source.runId.value, capture.runId);
        expect(source.snapshot.canonicalArguments, arguments);
        expect(
          find.descendant(
            of: inspection,
            matching: find.byWidgetPredicate(
              (widget) => widget is $StatefulWidget$bridge,
            ),
          ),
          findsWidgets,
        );
        expect((await capture.state()).state, 'absent');
        await _terminalUntil(
          tester,
          () => find
              .descendant(
                of: inspection,
                matching: find.text('No output capture has been admitted.'),
              )
              .evaluate()
              .isNotEmpty,
          'stock pre-admission watch is subscribed',
        );
        expect(
          find.descendant(of: inspection, matching: find.text('Show more')),
          findsNothing,
        );
        expect(children, hasLength(index));
        expect(console.eligibleTabs, hasLength(index == 0 ? 0 : 2));
        await _terminalTap(tester, find.text('Allow once'));
        await _terminalUntil(
          tester,
          () => children.length == index + 1,
          'one admitted foreground process',
        );
        final child = children[index];
        await child.stage('connected');
        expect(
          child.workingDirectory,
          await Directory(worktree).resolveSymbolicLinks(),
        );
        child.release('produce');
        await child.stage('started');
        await _projectionText(tester, inspection, 'T3B_PART');
        final preview = _projectionEngine(tester, inspection);
        expect(_terminalBuffer(preview), contains('T3B_BEGIN'));
        expect(_terminalBuffer(preview), contains('T3B_CR\nT3B_PART'));
        expect(_terminalBuffer(preview), isNot(contains('obsolete status')));
        final red = [
          for (var line = 0; line < preview.buffer.height; line++)
            preview.buffer.lines[line],
        ].singleWhere((line) => line.getText().trimRight() == 'T3B_RED');
        expect(red.getForeground(0) & CellColor.valueMask, 1);
        expect((await capture.state()).state, 'capturing');
        expect(await Directory('/proc/${child.pid}').exists(), isTrue);
        await _terminalTap(
          tester,
          find.descendant(of: inspection, matching: find.text('Show more')),
        );
        final consoleHost = find.byType(WorkbenchConsole);
        await _projectionText(tester, consoleHost, 'T3B_PART');
        final tab = console.selectedTab!;
        final initialEngine = _projectionEngine(tester, consoleHost);
        final initialMount = tester.state<TerminalViewState>(
          _projectionView(consoleHost),
        );
        expect(console.eligibleTabs, hasLength(index == 0 ? 1 : 3));
        expect(_projectionEngine(tester, consoleHost), isNot(same(preview)));
        for (final parent in [inspection, consoleHost]) {
          expect(
            tester.widget<TerminalView>(_projectionView(parent)).readOnly,
            isTrue,
          );
          _expectOutputPainted(tester, parent, 'T3B_PART');
        }
        await _terminalTap(
          tester,
          find.descendant(of: inspection, matching: find.text('Show more')),
        );
        expect(console.selectedTab, same(tab));
        expect(_projectionEngine(tester, consoleHost), same(initialEngine));
        expect(
          tester.state<TerminalViewState>(_projectionView(consoleHost)),
          same(initialMount),
        );
        expect(console.eligibleTabs, hasLength(index == 0 ? 1 : 3));
        expect(children, hasLength(index + 1));
        expect(fixture.runIds.values, hasLength(1));
        child.release('middle');
        await child.stage('middle');
        await _projectionText(tester, consoleHost, 'T3B_BULK_END');
        await _projectionText(tester, inspection, 'T3B_BULK_END');
        expect(_projectionEngine(tester, consoleHost).maxLines, 200);
        expect(
          _terminalBuffer(_projectionEngine(tester, consoleHost)),
          isNot(contains('T3B_BEGIN')),
        );
        expect(
          _terminalBuffer(_projectionEngine(tester, consoleHost)),
          isNot(contains('T3B_MIDDLE')),
        );

        if (index == 0) {
          // Actual native scroll freezes this reader before later output arrives;
          // the independently mounted Inspection must continue following.
          await tester.drag(_projectionView(consoleHost), const Offset(0, 180));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          await _terminalUntil(
            tester,
            () => find
                .descendant(
                  of: consoleHost,
                  matching: find.text('Reading history'),
                )
                .evaluate()
                .isNotEmpty,
            'scroll-away pauses follow',
          );
          final frozen = _terminalBuffer(
            _projectionEngine(tester, consoleHost),
          );
          child.release('late');
          await child.stage('late');
          await _projectionText(tester, inspection, 'T3B_LATE_PART');
          expect(
            _terminalBuffer(_projectionEngine(tester, consoleHost)),
            frozen,
          );
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position:
                  tester.getTopLeft(_projectionView(consoleHost)) +
                  const Offset(50, 30),
              scrollDelta: const Offset(0, 20000),
            ),
          );
          await _projectionText(tester, consoleHost, 'T3B_LATE_PART');
          expect((await capture.state()).state, 'capturing');
          await _terminalTap(
            tester,
            find.descendant(of: consoleHost, matching: find.text('Beginning')),
          );
          await _projectionText(tester, consoleHost, 'T3B_BEGIN');
          expect(
            _terminalBuffer(_projectionEngine(tester, consoleHost)),
            contains('T3B_PART-continued'),
          );
          await _terminalTap(
            tester,
            find.descendant(of: consoleHost, matching: find.text('Middle')),
          );
          await _projectionText(tester, consoleHost, 'T3B_MIDDLE');
          await tester.drag(_projectionView(consoleHost), const Offset(0, -72));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          final historicalScroll = tester
              .widget<TerminalView>(_projectionView(consoleHost))
              .scrollController!
              .offset;
          expect(historicalScroll, greaterThan(0));

          final historicalBuffer = _terminalBuffer(
            _projectionEngine(tester, consoleHost),
          );
          final collapsedEngine = _projectionEngine(tester, consoleHost);
          final collapsedMount = tester.state<TerminalViewState>(
            _projectionView(consoleHost),
          );
          final collapsedResident = console.residentPresentations.single;
          await _terminalTap(tester, find.byTooltip('Hide console'));
          expect(_projectionView(consoleHost), findsNothing);
          expect(console.residentPresentations, isEmpty);
          expect(collapsedResident.access.isActive, isFalse);
          expect(collapsedMount.mounted, isFalse);
          child.release('hidden');
          await child.stage('hidden');
          await _projectionText(tester, inspection, 'T3B_HIDDEN');
          await _terminalTap(tester, find.byTooltip('Show console'));
          await _projectionText(tester, consoleHost, 'T3B_MIDDLE');
          expect(
            _projectionEngine(tester, consoleHost),
            isNot(same(collapsedEngine)),
          );
          expect(
            _terminalBuffer(_projectionEngine(tester, consoleHost)),
            historicalBuffer,
          );
          expect(
            tester
                .widget<TerminalView>(_projectionView(consoleHost))
                .scrollController!
                .offset,
            closeTo(historicalScroll, 1),
          );
          await _terminalTap(
            tester,
            find.descendant(
              of: consoleHost,
              matching: find.byTooltip('Follow output'),
            ),
          );
          await _projectionText(tester, consoleHost, 'T3B_HIDDEN');
          final beforeTerminal = _projectionEngine(tester, consoleHost);

          // The interactive stock Terminal remains a different resource and mode.
          await _newTerminal(tester);
          await _terminalUntil(
            tester,
            () =>
                runtime.terminals.forEnvironment(environment.id).length == 1 &&
                _projectionView(consoleHost).evaluate().isNotEmpty,
            'interactive Terminal coexists',
          );
          final shell = runtime.terminals.forEnvironment(environment.id).single;
          shellTab = console.selectedTab!;
          expect(
            tester.widget<TerminalView>(_projectionView(consoleHost)).readOnly,
            isFalse,
          );
          await _terminalCommandIn(
            tester,
            consoleHost,
            r'''stty -echo; PS1=; printf '\nT3B_SHELL_READY\n' ''',
          );
          await _projectionText(tester, consoleHost, 'T3B_SHELL_READY');
          expect(console.eligibleTabs, hasLength(2));
          await _terminalTap(
            tester,
            find.descendant(
              of: find.byKey(ObjectKey(tab)),
              matching: find.byType(TextButton),
            ),
          );
          await _projectionText(tester, consoleHost, 'T3B_HIDDEN');
          expect(_projectionEngine(tester, consoleHost), same(beforeTerminal));
          expect(shell.state, EnvironmentTerminalState.running);
          await _terminalTap(
            tester,
            find.descendant(
              of: find.byKey(ObjectKey(tab)),
              matching: find.byType(IconButton),
            ),
          );
          await _terminalUntil(
            tester,
            () => console.eligibleTabs.length == 1,
            'close output without confirmation',
          );
          expect(find.byType(AlertDialog), findsNothing);
          await _terminalTap(
            tester,
            find.byTooltip('Dismiss Inspection').first,
          );
          expect(find.byType(ToolActivityInspectionHost), findsNothing);
          child.release('closed');
          await child.stage('closed');
          await _terminalUntil(
            tester,
            () async => (await capture.tail()).contains('T3B_AFTER_CLOSE'),
            'capture commits with neither Command reader mounted',
          );
          expect((await capture.state()).state, 'capturing');
          expect(await Directory('/proc/${child.pid}').exists(), isTrue);
          await _terminalTap(tester, compact);
          await _projectionText(tester, inspection, 'T3B_AFTER_CLOSE');
          await _terminalTap(
            tester,
            find.descendant(of: inspection, matching: find.text('Show more')),
          );
          await _projectionText(tester, consoleHost, 'T3B_AFTER_CLOSE');
          expect(console.eligibleTabs, hasLength(2));
          expect(console.selectedTab, isNot(same(tab)));
          expect(runtime.terminals.forEnvironment(environment.id), [
            same(shell),
          ]);
        } else {
          final firstTab = outputTabs.single;
          final firstEngine = outputEngines.single;
          final firstMount = outputMounts.single;
          final secondEngine = _projectionEngine(tester, consoleHost);
          final secondMount = tester.state<TerminalViewState>(
            _projectionView(consoleHost),
          );
          final secondResident = console.residentPresentations.singleWhere(
            (resident) => identical(resident.tab, tab),
          );
          final selectedEpoch = secondResident.access.interaction!;
          expect(console.residentPresentations, hasLength(2));
          expect(firstMount.mounted, isTrue);
          expect(secondEngine, isNot(same(firstEngine)));
          expect(
            _terminalBuffer(secondEngine),
            isNot(contains('T3B_LATE_PART')),
          );
          final firstBuffer = _terminalBuffer(firstEngine);
          await _terminalTap(
            tester,
            find.byTooltip('Dismiss Inspection').first,
          );
          expect(find.byType(ToolActivityInspectionHost), findsNothing);
          expect((await capture.state()).state, 'capturing');
          await selectTab(firstTab);
          expect(_projectionEngine(tester, consoleHost), same(firstEngine));
          expect(
            tester.state<TerminalViewState>(_projectionView(consoleHost)),
            same(firstMount),
          );
          expect(secondMount.mounted, isTrue);
          expect(secondResident.access.isActive, isTrue);
          expect(secondResident.access.interaction, isNull);
          expect(selectedEpoch.isActive, isFalse);

          // Only the hidden console reader can advance this exact emulator: the
          // Inspection is gone and the real process is still waiting for exit.
          child.release('late');
          await child.stage('late');
          await _terminalUntil(
            tester,
            () async =>
                (await capture.tail()).contains('T3B_LATE_PART') &&
                _terminalBuffer(secondEngine).contains('T3B_LATE_PART'),
            'hidden resident consumes a later committed partial line',
          );
          expect(console.selectedTab, same(firstTab));
          expect(_terminalBuffer(firstEngine), firstBuffer);
          expect(await child.isAlive(), isTrue);
          await _terminalTap(tester, compact);
          await _projectionText(tester, inspection, 'T3B_LATE_PART');
          for (var opening = 0; opening < 2; opening++) {
            await _terminalTap(
              tester,
              find.descendant(of: inspection, matching: find.text('Show more')),
            );
            expect(console.selectedTab, same(tab));
            expect(console.eligibleTabs, hasLength(3));
            expect(console.residentPresentations, hasLength(2));
            expect(
              console.residentPresentations.singleWhere(
                (resident) => identical(resident.tab, tab),
              ),
              same(secondResident),
            );
            expect(_projectionEngine(tester, consoleHost), same(secondEngine));
            expect(
              tester.state<TerminalViewState>(_projectionView(consoleHost)),
              same(secondMount),
            );
            expect(
              find.descendant(
                of: consoleHost,
                matching: find.text('Replaying output...'),
              ),
              findsNothing,
            );
            _expectOutputPainted(tester, consoleHost, 'T3B_LATE_PART');
          }
          expect(selectedEpoch.isActive, isFalse);
          expect(secondResident.access.interaction!.isActive, isTrue);

          // A selected-only interactive Terminal consumes a slot too, without
          // evicting either of the two opted-in output residents at this bound.
          await selectTab(shellTab);
          await _projectionText(tester, consoleHost, 'T3B_SHELL_READY');
          final shellMount = tester.state<TerminalViewState>(
            _projectionView(consoleHost),
          );
          expect(console.residentPresentations, hasLength(3));
          expect(
            tester.widget<TerminalView>(_projectionView(consoleHost)).readOnly,
            isFalse,
          );
          expect(firstMount.mounted, isTrue);
          expect(secondMount.mounted, isTrue);
          secondMount.widget.terminal.textInput(
            "printf '\\nT3B_FORBIDDEN_HIDDEN_INPUT\\n'\n",
          );
          await _terminalCommandIn(
            tester,
            consoleHost,
            r'''printf '\nT3B_SELECTED_INPUT\n' ''',
          );
          await _projectionText(tester, consoleHost, 'T3B_SELECTED_INPUT');
          expect(
            _terminalBuffer(_projectionEngine(tester, consoleHost)),
            isNot(contains('T3B_FORBIDDEN_HIDDEN_INPUT')),
          );
          expect(
            _terminalBuffer(secondEngine),
            isNot(contains('T3B_SELECTED_INPUT')),
          );
          child.release('hidden');
          await child.stage('hidden');
          await _terminalUntil(
            tester,
            () async =>
                (await capture.tail()).contains('T3B_HIDDEN') &&
                _terminalBuffer(secondEngine).contains('T3B_HIDDEN'),
            'output reader advances while interactive Terminal is selected',
          );
          expect(console.selectedTab, same(shellTab));
          await _terminalTap(
            tester,
            find.descendant(of: inspection, matching: find.text('Show more')),
          );
          expect(shellMount.mounted, isFalse);
          expect(console.residentPresentations, hasLength(2));
          expect(_projectionEngine(tester, consoleHost), same(secondEngine));
          expect(
            tester.state<TerminalViewState>(_projectionView(consoleHost)),
            same(secondMount),
          );
          child.release('closed');
          await child.stage('closed');
          await _projectionText(tester, consoleHost, 'T3B_AFTER_CLOSE');
          expect(console.selectedTab, same(tab));
          expect((await capture.state()).state, 'capturing');
          await _terminalTap(tester, compact);
          await _projectionText(tester, inspection, 'T3B_AFTER_CLOSE');
          expect(
            captures.last.invocationId,
            isNot(captures.first.invocationId),
          );
          expect(await children.first.isAlive(), isFalse);
        }
        final retainedTab = console.selectedTab;
        child.release('exit');
        final state = await capture.client
            .watch(capture.sessionId, capture.runId, capture.invocationId)
            .firstWhere((state) => state.state == 'complete')
            .timeout(const Duration(seconds: 15));
        completed.add(state);
        child.exited = true;
        expect(state.exitCode, 23);
        expect(state.termination, 'exited');
        expect(state.failure, isNull);
        await _terminalUntil(
          tester,
          () => find
              .descendant(of: inspection, matching: find.text('Exit code: 23'))
              .evaluate()
              .isNotEmpty,
          'completed nonzero Inspection',
        );
        await _terminalUntil(
          tester,
          () => find
              .descendant(
                of: consoleHost,
                matching: find.textContaining(
                  'Capture: complete | Process: exited | Exit: 23',
                ),
              )
              .evaluate()
              .isNotEmpty,
          'completed nonzero console capture',
        );
        expect(console.eligibleTabs, contains(same(retainedTab)));
        expect(console.selectedTab, same(retainedTab));
        await _projectionText(tester, consoleHost, 'T3B_AFTER_CLOSE');
        outputTabs.add(retainedTab!);
        outputEngines.add(_projectionEngine(tester, consoleHost));
        outputMounts.add(
          tester.state<TerminalViewState>(_projectionView(consoleHost)),
        );
        expect(children, hasLength(index + 1));
        await _terminalTap(tester, find.byTooltip('Dismiss Inspection').first);
      }
      await _terminalUntil(
        tester,
        () => find
            .text('Both commands exited with code 23.')
            .evaluate()
            .isNotEmpty,
        'ordinary Chat continuation',
      );
      _rethrowEndpointFailure(endpointFailures);
      expect(outbound, hasLength(3));
      expect(children, hasLength(2));
      expect(children[0].pid, isNot(children[1].pid));
      expect(fixture.runIds.values, hasLength(1));
      final runId = fixture.runIds.values.single;
      final retained = runtime.lifecycle.runActivity(runId)!;
      expect(retained.state, RunState.completed);
      expect(retained.tools.map((tool) => tool.canonicalArguments), [
        arguments,
        arguments,
      ]);
      expect(
        retained.tools.map((tool) => tool.id.value),
        captures.map((capture) => capture.invocationId),
      );
      for (final tool in retained.tools) {
        expect(
          tool.changes.where(
            (change) => change.kind == ToolActivityKind.progress,
          ),
          isEmpty,
        );
        expect(tool.outcome!.hostData['stdoutTruncated'], isTrue);
        expect(tool.outcome!.hostData['stdout'], isNot(contains('T3B_MIDDLE')));
      }
      final consoleHost = find.byType(WorkbenchConsole);
      await _terminalTap(
        tester,
        find.descendant(of: consoleHost, matching: find.text('Middle')),
      );
      await _projectionText(tester, consoleHost, 'T3B_MIDDLE');
      final historicalEngine = _projectionEngine(tester, consoleHost);
      final historicalBuffer = _terminalBuffer(historicalEngine);
      final residents = console.residentPresentations;
      expect(residents, hasLength(2));
      await _breadcrumb(tester, 'project-breadcrumb');
      await _terminalUntil(
        tester,
        () => find.byType(MainContentHost).evaluate().isEmpty,
        'Session departure releases the entire resident working set',
      );
      expect(consoleHost, findsNothing);
      expect(console.residentPresentations, isEmpty);
      expect(residents.every((resident) => !resident.access.isActive), isTrue);
      expect(outputMounts.every((mount) => !mount.mounted), isTrue);
      expect(outputTabs.every((tab) => tab.isActive), isTrue);
      expect(
        runtime.terminals.forEnvironment(environment.id).single.state,
        EnvironmentTerminalState.running,
      );
      await _terminalTap(tester, find.text(task.title));
      await _terminalTap(tester, _sessionRow(session.id));
      await _projectionText(tester, consoleHost, 'T3B_MIDDLE');
      expect(_session(tester), same(session));
      expect(console.selectedTab, same(outputTabs.last));
      expect(console.eligibleTabs, hasLength(3));
      expect(console.residentPresentations, hasLength(1));
      expect(
        _projectionEngine(tester, consoleHost),
        isNot(same(historicalEngine)),
      );
      expect(
        _terminalBuffer(_projectionEngine(tester, consoleHost)),
        historicalBuffer,
      );
      await selectTab(outputTabs.first);
      await _projectionText(tester, consoleHost, 'T3B_AFTER_CLOSE');
      expect(console.residentPresentations, hasLength(2));
      expect(
        _projectionEngine(tester, consoleHost),
        isNot(same(outputEngines.first)),
      );
      expect(residents.every((resident) => !resident.access.isActive), isTrue);
      expect(fixture.runIds.values, [runId]);
      expect(children, hasLength(2));
      final inventory = await _git(fixture.source, [
        'worktree',
        'list',
        '--porcelain',
      ]);
      final marker = await File('$worktree/.git').readAsBytes();
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      expect(console.residentPresentations, isEmpty);
      expect(commandBackend.connection!.isClosed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());

      // Fresh host, Project, backend and EVC. Git is not installed at all; history
      // must not restore an Environment or obtain process/execution authority.
      final freshRootParent = await Directory(
        '${fixture.directory.path}/fresh',
      ).create();
      final freshRoot = await prepared.copyInstallations(freshRootParent);
      await Directory(
        '${freshRoot.path}/$_gitPluginId',
      ).delete(recursive: true);
      final ids = _NoReopenIds();
      final fresh = NativeAdeleRuntime(ids: ids, runIds: ids);
      addTearDown(fresh.close);
      await fixture.launch(
        tester,
        prepared,
        root: freshRoot,
        usingRuntime: fresh,
        usingRunIds: ids,
      );
      expect(
        fresh.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(fresh.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        fresh.plugins.backends.any(
          (backend) => backend.installation.metadata.id.value == _gitPluginId,
        ),
        isFalse,
      );
      await _tap(tester, 'Open Local Directory...');
      await _pumpUntil(tester, () => fixture.shell(tester).project != null);
      expect(fixture.shell(tester).project!.id, project.id);
      expect(fixture.shell(tester).project, isNot(same(project)));
      await _tap(tester, task.title);
      await _openSession(tester, session.id);
      await _terminalUntil(
        tester,
        () =>
            find
                .descendant(
                  of: _chatView(),
                  matching: find.textContaining('Run Command:'),
                )
                .evaluate()
                .length ==
            2,
        'historical Chat compact occurrences',
      );
      final freshConsole = tester
          .widget<WorkbenchConsole>(find.byType(WorkbenchConsole))
          .controller;
      expect(freshConsole.eligibleTabs, isEmpty);
      final replacement = fresh.plugins.backends.singleWhere(
        (backend) => backend.installation.metadata.id.value == _commandPluginId,
      );
      expect(replacement.connection, isNot(same(commandBackend.connection)));
      for (var index = 0; index < 2; index++) {
        await _terminalTap(
          tester,
          find
              .ancestor(
                of: find
                    .descendant(
                      of: _chatView(),
                      matching: find.textContaining('Run Command:'),
                    )
                    .at(index),
                matching: find.byType(TextButton),
              )
              .first,
        );
        final inspection = find.byType(ToolActivityInspectionHost).first;
        await _projectionText(tester, inspection, 'T3B_AFTER_CLOSE');
        expect(
          tester
              .widget<ToolActivityInspectionHost>(inspection)
              .source
              .snapshot
              .id
              .value,
          captures[index].invocationId,
        );
        await _terminalTap(
          tester,
          find.descendant(of: inspection, matching: find.text('Show more')),
        );
        await _projectionText(
          tester,
          find.byType(WorkbenchConsole),
          'T3B_AFTER_CLOSE',
        );
        expect(freshConsole.eligibleTabs, hasLength(index + 1));
        await _terminalTap(
          tester,
          find.descendant(
            of: find.byType(WorkbenchConsole),
            matching: find.text('Beginning'),
          ),
        );
        await _projectionText(
          tester,
          find.byType(WorkbenchConsole),
          'T3B_PID=${children[index].pid}',
        );
        expect(
          _terminalBuffer(
            _projectionEngine(tester, find.byType(WorkbenchConsole)),
          ),
          isNot(contains('T3B_PID=${children[1 - index].pid}')),
        );
        final freshCapture = _PresentedCapture(
          CommandOutputServiceClient(
            replacement.connection!.channelFor(
              replacement.connection!.defaultConfigurationContext,
              commandOutputServiceId,
            ),
          ),
          session.id.value,
          runId.value,
          captures[index].invocationId,
        );
        final state = await freshCapture.state();
        expect(
          (
            state.state,
            state.version,
            state.highWater,
            state.totalCodeUnits,
            state.exitCode,
          ),
          (
            'complete',
            completed[index].version,
            completed[index].highWater,
            completed[index].totalCodeUnits,
            23,
          ),
        );
        await _terminalTap(tester, find.byTooltip('Dismiss Inspection').first);
      }
      expect(ids.calls, 0);
      expect(outbound, hasLength(3));
      expect(children, hasLength(2));
      expect(
        fresh.lifecycle.environmentRuntime.currentMaterialization(
          environment.id,
        ),
        isNull,
      );
      expect(fresh.terminals.forEnvironment(environment.id), isEmpty);
      expect(
        await _git(fixture.source, ['worktree', 'list', '--porcelain']),
        inventory,
      );
      expect(await File('$worktree/.git').readAsBytes(), marker);
      expect(tester.takeException(), isNull);
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      await tester.pumpWidget(const SizedBox.shrink());
    }),
    skip: !Platform.isLinux || Abi.current() != Abi.linuxX64,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'T2 installed Terminal keeps real shells across tabs and Session navigation',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _ProductFixture.create();
      final root = await prepared.copyInstallations(fixture.directory);
      final helper = await prepared.installTerminal(root);
      final launcher = await fixture.isolatedRuntime(prepared);
      final home = Directory('${fixture.directory.path}/home');
      await fixture.launch(
        tester,
        prepared,
        root: root,
        dartaotruntimeExecutable: launcher,
        startupArguments: {
          _gitPluginId: ['--pty-helper=${helper.path}'],
        },
      );
      final runtime = fixture.runtime;
      expect(runtime.plugins.catalog!.issues, isEmpty);
      final installed = runtime.plugins.catalog!.installations.singleWhere(
        (entry) => entry.metadata.id.value == _terminalPluginId,
      );
      expect(installed.backendArtifactUri, isNull);
      expect(installed.frontend, isNotNull);
      await _terminalUntil(
        tester,
        () => runtime.extensions
            .discover(consoleContributions)
            .any((entry) => entry.id.value == '$_terminalPluginId.console'),
        'prepared stock console registration',
      );
      expect(
        runtime.extensions
            .discover(consoleContributions)
            .map((entry) => entry.id.value),
        contains('$_terminalPluginId.console'),
      );
      expect(runtime.plugins.host, isA<PluginBackendHost>());
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(find.byType(WorkbenchConsole), findsNothing);
      await fixture.openTask(tester);
      final task = fixture.shell(tester).task!;
      final environment = fixture.shell(tester).environment!;
      final worktree = await Directory(
        developmentGitWorktreePath(fixture.shell(tester).project!, environment),
      ).resolveSymbolicLinks();
      expect(runtime.terminals.forEnvironment(environment.id), isEmpty);
      expect(find.byType(WorkbenchConsole), findsNothing);
      await _tap(tester, 'New Chat Session');
      await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
      final session = _session(tester);
      expect(runtime.terminals.forEnvironment(environment.id), isEmpty);
      final console = tester
          .widget<WorkbenchConsole>(find.byType(WorkbenchConsole))
          .controller;
      expect(console.eligibleTabs, isEmpty);
      expect(console.actions.single.label, 'New Terminal');

      await _newTerminal(tester);
      await _terminalUntil(
        tester,
        () =>
            runtime.terminals.forEnvironment(environment.id).length == 1 &&
            find.byType(TerminalView).evaluate().isNotEmpty,
        'first stock Terminal action',
      );
      final first = runtime.terminals.forEnvironment(environment.id).single;
      final firstEngine = _terminalEngine(tester);
      expect(
        first.request.launchKind,
        EnvironmentTerminalLaunchKind.defaultShell,
      );
      expect(first.request.program, isNull);
      expect(first.request.arguments, isEmpty);
      expect(first.request.relativeWorkingDirectory, '');
      expect(_terminalTab('Terminal 1'), findsOneWidget);
      final materialization = runtime.lifecycle.environmentRuntime
          .currentMaterialization(environment.id)!;
      expect(materialization.provider, isA<GeneratedEnvironmentProvider>());
      expect(materialization.validateBinding, returnsNormally);

      // Separate one-shot FIFOs prevent a previous writer's EOF from consuming
      // the next handshake before the next hidden output request is sent.
      await _terminalCommand(
        tester,
        'stty -echo; PS1=; T2_VALUE=first; mkfifo t2-title-1 t2-title-2 t2-exit; '
        r'''(for gate in 1 2; do IFS= read -r n < "t2-title-$gate"; printf '\033]0;First title %s\007\nHIDDEN_FIRST=%s\n' "$n" "$n"; done) & '''
        r'''printf '\nFIRST_PID=%s\nFIRST_CWD=%s\nFIRST_HOME=%s\nFIRST_SHELL=%s\nFIRST_READY\n' "$$" "$PWD" "$HOME" "$SHELL"''',
      );
      await _terminalText(tester, firstEngine, 'FIRST_READY');
      expect(_terminalBuffer(firstEngine), contains('FIRST_CWD=$worktree\n'));
      expect(
        _terminalBuffer(firstEngine),
        contains('FIRST_HOME=${home.path}\n'),
      );
      expect(_terminalBuffer(firstEngine), contains('FIRST_SHELL=/bin/sh\n'));
      final firstPid = _terminalPid(firstEngine, 'FIRST');
      final firstHelperPid = await _terminalParentPid(firstPid);
      expect(
        await _terminalParentPid(firstHelperPid),
        runtime.plugins.host!.processId,
      );
      expect(
        (await File('/proc/$firstPid/cmdline').readAsString()).split('\u0000'),
        ['/bin/sh', '-i', ''],
      );
      // Native keyboard input, not direct owner.write or emulator injection.
      for (final (key, character) in [
        (LogicalKeyboardKey.keyP, 'p'),
        (LogicalKeyboardKey.keyW, 'w'),
        (LogicalKeyboardKey.keyD, 'd'),
      ]) {
        await tester.sendKeyEvent(key, character: character);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _terminalText(tester, firstEngine, worktree);

      final oldColumns = firstEngine.viewWidth;
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      await tester.pump();
      expect(firstEngine.viewWidth, lessThan(oldColumns));
      final size = '${firstEngine.viewHeight} ${firstEngine.viewWidth}';
      // Ask the actual PTY for geometry; shell-specific SIGWINCH trap timing
      // while waiting for interactive input is not part of the contract.
      await _terminalCommand(
        tester,
        r'''printf '\nSTTY=%s\n' "$(stty size)"''',
      );
      await _terminalText(tester, firstEngine, 'STTY=$size');

      await _newTerminal(tester);
      await _terminalUntil(
        tester,
        () =>
            runtime.terminals.forEnvironment(environment.id).length == 2 &&
            find.byType(TerminalView).evaluate().isNotEmpty &&
            !identical(_terminalEngine(tester), firstEngine),
        'independent second shell',
      );
      final second = runtime.terminals.forEnvironment(environment.id).last;
      final secondEngine = _terminalEngine(tester);
      expect(second, isNot(same(first)));
      expect(second.surface, isNot(same(first.surface)));
      expect(_terminalTab('Terminal 1'), findsOneWidget);
      expect(_terminalTab('Terminal 2'), findsOneWidget);
      await _terminalCommand(
        tester,
        r'''stty -echo; PS1=; printf '\nSECOND_INHERITED=%s\n' "${T2_VALUE-unset}"; T2_VALUE=second; printf 'SECOND_PID=%s\nSECOND_READY\n' "$$"''',
      );
      await _terminalText(tester, secondEngine, 'SECOND_READY');
      expect(
        _terminalBuffer(secondEngine),
        contains('SECOND_INHERITED=unset\n'),
      );
      expect(_terminalBuffer(secondEngine), isNot(contains('FIRST_READY')));
      expect(_terminalBuffer(firstEngine), isNot(contains('SECOND_READY')));
      final secondPid = _terminalPid(secondEngine, 'SECOND');
      final secondHelperPid = await _terminalParentPid(secondPid);
      expect(secondPid, isNot(firstPid));
      expect(
        await _terminalParentPid(secondHelperPid),
        runtime.plugins.host!.processId,
      );
      expect(firstEngine.listeners, isEmpty);
      await File(
        '$worktree/t2-title-1',
      ).writeAsString('1\n').timeout(const Duration(seconds: 15));
      await _terminalText(tester, firstEngine, 'HIDDEN_FIRST=1');
      await _terminalUntil(
        tester,
        () => _terminalTab('First title 1').evaluate().isNotEmpty,
        'hidden tab title follows OSC',
      );
      expect(_terminalEngine(tester), same(secondEngine));

      await _terminalTap(tester, find.byTooltip('Hide console'));
      expect(find.byType(TerminalView), findsNothing);
      await File(
        '$worktree/t2-title-2',
      ).writeAsString('2\n').timeout(const Duration(seconds: 15));
      await _terminalText(tester, firstEngine, 'HIDDEN_FIRST=2');
      expect(first.title, 'First title 2');
      await _terminalTap(tester, find.byTooltip('Show console'));
      await _terminalUntil(
        tester,
        () => find.byType(TerminalView).evaluate().isNotEmpty,
        'show retained console',
      );
      expect(_terminalEngine(tester), same(secondEngine));
      expect(_terminalTab('First title 2'), findsOneWidget);

      await _breadcrumb(tester, 'task-breadcrumb');
      await _terminalUntil(
        tester,
        () => find.byType(MainContentHost).evaluate().isEmpty,
        'Task Browser navigation',
      );
      expect(find.byType(TerminalView), findsNothing);
      expect(find.byType(WorkbenchConsole), findsNothing);
      expect(runtime.terminals.forEnvironment(environment.id), [
        same(first),
        same(second),
      ]);
      await _terminalTap(tester, _sessionRow(session.id));
      await _terminalUntil(
        tester,
        () => find.byType(TerminalView).evaluate().isNotEmpty,
        'same Session console',
      );
      expect(_session(tester), same(session));
      expect(_terminalEngine(tester), same(secondEngine));
      await _breadcrumb(tester, 'task-breadcrumb');
      await _terminalUntil(
        tester,
        () => find.byType(MainContentHost).evaluate().isEmpty,
        'browse sibling Session',
      );
      await _terminalTap(tester, find.text('New Chat Session'));
      await _terminalUntil(
        tester,
        () => find.byType(TerminalView).evaluate().isNotEmpty,
        'same Environment sibling Session console',
      );
      final sibling = _session(tester);
      expect(sibling.id, isNot(session.id));
      expect(_terminalTab('First title 2'), findsOneWidget);
      expect(_terminalTab('Terminal 2'), findsOneWidget);
      await _terminalTap(tester, _terminalTab('First title 2'));
      expect(_terminalEngine(tester), same(firstEngine));

      await _breadcrumb(tester, 'project-breadcrumb');
      await _terminalUntil(
        tester,
        () => fixture.shell(tester).task == null,
        'Project browser',
      );
      await fixture.createTask(tester, 'Other Terminal Environment');
      final otherEnvironment = fixture.shell(tester).environment!;
      await _tap(tester, 'New Chat Session');
      await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
      final otherSession = _session(tester);
      expect(find.byType(TerminalView), findsNothing);
      expect(console.eligibleTabs, isEmpty);
      expect(_terminalTab('First title 2'), findsNothing);
      expect(_terminalTab('Terminal 2'), findsNothing);
      expect(runtime.terminals.forEnvironment(otherEnvironment.id), isEmpty);
      expect(runtime.terminals.forEnvironment(environment.id), [
        same(first),
        same(second),
      ]);
      await _breadcrumb(tester, 'project-breadcrumb');
      await _terminalUntil(
        tester,
        () => fixture.shell(tester).task == null,
        'return to original Task',
      );
      await _terminalTap(tester, find.text(task.title));
      await _terminalUntil(
        tester,
        () => _sessionRow(session.id).evaluate().isNotEmpty,
        'original Session row',
      );
      await _terminalTap(tester, _sessionRow(session.id));
      await _terminalUntil(
        tester,
        () => find.byType(TerminalView).evaluate().isNotEmpty,
        'original Environment console',
      );
      expect(_terminalEngine(tester), same(secondEngine));
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          environment.id,
        ),
        same(materialization),
      );
      await _terminalTap(tester, _terminalTab('First title 2'));
      expect(_terminalEngine(tester), same(firstEngine));
      await _terminalCommand(
        tester,
        r'''printf '\nFIRST_STILL=%s:%s\n' "$$" "$T2_VALUE"''',
      );
      await _terminalText(tester, firstEngine, 'FIRST_STILL=$firstPid:first');
      expect(_terminalBuffer(firstEngine), contains('HIDDEN_FIRST=2\n'));
      await _terminalTap(tester, _terminalTab('Terminal 2'));
      expect(_terminalEngine(tester), same(secondEngine));

      await _terminalTap(tester, find.byTooltip('Close Terminal 2'));
      await _terminalUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
        'live shell close confirmation',
      );
      await _terminalTap(tester, find.text('Cancel'));
      expect(second.state, EnvironmentTerminalState.running);
      expect(await Directory('/proc/$secondPid').exists(), isTrue);
      expect(runtime.terminals.forEnvironment(environment.id), [
        same(first),
        same(second),
      ]);
      await _terminalCommand(
        tester,
        r'''printf '\nSECOND_STILL=%s:%s\n' "$$" "$T2_VALUE"''',
      );
      await _terminalText(
        tester,
        secondEngine,
        'SECOND_STILL=$secondPid:second',
      );
      await _terminalTap(tester, find.byTooltip('Close Terminal 2'));
      await _terminalUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
        'confirmed shell close',
      );
      await _terminalTap(tester, find.text('Close'));
      await _terminalUntil(
        tester,
        () =>
            runtime.terminals.forEnvironment(environment.id).length == 1 &&
            second.cleanupSettled,
        'only confirmed shell removed',
      );
      expect(second.surface.isDisposed, isTrue);
      expect(second.cleanupError, isNull);
      expect(first.state, EnvironmentTerminalState.running);
      await _terminalReaped(tester, [secondPid, secondHelperPid]);

      await _terminalCommand(
        tester,
        r'''printf '\nEXIT_ARMED\n'; IFS= read -r finish < t2-exit; exit 23''',
      );
      await _terminalText(tester, firstEngine, 'EXIT_ARMED');

      // No mounted Console observes this exit. The retained stock policy must
      // remove the tab and owner from actual shell completion, not view disposal.
      await _breadcrumb(tester, 'task-breadcrumb');
      await _terminalUntil(
        tester,
        () => find.byType(MainContentHost).evaluate().isEmpty,
        'hide console before actual shell exit',
      );
      expect(find.byType(TerminalView), findsNothing);
      await File(
        '$worktree/t2-exit',
      ).writeAsString('exit\n').timeout(const Duration(seconds: 15));
      await _terminalUntil(
        tester,
        () =>
            runtime.terminals.forEnvironment(environment.id).isEmpty &&
            first.cleanupSettled,
        'hidden shell exit automatically removes tab',
      );
      expect(
        first.completion!.termination,
        EnvironmentTerminalTermination.exited,
      );
      expect(first.completion!.exitCode, 23);
      expect(first.surface.isDisposed, isTrue);
      expect(first.cleanupError, isNull);
      await _terminalReaped(tester, [firstPid, firstHelperPid]);
      await _terminalTap(tester, _sessionRow(session.id));
      await _terminalUntil(
        tester,
        () => _composer().evaluate().isNotEmpty,
        'reopen without automatic shell replacement',
      );
      expect(find.byType(TerminalView), findsNothing);
      expect(_terminalTab('First title 2'), findsNothing);
      expect(_terminalTab('Terminal 2'), findsNothing);
      expect(runtime.terminals.forEnvironment(environment.id), isEmpty);
      expect(console.eligibleTabs, isEmpty);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(fixture.runIds.values, isEmpty);
      for (final retained in [session, sibling, otherSession]) {
        expect(runtime.store.runsForSession(retained.id), isEmpty);
      }
      expect(tester.takeException(), isNull);
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      await tester.pumpWidget(const SizedBox.shrink());
    }),
    skip: !Platform.isLinux || Abi.current() != Abi.linuxX64,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // One existing real-installation fixture, not another remote-strategy matrix.
  // The two decisions exercise the common approval continuation with the actual
  // stock backend/frontend and independently compiled tool/provider components.
  for (final allowCommand in [true, false]) {
    testWidgets(
      'F3g installed Chat replays prompts and browses retained Tasks and Sessions (${allowCommand ? 'Allow once' : 'Deny'})',
      (tester) => tester.runAsync(() async {
        await tester.binding.setSurfaceSize(const Size(1400, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = await _ProductFixture.create();
        final answer = allowCommand
            ? 'Patched the Task file and git diff --check exited with code 0.'
            : 'Patched the Task file. The validation command was denied and did not run.';
        final outbound = <Map<String, Object?>>[];
        final endpointFailures = <(Object, StackTrace)>[];
        final continuationArrived = Completer<void>();
        final releaseFinal = Completer<void>();
        String? observedRevision;
        String? patchedRevision;
        late Map<String, Object?> patchArguments;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          try {
            expect(request.method, 'POST');
            expect(request.uri.path, '/backend-api/codex/responses');
            expect(
              request.headers.value(HttpHeaders.authorizationHeader),
              'Bearer f3g-fake-access-token',
            );
            expect(
              request.headers.value('ChatGPT-Account-ID'),
              'f3g-fixture-account',
            );
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, Object?>;
            outbound.add(body);
            expect(body['model'], 'gpt-6-astra');
            expect(body['instructions'], contains(_agentsText));
            expect(body['instructions'], isNot(contains(_projectAgentsText)));
            final tools = (body['tools']! as List<Object?>)
                .cast<Map<String, Object?>>();
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
            for (final forbidden in [
              'environmentId',
              'taskId',
              'providerId',
              'worktreePath',
              'worktreeRelativePath',
              'sourceRelativePath',
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
                expect(body['input'], [_userInput(_initialPrompt)]);
                _output(
                  request.response,
                  _message('initial-final', _initialAnswer),
                );
              case 2:
                // This is the actual HTTP model input, not reconstructed UI state.
                expect(body['input'], [
                  _userInput(_initialPrompt),
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
                  _userInput(_prompt),
                ]);
                _output(
                  request.response,
                  _call('read', 'read_file', {'relativePath': _sourcePath}),
                );
              case 3:
                final read = _toolOutput(body, 'read');
                expect(read, contains(_taskText));
                expect(read, isNot(contains('project-source-only')));
                observedRevision = _revision(read);
                patchArguments = {
                  'relativePath': _sourcePath,
                  'expectedRevision': observedRevision,
                  'edits': [
                    {
                      'search': _taskText.trimRight(),
                      'replace': _patchedText.trimRight(),
                    },
                  ],
                };
                _output(request.response, _reasoningItem());
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
                  _call('command', 'run_command', _commandArguments),
                );
              case 4:
                final patch = _toolOutput(body, 'patch');
                patchedRevision = _revision(patch);
                expect(patchedRevision, isNot(observedRevision));
                expect(
                  patch,
                  'Patched: ${jsonEncode(_sourcePath)}\nEdits applied: 1\nRevision: ${jsonEncode(patchedRevision)}',
                );
                final command = _toolOutput(body, 'command');
                if (allowCommand) {
                  expect(
                    command,
                    allOf(
                      contains('Program: "git"'),
                      contains('Arguments: ["diff","--check"]'),
                      contains('Termination: exited'),
                      contains('Exit code: 0'),
                    ),
                  );
                } else {
                  expect(command, contains('rejected'));
                  expect(command, isNot(contains('Exit code:')));
                }
                expect(
                  (body['input']! as List<Object?>)
                      .cast<Map<String, Object?>>()
                      .where((item) => item['type'] == 'function_call_output')
                      .map((item) => item['call_id']),
                  ['read', 'patch', 'command'],
                );
                expect(body['input'], [
                  ...(outbound[2]['input']! as List<Object?>),
                  _reasoningItem(),
                  _message('batch-purpose', _narration),
                  _call('patch', 'apply_patch', patchArguments),
                  _call('command', 'run_command', _commandArguments),
                  {
                    'type': 'function_call_output',
                    'call_id': 'patch',
                    'output': patch,
                  },
                  {
                    'type': 'function_call_output',
                    'call_id': 'command',
                    'output': command,
                  },
                ]);
                continuationArrived.complete();
                await releaseFinal.future;
                _output(request.response, _message('final', answer));
              case 5:
                expect(body['input'], [_userInput(_siblingPrompt)]);
                _output(
                  request.response,
                  _message('sibling-final', _siblingAnswer),
                );
              case 6:
                expect(body['input'], [_userInput(_otherPrompt)]);
                _output(
                  request.response,
                  _message('other-final', _otherAnswer),
                );
              default:
                fail('Unexpected model invocation ${outbound.length}.');
            }
            _sse(request.response, {
              'type': 'response.completed',
              'response': {
                'id': 'f3g-${outbound.length}',
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
        });
        addTearDown(() async {
          await server.close(force: true);
          await subscription.cancel();
        });

        await fixture.launch(tester, prepared, endpoint: server);
        // Release the endpoint before application teardown drains an accepted Run,
        // including when an assertion fails during the held final inference.
        addTearDown(() {
          if (!releaseFinal.isCompleted) releaseFinal.complete();
        });
        final runtime = fixture.runtime;
        final catalog = runtime.plugins.catalog!;
        expect(catalog.issues, isEmpty);
        expect(catalog.installations, hasLength(9));
        expect(
          catalog.installations.where(
            (entry) => entry.backendArtifactUri != null,
          ),
          hasLength(8),
        );
        expect(
          catalog.installations.where((entry) => entry.frontend != null),
          hasLength(6),
        );
        expect(runtime.plugins.backends, hasLength(8));
        for (final backend in runtime.plugins.backends) {
          expect(
            backend.state,
            InstalledBackendState.active,
            reason: backend.installation.metadata.id.value,
          );
          expect(backend.failure, isNull);
        }
        final chatBackend = runtime.plugins.backends.singleWhere(
          (entry) => entry.installation.metadata.id.value == _chatPluginId,
        );
        final connection = chatBackend.connection!;
        expect(connection.capabilityExposures, isEmpty);
        expect(
          chatBackend.installation.backendArtifactUri,
          prepared.backend(_chatPluginId).uri,
        );
        expect(
          connection.extensionExposures.single.extensionId,
          chatStrategyExtensionId.value,
        );
        final strategy = runtime.extensions
            .discover(orchestrationStrategyContributions)
            .single;
        expect(strategy.value.strategyId, chatStrategyId);
        final presentation = runtime.extensions
            .discover(mainContentContributions)
            .single;
        expect(presentation.id.value, '$_chatPluginId.presentation');
        // Pin the generated client to this installed backend, never capability
        // default routing or in-process state substituted by the test.
        final chat = _chatClient(connection);
        expect(fixture.runIds.values, isEmpty);
        expect(outbound, isEmpty);

        await fixture.openTask(tester);
        final environment = fixture.shell(tester).environment!;
        final worktree = Directory(
          developmentGitWorktreePath(
            fixture.shell(tester).project!,
            environment,
          ),
        );
        expect(worktree.path, isNot(fixture.source.path));
        await File(
          '${fixture.source.path}/$_sourcePath',
        ).writeAsString(_projectText);
        await File(
          '${fixture.source.path}/AGENTS.md',
        ).writeAsString(_projectAgentsText);
        final projectBefore = await _sourceSnapshot(
          fixture.source,
          taskWorktree: worktree,
        );
        expect(
          (await Process.run('git', [
            'diff',
            '--check',
          ], workingDirectory: fixture.source.path)).exitCode,
          isNot(0),
        );
        await _tap(tester, 'New Chat Session');
        await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
        final host = find.byType(MainContentHost);
        final session = _session(tester);
        expect(runtime.store.session(session.id), same(session));
        expect(session.strategyId, chatStrategyId);
        expect(
          runtime.store.requireSessionAuthority(session.id).environmentId,
          environment.id,
        );
        final initial = await chat.snapshot(session.id.value);
        expect(initial.entries, isEmpty);
        expect(initial.draftRequest, '');
        expect(
          find.descendant(
            of: host,
            matching: find.byWidgetPredicate(
              (widget) => widget is $StatefulWidget$bridge,
            ),
          ),
          findsOneWidget,
        );

        final composer = find.descendant(
          of: host,
          matching: find.byType(TextField),
        );
        const partialDraft = '  Explain the approval workflow\twithout...  ';
        await tester.enterText(composer, partialDraft);
        expect(
          tester.widget<TextField>(composer).controller!.text,
          partialDraft,
        );
        await _pumpUntil(
          tester,
          () async =>
              (await chat.snapshot(session.id.value)).draftRequest ==
              partialDraft,
        );
        expect((await chat.snapshot(session.id.value)).entries, isEmpty);
        expect(fixture.runIds.values, isEmpty);
        expect(outbound, isEmpty);

        // Send must flush the final edit, not submit the previous saved draft.
        await _send(tester, _initialPrompt);
        await _pumpUntil(
          tester,
          () => find.text(_initialAnswer).evaluate().isNotEmpty,
        );
        _rethrowEndpointFailure(endpointFailures);
        final first = await chat.snapshot(session.id.value);
        expect(first.draftRequest, '');
        expect(tester.widget<TextField>(composer).controller!.text, '');
        expect(first.entries.map((entry) => (entry.role, entry.content)), [
          ('user', _initialPrompt),
          ('assistant', _initialAnswer),
        ]);
        expect(first.entries.map((entry) => entry.id).toSet(), hasLength(2));
        expect(fixture.runIds.values, hasLength(1));
        expect(first.entries.map((entry) => entry.runId), [
          fixture.runIds.values.single.value,
          null,
        ]);
        expect(outbound, hasLength(1));

        await _send(tester, _prompt);
        await _pumpUntil(
          tester,
          () => fixture.status(tester).pendingApproval != null,
        );
        _rethrowEndpointFailure(endpointFailures);
        final patchApproval = fixture.status(tester).pendingApproval!;
        expect(patchApproval.toolId, '$_filesystemPluginId.apply-patch');
        expect(
          jsonDecode(patchApproval.canonicalArgumentsJson),
          patchArguments,
        );
        expect(outbound, hasLength(3));
        expect(fixture.runIds.values, hasLength(2));
        expect(fixture.runIds.values.toSet(), hasLength(2));
        expect(
          await File('${worktree.path}/$_sourcePath').readAsString(),
          _taskText,
        );
        final waiting = await chat.snapshot(session.id.value);
        expect(waiting.draftRequest, '');
        expect(waiting.entries.map((entry) => (entry.role, entry.content)), [
          ('user', _initialPrompt),
          ('assistant', _initialAnswer),
          ('user', _prompt),
        ]);
        expect(
          waiting.entries.take(2).map((entry) => entry.id),
          first.entries.map((entry) => entry.id),
        );
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: host, matching: find.byType(TextField)),
              )
              .enabled,
          isFalse,
        );
        expect(find.text(_narration), findsOneWidget);
        _expectNoSecrets(tester);

        // Both routes detach only presentation. Reopening the canonical Session
        // must expose the exact still-pending approval without another Run.
        final oldApprovalView = fixture.status(tester);
        for (final breadcrumb in ['task-breadcrumb', 'project-breadcrumb']) {
          final task = fixture.shell(tester).task!;
          await _breadcrumb(tester, breadcrumb);
          await _pumpUntil(
            tester,
            () => find.byType(MainContentHost).evaluate().isEmpty,
          );
          expect(fixture.shell(tester).navigationError, isNull);
          oldApprovalView.onDecision(patchApproval, true);
          await tester.pump();
          if (breadcrumb == 'project-breadcrumb') {
            await _tap(tester, task.title);
          }
          await _openSession(tester, session.id);
          await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
          oldApprovalView.onDecision(patchApproval, true);
          oldApprovalView.onDecision(patchApproval, false);
          await tester.pump();
          expect(_session(tester), same(session));
          expect(fixture.shell(tester).task!.id, session.taskId);
          expect(fixture.status(tester).pendingApproval, same(patchApproval));
          expect(fixture.status(tester).isAdvancing, isFalse);
          expect(runtime.store.runsForSession(session.id), hasLength(1));
          expect(runtime.store.runRecord(fixture.runIds.values.last), isNull);
          expect(outbound, hasLength(3));
        }

        await _tap(tester, 'Allow once');
        await _pumpUntil(
          tester,
          () =>
              fixture.status(tester).pendingApproval?.toolId ==
              '$_commandPluginId.run-command',
        );
        final commandApproval = fixture.status(tester).pendingApproval!;
        expect(commandApproval, isNot(same(patchApproval)));
        expect(
          jsonDecode(commandApproval.canonicalArgumentsJson),
          _commandArguments,
        );
        expect(
          outbound,
          hasLength(3),
          reason: 'The entire model proposal batch resumes before inference.',
        );
        expect(
          await File('${worktree.path}/$_sourcePath').readAsString(),
          _patchedText,
        );
        expect(
          (await chat.snapshot(
            session.id.value,
          )).entries.map((entry) => entry.id),
          waiting.entries.map((entry) => entry.id),
        );

        await _tap(tester, allowCommand ? 'Allow once' : 'Deny');
        await continuationArrived.future.timeout(const Duration(seconds: 15));
        _rethrowEndpointFailure(endpointFailures);
        expect(outbound, hasLength(4));
        expect(fixture.status(tester).isAdvancing, isTrue);
        expect((await chat.snapshot(session.id.value)).entries, hasLength(3));
        for (final breadcrumb in ['project-breadcrumb', 'task-breadcrumb']) {
          final task = fixture.shell(tester).task!;
          await _breadcrumb(tester, breadcrumb);
          await _pumpUntil(
            tester,
            () => find.byType(MainContentHost).evaluate().isEmpty,
          );
          expect(fixture.shell(tester).navigationError, isNull);
          if (breadcrumb == 'project-breadcrumb') {
            await _tap(tester, task.title);
          }
          await _openSession(tester, session.id);
          await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
          expect(_session(tester), same(session));
          expect(fixture.status(tester).isAdvancing, isTrue);
          expect(fixture.status(tester).pendingApproval, same(commandApproval));
          expect(runtime.store.runRecord(fixture.runIds.values.last), isNull);
          expect(outbound, hasLength(4));
        }
        releaseFinal.complete();
        await _pumpUntil(tester, () => find.text(answer).evaluate().isNotEmpty);
        _rethrowEndpointFailure(endpointFailures);
        final canonical = await chat.snapshot(session.id.value);
        expect(canonical.draftRequest, '');
        expect(canonical.entries.map((entry) => (entry.role, entry.content)), [
          ('user', _initialPrompt),
          ('assistant', _initialAnswer),
          ('user', _prompt),
          ('assistant', answer),
        ]);
        expect(
          canonical.entries.take(3).map((entry) => entry.id),
          waiting.entries.map((entry) => entry.id),
        );
        expect(
          canonical.entries.map((entry) => entry.id).toSet(),
          hasLength(4),
        );
        final runId = fixture.runIds.values.last;
        expect(canonical.entries.map((entry) => entry.runId), [
          fixture.runIds.values.first.value,
          null,
          runId.value,
          null,
        ]);
        final retainedActivity = runtime.lifecycle.runActivity(runId)!;
        expect(retainedActivity.state, RunState.completed);
        expect(retainedActivity.models, hasLength(3));
        expect(retainedActivity.tools.map((tool) => tool.alias), [
          'read_file',
          'apply_patch',
          'run_command',
        ]);
        final native = retainedActivity.models
            .expand((model) => model.outputs)
            .map((output) => output.item)
            .whereType<ModelNativeOutput>()
            .single;
        expect(native.presentation!.compactText, _reasoning);
        expect(
          jsonEncode(native.providerNativeMetadata.data),
          contains(_encrypted),
        );
        expect(
          jsonEncode(native.providerNativeMetadata.data),
          contains(_privateReasoning),
        );
        final project = fixture.shell(tester).project!;
        final task = fixture.shell(tester).task!;
        final authority = runtime.store.requireSessionAuthority(session.id);
        final database = runtime.lifecycle.databaseForSession(session.id)!;
        final marker = await File('${worktree.path}/.git').readAsBytes();
        expect(fixture.status(tester).pendingApproval, isNull);
        expect(fixture.status(tester).failureMessage, isNull);
        expect(fixture.status(tester).isAdvancing, isFalse);
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: host, matching: find.byType(TextField)),
              )
              .enabled,
          isTrue,
        );
        expect(fixture.runIds.values, hasLength(2));
        expect(
          await _sourceSnapshot(fixture.source, taskWorktree: worktree),
          projectBefore,
        );
        expect(
          await File('${worktree.path}/$_sourcePath').readAsString(),
          _patchedText,
        );

        // The installed frontend owns grouping; retain one product smoke check,
        // not the old app-owned grouping/Inspection permutation matrix.
        await _tap(tester, _narration);
        expect(find.byType(InspectionHost), findsOneWidget);
        expect(find.textContaining('Apply Patch'), findsWidgets);
        _expectNoSecrets(tester);
        expect(
          (await chat.snapshot(
            session.id.value,
          )).entries.map((entry) => entry.id),
          canonical.entries.map((entry) => entry.id),
        );
        expect(outbound, hasLength(4));

        final sessionRunIds = List<RunId>.of(fixture.runIds.values);
        const retainedDraft = '  Continue after restart:\tkeep this draft  ';
        await tester.enterText(composer, retainedDraft);
        await _breadcrumb(tester, 'task-breadcrumb');
        await _pumpUntil(
          tester,
          () => find.byType(MainContentHost).evaluate().isEmpty,
        );
        expect(fixture.shell(tester).task, same(task));
        expect(find.byType(InspectionHost), findsNothing);
        expect(_sessionRow(session.id), findsOneWidget);
        expect(
          (await chat.snapshot(session.id.value)).draftRequest,
          retainedDraft,
        );

        // Duplicate Chat labels require selection by the secondary Session ID,
        // not by row order or by creating a replacement Session.
        await _tap(tester, 'New Chat Session');
        await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
        final sibling = _session(tester);
        await _send(tester, _siblingPrompt);
        await _pumpUntil(
          tester,
          () => find.text(_siblingAnswer).evaluate().isNotEmpty,
        );
        final siblingHistory = await chat.snapshot(sibling.id.value);
        final siblingActivity = runtime.lifecycle
            .runActivitiesForSession(sibling.id)
            .single;
        const siblingDraft = '  Same Task, different Session\t  ';
        await tester.enterText(_composer(), siblingDraft);
        await _breadcrumb(tester, 'project-breadcrumb');
        await _pumpUntil(tester, () => fixture.shell(tester).task == null);
        expect(
          (await chat.snapshot(sibling.id.value)).draftRequest,
          siblingDraft,
        );
        await fixture.createTask(tester, 'Another retained Task');
        final otherTask = fixture.shell(tester).task!;
        final otherEnvironment = fixture.shell(tester).environment!;
        await _tap(tester, 'New Chat Session');
        await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
        final otherSession = _session(tester);
        await _send(tester, _otherPrompt);
        await _pumpUntil(
          tester,
          () => find.text(_otherAnswer).evaluate().isNotEmpty,
        );
        final otherHistory = await chat.snapshot(otherSession.id.value);
        final otherActivity = runtime.lifecycle
            .runActivitiesForSession(otherSession.id)
            .single;
        const otherDraft = '  Other Task draft\t  ';
        await tester.enterText(_composer(), otherDraft);
        await _breadcrumb(tester, 'project-breadcrumb');
        await _pumpUntil(tester, () => fixture.shell(tester).task == null);
        expect(
          (await chat.snapshot(otherSession.id.value)).draftRequest,
          otherDraft,
        );
        final inventory = await _git(fixture.source, [
          'worktree',
          'list',
          '--porcelain',
        ]);
        final retainedSource = await _sourceSnapshot(
          fixture.source,
          taskWorktree: worktree,
        );
        expect(fixture.runIds.values, hasLength(4));
        expect(outbound, hasLength(6));
        _rethrowEndpointFailure(endpointFailures);
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
        expect(runtime.plugins.state, ApplicationPluginState.closed);
        expect(database.loadProductGraph, throwsStateError);
        for (final backend in runtime.plugins.backends) {
          expect(backend.connection!.isClosed, isTrue);
        }
        expect(strategy.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(presentation.validate, throwsA(isA<StaleExtensionBinding>()));
        await expectLater(
          chat.snapshot(session.id.value),
          throwsA(isA<PluginConnectionClosed>()),
        );
        expect(
          runtime.extensions.discover(orchestrationStrategyContributions),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());

        // Reopen through the actual application and prepared Project selector.
        // No credentials are supplied; browsing cannot create execution authority.
        final ids = _NoReopenIds();
        final fresh = NativeAdeleRuntime(ids: ids, runIds: ids);
        addTearDown(fresh.close);
        await fixture.launch(
          tester,
          prepared,
          usingRuntime: fresh,
          usingRunIds: ids,
        );
        expect(fresh.registry.providersFor(modelProviderCapability), isEmpty);
        expect(fresh.store.session(session.id), isNull);
        await _tap(tester, 'Open Local Directory...');
        await _pumpUntil(tester, () => fixture.shell(tester).project != null);
        final reopened = fixture.shell(tester).project!;
        expect(reopened.id, project.id);
        expect(reopened, isNot(same(project)));
        expect(fixture.shell(tester).task, isNull);
        expect(fixture.shell(tester).environment, isNull);
        expect(find.byType(MainContentHost), findsNothing);
        expect(find.byType(InspectionHost), findsNothing);
        expect(
          fresh.store.tasksFor(reopened.id).map((task) => task.id),
          unorderedEquals([task.id, otherTask.id]),
        );
        expect(find.text(task.title), findsOneWidget);
        expect(find.text(otherTask.title), findsOneWidget);
        await _tap(tester, task.title);
        await _pumpUntil(
          tester,
          () => fixture.shell(tester).task?.id == task.id,
        );
        expect(_sessionRow(session.id), findsOneWidget);
        expect(_sessionRow(sibling.id), findsOneWidget);
        expect(_sessionRow(otherSession.id), findsNothing);
        expect(find.text('Chat'), findsNWidgets(2));
        expect(find.text('New Chat Session'), findsOneWidget);
        expect(find.byType(MainContentHost), findsNothing);
        final restoredEnvironment = fresh.store.primaryEnvironmentFor(task.id)!;
        expect(restoredEnvironment.id, environment.id);
        expect(restoredEnvironment.providerState, environment.providerState);
        final restoredSession = fresh.store.session(session.id)!;
        expect(restoredSession, isNot(same(session)));
        expect(restoredSession.taskId, task.id);
        expect(restoredSession.strategyId, session.strategyId);
        final restoredAuthority = fresh.store.requireSessionAuthority(
          session.id,
        );
        expect(restoredAuthority, isNot(same(authority)));
        expect(restoredAuthority.environmentId, environment.id);
        expect(
          fresh.store
              .runsForSession(session.id)
              .map((record) => (record.id, record.state)),
          unorderedEquals([
            for (final id in sessionRunIds) (id, RunTerminalState.completed),
          ]),
        );
        final restoredActivity = fresh.lifecycle.runActivity(runId)!;
        expect(restoredActivity, isNot(same(retainedActivity)));
        expect(
          _activityEvidence(restoredActivity),
          _activityEvidence(retainedActivity),
        );
        expect(
          fresh.lifecycle
              .runActivitiesForSession(session.id)
              .map((activity) => activity.runId),
          unorderedEquals(sessionRunIds),
        );
        expect(
          fresh.lifecycle.environmentRuntime.currentMaterialization(
            environment.id,
          ),
          isNull,
        );
        final freshChatConnection = fresh.plugins.backends
            .singleWhere(
              (backend) =>
                  backend.installation.metadata.id.value == _chatPluginId,
            )
            .connection!;
        expect(freshChatConnection, isNot(same(connection)));
        final freshChat = _chatClient(freshChatConnection);
        final restoredChat = await freshChat.snapshot(session.id.value);
        expect(
          restoredChat.entries.map(
            (entry) => (entry.id, entry.role, entry.content, entry.runId),
          ),
          canonical.entries.map(
            (entry) => (entry.id, entry.role, entry.content, entry.runId),
          ),
        );
        await _openSession(tester, session.id);
        await _pumpUntil(
          tester,
          () => find.text(_narration).evaluate().isNotEmpty,
        );
        expect(_session(tester), same(restoredSession));
        expect(
          tester.widget<TextField>(_composer()).controller!.text,
          retainedDraft,
        );
        expect(restoredChat.draftRequest, retainedDraft);
        for (final text in [_initialPrompt, _initialAnswer, _prompt, answer]) {
          expect(find.text(text), findsOneWidget);
        }
        expect(
          tester.getTopLeft(find.text(_prompt)).dy,
          lessThan(tester.getTopLeft(find.text(_narration)).dy),
        );
        expect(
          tester.getTopLeft(find.text(_narration)).dy,
          lessThan(tester.getTopLeft(find.text(answer)).dy),
        );
        _expectNoSecrets(tester);

        await _tap(tester, _narration);
        expect(find.byType(InspectionHost), findsOneWidget);
        await _tap(tester, 'Reasoning: $_reasoning');
        expect(find.byType(InspectionHost), findsNWidgets(2));
        expect(find.text('Reasoning summary'), findsWidgets);
        _expectNoSecrets(tester);
        await _tap(tester, 'Apply Patch: "$_sourcePath" / 1 edit');
        expect(find.byType(InspectionHost), findsNWidgets(3));
        expect(find.text('New revision: $patchedRevision'), findsOneWidget);
        expect(find.text('Lifecycle: completed'), findsOneWidget);
        _expectNoSecrets(tester);
        expect(fixture.status(tester).pendingApproval, isNull);
        expect(fixture.status(tester).isAdvancing, isFalse);
        expect(fixture.status(tester).failureMessage, isNull);
        expect(fixture.status(tester).unavailableReason, isNotNull);
        expect(ids.calls, 0);
        expect(fixture.runIds.values, hasLength(4));
        expect(outbound, hasLength(6));
        expect(
          fresh.lifecycle.environmentRuntime.currentMaterialization(
            environment.id,
          ),
          isNull,
        );
        expect(
          await _git(fixture.source, ['worktree', 'list', '--porcelain']),
          inventory,
        );
        expect(await File('${worktree.path}/.git').readAsBytes(), marker);
        expect(
          await File('${worktree.path}/$_sourcePath').readAsString(),
          _patchedText,
        );
        expect(
          await _sourceSnapshot(fixture.source, taskWorktree: worktree),
          retainedSource,
        );
        expect(
          (await freshChat.snapshot(
            session.id.value,
          )).entries.map((entry) => (entry.id, entry.runId)),
          canonical.entries.map((entry) => (entry.id, entry.runId)),
        );
        await _breadcrumb(tester, 'task-breadcrumb');
        await _pumpUntil(
          tester,
          () => find.byType(MainContentHost).evaluate().isEmpty,
        );
        expect(fixture.shell(tester).task!.id, task.id);
        expect(find.byType(InspectionHost), findsNothing);
        await _openSession(tester, sibling.id);
        await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
        expect(_session(tester), same(fresh.store.session(sibling.id)));
        expect(
          tester.widget<TextField>(_composer()).controller!.text,
          siblingDraft,
        );
        expect(find.text(_initialPrompt), findsNothing);
        expect(find.text(_narration), findsNothing);
        expect(find.text(_siblingPrompt), findsOneWidget);
        expect(find.text(_siblingAnswer), findsOneWidget);
        expect(find.text(_otherAnswer), findsNothing);
        expect(
          (await freshChat.snapshot(sibling.id.value)).entries.map(
            (entry) => (entry.id, entry.role, entry.content, entry.runId),
          ),
          siblingHistory.entries.map(
            (entry) => (entry.id, entry.role, entry.content, entry.runId),
          ),
        );
        expect(
          _activityEvidence(
            fresh.lifecycle.runActivitiesForSession(sibling.id).single,
          ),
          _activityEvidence(siblingActivity),
        );
        await _breadcrumb(tester, 'project-breadcrumb');
        await _pumpUntil(tester, () => fixture.shell(tester).task == null);
        expect(fixture.shell(tester).environment, isNull);
        expect(find.byType(MainContentHost), findsNothing);
        expect(_sessionRow(session.id), findsNothing);
        await _tap(tester, otherTask.title);
        await _pumpUntil(
          tester,
          () => fixture.shell(tester).task?.id == otherTask.id,
        );
        expect(_sessionRow(otherSession.id), findsOneWidget);
        expect(_sessionRow(session.id), findsNothing);
        expect(_sessionRow(sibling.id), findsNothing);
        await _openSession(tester, otherSession.id);
        await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
        expect(_session(tester), same(fresh.store.session(otherSession.id)));
        expect(
          tester.widget<TextField>(_composer()).controller!.text,
          otherDraft,
        );
        expect(find.byType(InspectionHost), findsNothing);
        expect(find.text(_otherPrompt), findsOneWidget);
        expect(find.text(_otherAnswer), findsOneWidget);
        expect(find.text(_siblingAnswer), findsNothing);
        expect(find.text(_initialPrompt), findsNothing);
        expect(
          (await freshChat.snapshot(otherSession.id.value)).entries.map(
            (entry) => (entry.id, entry.role, entry.content, entry.runId),
          ),
          otherHistory.entries.map(
            (entry) => (entry.id, entry.role, entry.content, entry.runId),
          ),
        );
        expect(
          _activityEvidence(
            fresh.lifecycle.runActivitiesForSession(otherSession.id).single,
          ),
          _activityEvidence(otherActivity),
        );
        await _breadcrumb(tester, 'task-breadcrumb');
        await _pumpUntil(
          tester,
          () => find.byType(MainContentHost).evaluate().isEmpty,
        );
        expect(fixture.shell(tester).task!.id, otherTask.id);
        await _breadcrumb(tester, 'project-breadcrumb');
        await _pumpUntil(tester, () => fixture.shell(tester).task == null);
        expect(find.text(task.title), findsOneWidget);
        expect(find.text(otherTask.title), findsOneWidget);
        expect(
          fresh.store.sessionsForTask(task.id).map((session) => session.id),
          unorderedEquals([session.id, sibling.id]),
        );
        expect(
          fresh.store.sessionsForTask(otherTask.id).single.id,
          otherSession.id,
        );
        for (final id in [environment.id, otherEnvironment.id]) {
          expect(
            fresh.lifecycle.environmentRuntime.currentMaterialization(id),
            isNull,
          );
        }
        expect(ids.calls, 0);
        expect(fixture.runIds.values, hasLength(4));
        expect(outbound, hasLength(6));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      }),
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  for (final rejectLatest in [false, true]) {
    testWidgets(
      'prepared Chat navigation ${rejectLatest ? 'retains the Session after draft failure and retries' : 'awaits the latest draft before leaving'}',
      (tester) => tester.runAsync(() async {
        await tester.binding.setSurfaceSize(const Size(1400, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = await _ProductFixture.create();
        final root = await prepared.copyInstallations(fixture.directory);
        await prepared.gatedChat.copy(
          '${root.path}/$_chatPluginId/backend.aot',
        );
        final firstArrived = Completer<void>();
        final latestArrived = Completer<void>();
        final releaseFirst = Completer<void>();
        final releaseLatest = Completer<void>();
        final failures = <(Object, StackTrace)>[];
        final writes = <String>[];
        const firstDraft = 'Older draft';
        const latestDraft = '  Latest unsent draft:\tpreserve exactly  ';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          try {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            final content = (body['parameters'] as Map)[':draft'] as String;
            writes.add(content);
            switch (writes.length) {
              case 1:
                expect(content, firstDraft);
                firstArrived.complete();
                await releaseFirst.future;
              case 2:
                expect(content, latestDraft);
                latestArrived.complete();
                await releaseLatest.future;
                if (rejectLatest) {
                  request.response.statusCode = HttpStatus.conflict;
                }
              case 3:
                expect(rejectLatest, isTrue);
                expect(content, latestDraft);
              default:
                fail('Unexpected automatic draft retry ${writes.length}.');
            }
          } on Object catch (error, stack) {
            failures.add((error, stack));
            request.response.statusCode = HttpStatus.internalServerError;
          } finally {
            await request.response.close();
          }
        });
        addTearDown(() async {
          await subscription.cancel();
          await server.close(force: true);
        });
        await fixture.launch(
          tester,
          prepared,
          root: root,
          endpoint: server,
          startupArguments: {
            _chatPluginId: [
              'http://${server.address.address}:${server.port}/draft',
            ],
          },
        );
        addTearDown(() {
          if (!releaseFirst.isCompleted) releaseFirst.complete();
          if (!releaseLatest.isCompleted) releaseLatest.complete();
        });
        await fixture.openTask(tester);
        // The gated backend intentionally has no optional strategy display name.
        await _tap(tester, 'New ${chatStrategyId.value} Session');
        await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
        final session = _session(tester);
        final task = fixture.shell(tester).task!;
        final connection = fixture.runtime.plugins.backends
            .singleWhere(
              (backend) =>
                  backend.installation.metadata.id.value == _chatPluginId,
            )
            .connection!;
        final chat = _chatClient(connection);
        await tester.enterText(_composer(), firstDraft);
        await firstArrived.future.timeout(const Duration(seconds: 15));
        await tester.enterText(_composer(), latestDraft);
        await _breadcrumb(
          tester,
          rejectLatest ? 'project-breadcrumb' : 'task-breadcrumb',
        );
        expect(fixture.shell(tester).navigating, isTrue);
        expect(_session(tester), same(session));
        expect(fixture.shell(tester).task, same(task));
        expect(
          tester.widget<TextField>(_composer()).controller!.text,
          latestDraft,
        );
        // Chat serializes reads behind its draft write. Observe the transaction
        // gates here, then assert durable content after releasing them.
        expect(writes, [firstDraft]);
        releaseFirst.complete();
        await latestArrived.future.timeout(const Duration(seconds: 15));
        await tester.pump();
        expect(fixture.shell(tester).navigating, isTrue);
        expect(_session(tester), same(session));
        expect(writes, [firstDraft, latestDraft]);
        expect(fixture.runIds.values, isEmpty);
        expect(fixture.runtime.store.runsForSession(session.id), isEmpty);
        releaseLatest.complete();
        await _pumpUntil(tester, () => !fixture.shell(tester).navigating);
        _rethrowEndpointFailure(failures);
        if (rejectLatest) {
          expect(_session(tester), same(session));
          expect(fixture.shell(tester).task, same(task));
          expect(fixture.status(tester).unavailableReason, isNull);
          expect(tester.widget<TextField>(_composer()).enabled, isTrue);
          expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Send'))
                .onPressed,
            isNotNull,
          );
          expect(
            find.text(
              'Could not leave this Session. Save pending changes and try again.',
            ),
            findsOneWidget,
          );
          expect(
            find.text('Draft was not saved. Your text is preserved.'),
            findsOneWidget,
          );
          expect(
            tester.widget<TextField>(_composer()).controller!.text,
            latestDraft,
          );
          expect(
            (await chat.snapshot(session.id.value)).draftRequest,
            firstDraft,
          );
          expect(writes, [firstDraft, latestDraft]);
          // Retrying navigation must use the same still-live prepared view and
          // owning backend route, not a replacement Session or a lost draft.
          await _breadcrumb(tester, 'project-breadcrumb');
          await _pumpUntil(
            tester,
            () => find.byType(MainContentHost).evaluate().isEmpty,
          );
          expect(fixture.shell(tester).task, isNull);
          expect(writes, [firstDraft, latestDraft, latestDraft]);
          await _tap(tester, task.title);
          await _pumpUntil(
            tester,
            () => fixture.shell(tester).task?.id == task.id,
          );
        } else {
          expect(find.byType(MainContentHost), findsNothing);
          expect(fixture.shell(tester).task, same(task));
          expect(writes, [firstDraft, latestDraft]);
        }
        expect(fixture.shell(tester).navigationError, isNull);
        expect(
          (await chat.snapshot(session.id.value)).draftRequest,
          latestDraft,
        );
        expect((await chat.snapshot(session.id.value)).entries, isEmpty);
        await _openSession(tester, session.id);
        await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
        expect(_session(tester), same(session));
        expect(
          tester.widget<TextField>(_composer()).controller!.text,
          latestDraft,
        );
        expect(fixture.runtime.store.sessionsForTask(task.id), [session]);
        expect(fixture.runIds.values, isEmpty);
        expect(connection.isClosed, isFalse);
        expect(tester.takeException(), isNull);
        _rethrowEndpointFailure(failures);
        await tester.binding.handleRequestAppExit();
        await tester.pumpWidget(const SizedBox.shrink());
      }),
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  // Retain the application-level shutdown boundary as well as controller-unit
  // draining: an accepted remote call must finish before its backend is retired,
  // while an unresolved approval must never be silently allowed during disposal.
  for (final waiting in [false, true]) {
    testWidgets(
      'hidden installed Session ${waiting ? 'disposal abandons waiting approval' : 'frontend retirement preserves accepted model work until exit drains before backend shutdown'}',
      (tester) => tester.runAsync(() async {
        final fixture = await _ProductFixture.create();
        final arrived = Completer<void>();
        final release = Completer<void>();
        final errors = <(Object, StackTrace)>[];
        var requests = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final subscription = server.listen((request) async {
          try {
            final body =
                jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, Object?>;
            requests++;
            expect(
              requests,
              1,
              reason: 'Closing cannot initiate another model turn.',
            );
            expect(body['input'], [_userInput('Shutdown fixture')]);
            arrived.complete();
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
            if (waiting) {
              _output(
                request.response,
                _call('unresolved', 'run_command', _commandArguments),
              );
            } else {
              await release.future;
              _output(
                request.response,
                _message('late-final', 'Late accepted answer.'),
              );
            }
            _sse(request.response, {
              'type': 'response.completed',
              'response': {'id': 'shutdown-response', 'model': 'gpt-6-astra'},
            });
          } on Object catch (error, stack) {
            errors.add((error, stack));
            if (!arrived.isCompleted) arrived.complete();
          } finally {
            await request.response.close();
          }
        });
        addTearDown(() async {
          await subscription.cancel();
          await server.close(force: true);
        });
        try {
          await fixture.launch(tester, prepared, endpoint: server);
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          await fixture.openTask(tester);
          await _tap(tester, 'New Chat Session');
          await _send(tester, 'Shutdown fixture');
          await arrived.future.timeout(const Duration(seconds: 15));
          _rethrowEndpointFailure(errors);
          final runtime = fixture.runtime;
          final session = _session(tester);
          final connection = runtime.plugins.backends
              .singleWhere(
                (backend) =>
                    backend.installation.metadata.id.value == _chatPluginId,
              )
              .connection!;
          final chat = _chatClient(connection);
          expect(
            (await chat.snapshot(session.id.value)).entries.single.content,
            'Shutdown fixture',
          );
          expect(fixture.runIds.values, hasLength(1));
          if (waiting) {
            await _pumpUntil(
              tester,
              () => fixture.status(tester).pendingApproval != null,
            );
          }
          final hiddenStatus = fixture.status(tester);
          await _breadcrumb(tester, 'task-breadcrumb');
          await _pumpUntil(
            tester,
            () => find.byType(MainContentHost).evaluate().isEmpty,
          );
          // At the default small viewport, the existing Session row can put
          // creation below the detail ListView's built children. Mount it by
          // scrolling this pane, rather than polling for an off-screen element.
          final taskDetail = find.ancestor(
            of: find.text('Primary Environment'),
            matching: find.byType(Scrollable),
          );
          expect(taskDetail, findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('New Chat Session'),
            120,
            scrollable: taskDetail,
            maxScrolls: 8,
          );
          await _tap(tester, 'New Chat Session');
          await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
          expect(_session(tester).id, isNot(session.id));
          expect(fixture.status(tester).pendingApproval, isNull);
          expect(fixture.status(tester).isAdvancing, isFalse);
          if (waiting) {
            final approval = hiddenStatus.pendingApproval!;
            await tester.pumpWidget(const SizedBox.shrink());
            hiddenStatus.onDecision(approval, true);
            hiddenStatus.onDecision(approval, false);
          } else {
            final selected = _session(tester);
            PreparedFrontend? generation;
            // Prepared views key their exact generation. Retire the shared Chat
            // frontend through B's actual pane while A's accepted Run is hidden.
            tester.element(_chatView()).visitAncestorElements((element) {
              if (element.widget.key case ValueKey(
                value: (
                  final PreparedFrontend owner,
                  String _,
                  String _,
                  Key? _,
                ),
              )) {
                generation = owner;
                return false;
              }
              return true;
            });
            expect(generation, isNotNull);
            generation!.invalidate();
            await _pumpUntil(tester, () => _composer().evaluate().isEmpty);
            expect(_session(tester), same(selected));
            expect(find.text('Frontend unavailable.'), findsOneWidget);
            expect(connection.isClosed, isFalse);
            expect(runtime.plugins.state, ApplicationPluginState.ready);
            expect(
              runtime.store.runRecord(fixture.runIds.values.single),
              isNull,
            );
            expect(
              (await chat.snapshot(session.id.value)).entries,
              hasLength(1),
            );
            expect(fixture.runIds.values, hasLength(1));
            expect(requests, 1);
            var exited = false;
            final exiting = tester.binding.handleRequestAppExit().then((
              result,
            ) {
              exited = true;
              return result;
            });
            await Future<void>.delayed(Duration.zero);
            await tester.pump();
            expect(exited, isFalse);
            expect(runtime.plugins.state, ApplicationPluginState.ready);
            expect(connection.isClosed, isFalse);
            expect(
              (await chat.snapshot(session.id.value)).entries,
              hasLength(1),
            );
            release.complete();
            expect(
              await exiting.timeout(const Duration(seconds: 15)),
              AppExitResponse.exit,
            );
            expect(find.text('Late accepted answer.'), findsNothing);
          }
          await _pumpUntil(
            tester,
            () => runtime.plugins.state == ApplicationPluginState.closed,
          );
          _rethrowEndpointFailure(errors);
          expect(requests, 1);
          expect(fixture.runIds.values, hasLength(1));
          expect(
            runtime.store.runRecord(fixture.runIds.values.single)?.state,
            waiting ? isNull : RunTerminalState.completed,
          );
          expect(connection.isClosed, isTrue);
          expect(
            runtime.extensions.discover(orchestrationStrategyContributions),
            isEmpty,
          );
          await expectLater(
            chat.snapshot(session.id.value),
            throwsA(isA<PluginConnectionClosed>()),
          );
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        } finally {
          if (!release.isCompleted) release.complete();
          await tester.binding.handleRequestAppExit().timeout(
            const Duration(seconds: 30),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }),
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }

  for (final component in ['backend', 'frontend']) {
    for (final corruption in ['missing', 'corrupt']) {
      testWidgets(
        'F3g Chat $component $corruption is independent without native fallback',
        (tester) => tester.runAsync(() async {
          final fixture = await _ProductFixture.create();
          final root = await prepared.copyInstallations(fixture.directory);
          final damaged = File(
            '${root.path}/$_chatPluginId/${component == 'backend' ? 'backend.aot' : 'frontend.evc'}',
          );
          if (corruption == 'missing') {
            await damaged.delete();
          } else {
            await damaged.writeAsBytes([0, 1, 2, 3]);
          }
          await fixture.launch(tester, prepared, root: root);
          final runtime = fixture.runtime;
          final catalog = runtime.plugins.catalog!;
          expect(catalog.installations, hasLength(9));
          expect(catalog.issues, hasLength(corruption == 'missing' ? 1 : 0));
          expect(runtime.plugins.state, ApplicationPluginState.ready);
          expect(runtime.plugins.failure, isNull);
          final healthy = runtime.plugins.backends.where(
            (entry) => entry.installation.metadata.id.value != _chatPluginId,
          );
          expect(healthy, hasLength(7));
          for (final backend in healthy) {
            expect(
              backend.state,
              InstalledBackendState.active,
              reason: backend.installation.metadata.id.value,
            );
            expect(backend.connection!.isClosed, isFalse);
          }
          expect(
            runtime.extensions.discover(inferenceContextSources),
            hasLength(1),
          );
          expect(
            runtime.extensions.discover(modelToolContributions),
            hasLength(3),
          );
          expect(
            runtime.extensions.discover(toolActivityInspectionContributions),
            hasLength(2),
          );
          expect(
            runtime.extensions.discover(
              modelNativeActivityPresentationContributions,
            ),
            hasLength(1),
          );
          expect(
            runtime.extensions.discover(projectSelectorContributions),
            hasLength(1),
          );
          await fixture.openTask(tester);
          final task = fixture.shell(tester).task!;
          expect(
            runtime.lifecycle.environmentRuntime.currentMaterialization(
              fixture.shell(tester).environment!.id,
            ),
            isNotNull,
          );
          if (component == 'backend') {
            expect(
              runtime.extensions.discover(orchestrationStrategyContributions),
              isEmpty,
            );
            expect(
              runtime.extensions.discover(mainContentContributions),
              hasLength(1),
            );
            final backends = runtime.plugins.backends.where(
              (entry) => entry.installation.metadata.id.value == _chatPluginId,
            );
            if (corruption == 'corrupt') {
              expect(backends.single.state, InstalledBackendState.failed);
            } else {
              expect(backends, isEmpty);
            }
            expect(
              () => runtime.lifecycle.createSession(
                taskId: task.id,
                strategyId: chatStrategyId,
              ),
              throwsA(isA<OrchestrationStrategyUnavailable>()),
            );
            expect(find.text('New Chat Session'), findsNothing);
            expect(runtime.store.sessionsForTask(task.id), isEmpty);
            expect(find.byType(MainContentHost), findsNothing);
            expect(find.text('Send'), findsNothing);
          } else {
            final backend = runtime.plugins.backends.singleWhere(
              (entry) => entry.installation.metadata.id.value == _chatPluginId,
            );
            expect(backend.state, InstalledBackendState.active);
            expect(
              runtime.extensions.discover(orchestrationStrategyContributions),
              hasLength(1),
            );
            final chat = _chatClient(backend.connection!);
            // Creation is a backend strategy operation, not renderer selection.
            await _tap(tester, 'New Chat Session');
            await _pumpUntil(
              tester,
              () => find.byType(MainContentHost).evaluate().isNotEmpty,
            );
            final session = _session(tester);
            expect(runtime.store.sessionsForTask(task.id), [same(session)]);
            await chat.configureSession(
              session.id.value,
              'Backend remains independent.',
              3,
            );
            final entry = await chat.appendUserMessage(
              session.id.value,
              'Backend survives frontend failure.',
            );
            final snapshot = await chat.snapshot(session.id.value);
            expect(snapshot.entries.single.id, entry.id);
            expect(snapshot.entries.single.content, entry.content);
            expect(snapshot.instructions, 'Backend remains independent.');
            expect(snapshot.maxModelInvocations, 3);
            // Main Content validates bytecode on activation. Both absence and
            // corruption leave no Chat registration, without a native fallback.
            expect(
              runtime.extensions.discover(mainContentContributions),
              isEmpty,
            );
            expect(
              find.text('No Main Content is available for this Session.'),
              findsOneWidget,
            );
            await _breadcrumb(tester, 'task-breadcrumb');
            await _pumpUntil(
              tester,
              () => find.byType(MainContentHost).evaluate().isEmpty,
            );
            await _openSession(tester, session.id);
            await _pumpUntil(
              tester,
              () => find.byType(MainContentHost).evaluate().isNotEmpty,
            );
            expect(_session(tester), same(session));
            expect(runtime.store.sessionsForTask(task.id), [same(session)]);
            expect(runtime.store.runsForSession(session.id), isEmpty);
            expect(find.text('Send'), findsNothing);
          }
          expect(fixture.runIds.values, isEmpty);
          expect(find.text('Ask ADELE...'), findsNothing);
          expect(tester.takeException(), isNull);
          expect(
            await tester.binding.handleRequestAppExit(),
            AppExitResponse.exit,
          );
          expect(
            runtime.extensions.discover(orchestrationStrategyContributions),
            isEmpty,
          );
          expect(
            runtime.extensions.discover(mainContentContributions),
            isEmpty,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }),
        timeout: const Timeout(Duration(seconds: 45)),
      );
    }
  }

  for (final availability in [
    'Chat frontend absent with backend and editor contribution',
    'Chat backend unavailable',
    'no Main Content contributions',
  ]) {
    testWidgets(
      'actual Task Browser opens retained canonical Session: $availability',
      (tester) => tester.runAsync(() async {
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = await _ProductFixture.create();
        final resources = MainContentFixtureResources();
        addTearDown(resources.dispose);
        try {
          await fixture.launch(tester, prepared);
          await fixture.openTask(tester);
          await _tap(tester, 'New Chat Session');
          await _pumpUntil(tester, () => _composer().evaluate().isNotEmpty);
          final original = _session(tester);
          final task = fixture.shell(tester).task!;
          final environment = fixture.shell(tester).environment!;
          expect(fixture.runIds.values, isEmpty);
          await tester.binding.handleRequestAppExit();
          await tester.pumpWidget(const SizedBox.shrink());

          final root = await prepared.copyInstallations(fixture.directory);
          final backendUnavailable = availability == 'Chat backend unavailable';
          final hasEditors =
              availability ==
              'Chat frontend absent with backend and editor contribution';
          await File(
            '${root.path}/$_chatPluginId/${backendUnavailable ? 'backend.aot' : 'frontend.evc'}',
          ).delete();
          if (hasEditors) {
            await installMainContentFixture(
              installationRoot: root,
              artifact: await prepared.mainContentFixture(),
            );
          }
          final ids = _NoReopenIds();
          final fresh = NativeAdeleRuntime(ids: ids, runIds: ids);
          addTearDown(fresh.close);
          await fixture.launch(
            tester,
            prepared,
            root: root,
            usingRuntime: fresh,
            usingRunIds: ids,
            mainContentHost: resources.host,
          );
          await _tap(tester, 'Open Local Directory...');
          await _pumpUntil(tester, () => fixture.shell(tester).project != null);
          final restored = fresh.store.session(original.id)!;
          final authority = fresh.store.requireSessionAuthority(restored.id);
          expect(restored, isNot(same(original)));
          expect(restored.taskId, task.id);
          expect(restored.strategyId, original.strategyId);
          expect(authority.environmentId, environment.id);
          expect(
            fresh.lifecycle.environmentRuntime.currentMaterialization(
              environment.id,
            ),
            isNull,
          );
          await _tap(tester, task.title);
          await _pumpUntil(
            tester,
            () => _sessionRow(restored.id).evaluate().isNotEmpty,
          );
          expect(
            tester.widget<ListTile>(_sessionRow(restored.id)).onTap,
            isNotNull,
          );
          expect(
            find.text('New Chat Session'),
            backendUnavailable ? findsNothing : findsOneWidget,
          );
          if (backendUnavailable) {
            expect(
              () => fresh.lifecycle.createSession(
                taskId: task.id,
                strategyId: restored.strategyId,
              ),
              throwsA(isA<OrchestrationStrategyUnavailable>()),
            );
          }
          await _terminalTap(tester, _sessionRow(restored.id));
          await _terminalUntil(
            tester,
            () => find.byType(MainContentHost).evaluate().isNotEmpty,
            'retained canonical workspace opening',
          );
          expect(_session(tester), same(restored));
          expect(fixture.shell(tester).sessionPresented, isTrue);
          expect(fixture.shell(tester).navigationError, isNull);
          expect(fresh.store.sessionsForTask(task.id), [same(restored)]);
          expect(
            fresh.store.requireSessionAuthority(restored.id),
            same(authority),
          );
          if (hasEditors) {
            await _terminalUntil(
              tester,
              () => find.byType(CodeForge).evaluate().length == 1,
              'independent editor with absent Chat frontend',
            );
            expect(resources.editor(restored.id, 'editor-a'), isNotNull);
            expect(
              fresh.extensions.discover(mainContentContributions),
              hasLength(1),
            );
          } else if (backendUnavailable) {
            await _pumpUntil(
              tester,
              () => find.text('Frontend unavailable.').evaluate().isNotEmpty,
            );
            expect(
              fresh.extensions.discover(mainContentContributions),
              hasLength(1),
            );
          } else {
            expect(
              fresh.extensions.discover(mainContentContributions),
              isEmpty,
            );
            expect(
              find.text('No Main Content is available for this Session.'),
              findsOneWidget,
            );
          }
          expect(_composer(), findsNothing);
          expect(find.byType(RunExecutionStatus), findsNothing);
          expect(fresh.store.runsForSession(restored.id), isEmpty);
          expect(fresh.lifecycle.runActivitiesForSession(restored.id), isEmpty);
          expect(
            fresh.lifecycle.environmentRuntime.currentMaterialization(
              environment.id,
            ),
            isNull,
          );
          expect(ids.calls, 0);
          expect(fixture.runIds.values, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          // Real backend cleanup must finish before fake-async auto-disposal.
          await tester.binding.handleRequestAppExit().timeout(
            const Duration(seconds: 30),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }),
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }

  // Preserve the focused installed-tool startup regression while using the same
  // prepared AOT artifacts, rather than reintroducing semantic fallbacks.
  for (final pluginId in [
    _searchPluginId,
    _filesystemPluginId,
    _commandPluginId,
  ]) {
    test(
      '$pluginId failure preserves installed Chat and sibling backends',
      () async {
        final runtime = AdeleRuntime();
        addTearDown(runtime.close);
        await prepared.start(
          runtime,
          startupArguments: {
            pluginId: ['unexpected-test-argument'],
          },
        );
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.backends, hasLength(8));
        for (final backend in runtime.plugins.backends) {
          expect(
            backend.state,
            backend.installation.metadata.id.value == pluginId
                ? InstalledBackendState.failed
                : InstalledBackendState.active,
          );
        }
        expect(
          runtime.extensions
              .discover(orchestrationStrategyContributions)
              .single
              .value
              .strategyId,
          chatStrategyId,
        );
        expect(
          runtime.extensions
              .discover(modelToolContributions)
              .map((entry) => entry.id.value),
          unorderedEquals([
            for (final id in [
              _searchPluginId,
              _filesystemPluginId,
              _commandPluginId,
            ])
              if (id != pluginId) '$id.model-tools',
          ]),
        );
        expect(
          runtime.extensions.discover(inferenceContextSources),
          hasLength(1),
        );
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          hasLength(1),
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      },
    );
  }
}

final class _PresentationProcess {
  _PresentationProcess(this.socket)
    : lines = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  final Socket socket;
  final StreamIterator<String> lines;
  int? pid;
  bool exited = false;
  late String workingDirectory;

  Future<void> stage(String stage) async {
    expect(await lines.moveNext().timeout(const Duration(seconds: 15)), isTrue);
    final parts = lines.current.split(':');
    expect(parts.first, stage);
    pid = int.parse(parts[1]);
    workingDirectory = parts.skip(2).join(':');
  }

  void release(String stage) => socket.writeln(stage);
  Future<bool> isAlive() => Directory('/proc/$pid').exists();
}

final class _PresentedCapture {
  const _PresentedCapture(
    this.client,
    this.sessionId,
    this.runId,
    this.invocationId,
  );
  final CommandOutputServiceClient client;
  final String sessionId;
  final String runId;
  final String invocationId;

  Future<CommandCaptureState> state() => client
      .getState(sessionId, runId, invocationId)
      .timeout(const Duration(seconds: 15));

  Future<String> tail() async {
    final page = await client
        .readBefore(
          sessionId,
          runId,
          invocationId,
          null,
          commandOutputPageChunks,
          commandOutputPageCodeUnits,
        )
        .timeout(const Duration(seconds: 15));
    return page.chunks.map((chunk) => chunk.text).join();
  }
}

Finder _projectionView(Finder parent) =>
    find.descendant(of: parent, matching: find.byType(TerminalView));

void _expectOutputPainted(WidgetTester tester, Finder parent, String text) {
  final view = _projectionView(parent);
  final buffer = tester.widget<TerminalView>(view).terminal.buffer;
  final row = List.generate(
    buffer.height,
    (index) => index,
  ).singleWhere((index) => buffer.lines[index].getText().contains(text));
  final render = tester.state<TerminalViewState>(view).renderTerminal;
  final top = render.getOffset(CellOffset(0, row)).dy;
  expect(top, greaterThanOrEqualTo(-0.01));
  expect(top + render.lineHeight, lessThanOrEqualTo(render.size.height + 0.01));
}

Terminal _projectionEngine(WidgetTester tester, Finder parent) =>
    tester
            .widget<TerminalView>(_projectionView(parent))
            .terminal
            .buffer
            .terminal
        as Terminal;

Future<void> _projectionText(
  WidgetTester tester,
  Finder parent,
  String text,
) async {
  try {
    await _terminalUntil(tester, () {
      final views = _projectionView(parent).evaluate();
      return views.length == 1 &&
          find
              .descendant(
                of: parent,
                matching: find.text('Replaying output...'),
              )
              .evaluate()
              .isEmpty &&
          _terminalBuffer(_projectionEngine(tester, parent)).contains(text);
    }, 'native projection contains $text');
  } on TestFailure {
    final labels = tester
        .widgetList<Text>(
          find.descendant(of: parent, matching: find.byType(Text)),
        )
        .map((widget) => widget.data)
        .whereType<String>()
        .join('\n');
    final views = _projectionView(parent).evaluate();
    final buffer = views.length == 1
        ? _terminalBuffer(_projectionEngine(tester, parent))
        : 'No unique projection';
    fail('Missing $text. Reader state:\n$labels\nEmulator:\n$buffer');
  }
}

final class _PreparedProduct {
  _PreparedProduct(this.directory, this.root, this.dart, this.dartaotruntime);
  final Directory directory;
  final Directory root;
  final String dart;
  final String dartaotruntime;
  File get host => File('${directory.path}/host.aot');
  File get gatedChat => File('${directory.path}/gated-chat.aot');
  File get commandProcess => File('${directory.path}/command-process.aot');
  File backend(String id) => File('${root.path}/$id/backend.aot');
  Future<File>? _mainContentFixture;

  Future<File> mainContentFixture() => _mainContentFixture ??= () async {
    final artifact = File('${directory.path}/main-content.evc');
    await prepareMainContentFixture(
      repositoryRoot: Directory.current.parent,
      artifact: artifact,
    );
    return artifact;
  }();

  static Future<_PreparedProduct> prepare() async {
    final repository = Directory.current.parent;
    final directory = await Directory.systemTemp.createTemp(
      'adele-normal-chatgpt-aot-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final root = await Directory('${directory.path}/installed').create();
    final dart = _dartExecutable();
    final runtime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    final result = _PreparedProduct(directory, root, dart, runtime);
    const entrypoints = {
      _gitPluginId:
          'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
      _agentsMdPluginId:
          'plugins/agents_md/packages/backend/bin/agents_md_backend.dart',
      _searchPluginId:
          'plugins/search_tools/packages/backend/bin/search_tools_backend.dart',
      _filesystemPluginId:
          'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart',
      _commandPluginId:
          'plugins/command_tools/packages/backend/bin/command_tools_backend.dart',
      _openAiPluginId:
          'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
      _chatPluginId:
          'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart',
      _localDirectoryProjectPluginId:
          'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
    };
    for (final id in [...entrypoints.keys, _taskBrowserPluginId]) {
      final installed = await Directory('${root.path}/$id').create();
      await File(
        '${installed.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {'id': id, 'version': '1.0.0', 'displayName': id},
          'components': {
            if (entrypoints.containsKey(id))
              'backend': {'artifact': 'backend.aot'},
            if (stockFrontendDescriptors.containsKey(id) ||
                stockFrontendExtensionDescriptors.containsKey(id))
              'frontend': {
                'artifact': 'frontend.evc',
                'presentations': stockFrontendDescriptors[id] ?? const [],
                'extensions': ?stockFrontendExtensionDescriptors[id],
              },
          },
        }),
      );
    }
    await compileChatFrontend(
      repositoryRoot: repository,
      artifact: File('${root.path}/$_chatPluginId/frontend.evc'),
    );
    await File('${root.path}/$_taskBrowserPluginId/frontend.evc').writeAsBytes(
      await compileTaskBrowserFrontend(repositoryRoot: repository),
    );
    await File(
      '${root.path}/$_localDirectoryProjectPluginId/frontend.evc',
    ).writeAsBytes(
      await compileLocalDirectoryProjectFrontend(repositoryRoot: repository),
    );
    await File('${root.path}/$_openAiPluginId/frontend.evc').writeAsBytes(
      await compileOpenAiActivityFrontend(repositoryRoot: repository),
    );
    for (final (id, frontend) in [
      (_filesystemPluginId, ToolInspectionFrontend.filesystem),
      (_commandPluginId, ToolInspectionFrontend.command),
    ]) {
      await compileToolInspectionFrontend(
        repositoryRoot: repository,
        artifact: File('${root.path}/$id/frontend.evc'),
        frontend: frontend,
      );
    }
    await compileAotSnapshot(
      dartExecutable: dart,
      workingDirectory: repository,
      entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      artifact: result.host,
      stage: 'normal-chatgpt-host',
    );
    for (final entry in entrypoints.entries) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entry.value,
        artifact: result.backend(entry.key),
        stage: 'normal-chatgpt-${entry.key}',
      );
    }
    await compileAotSnapshot(
      dartExecutable: dart,
      workingDirectory: repository,
      entrypoint: 'app/test/support/gated_chat_backend.dart',
      artifact: result.gatedChat,
      stage: 'normal-chatgpt-gated-storage',
    );
    await compileAotSnapshot(
      dartExecutable: dart,
      workingDirectory: repository,
      entrypoint: 'app/test/fixtures/command_output_process.dart',
      artifact: result.commandProcess,
      stage: 'normal-chatgpt-command-process',
    );
    return result;
  }

  Future<void> start(
    AdeleRuntime runtime, {
    Directory? installationRoot,
    String? dartaotruntimeExecutable,
    Map<String, List<String>>? startupArguments,
  }) => runtime.plugins.start(
    installationRoot: (installationRoot ?? root).path,
    dartaotruntimeExecutable: dartaotruntimeExecutable ?? dartaotruntime,
    hostArtifactPath: host.path,
    startupArguments: startupArguments,
  );

  Future<Directory> copyInstallations(Directory parent) async {
    final copy = await Directory('${parent.path}/installed').create();
    await for (final directory in root.list()) {
      final installed = await Directory(
        '${copy.path}/${directory.uri.pathSegments.where((s) => s.isNotEmpty).last}',
      ).create();
      await for (final file in (directory as Directory).list()) {
        await (file as File).copy(
          '${installed.path}/${file.uri.pathSegments.last}',
        );
      }
    }
    return copy;
  }

  Future<File> installTerminal(Directory root) async {
    final installed = await Directory(
      '${root.path}/$_terminalPluginId',
    ).create();
    await File(
      '${installed.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': _terminalPluginId,
          'version': '1.0.0',
          'displayName': 'Terminal',
        },
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': stockFrontendDescriptors[_terminalPluginId]!,
          },
        },
      }),
    );
    await File('${installed.path}/frontend.evc').writeAsBytes(
      await compileTerminalFrontend(repositoryRoot: Directory.current.parent),
    );
    final helper = File('${root.path}/$_gitPluginId/git-pty-helper');
    await prepareGitPtyHelper(
      repositoryRoot: Directory.current.parent,
      output: helper,
    );
    return helper;
  }
}

final class _ProductFixture {
  _ProductFixture(this.directory, this.source);
  final Directory directory;
  final Directory source;
  final runtime = NativeAdeleRuntime(
    ids: MonotonicProductIdSource(seed: 'f3g-product'),
  );
  final runIds = _RunIds();

  static Future<_ProductFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'adele-normal-chatgpt-run-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = Directory('${directory.path}/project');
    await Directory('${source.path}/lib').create(recursive: true);
    await File('${source.path}/$_sourcePath').writeAsString(_taskText);
    await File('${source.path}/AGENTS.md').writeAsString(_agentsText);
    await _git(source, ['init', '--initial-branch=main']);
    await _git(source, ['add', '.']);
    await _git(source, ['commit', '-m', 'Fixture baseline']);
    final fixture = _ProductFixture(directory, source);
    addTearDown(fixture.runtime.close);
    return fixture;
  }

  AdeleShell shell(WidgetTester tester) =>
      tester.widget<AdeleShell>(find.byType(AdeleShell));
  RunExecutionStatus status(WidgetTester tester) =>
      tester.widget<RunExecutionStatus>(find.byType(RunExecutionStatus));

  Future<String> isolatedRuntime(_PreparedProduct prepared) async {
    final home = await Directory('${directory.path}/home').create();
    // Only the child host's ambient environment changes. The stock host and
    // Git AOT entrypoints, default-shell resolution and PTY remain unmodified.
    final launcher = File('${directory.path}/dartaotruntime');
    await launcher.writeAsString(
      '#!/bin/sh\n'
      'exec /usr/bin/env -i HOME=${_shellQuote(home.path)} '
      'SHELL=/bin/sh PATH=/usr/bin:/bin LANG=C.UTF-8 '
      '${_shellQuote(prepared.dartaotruntime)} "\$@"\n',
    );
    final chmod = await Process.run('chmod', ['700', launcher.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
    return launcher.path;
  }

  Future<void> launch(
    WidgetTester tester,
    _PreparedProduct prepared, {
    Directory? root,
    String? dartaotruntimeExecutable,
    HttpServer? endpoint,
    NativeAdeleRuntime? usingRuntime,
    RunIdSource? usingRunIds,
    PreparedMainContentHost? mainContentHost,
    Map<String, List<String>> startupArguments = const {},
  }) async {
    final runtime = usingRuntime ?? this.runtime;
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    final previousPicker = FileSelectorPlatform.instance;
    final picker = _DirectoryPicker(source.path);
    FileSelectorPlatform.instance = picker;
    addTearDown(() => FileSelectorPlatform.instance = previousPicker);
    final startup = <String, List<String>>{...startupArguments};
    if (endpoint != null) {
      final credentials = File('${directory.path}/credentials.json');
      await credentials.writeAsString(
        jsonEncode({
          'version': 1,
          'instances': {
            'fixture': {
              'revision': 1,
              'credential': {
                'idToken': _idToken('f3g-fixture-account'),
                'accessToken': 'f3g-fake-access-token',
                'refreshToken': 'f3g-fake-refresh-never-used',
                'accountId': 'f3g-fixture-account',
                'fedRamp': false,
              },
            },
          },
        }),
      );
      startup[_openAiPluginId] = [
        '--chatgpt-only',
        jsonEncode({
          'credentialFile': credentials.path,
          'clientId': 'fixture',
          'instanceId': 'fixture',
          'issuer': 'http://${endpoint.address.address}:${endpoint.port}',
          'endpoint':
              'http://${endpoint.address.address}:${endpoint.port}/backend-api/codex/responses',
        }),
      ];
    }
    late Future<void> starting;
    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: () => runtime,
        readChatGptConfiguration: () =>
            const StockChatGptConfiguration(model: 'gpt-6-astra'),
        runIds: usingRunIds ?? runIds,
        mainContentHost: mainContentHost,
        bootstrapPlugins: (_) => starting = prepared.start(
          runtime,
          installationRoot: root,
          dartaotruntimeExecutable: dartaotruntimeExecutable,
          startupArguments: startup,
        ),
      ),
    );
    addTearDown(() async {
      await tester.binding.handleRequestAppExit();
      await tester.pumpWidget(const SizedBox.shrink());
    });
    await starting;
    await _pumpUntil(
      tester,
      () =>
          runtime.extensions
              .discover(projectSelectorContributions)
              .isNotEmpty &&
          runtime.extensions.discover(taskBrowserContributions).isNotEmpty &&
          runtime.extensions
                  .discover(toolActivityInspectionContributions)
                  .length ==
              2 &&
          runtime.extensions
                  .discover(modelNativeActivityPresentationContributions)
                  .length ==
              1,
    );
    expect(picker.calls, 0);
    if (usingRunIds == null) expect(runIds.values, isEmpty);
  }

  Future<void> openTask(WidgetTester tester) async {
    await _tap(tester, 'Open Local Directory...');
    await _pumpUntil(tester, () => shell(tester).project != null);
    final project = shell(tester).project!;
    expect(project.sourceLocation, source.uri);
    expect(runtime.store.project(project.id), same(project));
    expect(await File('${source.path}/.adele/data.db').exists(), isTrue);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    await createTask(tester, 'Approve installed product work');
  }

  Future<void> createTask(WidgetTester tester, String title) async {
    final previous = shell(tester).task;
    await _tap(tester, 'New Task');
    expect(find.text('Task title'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, title);
    await _tap(tester, 'Create Task');
    await _pumpUntil(
      tester,
      () => shell(tester).task != null && shell(tester).task != previous,
    );
    expect(
      runtime.lifecycle.environmentRuntime.currentMaterialization(
        shell(tester).environment!.id,
      ),
      isNotNull,
    );
    expect(
      runtime.store.primaryEnvironmentFor(shell(tester).task!.id),
      same(shell(tester).environment),
    );
  }
}

ChatSessionServiceClient _chatClient(PluginBackendConnection connection) =>
    ChatSessionServiceClient(
      connection.channelFor(
        connection.defaultConfigurationContext,
        chatSessionServiceId,
      ),
    );

Map<String, Object?> _activityEvidence(RunActivitySnapshot activity) => {
  'runId': activity.runId.value,
  'sessionId': activity.sessionId.value,
  'state': activity.state.name,
  'sequence': activity.sequence,
  'lifecycle': [
    for (final change in activity.lifecycle) (change.sequence, change.state),
  ],
  'models': [
    for (final model in activity.models)
      {
        'id': model.id.value,
        'start': model.startSequence,
        'terminal': model.terminalSequence,
        'settlement': model.settlement?.name,
        'effectiveModel': model.metadata?.effectiveModel,
        'responseId': model.metadata?.providerResponseId,
        'outputs': [
          for (final output in model.outputs)
            {
              'sequence': output.sequence,
              ...switch (output.item) {
                ModelTextOutput(:final content, :final providerItemId) => {
                  'text': content,
                  'itemId': providerItemId,
                },
                ModelToolProposalOutput(:final proposal) => {
                  'callId': proposal.providerCallId,
                  'alias': proposal.alias,
                  'arguments': proposal.arguments,
                },
                ModelNativeOutput(
                  :final providerItemId,
                  :final providerNativeMetadata,
                  :final presentation,
                ) =>
                  {
                    'itemId': providerItemId,
                    'nativeKind': providerNativeMetadata.kind,
                    'nativeCompatibility': providerNativeMetadata.compatibility,
                    'nativeData': providerNativeMetadata.data,
                    'presentationKind': presentation?.kind,
                    'compactText': presentation?.compactText,
                    'presentationData': presentation?.data,
                  },
              },
            },
        ],
      },
  ],
  'tools': [
    for (final tool in activity.tools)
      {
        'id': tool.id.value,
        'modelId': tool.modelInvocationId.value,
        'proposalSequence': tool.proposalSequence,
        'preparedSequence': tool.preparedSequence,
        'toolId': tool.toolId.value,
        'alias': tool.alias,
        'callId': tool.providerCallId,
        'arguments': tool.canonicalArguments,
        'changes': [
          for (final change in tool.changes)
            {
              'sequence': change.sequence,
              'kind': change.kind.name,
              'decision': change.policyDecision?.name,
              'interruptionId': change.interruptionId?.value,
              'approved': change.approved,
              'progressKind': change.progress?.kind.name,
              'progressContent': change.progress?.content,
            },
        ],
        'disposition': tool.outcome?.disposition.name,
        'certainty': tool.outcome?.effectCertainty.name,
        'failureKind': tool.outcome?.failureKind?.name,
        'modelContent': tool.outcome?.modelContent,
        'hostData': tool.outcome?.hostData,
      },
  ],
};

final class _NoReopenIds implements ProductIdSource, RunIdSource {
  int calls = 0;
  Never _allocate(String kind) {
    calls++;
    throw StateError('Displaying retained work must not allocate $kind IDs.');
  }

  @override
  ProjectId nextProjectId() => _allocate('Project');
  @override
  TaskId nextTaskId() => _allocate('Task');
  @override
  EnvironmentId nextEnvironmentId() => _allocate('Environment');
  @override
  SessionId nextSessionId() => _allocate('Session');
  @override
  RunId nextRunId() => _allocate('Run');
}

final class _DirectoryPicker extends FileSelectorPlatform {
  _DirectoryPicker(this.path);
  final String path;
  int calls = 0;
  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    calls++;
    return path;
  }
}

final class _RunIds implements RunIdSource {
  final values = <RunId>[];
  @override
  RunId nextRunId() {
    final id = RunId('f3g-run-${values.length + 1}');
    values.add(id);
    return id;
  }
}

// Terminal cursors do not settle. Advance gesture/route animation frames only;
// real process progress is always established by a bounded predicate or marker.
Future<void> _terminalUntil(
  WidgetTester tester,
  FutureOr<bool> Function() ready,
  String description,
) async {
  final clock = Stopwatch()..start();
  while (!await ready()) {
    if (clock.elapsed >= const Duration(seconds: 15)) {
      fail('Timed out: $description');
    }
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
  }
  await tester.pump();
}

Future<void> _terminalTap(WidgetTester tester, Finder target) async {
  await _terminalUntil(tester, () => target.evaluate().isNotEmpty, '$target');
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _newTerminal(WidgetTester tester) async {
  await _terminalTap(tester, find.byTooltip('New console'));
  await _terminalTap(tester, find.text('New Terminal'));
}

Finder _terminalTab(String title) => find.widgetWithText(TextButton, title);

Terminal _terminalEngine(WidgetTester tester) =>
    tester
            .widget<TerminalView>(find.byType(TerminalView))
            .terminal
            .buffer
            .terminal
        as Terminal;

Future<void> _terminalCommand(WidgetTester tester, String command) =>
    _terminalCommandIn(tester, find.byType(WorkbenchConsole), command);

Future<void> _terminalCommandIn(
  WidgetTester tester,
  Finder parent,
  String command,
) async {
  final view = _projectionView(parent);
  await _terminalTap(tester, view);
  final context = tester.element(
    find.descendant(of: view, matching: find.byType(Scrollable)).last,
  );
  expect(Focus.of(context).hasFocus, isTrue);
  final messenger = tester.binding.defaultBinaryMessenger;
  final previous = messenger.allMessagesHandler;
  final channel = SystemChannels.platform;
  var reads = 0;
  messenger.allMessagesHandler = (name, handler, message) {
    if (name == channel.name && message != null) {
      final call = channel.codec.decodeMethodCall(message);
      if (call.method == 'Clipboard.getData') {
        expect(call.arguments, Clipboard.kTextPlain);
        reads++;
        return Future.value(
          channel.codec.encodeSuccessEnvelope({'text': '$command\n'}),
        );
      }
    }
    if (previous != null) return previous(name, handler, message);
    return handler != null
        ? handler(message)
        : messenger.delegate.send(name, message);
  };
  try {
    await (Actions.invoke(
          context,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        )
        as Future<Object?>);
    expect(reads, 1);
  } finally {
    messenger.allMessagesHandler = previous;
  }
}

String _terminalBuffer(Terminal engine) {
  final text = StringBuffer();
  for (var i = 0; i < engine.buffer.height; i++) {
    final line = engine.buffer.lines[i];
    if (i > 0 && !line.isWrapped) text.writeln();
    text.write(line.getText().trimRight());
  }
  return text.toString();
}

Future<void> _terminalText(
  WidgetTester tester,
  Terminal engine,
  String marker,
) async {
  try {
    await _terminalUntil(
      tester,
      () => _terminalBuffer(engine).split('\n').contains(marker),
      'shell output $marker',
    );
  } on TestFailure {
    fail('Missing $marker in emulator screen:\n${_terminalBuffer(engine)}');
  }
}

int _terminalPid(Terminal engine, String prefix) => int.parse(
  RegExp(
    '^${prefix}_PID=(\\d+)\$',
    multiLine: true,
  ).firstMatch(_terminalBuffer(engine))![1]!,
);

Future<int> _terminalParentPid(int pid) async {
  final stat = await File('/proc/$pid/stat').readAsString();
  return int.parse(stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1]);
}

Future<void> _terminalReaped(WidgetTester tester, List<int> pids) =>
    _terminalUntil(tester, () async {
      for (final pid in pids) {
        if (await Directory('/proc/$pid').exists()) return false;
      }
      return true;
    }, 'shell/helper reaped: $pids');

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

Future<void> _pumpUntil(
  WidgetTester tester,
  FutureOr<bool> Function() ready,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!await ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
  }
  expect(
    await ready(),
    isTrue,
    reason: 'Timed out waiting for installed product state.',
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate(
      (widget) => widget is ButtonStyleButton || widget is ListTile,
    ),
  );
  await _pumpUntil(tester, () => button.evaluate().isNotEmpty);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Session _session(WidgetTester tester) =>
    tester.widget<MainContentHost>(find.byType(MainContentHost)).session;

Finder _composer() =>
    find.descendant(of: _chatView(), matching: find.byType(TextField));

Finder _chatView() => find.ancestor(
  of: find.descendant(
    of: find.byType(MainContentHost),
    matching: find.text('Ask ADELE...'),
  ),
  matching: find.byWidgetPredicate(
    (widget) => widget is $StatefulWidget$bridge,
  ),
);

Finder _sessionRow(SessionId id) => find.ancestor(
  of: find.textContaining(id.value),
  matching: find.byType(ListTile),
);

Future<void> _openSession(WidgetTester tester, SessionId id) async {
  final row = _sessionRow(id);
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

Future<void> _breadcrumb(WidgetTester tester, String key) async {
  final breadcrumb = find.byKey(ValueKey(key));
  await tester.ensureVisible(breadcrumb);
  await tester.tap(breadcrumb);
  await tester.pump();
}

Future<void> _send(WidgetTester tester, String prompt) async {
  final field = _composer();
  await _pumpUntil(
    tester,
    () =>
        field.evaluate().isNotEmpty &&
        tester.widget<TextField>(field).enabled == true,
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, prompt);
  await _tap(tester, 'Send');
}

void _rethrowEndpointFailure(List<(Object, StackTrace)> failures) {
  if (failures.isNotEmpty) {
    final (error, stack) = failures.first;
    Error.throwWithStackTrace(error, stack);
  }
}

void _expectNoSecrets(WidgetTester tester) {
  final rendered = tester
      .widgetList<Text>(find.byType(Text, skipOffstage: false))
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
      .join('\n');
  expect(rendered, isNot(contains(_encrypted)));
  expect(rendered, isNot(contains(_privateReasoning)));
  expect(find.text('Frontend unavailable.'), findsNothing);
}

Map<String, Object?> _userInput(String text) => {
  'type': 'message',
  'role': 'user',
  'content': [
    {'type': 'input_text', 'text': text},
  ],
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
Map<String, Object?> _reasoningItem() => {
  'type': 'reasoning',
  'id': 'reasoning',
  'status': 'completed',
  'summary': [
    {'type': 'summary_text', 'text': _reasoning},
  ],
  'encrypted_content': _encrypted,
  'content': [
    {'type': 'reasoning_text', 'text': _privateReasoning},
  ],
};
void _output(HttpResponse response, Map<String, Object?> item) =>
    _sse(response, {'type': 'response.output_item.done', 'item': item});
void _sse(HttpResponse response, Map<String, Object?> event) =>
    response.write('data: ${jsonEncode(event)}\n\n');
String _toolOutput(Map<String, Object?> body, String callId) =>
    (body['input']! as List<Object?>).cast<Map<String, Object?>>().singleWhere(
          (item) =>
              item['type'] == 'function_call_output' &&
              item['call_id'] == callId,
        )['output']!
        as String;
String _revision(String output) =>
    jsonDecode(
          output
              .split('\n')
              .singleWhere((line) => line.startsWith('Revision: '))
              .substring('Revision: '.length),
        )
        as String;
String _idToken(String accountId) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'none'})}.${encode({
    'https://api.openai.com/auth': {'chatgpt_account_id': accountId},
  })}.';
}

Future<Map<String, Object?>> _sourceSnapshot(
  Directory repository, {
  required Directory taskWorktree,
}) async {
  repository = Directory(await repository.resolveSymbolicLinks());
  final taskPath = await taskWorktree.resolveSymbolicLinks();
  final files = <String, Object?>{};
  Future<void> visit(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity.path == '${repository.path}/.git') continue;
      if (entity.path == taskPath) continue;
      // Session and Chat persistence may change only the Project database here.
      final relativePath = entity.path.substring(repository.path.length + 1);
      if (const {
        '.adele/data.db',
        '.adele/data.db-wal',
        '.adele/data.db-shm',
        '.adele/data.db-journal',
      }.contains(relativePath)) {
        continue;
      }
      if (entity is Directory) {
        await visit(entity);
      } else if (entity is File) {
        files[entity.path.substring(repository.path.length + 1)] = await entity
            .readAsBytes();
      } else {
        throw StateError('Unexpected fixture entity ${entity.path}.');
      }
    }
  }

  await visit(repository);
  return {
    'files': files,
    'head': await _git(repository, ['rev-parse', 'HEAD']),
    'status': await _git(repository, ['status', '--porcelain=v1', '-z']),
    'diff': await _git(repository, ['diff', '--binary', 'HEAD']),
    'staged': await _git(repository, ['diff', '--cached', '--binary']),
  };
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run('git', [
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
