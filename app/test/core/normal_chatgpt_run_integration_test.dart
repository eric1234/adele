@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/plugins/temporary_chatgpt_selection.dart';
import 'package:adele_desktop/ui/execution/run_execution_status.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/widgets.dart' show $StatefulWidget$bridge;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/stock_frontend_descriptors.dart';
import '../../tool/chat_frontend_compiler.dart';
import '../../tool/local_directory_project_frontend_compiler.dart';
import '../../tool/openai_activity_frontend_compiler.dart';
import '../../tool/self_hosting/development_self_hosting.dart';
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
const _sourcePath = 'lib/task_answer.dart';
const _taskText = 'const taskAnswer = "task-worktree-only";\n';
const _patchedText = 'const taskAnswer = "approved-task-value";\n';
const _agentsText = 'Inspect source before proposing an edit and validation.\n';
const _projectText = 'const projectAnswer = "project-source-only"; \t\n';
const _projectAgentsText = 'Project-only guidance must not be used.\n';
const _initialPrompt = 'Explain the approval workflow without tools.';
const _initialAnswer =
    'Source edits and validation commands require separate approvals.';
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
    prepared = await _PreparedProduct.prepare();
  });

  // One existing real-installation fixture, not another remote-strategy matrix.
  // The two decisions exercise the common approval continuation with the actual
  // stock backend/frontend and independently compiled tool/provider components.
  for (final allowCommand in [true, false]) {
    testWidgets(
      'F3g installed Chat replays two prompts and ordered approvals (${allowCommand ? 'Allow once' : 'Deny'})',
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
          await subscription.cancel();
          await server.close(force: true);
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
        expect(catalog.installations, hasLength(8));
        expect(
          catalog.installations.where(
            (entry) => entry.backendArtifactUri != null,
          ),
          hasLength(8),
        );
        expect(
          catalog.installations.where((entry) => entry.frontend != null),
          hasLength(5),
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
            .discover(sessionPresentationContributions)
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
        await _pumpUntil(
          tester,
          () => find.byType(TextField).evaluate().isNotEmpty,
        );
        final host = find.byType(SessionPresentationHost);
        final session = tester.widget<SessionPresentationHost>(host).session;
        expect(runtime.store.session(session.id), same(session));
        expect(session.strategyId, chatStrategyId);
        expect(
          runtime.store.requireSessionAuthority(session.id).environmentId,
          environment.id,
        );
        expect((await chat.snapshot(session.id.value)).entries, isEmpty);
        expect(
          find.descendant(
            of: host,
            matching: find.byWidgetPredicate(
              (widget) => widget is $StatefulWidget$bridge,
            ),
          ),
          findsOneWidget,
        );

        await _send(tester, _initialPrompt);
        await _pumpUntil(
          tester,
          () => find.text(_initialAnswer).evaluate().isNotEmpty,
        );
        _rethrowEndpointFailure(endpointFailures);
        final first = await chat.snapshot(session.id.value);
        expect(first.entries.map((entry) => (entry.role, entry.content)), [
          ('user', _initialPrompt),
          ('assistant', _initialAnswer),
        ]);
        expect(first.entries.map((entry) => entry.id).toSet(), hasLength(2));
        expect(fixture.runIds.values, hasLength(1));
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
        releaseFinal.complete();
        await _pumpUntil(tester, () => find.text(answer).evaluate().isNotEmpty);
        _rethrowEndpointFailure(endpointFailures);
        final canonical = await chat.snapshot(session.id.value);
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
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
        expect(runtime.plugins.state, ApplicationPluginState.closed);
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
        expect(tester.takeException(), isNull);
      }),
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  // Retain the application-level shutdown boundary as well as controller-unit
  // draining: an accepted remote call must finish before its backend is retired,
  // while an unresolved approval must never be silently allowed during disposal.
  for (final waiting in [false, true]) {
    testWidgets(
      'installed Session ${waiting ? 'disposal abandons waiting approval' : 'exit drains accepted model work before backend shutdown'}',
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
        final session = tester
            .widget<SessionPresentationHost>(
              find.byType(SessionPresentationHost),
            )
            .session;
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
          final status = fixture.status(tester);
          final approval = status.pendingApproval!;
          await tester.pumpWidget(const SizedBox.shrink());
          status.onDecision(approval, true);
          status.onDecision(approval, false);
        } else {
          var exited = false;
          final exiting = tester.binding.handleRequestAppExit().then((result) {
            exited = true;
            return result;
          });
          await Future<void>.delayed(Duration.zero);
          await tester.pump();
          expect(exited, isFalse);
          expect(runtime.plugins.state, ApplicationPluginState.ready);
          expect(connection.isClosed, isFalse);
          expect((await chat.snapshot(session.id.value)).entries, hasLength(1));
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
          expect(catalog.installations, hasLength(8));
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
          expect(fixture.shell(tester).environmentReady, isTrue);
          if (component == 'backend') {
            expect(
              runtime.extensions.discover(orchestrationStrategyContributions),
              isEmpty,
            );
            expect(
              runtime.extensions.discover(sessionPresentationContributions),
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
            final session = runtime.lifecycle.createSession(
              taskId: task.id,
              strategyId: chatStrategyId,
            );
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
            if (corruption == 'corrupt') {
              await _tap(tester, 'New Chat Session');
              await _pumpUntil(
                tester,
                () => find.text('Frontend unavailable.').evaluate().isNotEmpty,
              );
            } else {
              expect(
                runtime.extensions.discover(sessionPresentationContributions),
                isEmpty,
              );
            }
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
            runtime.extensions.discover(sessionPresentationContributions),
            isEmpty,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }),
        timeout: const Timeout(Duration(seconds: 45)),
      );
    }
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

final class _PreparedProduct {
  _PreparedProduct(this.directory, this.root, this.dart, this.dartaotruntime);
  final Directory directory;
  final Directory root;
  final String dart;
  final String dartaotruntime;
  File get host => File('${directory.path}/host.aot');
  File backend(String id) => File('${root.path}/$id/backend.aot');

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
    for (final id in entrypoints.keys) {
      final installed = await Directory('${root.path}/$id').create();
      await File(
        '${installed.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {'id': id, 'version': '1.0.0', 'displayName': id},
          'components': {
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
    return result;
  }

  Future<void> start(
    AdeleRuntime runtime, {
    Directory? installationRoot,
    Map<String, List<String>>? startupArguments,
  }) => runtime.plugins.start(
    installationRoot: (installationRoot ?? root).path,
    dartaotruntimeExecutable: dartaotruntime,
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
}

final class _ProductFixture {
  _ProductFixture(this.directory, this.source);
  final Directory directory;
  final Directory source;
  final runtime = AdeleRuntime(
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

  Future<void> launch(
    WidgetTester tester,
    _PreparedProduct prepared, {
    Directory? root,
    HttpServer? endpoint,
  }) async {
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    final previousPicker = FileSelectorPlatform.instance;
    final picker = _DirectoryPicker(source.path);
    FileSelectorPlatform.instance = picker;
    addTearDown(() => FileSelectorPlatform.instance = previousPicker);
    final startup = <String, List<String>>{};
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
        runIds: runIds,
        bootstrapPlugins: (_) => starting = prepared.start(
          runtime,
          installationRoot: root,
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
    expect(runIds.values, isEmpty);
  }

  Future<void> openTask(WidgetTester tester) async {
    await _tap(tester, 'Open Local Directory...');
    await _pumpUntil(tester, () => shell(tester).project != null);
    final project = shell(tester).project!;
    expect(project.sourceLocation, source.uri);
    expect(runtime.store.project(project.id), same(project));
    expect(await File('${source.path}/.adele/data.db').exists(), isTrue);
    expect(runtime.store.tasksFor(project.id), isEmpty);
    await _tap(tester, 'New Task');
    await tester.enterText(
      find.byType(TextField),
      'Approve installed product work',
    );
    await _tap(tester, 'Create Task');
    await _pumpUntil(tester, () => shell(tester).task != null);
    expect(shell(tester).environmentReady, isTrue);
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

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
  expect(
    ready(),
    isTrue,
    reason: 'Timed out waiting for installed product state.',
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester, String prompt) async {
  final field = find.descendant(
    of: find.byType(SessionPresentationHost),
    matching: find.byType(TextField),
  );
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
