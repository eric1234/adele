import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/plugins/stock_openai.dart';
import 'package:adele_desktop/ui/chat/approval_display.dart';
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_desktop/ui/chat/chat_view.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const StockChatGptConfiguration _configuration = StockChatGptConfiguration(
  credentialFile: 'fake-unused',
  model: 'gpt-6-astra',
);

const Map<String, Object?> _patchArguments = <String, Object?>{
  'relativePath': './lib//example.dart',
  'expectedRevision': 'source-revision-0',
  'edits': <Object?>[
    <String, Object?>{'search': 'before', 'replace': 'after'},
  ],
};

const Map<String, Object?> _commandArguments = <String, Object?>{
  'program': 'git',
  'arguments': <String>['diff', '--check'],
};

Iterable<ExecutionEvent> _events(AgentRun run) =>
    run.journal.records.map((record) => record.event);

void main() {
  late _Fixture fixture;

  setUp(() {
    fixture = _Fixture();
    addTearDown(fixture.close);
  });

  AdeleShell shell(WidgetTester tester) =>
      tester.widget<AdeleShell>(find.byType(AdeleShell));

  ChatController chat(WidgetTester tester) =>
      tester.widget<ChatView>(find.byType(ChatView)).controller;

  FilledButton button(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.widgetWithText(FilledButton, label));
    await tester.tap(find.widgetWithText(FilledButton, label));
    await tester.pumpAndSettle();
  }

  Future<void> openTask(
    WidgetTester tester, {
    StockChatGptConfiguration? configuration = _configuration,
  }) async {
    await tester.pumpWidget(fixture.application(configuration: configuration));
    expect(find.text('New Session'), findsNothing);
    await tap(tester, 'Open Chat Test Project...');
    expect(find.text('New Session'), findsNothing);
    await tap(tester, 'New Task');
    await tester.enterText(find.byType(TextField), 'Inspect the source');
    await tap(tester, 'Create Task');
    expect(shell(tester).task, isNotNull);
    expect(shell(tester).environmentReady, isTrue);
    expect(fixture.ids.calls, <String>['project', 'task', 'environment']);
    expect(fixture.runIds.values, isEmpty);
    expect(fixture.environment.reads, isEmpty);
  }

  Future<void> openChat(
    WidgetTester tester, {
    StockChatGptConfiguration? configuration = _configuration,
  }) async {
    await openTask(tester, configuration: configuration);
    await tap(tester, 'New Session');
    expect(find.byType(ChatView), findsOneWidget);
  }

  Future<void> send(WidgetTester tester, String prompt) async {
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), prompt);
    await tap(tester, 'Send');
  }

  Future<void> disposeApplication(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.runtime.close();
    await fixture.close();
    expect(tester.takeException(), isNull);
  }

  for (final bool configured in <bool>[false, true]) {
    testWidgets(
      'New Session publishes exactly once without ${configured ? 'a provider' : 'model configuration'}',
      (tester) async {
        await openTask(
          tester,
          configuration: configured ? _configuration : null,
        );
        final Task task = shell(tester).task!;
        final Environment environment = shell(tester).environment!;
        final VoidCallback retained = button(tester, 'New Session').onPressed!;
        retained();
        retained();
        await tester.pumpAndSettle();
        retained();
        final ChatController controller = chat(tester);
        final Session session = controller.session;
        final SessionEnvironmentAuthority authority = fixture.runtime.store
            .requireSessionAuthority(session.id);

        expect(session.id, SessionId('session-1'));
        expect(session.taskId, task.id);
        expect(session.strategyId, chatStrategyId);
        expect(fixture.runtime.store.session(session.id), same(session));
        expect(authority.sessionId, session.id);
        expect(authority.taskId, task.id);
        expect(authority.environmentId, environment.id);
        expect(
          fixture.runtime.store.primaryEnvironmentFor(task.id),
          same(environment),
        );
        expect(controller.snapshot.id, session.id);
        expect(controller.snapshot.entries, isEmpty);
        expect(controller.currentRun, isNull);
        expect(controller.activeRunFuture, isNull);
        expect(controller.isRunning, isFalse);
        expect(controller.unavailableReason, isNotNull);
        expect(button(tester, 'Send').onPressed, isNull);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );
        expect(controller.submit('Cannot execute'), isFalse);
        expect(fixture.runIds.values, isEmpty);
        expect(fixture.environment.reads, isEmpty);
        expect(fixture.environment.establishments, hasLength(1));
        expect(fixture.ids.calls, <String>[
          'project',
          'task',
          'environment',
          'session',
        ]);

        await tester.pumpWidget(
          fixture.application(
            configuration: configured ? _configuration : null,
          ),
        );
        await tester.pumpAndSettle();
        expect(fixture.runtimeCreations, 1);
        expect(fixture.bootstraps, 1);
        expect(fixture.configurationReads, 1);
        expect(chat(tester), same(controller));
        expect(shell(tester).task, same(task));
        expect(shell(tester).environment, same(environment));
        expect(fixture.runtime.store.session(SessionId('session-2')), isNull);
        expect(
          fixture.ids.calls.where((call) => call == 'session'),
          hasLength(1),
        );
        await disposeApplication(tester);
      },
    );
  }

  testWidgets('two prompts use fresh Runs and replay canonical Chat entries', (
    tester,
  ) async {
    final _ModelChannel model = fixture.registerModel();
    await openChat(tester);
    final ChatController controller = chat(tester);
    final Session session = controller.session;
    expect(model.calls, isEmpty);
    await send(tester, '  First question  ');
    final AgentRun first = controller.currentRun!.run;
    final ChatEntry accepted = controller.snapshot.entries.single;
    expect(accepted, isA<ChatUserMessage>());
    expect(accepted.content, '  First question  ');
    expect(first.id, RunId('run-test-1'));
    expect(first.sessionId, session.id);
    expect(first.state, RunState.running);
    expect(fixture.runIds.values, <RunId>[first.id]);
    expect(model.calls.single.messages, <(String, String)>[
      ('user', '  First question  '),
    ]);
    expect(model.calls.single.request['model'], 'gpt-6-astra');
    expect(
      model.calls.single.request['instructions'],
      contains(_EnvironmentChannel.instructions),
    );
    expect(fixture.environment.reads.single, <String, Object?>{
      'environmentId': 'environment-1',
      'relativePath': 'AGENTS.md',
    });
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    model.calls.single.output('First answer.');
    await tester.pumpAndSettle();
    // Even completed output is Run-local until a successful semantic terminal.
    expect(controller.snapshot.entries, <ChatEntry>[accepted]);
    expect(find.text('First answer.'), findsNothing);
    model.calls.single.settle();
    await tester.pumpAndSettle();
    expect(first.state, RunState.completed);
    expect(controller.isRunning, isFalse);
    expect(controller.activeRunFuture, isNull);
    expect(controller.failure, isNull);
    final ChatEntry assistant = controller.snapshot.entries.last;
    expect(assistant, isA<ChatAssistantMessage>());
    expect(assistant.content, 'First answer.');
    expect(
      fixture.runtime.chat.sessions.obtain(session.id).snapshot().entries.last,
      same(assistant),
    );
    expect(find.text('First answer.'), findsOneWidget);

    await send(tester, 'Second question');
    final AgentRun second = controller.currentRun!.run;
    expect(second, isNot(same(first)));
    expect(second.id, RunId('run-test-2'));
    expect(second.sessionId, session.id);
    expect(controller.session, same(session));
    expect(model.calls, hasLength(2));
    expect(model.calls.last.messages, <(String, String)>[
      ('user', '  First question  '),
      ('assistant', 'First answer.'),
      ('user', 'Second question'),
    ]);
    expect(controller.snapshot.entries.first, same(accepted));
    expect(controller.snapshot.entries[1], same(assistant));
    model.calls.last.output('Second answer.');
    model.calls.last.settle();
    await tester.pumpAndSettle();
    expect(second.state, RunState.completed);
    expect(fixture.environment.reads, hasLength(2));
    expect(controller.snapshot.entries.map((entry) => entry.content), <String>[
      '  First question  ',
      'First answer.',
      'Second question',
      'Second answer.',
    ]);
    expect(fixture.ids.calls.where((call) => call == 'session'), hasLength(1));
    await disposeApplication(tester);
  });

  testWidgets(
    'missing configuration disables only execution with a provider present',
    (tester) async {
      final _ModelChannel model = fixture.registerModel();
      await openChat(tester, configuration: null);
      final ChatController controller = chat(tester);
      expect(controller.unavailableReason, contains('not configured'));
      expect(shell(tester).environmentReady, isTrue);
      expect(shell(tester).task!.id, controller.session.taskId);
      expect(button(tester, 'Send').onPressed, isNull);
      expect(
        controller.submit('Provider presence cannot replace configuration'),
        isFalse,
      );
      expect(controller.snapshot.entries, isEmpty);
      expect(fixture.runIds.values, isEmpty);
      expect(model.calls, isEmpty);
      await disposeApplication(tester);
    },
  );

  testWidgets('blank and active submissions reject retained Send callbacks', (
    tester,
  ) async {
    final _ModelChannel model = fixture.registerModel();
    await openChat(tester);
    final ChatController controller = chat(tester);
    await send(tester, ' \t\n ');
    expect(controller.submit('\n\t'), isFalse);
    expect(fixture.runIds.values, isEmpty);
    expect(controller.snapshot.entries, isEmpty);
    expect(model.calls, isEmpty);
    await tester.enterText(find.byType(TextField), 'Only once');
    final VoidCallback retained = button(tester, 'Send').onPressed!;
    retained();
    final Future<void> active = controller.activeRunFuture!;
    retained();
    expect(controller.submit('Duplicate before rebuild'), isFalse);
    await tester.pumpAndSettle();
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    // A stale callback must reject nonblank text, not merely the cleared editor.
    field.controller!.text = 'Retained duplicate';
    retained();
    expect(controller.submit('Duplicate while active'), isFalse);
    await tester.pump();
    expect(field.enabled, isFalse);
    expect(button(tester, 'Send').onPressed, isNull);
    expect(find.text('Running...'), findsOneWidget);
    expect(controller.activeRunFuture, same(active));
    expect(fixture.runIds.values, hasLength(1));
    expect(model.calls, hasLength(1));
    expect(controller.snapshot.entries.single.content, 'Only once');
    model.calls.single.output('Accepted once.');
    model.calls.single.settle();
    await tester.pumpAndSettle();
    expect(controller.snapshot.entries, hasLength(2));
    expect(controller.isRunning, isFalse);
    expect(button(tester, 'Send').onPressed, isNotNull);
    await disposeApplication(tester);
  });

  testWidgets('model failure preserves history and accepted user for retry', (
    tester,
  ) async {
    final _ModelChannel model = fixture.registerModel();
    await openChat(tester);
    final ChatController controller = chat(tester);
    final Session session = controller.session;
    await send(tester, 'Successful question');
    model.calls.single.output('Prior answer.');
    model.calls.single.settle();
    await tester.pumpAndSettle();
    final List<ChatEntry> prior = controller.snapshot.entries;
    await send(tester, 'Fail this question');
    model.calls.last.output('Partial answer must not become canonical.');
    model.calls.last.settle(fails: true);
    await tester.pumpAndSettle();
    expect(controller.currentRun!.run.state, RunState.failed);
    expect(
      controller.failure,
      isA<ModelFailure>().having(
        (failure) => failure.kind,
        'kind',
        ModelFailureKind.rateLimited,
      ),
    );
    expect(controller.snapshot.entries, hasLength(3));
    expect(controller.snapshot.entries.first, same(prior.first));
    expect(controller.snapshot.entries[1], same(prior[1]));
    expect(controller.snapshot.entries.last.content, 'Fail this question');
    expect(find.textContaining('Partial answer'), findsNothing);
    expect(find.text('Run failed: model rateLimited.'), findsOneWidget);
    expect(controller.isRunning, isFalse);
    expect(controller.activeRunFuture, isNull);
    expect(button(tester, 'Send').onPressed, isNotNull);
    expect(controller.session, same(session));
    expect(fixture.runtime.store.session(session.id), same(session));
    await send(tester, 'Try again');
    expect(controller.failure, isNull);
    expect(find.textContaining('Run failed:'), findsNothing);
    expect(model.calls.last.messages, <(String, String)>[
      ('user', 'Successful question'),
      ('assistant', 'Prior answer.'),
      ('user', 'Fail this question'),
      ('user', 'Try again'),
    ]);
    model.calls.last.output('Recovered.');
    model.calls.last.settle();
    await tester.pumpAndSettle();
    expect(controller.currentRun!.run.id, RunId('run-test-3'));
    expect(controller.currentRun!.run.state, RunState.completed);
    expect(controller.snapshot.entries, hasLength(5));
    expect(controller.snapshot.entries.last.content, 'Recovered.');
    await disposeApplication(tester);
  });

  testWidgets('retirement never falls back and replacement binds a fresh Run', (
    tester,
  ) async {
    final _ModelChannel original = fixture.registerModel();
    final _ModelChannel fallback = fixture.registerModel(
      providerId: ProviderId('dev.adele.test.fallback'),
      rank: 100,
    );
    await openChat(tester);
    final ChatController controller = chat(tester);
    await send(tester, 'Original generation');
    original.calls.single.output('Original answer.');
    original.calls.single.settle();
    await tester.pumpAndSettle();
    final AgentRun first = controller.currentRun!.run;
    final ChatSessionSnapshot prior = controller.snapshot;
    final VoidCallback retained = button(tester, 'Send').onPressed!;
    await original.registration.close();
    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'No fallback';
    retained();
    expect(controller.submit('No substitution'), isFalse);
    expect(controller.unavailableReason, isNotNull);
    expect(controller.snapshot, same(prior));
    expect(fixture.runIds.values, hasLength(1));
    expect(fallback.calls, isEmpty);
    await tester.pumpWidget(fixture.application());
    await tester.pumpAndSettle();
    expect(button(tester, 'Send').onPressed, isNull);
    final _ModelChannel replacement = fixture.registerModel();
    await tester.pumpWidget(fixture.application());
    await tester.pumpAndSettle();
    await send(tester, 'Replacement generation');
    expect(controller.currentRun!.run.id, RunId('run-test-2'));
    expect(controller.currentRun!.run.sessionId, first.sessionId);
    expect(original.calls, hasLength(1));
    expect(fallback.calls, isEmpty);
    expect(replacement.calls.single.messages, <(String, String)>[
      ('user', 'Original generation'),
      ('assistant', 'Original answer.'),
      ('user', 'Replacement generation'),
    ]);
    replacement.calls.single.output('Replacement answer.');
    replacement.calls.single.settle();
    await tester.pumpAndSettle();
    expect(controller.currentRun!.run.state, RunState.completed);
    await disposeApplication(tester);
  });

  testWidgets('accepted preparation keeps its exact retired model binding', (
    tester,
  ) async {
    final _ModelChannel original = fixture.registerModel();
    await openChat(tester);
    final ChatController controller = chat(tester);
    fixture.environment.readGate = Completer<void>();
    await send(tester, 'Bound before context capture');
    expect(fixture.environment.reads, hasLength(1));
    expect(original.calls, isEmpty);
    await original.registration.close();
    final _ModelChannel replacement = fixture.registerModel();
    fixture.environment.readGate!.complete();
    await tester.pumpAndSettle();
    expect(controller.isRunning, isFalse);
    expect(controller.currentRun!.run.state, RunState.failed);
    expect(controller.failure, isA<ProviderUnavailable>());
    expect(original.calls, isEmpty);
    expect(replacement.calls, isEmpty);
    expect(
      controller.snapshot.entries.single.content,
      'Bound before context capture',
    );
    await send(tester, 'Fresh binding');
    expect(replacement.calls, hasLength(1));
    replacement.calls.single.output('Fresh answer.');
    replacement.calls.single.settle();
    await tester.pumpAndSettle();
    expect(controller.currentRun!.run.id, RunId('run-test-2'));
    expect(controller.currentRun!.run.state, RunState.completed);
    await disposeApplication(tester);
  });

  for (final bool exit in <bool>[false, true]) {
    for (final RunState settlement in <RunState>[
      RunState.completed,
      RunState.failed,
      RunState.waiting,
    ]) {
      final bool fails = settlement == RunState.failed;
      final bool waits = settlement == RunState.waiting;
      testWidgets(
        '${exit ? 'exit' : 'disposal'} freezes Chat and drains Run ${waits
            ? 'late first approval'
            : fails
            ? 'failure'
            : 'success'} before runtime close',
        (tester) async {
          final _ModelChannel model = fixture.registerModel();
          await openChat(tester);
          final ChatController controller = chat(tester);
          final Task task = shell(tester).task!;
          final Environment environment = shell(tester).environment!;
          final VoidCallback retained = button(tester, 'Send').onPressed!;
          await send(tester, 'Drain accepted work');
          tester.widget<TextField>(find.byType(TextField)).controller!.text =
              'Retained submission after closing';
          final AgentRun run = controller.currentRun!.run;
          final ChatSessionSnapshot frozen = controller.snapshot;
          final Future<void> active = controller.activeRunFuture!;
          final strategy = fixture.runtime.extensions
              .discover(orchestrationStrategyContributions)
              .single;
          final List<RunState> backendClosingStates = <RunState>[];
          final subscription = fixture.runtime.plugins.changes.listen((state) {
            if (state == ApplicationPluginState.closing) {
              backendClosingStates.add(run.state);
            }
          });
          addTearDown(subscription.cancel);
          Future<AppExitResponse>? exiting;
          bool exitCompleted = false;
          if (exit) {
            exiting = tester.binding.handleRequestAppExit().then((response) {
              exitCompleted = true;
              return response;
            });
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          expect(controller.submit('Closing duplicate'), isFalse);
          retained();
          await tester.pumpAndSettle();
          expect(exitCompleted, isFalse);
          expect(backendClosingStates, isEmpty);
          expect(
            fixture.runtime.plugins.state,
            ApplicationPluginState.unconfigured,
          );
          expect(strategy.validate, returnsNormally);
          expect(controller.unavailableReason, contains('closing'));
          expect(controller.snapshot, same(frozen));
          expect(fixture.runIds.values, hasLength(1));
          expect(model.calls, hasLength(1));
          model.calls.single.output('Late answer.');
          if (waits) {
            model.calls.single.propose(
              'late-first-patch',
              'apply_patch',
              _patchArguments,
            );
          }
          model.calls.single.settle(fails: fails);
          await tester.pumpAndSettle();
          await active;
          if (exiting != null) expect(await exiting, AppExitResponse.exit);
          expect(run.state, settlement);
          expect(backendClosingStates, <RunState>[run.state]);
          expect(fixture.runtime.plugins.state, ApplicationPluginState.closed);
          expect(strategy.validate, throwsA(isA<StaleExtensionBinding>()));
          expect(controller.snapshot, same(frozen));
          expect(controller.failure, isNull);
          expect(controller.submit('Already closed'), isFalse);
          retained();
          expect(fixture.runIds.values, hasLength(1));
          expect(
            fixture.runtime.store.session(controller.session.id),
            same(controller.session),
          );
          final canonical = fixture.runtime.chat.sessions
              .obtain(controller.session.id)
              .snapshot()
              .entries;
          expect(canonical, hasLength(fails || waits ? 1 : 2));
          if (!fails && !waits) expect(canonical.last.content, 'Late answer.');
          if (waits) {
            expect(
              run.interruptions.values.single,
              isA<ToolApprovalInterruption>(),
            );
            expect(controller.pendingApproval, isNull);
            expect(controller.activeRunFuture, isNull);
            expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
            expect(_events(run).whereType<RunInterruptionResolved>(), isEmpty);
            expect(fixture.environment.replacements, isEmpty);
            expect(
              fixture.environment.sourceText,
              _EnvironmentChannel.initialText,
            );
            expect(find.text('Approval required'), findsNothing);
          }
          if (exit) {
            expect(shell(tester).task, same(task));
            expect(shell(tester).environment, same(environment));
            expect(chat(tester), same(controller));
          } else {
            expect(find.byType(ChatView), findsNothing);
          }
          expect(find.text('Late answer.'), findsNothing);
          expect(find.textContaining('Run failed:'), findsNothing);
          expect(tester.takeException(), isNull);
          await disposeApplication(tester);
        },
      );
    }

    testWidgets(
      '${exit ? 'exit' : 'disposal'} closes the application with an unresolved waiting approval',
      (tester) async {
        final _ModelChannel model = fixture.registerModel();
        await openChat(tester);
        final ChatController controller = chat(tester);
        await send(tester, 'Leave this approval unresolved on close');
        final Future<void> starting = controller.activeRunFuture!;
        model.calls.single.propose(
          'waiting-patch',
          'apply_patch',
          _patchArguments,
        );
        model.calls.single.settle();
        await tester.pumpAndSettle();
        await starting;
        final AgentRun run = controller.currentRun!.run;
        final PendingToolApproval approval = controller.pendingApproval!;
        final ChatSessionSnapshot frozen = controller.snapshot;
        final List<ExecutionEventRecord> journal = run.journal.records;
        final VoidCallback retainedAllow = button(
          tester,
          'Allow once',
        ).onPressed!;
        final VoidCallback retainedDeny = tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Deny'))
            .onPressed!;
        expect(run.state, RunState.waiting);
        expect(controller.isAdvancing, isFalse);
        expect(controller.activeRunFuture, isNull);
        expect(find.text(approval.summary), findsOneWidget);
        final strategy = fixture.runtime.extensions
            .discover(orchestrationStrategyContributions)
            .single;
        final List<RunState> backendClosingStates = <RunState>[];
        final subscription = fixture.runtime.plugins.changes.listen((state) {
          if (state == ApplicationPluginState.closing) {
            backendClosingStates.add(run.state);
          }
        });
        addTearDown(subscription.cancel);

        Future<AppExitResponse>? exiting;
        if (exit) {
          exiting = tester.binding.handleRequestAppExit();
          // Flutter dispatches the lifecycle request asynchronously.
          await tester.pump();
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        expect(controller.isClosed, isTrue);
        retainedAllow();
        retainedDeny();
        expect(controller.resolveApproval(approval, approved: true), isFalse);
        expect(controller.resolveApproval(approval, approved: false), isFalse);
        expect(
          controller.submit('Cannot submit after application close'),
          isFalse,
        );
        await tester.pumpAndSettle();
        // Assert application-owned shutdown before any fixture cleanup can close it.
        expect(fixture.runtime.plugins.state, ApplicationPluginState.closed);
        if (exiting != null) expect(await exiting, AppExitResponse.exit);
        expect(backendClosingStates, <RunState>[RunState.waiting]);
        expect(strategy.validate, throwsA(isA<StaleExtensionBinding>()));
        retainedAllow();
        retainedDeny();
        await tester.pump();
        expect(run.state, RunState.waiting);
        expect(run.journal.records, journal);
        expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
        expect(_events(run).whereType<RunInterruptionResolved>(), isEmpty);
        expect(fixture.environment.replacements, isEmpty);
        expect(fixture.environment.processes, isEmpty);
        expect(fixture.environment.writeCount, 0);
        expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
        expect(model.calls, hasLength(1));
        expect(controller.snapshot, same(frozen));
        expect(controller.pendingApproval, same(approval));
        expect(controller.activeRunFuture, isNull);
        expect(controller.failure, isNull);
        expect(
          fixture.runtime.chat.sessions
              .obtain(controller.session.id)
              .snapshot()
              .entries,
          frozen.entries,
        );
        if (exit) {
          expect(chat(tester), same(controller));
          expect(find.text(approval.summary), findsOneWidget);
          expect(find.text('Approval required'), findsOneWidget);
        } else {
          expect(find.byType(ChatView), findsNothing);
        }
        expect(find.textContaining('Run failed:'), findsNothing);
        await disposeApplication(tester);
      },
    );
  }

  testWidgets('narrow layout supports prompt, pending and final Chat', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _ModelChannel model = fixture.registerModel();
    await openChat(tester);
    await send(tester, 'Explain the source on a narrow mobile display.');
    expect(find.text('Running...'), findsOneWidget);
    expect(tester.takeException(), isNull);
    model.calls.single.output(
      'A longer final answer that wraps without overflowing the narrow Chat surface.',
    );
    model.calls.single.settle();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Send'));
    expect(button(tester, 'Send').onPressed, isNotNull);
    expect(chat(tester).snapshot.entries, hasLength(2));
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets('stock read and search continue automatically without approval', (
    tester,
  ) async {
    final _ModelChannel model = fixture.registerModel();
    await openChat(tester);
    final ChatController controller = chat(tester);
    await send(tester, 'Read and search the source');
    final AgentRun run = controller.currentRun!.run;
    final Future<void> active = controller.activeRunFuture!;
    model.calls.single.propose('read-1', 'read_file', <String, Object?>{
      'relativePath': _EnvironmentChannel.sourcePath,
    });
    model.calls.single.propose('search-1', 'search', <String, Object?>{
      'query': 'before',
      'path': 'lib',
    });
    model.calls.single.settle();
    await tester.pumpAndSettle();

    expect(model.calls, hasLength(2));
    expect(controller.isRunning, isTrue);
    expect(controller.isAdvancing, isTrue);
    expect(controller.activeRunFuture, same(active));
    expect(controller.pendingApproval, isNull);
    expect(find.text('Approval required'), findsNothing);
    expect(_events(run).whereType<RunInterrupted>(), isEmpty);
    expect(
      _events(
        run,
      ).whereType<ToolPolicyEvaluated>().map((event) => event.decision),
      <ToolPolicyDecision>[ToolPolicyDecision.allow, ToolPolicyDecision.allow],
    );
    expect(fixture.environment.directories.single['relativePath'], 'lib');
    expect(
      fixture.environment.reads.where(
        (read) => read['relativePath'] == _EnvironmentChannel.sourcePath,
      ),
      hasLength(2),
    );
    expect(fixture.environment.replacements, isEmpty);
    expect(fixture.environment.processes, isEmpty);
    expect(
      model.calls.last.outcomes.map(
        (outcome) => (outcome['callId'], outcome['status']),
      ),
      <(String, String)>[('read-1', 'success'), ('search-1', 'success')],
    );
    expect(
      model.calls.last.outcomes.first['content'],
      contains('source-revision-0'),
    );
    expect(model.calls.last.outcomes.last['content'], contains('before'));
    expect(
      controller.snapshot.entries.single.content,
      'Read and search the source',
    );
    model.calls.last.output('Read and search complete.');
    model.calls.last.settle();
    await tester.pumpAndSettle();
    await active;
    expect(run.state, RunState.completed);
    expect(controller.isRunning, isFalse);
    expect(controller.isAdvancing, isFalse);
    expect(controller.activeRunFuture, isNull);
    expect(controller.failure, isNull);
    expect(controller.snapshot.entries.map((entry) => entry.content), <String>[
      'Read and search the source',
      'Read and search complete.',
    ]);
    await disposeApplication(tester);
  });

  testWidgets(
    'narrow approval cards gate an ordered patch and command batch exactly once',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final _ModelChannel model = fixture.registerModel();
      fixture.environment.replaceGate = Completer<void>();
      fixture.environment.processGate = Completer<void>();
      await openChat(tester);
      final ChatController controller = chat(tester);
      await send(tester, 'Patch the source, then check the diff');
      final AgentRun run = controller.currentRun!.run;
      final Future<void> starting = controller.activeRunFuture!;
      model.calls.single.output('Intermediate proposal text stays Run-local.');
      model.calls.single.propose('patch-A', 'apply_patch', _patchArguments);
      model.calls.single.propose('command-B', 'run_command', _commandArguments);
      model.calls.single.settle();
      await tester.pumpAndSettle();
      await starting;

      final PendingToolApproval patch = controller.pendingApproval!;
      expect(run.state, RunState.waiting);
      expect(controller.isRunning, isTrue);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(controller.submit('Cannot skip this approval'), isFalse);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(button(tester, 'Send').onPressed, isNull);
      expect(patch.toolAlias, 'apply_patch');
      expect(patch.toolId, 'dev.adele.plugin.filesystem-tools.apply-patch');
      expect(patch.effects, <ToolEffect>{ToolEffect.sourceMutation});
      expect(patch.uncertainty, EffectUncertainty.none);
      expect(
        patch.summary,
        'Apply 1 exact edit to Environment file lib/example.dart.',
      );
      expect(patch.targets, <String>[
        'adele-environment:/environment-1/lib/example.dart',
      ]);
      expect(() => patch.targets.add('file:///other'), throwsUnsupportedError);
      expect(
        () => patch.effects.add(ToolEffect.processExecution),
        throwsUnsupportedError,
      );
      expect(jsonDecode(patch.canonicalArgumentsJson), <String, Object?>{
        ..._patchArguments,
        'relativePath': _EnvironmentChannel.sourcePath,
      });
      expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.processes, isEmpty);
      expect(fixture.environment.reads.single['relativePath'], 'AGENTS.md');
      expect(model.calls, hasLength(1));
      expect(find.text('Approval required'), findsOneWidget);
      expect(find.text('Modify source'), findsOneWidget);
      expect(find.text(patch.summary), findsOneWidget);
      expect(find.text('Tool: apply_patch'), findsOneWidget);
      expect(
        find.text('Effects may extend beyond the listed target.'),
        findsNothing,
      );
      expect(
        find.text('Intermediate proposal text stays Run-local.'),
        findsNothing,
      );

      await tester.ensureVisible(find.text('Details'));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text(patch.canonicalArgumentsJson), findsOneWidget);
      expect(
        find.text(
          'Tool ID: ${patch.toolId}\nEffects: sourceMutation\n'
          'Uncertainty: none\nTarget: ${patch.targets.single}',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text(patch.canonicalArgumentsJson));
      expect(tester.takeException(), isNull);

      final VoidCallback retainedAllow = button(
        tester,
        'Allow once',
      ).onPressed!;
      final VoidCallback retainedDeny = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Deny'))
          .onPressed!;
      retainedAllow();
      final Future<void> patchResume = controller.activeRunFuture!;
      expect(controller.isAdvancing, isTrue);
      expect(controller.isRunning, isTrue);
      expect(controller.pendingApproval, same(patch));
      expect(controller.resolveApproval(patch, approved: true), isFalse);
      expect(controller.resolveApproval(patch, approved: false), isFalse);
      retainedAllow();
      retainedDeny();
      await tester.pump();
      expect(button(tester, 'Allow once').onPressed, isNull);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Deny'))
            .onPressed,
        isNull,
      );
      expect(find.text(patch.summary), findsOneWidget);
      expect(find.text(patch.canonicalArgumentsJson), findsOneWidget);
      expect(fixture.environment.replacements, hasLength(1));
      expect(fixture.environment.writeCount, 0);
      expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
      expect(model.calls, hasLength(1));

      fixture.environment.replaceGate!.complete();
      await tester.pumpAndSettle();
      await patchResume;
      final PendingToolApproval command = controller.pendingApproval!;
      expect(command, isNot(same(patch)));
      expect(run.state, RunState.waiting);
      expect(controller.isRunning, isTrue);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(fixture.environment.writeCount, 1);
      expect(fixture.environment.sourceText, 'final value = "after";\n');
      expect(fixture.environment.replacements.single, <String, Object?>{
        'environmentId': 'environment-1',
        'relativePath': _EnvironmentChannel.sourcePath,
        'expectedRevision': 'source-revision-0',
        'replacementText': 'final value = "after";\n',
      });
      expect(fixture.environment.processes, isEmpty);
      expect(model.calls, hasLength(1));
      expect(find.text(patch.summary), findsNothing);
      expect(find.text(patch.canonicalArgumentsJson), findsNothing);
      expect(find.text('Approval required'), findsOneWidget);
      expect(find.text('Run command'), findsOneWidget);
      expect(command.toolAlias, 'run_command');
      expect(command.toolId, 'dev.adele.plugin.command-tools.run-command');
      expect(command.effects, <ToolEffect>{ToolEffect.processExecution});
      expect(command.uncertainty, EffectUncertainty.uncertain);
      expect(
        command.summary,
        'Run program "git" with arguments ["diff","--check"] '
        'from Environment root with a 120-second timeout.',
      );
      expect(find.text(command.summary), findsOneWidget);
      expect(
        find.text('Effects may extend beyond the listed target.'),
        findsOneWidget,
      );
      expect(jsonDecode(command.canonicalArgumentsJson), <String, Object?>{
        ..._commandArguments,
        'workingDirectory': '',
        'timeoutSeconds': 120,
      });
      expect(find.text(command.canonicalArgumentsJson), findsNothing);
      await tester.ensureVisible(find.text('Details'));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text(command.canonicalArgumentsJson), findsOneWidget);
      expect(
        find.text(
          'Tool ID: ${command.toolId}\nEffects: processExecution\n'
          'Uncertainty: uncertain\nTarget: adele-environment:/environment-1/',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text(command.canonicalArgumentsJson));
      expect(tester.takeException(), isNull);

      // The old card's closures cannot authorize the next invocation.
      retainedAllow();
      retainedDeny();
      expect(controller.resolveApproval(patch, approved: true), isFalse);
      expect(controller.pendingApproval, same(command));
      expect(controller.activeRunFuture, isNull);
      expect(_events(run).whereType<RunInterruptionResolved>(), hasLength(1));
      await tap(tester, 'Allow once');
      final Future<void> commandResume = controller.activeRunFuture!;
      expect(controller.pendingApproval, same(command));
      expect(button(tester, 'Allow once').onPressed, isNull);
      expect(fixture.environment.processes.single, <String, Object?>{
        'environmentId': 'environment-1',
        'request': <String, Object?>{
          'program': 'git',
          'arguments': <String>['diff', '--check'],
          'relativeWorkingDirectory': '',
          'timeoutSeconds': 120,
        },
      });
      expect(model.calls, hasLength(1));
      fixture.environment.processGate!.complete();
      await tester.pumpAndSettle();
      expect(model.calls, hasLength(2));
      expect(controller.pendingApproval, same(command));
      expect(controller.isAdvancing, isTrue);
      expect(controller.activeRunFuture, same(commandResume));
      expect(button(tester, 'Allow once').onPressed, isNull);
      final List<Map<String, Object?>> outcomes = model.calls.last.outcomes;
      expect(
        outcomes.map((outcome) => (outcome['callId'], outcome['status'])),
        <(String, String)>[('patch-A', 'success'), ('command-B', 'success')],
      );
      expect(outcomes.first['content'], contains('source-revision-1'));
      expect(
        outcomes.last['content'],
        contains(_EnvironmentChannel.commandStdout),
      );
      expect(
        outcomes.last['content'],
        contains(_EnvironmentChannel.commandStderr),
      );
      expect(
        _events(run).whereType<ToolProgressObserved>().map(
          (event) => (
            event.invocationId.value,
            event.progress.kind,
            event.progress.content,
          ),
        ),
        <(String, ToolProgressKind, String)>[
          (
            'run-test-1-tool-2',
            ToolProgressKind.stdout,
            _EnvironmentChannel.commandStdout,
          ),
          (
            'run-test-1-tool-2',
            ToolProgressKind.stderr,
            _EnvironmentChannel.commandStderr,
          ),
        ],
      );
      expect(controller.snapshot.entries.single, isA<ChatUserMessage>());
      expect(find.text(_EnvironmentChannel.commandStdout), findsNothing);
      model.calls.last.output('Patched and checked.');
      model.calls.last.settle();
      await tester.pumpAndSettle();
      await commandResume;
      expect(run.state, RunState.completed);
      expect(controller.isRunning, isFalse);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.failure, isNull);
      expect(find.text('Approval required'), findsNothing);
      expect(find.text('Allow once'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      expect(find.text(command.canonicalArgumentsJson), findsNothing);
      expect(button(tester, 'Send').onPressed, isNotNull);
      expect(
        controller.snapshot.entries.map((entry) => entry.runtimeType),
        <Type>[ChatUserMessage, ChatAssistantMessage],
      );
      expect(
        controller.snapshot.entries.map((entry) => entry.content),
        <String>[
          'Patch the source, then check the diff',
          'Patched and checked.',
        ],
      );
      expect(fixture.environment.writeCount, 1);
      expect(fixture.environment.replacements, hasLength(1));
      expect(fixture.environment.processes, hasLength(1));
      expect(
        _events(run).whereType<ToolInvocationPrepared>().map(
          (event) => (
            event.invocation.id.value,
            event.invocation.proposal.providerCallId,
          ),
        ),
        <(String, String)>[
          ('run-test-1-tool-1', 'patch-A'),
          ('run-test-1-tool-2', 'command-B'),
        ],
      );
      expect(
        _events(run).whereType<RunInterruptionResolved>().map((event) {
          final resolution = event.resolution as ToolApprovalResolution;
          expect(resolution.interruptionId, event.interruption.id);
          return (resolution.toolInvocationId.value, resolution.approved);
        }),
        <(String, bool)>[
          ('run-test-1-tool-1', true),
          ('run-test-1-tool-2', true),
        ],
      );
      expect(
        _events(run).whereType<ToolExecutionStarted>().map(
          (event) => event.invocationId.value,
        ),
        <String>['run-test-1-tool-1', 'run-test-1-tool-2'],
      );
      expect(
        _events(run).whereType<ToolExecutionCompleted>().map(
          (event) => (event.invocationId.value, event.outcome.disposition),
        ),
        <(String, ToolOutcomeDisposition)>[
          ('run-test-1-tool-1', ToolOutcomeDisposition.success),
          ('run-test-1-tool-2', ToolOutcomeDisposition.success),
        ],
      );
      expect(tester.takeException(), isNull);
      await disposeApplication(tester);
    },
  );

  for (final bool command in <bool>[false, true]) {
    testWidgets(
      '${command ? 'command' : 'patch'} denial reaches the model without effects or Run failure',
      (tester) async {
        final _ModelChannel model = fixture.registerModel();
        await openChat(tester);
        final ChatController controller = chat(tester);
        await send(tester, 'Propose work for rejection');
        final AgentRun run = controller.currentRun!.run;
        model.calls.single.propose(
          'denied-1',
          command ? 'run_command' : 'apply_patch',
          command ? _commandArguments : _patchArguments,
        );
        model.calls.single.settle();
        await tester.pumpAndSettle();
        final PendingToolApproval approval = controller.pendingApproval!;
        expect(run.state, RunState.waiting);
        expect(controller.isRunning, isTrue);
        expect(controller.isAdvancing, isFalse);
        expect(controller.activeRunFuture, isNull);
        expect(find.text(approval.summary), findsOneWidget);
        expect(
          find.text('Effects may extend beyond the listed target.'),
          command ? findsOneWidget : findsNothing,
        );
        expect(button(tester, 'Allow once').onPressed, isNotNull);
        final Finder deny = find.widgetWithText(OutlinedButton, 'Deny');
        await tester.ensureVisible(deny);
        await tester.tap(deny);
        final Future<void> active = controller.activeRunFuture!;
        expect(controller.resolveApproval(approval, approved: true), isFalse);
        await tester.pumpAndSettle();
        expect(model.calls, hasLength(2));
        expect(model.calls.last.outcomes.single, <String, Object?>{
          'callId': 'denied-1',
          'status': 'rejected',
          'content': 'The user rejected this tool invocation.',
        });
        expect(run.state, RunState.running);
        expect(controller.failure, isNull);
        expect(controller.pendingApproval, same(approval));
        expect(button(tester, 'Allow once').onPressed, isNull);
        expect(tester.widget<OutlinedButton>(deny).onPressed, isNull);
        final ToolInvocationCompleted rejected = _events(
          run,
        ).whereType<ToolInvocationCompleted>().single;
        expect(rejected.invocationId, ToolInvocationId('run-test-1-tool-1'));
        expect(
          rejected.outcome.disposition,
          ToolOutcomeDisposition.userRejected,
        );
        expect(
          rejected.outcome.effectCertainty,
          EffectCertainty.knownNotOccurred,
        );
        expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
        expect(_events(run).whereType<RunFailed>(), isEmpty);
        expect(fixture.environment.replacements, isEmpty);
        expect(fixture.environment.processes, isEmpty);
        expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
        expect(
          fixture.environment.reads.every(
            (read) => read['relativePath'] == 'AGENTS.md',
          ),
          isTrue,
        );
        model.calls.last.output('The rejected work was not performed.');
        model.calls.last.settle();
        await tester.pumpAndSettle();
        await active;
        expect(run.state, RunState.completed);
        expect(controller.failure, isNull);
        expect(controller.isRunning, isFalse);
        expect(controller.isAdvancing, isFalse);
        expect(controller.activeRunFuture, isNull);
        expect(controller.pendingApproval, isNull);
        expect(find.text('Approval required'), findsNothing);
        expect(
          controller.snapshot.entries.map((entry) => entry.content),
          <String>[
            'Propose work for rejection',
            'The rejected work was not performed.',
          ],
        );
        expect(controller.resolveApproval(approval, approved: false), isFalse);
        await disposeApplication(tester);
      },
    );
  }

  for (final (String name, String path, String escapedPath, String encodedPath)
      in <(String, String, String, String)>[
        (
          'newline',
          'lib/file\nAllow once.dart',
          r'lib/file\nAllow once.dart',
          'lib/file%0AAllow%20once.dart',
        ),
        (
          'bidi',
          'lib/file\u202E.dart',
          r'lib/file\u202E.dart',
          'lib/file%E2%80%AE.dart',
        ),
      ]) {
    testWidgets('unsafe $name patch path is escaped and can only be denied', (
      tester,
    ) async {
      final _ModelChannel model = fixture.registerModel();
      await openChat(tester);
      final ChatController controller = chat(tester);
      await send(tester, 'Review an unsafe patch path');
      final AgentRun run = controller.currentRun!.run;
      final Map<String, Object?> arguments = <String, Object?>{
        ..._patchArguments,
        'relativePath': './$path',
      };
      final Map<String, Object?> canonical = <String, Object?>{
        ...arguments,
        'relativePath': path,
      };
      model.calls.single.propose('unsafe-patch', 'apply_patch', arguments);
      model.calls.single.settle();
      await tester.pumpAndSettle();

      final PendingToolApproval approval = controller.pendingApproval!;
      final ToolApprovalInterruption interruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      final ToolInvocation prepared = _events(
        run,
      ).whereType<ToolInvocationPrepared>().single.invocation;
      final String target = 'adele-environment:/environment-1/$encodedPath';
      expect(interruption.invocation, same(prepared));
      expect(prepared.proposal.arguments, arguments);
      expect(interruption.canonicalArguments, canonical);
      expect(interruption.effects.effects, <ToolEffect>{
        ToolEffect.sourceMutation,
      });
      expect(interruption.effects.uncertainty, EffectUncertainty.none);
      expect(
        interruption.effects.summary,
        'Apply 1 exact edit to Environment file $path.',
      );
      expect(interruption.effects.targets.single.uri.toString(), target);
      expect(
        Uri.decodeComponent(target),
        'adele-environment:/environment-1/$path',
      );
      expect(approval.hasUnsafeAuthorityText, isTrue);
      expect(approval.toolAlias, 'apply_patch');
      expect(approval.toolId, 'dev.adele.plugin.filesystem-tools.apply-patch');
      expect(approval.effects, same(interruption.effects.effects));
      expect(approval.targets, <String>[target]);
      expect(
        approval.summary,
        'Apply 1 exact edit to Environment file $escapedPath.',
      );
      expect(jsonDecode(approval.canonicalArgumentsJson), canonical);
      expect(
        approval.canonicalArgumentsJson,
        contains('"relativePath": "$escapedPath"'),
      );
      expect(find.text(approval.summary), findsOneWidget);
      expect(
        find.text(
          'Allow once is unavailable: tool identity, summary, or targets '
          'contain unsafe display controls or cannot be displayed reliably. '
          'Review the escaped details and choose Deny.',
        ),
        findsOneWidget,
      );
      expect(button(tester, 'Allow once').onPressed, isNull);
      final Finder deny = find.widgetWithText(OutlinedButton, 'Deny');
      expect(tester.widget<OutlinedButton>(deny).onPressed, isNotNull);

      await tester.ensureVisible(find.text('Details'));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      final String details =
          'Tool ID: dev.adele.plugin.filesystem-tools.apply-patch\n'
          'Effects: sourceMutation\nUncertainty: none\nTarget: $target';
      expect(find.text(details), findsOneWidget);
      expect(find.text(approval.canonicalArgumentsJson), findsOneWidget);
      final Finder card = find.ancestor(
        of: find.text('Approval required'),
        matching: find.byType(Card),
      );
      expect(card, findsOneWidget);
      final List<String> leaves = <String>[
        for (final SelectableText text in tester.widgetList<SelectableText>(
          find.descendant(of: card, matching: find.byType(SelectableText)),
        ))
          text.data ?? text.textSpan!.toPlainText(),
        for (final Text text in tester.widgetList<Text>(
          find.descendant(of: card, matching: find.byType(Text)),
        ))
          text.data ?? text.textSpan!.toPlainText(),
      ];
      for (final String leaf in leaves) {
        // Only exact host layout and parseable pretty JSON may contain real LF.
        final bool trustedNewlines =
            leaf == details || leaf == approval.canonicalArgumentsJson;
        expect(
          hasUnsafeApprovalControls(
            trustedNewlines ? leaf.replaceAll('\n', '') : leaf,
          ),
          isFalse,
          reason: 'Approval card must not render active untrusted controls',
        );
      }

      final ChatSessionSnapshot frozen = controller.snapshot;
      final List<ExecutionEventRecord> journal = run.journal.records;
      final List<Map<String, Object?>> reads = List.of(
        fixture.environment.reads,
      );
      expect(controller.resolveApproval(approval, approved: true), isFalse);
      await tester.pumpAndSettle();
      expect(controller.currentRun!.run, same(run));
      expect(run.state, RunState.waiting);
      expect(controller.pendingApproval, same(approval));
      expect(controller.snapshot, same(frozen));
      expect(controller.isRunning, isTrue);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(controller.failure, isNull);
      expect(run.journal.records, journal);
      expect(run.interruptions.values.single, same(interruption));
      expect(interruption.canonicalArguments, canonical);
      expect(_events(run).whereType<RunInterruptionResolved>(), isEmpty);
      expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
      expect(model.calls, hasLength(1));
      expect(fixture.environment.reads, reads);
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.processes, isEmpty);

      await tester.ensureVisible(deny);
      await tester.tap(deny);
      final Future<void> resuming = controller.activeRunFuture!;
      await tester.pumpAndSettle();
      expect(model.calls, hasLength(2));
      expect(model.calls.last.outcomes.single, <String, Object?>{
        'callId': 'unsafe-patch',
        'status': 'rejected',
        'content': 'The user rejected this tool invocation.',
      });
      final RunInterruptionResolved resolved = _events(
        run,
      ).whereType<RunInterruptionResolved>().single;
      final ToolApprovalResolution resolution =
          resolved.resolution as ToolApprovalResolution;
      expect(resolved.interruption, same(interruption));
      expect(resolution.interruptionId, interruption.id);
      expect(resolution.toolInvocationId, prepared.id);
      expect(resolution.approved, isFalse);
      final ToolInvocationCompleted rejected = _events(
        run,
      ).whereType<ToolInvocationCompleted>().single;
      expect(rejected.invocationId, prepared.id);
      expect(rejected.outcome.disposition, ToolOutcomeDisposition.userRejected);
      expect(
        rejected.outcome.effectCertainty,
        EffectCertainty.knownNotOccurred,
      );
      expect(run.state, RunState.running);
      model.calls.last.output('The unsafe patch was not performed.');
      model.calls.last.settle();
      await tester.pumpAndSettle();
      await resuming;
      expect(controller.currentRun!.run, same(run));
      expect(fixture.runIds.values, <RunId>[run.id]);
      expect(run.state, RunState.completed);
      expect(controller.pendingApproval, isNull);
      expect(controller.failure, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
      expect(_events(run).whereType<RunFailed>(), isEmpty);
      expect(
        fixture.environment.reads.map((read) => read['relativePath']),
        <String>['AGENTS.md', 'AGENTS.md'],
      );
      expect(fixture.environment.directories, isEmpty);
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.processes, isEmpty);
      expect(fixture.environment.writeCount, 0);
      expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
      expect(interruption.canonicalArguments, canonical);
      expect(
        interruption.effects.summary,
        'Apply 1 exact edit to Environment file $path.',
      );
      expect(interruption.effects.targets.single.uri.toString(), target);
      expect(find.text('Approval required'), findsNothing);
      expect(
        controller.snapshot.entries.map((entry) => entry.runtimeType),
        <Type>[ChatUserMessage, ChatAssistantMessage],
      );
      expect(
        controller.snapshot.entries.map((entry) => entry.content),
        <String>[
          'Review an unsafe patch path',
          'The unsafe patch was not performed.',
        ],
      );
      expect(
        fixture.runtime.chat.sessions
            .obtain(controller.session.id)
            .snapshot()
            .entries,
        controller.snapshot.entries,
      );
      await disposeApplication(tester);
    });
  }

  test(
    'safe patch identity permits exact control-bearing source payload',
    () async {
      final _ModelChannel model = fixture.registerModel();
      final ChatController controller = await fixture.createController();
      const String replacement =
          'line one\nline two\r\n\t\u0000\u0085\u202E\u200D\u{E0020}'
          ' caf\u00E9 e\u0301 \u{1F680} '
          r'\n\u202E';
      fixture.environment.sourceRevision = 'payload-revision-0';
      final Map<String, Object?> arguments = <String, Object?>{
        ..._patchArguments,
        'expectedRevision': fixture.environment.sourceRevision,
        'edits': <Object?>[
          <String, Object?>{'search': 'before', 'replace': replacement},
        ],
      };
      expect(controller.submit('Apply exact source text'), isTrue);
      final Future<void> starting = controller.activeRunFuture!;
      final _ModelCall proposal = await model.callAt(0);
      proposal.propose('payload-patch', 'apply_patch', arguments);
      proposal.settle();
      await starting;
      final AgentRun run = controller.currentRun!.run;
      final PendingToolApproval approval = controller.pendingApproval!;
      final ToolApprovalInterruption interruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      final Map<String, Object?> canonical = <String, Object?>{
        ...arguments,
        'relativePath': _EnvironmentChannel.sourcePath,
      };
      expect(run.state, RunState.waiting);
      expect(approval.hasUnsafeAuthorityText, isFalse);
      expect(
        approval.summary,
        'Apply 1 exact edit to Environment file lib/example.dart.',
      );
      expect(interruption.canonicalArguments, canonical);
      expect(jsonDecode(approval.canonicalArgumentsJson), canonical);
      expect(approval.canonicalArgumentsJson, contains(r'\u202E'));
      expect(approval.canonicalArgumentsJson, contains(r'\\n\\u202E'));
      expect(
        hasUnsafeApprovalControls(
          approval.canonicalArgumentsJson.replaceAll('\n', ''),
        ),
        isFalse,
      );
      expect(fixture.environment.replacements, isEmpty);
      expect(controller.resolveApproval(approval, approved: true), isTrue);
      final Future<void> resuming = controller.activeRunFuture!;
      final _ModelCall continuation = await model.callAt(1);
      final String expectedText = _EnvironmentChannel.initialText.replaceFirst(
        'before',
        replacement,
      );
      expect(fixture.environment.replacements.single, <String, Object?>{
        'environmentId': 'environment-1',
        'relativePath': _EnvironmentChannel.sourcePath,
        'expectedRevision': 'payload-revision-0',
        'replacementText': expectedText,
      });
      expect(fixture.environment.sourceText, expectedText);
      expect(fixture.environment.writeCount, 1);
      expect(interruption.canonicalArguments, canonical);
      expect(_events(run).whereType<ToolExecutionStarted>(), hasLength(1));
      expect(
        _events(
          run,
        ).whereType<ToolExecutionCompleted>().single.outcome.disposition,
        ToolOutcomeDisposition.success,
      );
      expect(continuation.outcomes.single['callId'], 'payload-patch');
      expect(continuation.outcomes.single['status'], 'success');
      continuation.output('Exact source text applied.');
      continuation.settle();
      await resuming;
      expect(controller.currentRun!.run, same(run));
      expect(run.state, RunState.completed);
      expect(controller.pendingApproval, isNull);
      expect(controller.failure, isNull);
      expect(
        controller.snapshot.entries.map((entry) => entry.content),
        <String>['Apply exact source text', 'Exact source text applied.'],
      );
      await controller.close();
    },
  );

  test(
    'bidi command argument blocks approval through its raw summary',
    () async {
      final _ModelChannel model = fixture.registerModel();
      int notifications = 0;
      final ChatController controller = await fixture.createController(
        onChanged: () => notifications++,
      );
      final Map<String, Object?> arguments = <String, Object?>{
        ..._commandArguments,
        'arguments': <String>['diff', '--check', 'file\u202E.dart'],
      };
      expect(controller.submit('Review a command'), isTrue);
      final Future<void> starting = controller.activeRunFuture!;
      final _ModelCall proposal = await model.callAt(0);
      proposal.propose('bidi-command', 'run_command', arguments);
      proposal.settle();
      await starting;
      final AgentRun run = controller.currentRun!.run;
      final PendingToolApproval approval = controller.pendingApproval!;
      final ToolApprovalInterruption interruption =
          run.interruptions.values.single as ToolApprovalInterruption;
      expect(interruption.effects.summary, contains('file\u202E.dart'));
      expect(approval.summary, contains(r'file\u202E.dart'));
      expect(hasUnsafeApprovalControls(approval.summary), isFalse);
      expect(approval.targets, <String>['adele-environment:/environment-1/']);
      expect(approval.hasUnsafeAuthorityText, isTrue);
      expect(jsonDecode(approval.canonicalArgumentsJson), <String, Object?>{
        ...arguments,
        'workingDirectory': '',
        'timeoutSeconds': 120,
      });
      final int beforeApproval = notifications;
      final List<ExecutionEventRecord> journal = run.journal.records;
      expect(controller.resolveApproval(approval, approved: true), isFalse);
      expect(notifications, beforeApproval);
      expect(controller.pendingApproval, same(approval));
      expect(controller.activeRunFuture, isNull);
      expect(controller.isAdvancing, isFalse);
      expect(run.state, RunState.waiting);
      expect(run.journal.records, journal);
      expect(fixture.environment.processes, isEmpty);
      expect(controller.resolveApproval(approval, approved: false), isTrue);
      final Future<void> resuming = controller.activeRunFuture!;
      final _ModelCall continuation = await model.callAt(1);
      expect(continuation.outcomes.single['status'], 'rejected');
      expect(
        _events(
          run,
        ).whereType<ToolInvocationCompleted>().single.outcome.disposition,
        ToolOutcomeDisposition.userRejected,
      );
      expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
      expect(fixture.environment.processes, isEmpty);
      continuation.output('Command denied.');
      continuation.settle();
      await resuming;
      expect(run.state, RunState.completed);
      expect(controller.failure, isNull);
      await controller.close();
    },
  );

  test(
    'approval cannot override a revision change while the patch is waiting',
    () async {
      final _ModelChannel model = fixture.registerModel();
      final ChatController controller = await fixture.createController();
      expect(controller.submit('Patch only the observed revision'), isTrue);
      final Future<void> starting = controller.activeRunFuture!;
      final _ModelCall proposal = await model.callAt(0);
      proposal.propose(
        'revision-guarded-patch',
        'apply_patch',
        _patchArguments,
      );
      proposal.settle();
      await starting;
      final AgentRun run = controller.currentRun!.run;
      final PendingToolApproval approval = controller.pendingApproval!;
      expect(run.state, RunState.waiting);
      expect(controller.activeRunFuture, isNull);
      expect(
        (jsonDecode(approval.canonicalArgumentsJson)
            as Map<String, Object?>)['expectedRevision'],
        fixture.environment.sourceRevision,
      );
      expect(fixture.environment.replacements, isEmpty);

      // Preserve the unique search text so only the revision guard prevents a write.
      final String externalText =
          '// External edit\n${_EnvironmentChannel.initialText}';
      fixture.environment.sourceText = externalText;
      fixture.environment.sourceRevision = 'external-revision-1';
      expect(controller.resolveApproval(approval, approved: true), isTrue);
      final Future<void> resuming = controller.activeRunFuture!;
      final _ModelCall continuation = await model.callAt(1);
      final ToolExecutionCompleted result = _events(
        run,
      ).whereType<ToolExecutionCompleted>().single;
      expect(result.invocationId, ToolInvocationId('run-test-1-tool-1'));
      expect(result.outcome.disposition, ToolOutcomeDisposition.failure);
      expect(result.outcome.failureKind, ToolFailureKind.domain);
      expect(result.outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(result.outcome.hostData['code'], environmentRevisionConflictCode);
      expect(continuation.outcomes.single, <String, Object?>{
        'callId': 'revision-guarded-patch',
        'status': 'failed',
        'content': result.outcome.modelContent,
      });
      expect(
        result.outcome.modelContent,
        contains('No stale ADELE write was performed.'),
      );
      expect(
        _events(run)
            .whereType<ToolInvocationPrepared>()
            .single
            .invocation
            .canonicalArguments['expectedRevision'],
        'source-revision-0',
      );
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.writeCount, 0);
      expect(fixture.environment.sourceText, externalText);
      expect(fixture.environment.sourceRevision, 'external-revision-1');
      expect(controller.failure, isNull);
      expect(run.state, RunState.running);
      continuation.output('The file changed; the stale patch was not applied.');
      continuation.settle();
      await resuming;
      expect(run.state, RunState.completed);
      expect(_events(run).whereType<RunFailed>(), isEmpty);
      expect(controller.failure, isNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(
        controller.snapshot.entries.map((entry) => entry.content),
        <String>[
          'Patch only the observed revision',
          'The file changed; the stale patch was not applied.',
        ],
      );
      await controller.close();
    },
  );

  test(
    'Allow once never authorizes an identical later command invocation',
    () async {
      final _ModelChannel model = fixture.registerModel();
      final ChatController controller = await fixture.createController();
      expect(controller.submit('Run the check twice'), isTrue);
      final Future<void> starting = controller.activeRunFuture!;
      final _ModelCall first = await model.callAt(0);
      first.propose('command-1', 'run_command', _commandArguments);
      first.settle();
      await starting;
      final PendingToolApproval original = controller.pendingApproval!;
      expect(controller.resolveApproval(original, approved: true), isTrue);
      final Future<void> resuming = controller.activeRunFuture!;
      final _ModelCall second = await model.callAt(1);
      expect(fixture.environment.processes, hasLength(1));
      second.propose('command-2', 'run_command', _commandArguments);
      second.settle();
      await resuming;
      final PendingToolApproval repeated = controller.pendingApproval!;
      final AgentRun run = controller.currentRun!.run;
      expect(repeated, isNot(same(original)));
      expect(repeated.canonicalArgumentsJson, original.canonicalArgumentsJson);
      expect(repeated.toolId, original.toolId);
      expect(repeated.summary, original.summary);
      expect(run.state, RunState.waiting);
      expect(controller.isRunning, isTrue);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      expect(fixture.environment.processes, hasLength(1));
      expect(controller.resolveApproval(original, approved: true), isFalse);
      expect(controller.resolveApproval(repeated, approved: false), isTrue);
      final Future<void> denying = controller.activeRunFuture!;
      final _ModelCall finalCall = await model.callAt(2);
      expect(
        finalCall.outcomes.map(
          (outcome) => (outcome['callId'], outcome['status']),
        ),
        <(String, String)>[('command-1', 'success'), ('command-2', 'rejected')],
      );
      finalCall.output('Checked once; repeat declined.');
      finalCall.settle();
      await denying;
      expect(run.state, RunState.completed);
      expect(_events(run).whereType<RunInterrupted>(), hasLength(2));
      expect(fixture.environment.processes, hasLength(1));
      expect(controller.pendingApproval, isNull);
      await controller.close();
    },
  );

  test(
    'close abandons quiescent approval without resolution or presentation changes',
    () async {
      final _ModelChannel model = fixture.registerModel();
      int notifications = 0;
      final ChatController controller = await fixture.createController(
        onChanged: () => notifications++,
      );
      expect(controller.submit('Leave this patch pending'), isTrue);
      final Future<void> starting = controller.activeRunFuture!;
      final _ModelCall call = await model.callAt(0);
      call.propose('abandoned-patch', 'apply_patch', _patchArguments);
      call.settle();
      await starting;
      final AgentRun run = controller.currentRun!.run;
      final PendingToolApproval approval = controller.pendingApproval!;
      final ChatSessionSnapshot frozen = controller.snapshot;
      final int beforeClose = notifications;
      final List<ExecutionEventRecord> journal = run.journal.records;
      expect(controller.activeRunFuture, isNull);
      final Future<void> closing = controller.close();
      expect(controller.close(), same(closing));
      expect(controller.isClosed, isTrue);
      expect(controller.resolveApproval(approval, approved: true), isFalse);
      expect(controller.resolveApproval(approval, approved: false), isFalse);
      expect(controller.submit('Closing cannot start work'), isFalse);
      await closing;
      expect(run.state, RunState.waiting);
      expect(run.journal.records, journal);
      expect(_events(run).whereType<RunInterruptionResolved>(), isEmpty);
      expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
      expect(controller.pendingApproval, same(approval));
      expect(controller.snapshot, same(frozen));
      expect(controller.failure, isNull);
      expect(controller.activeRunFuture, isNull);
      expect(notifications, beforeClose);
      expect(model.calls, hasLength(1));
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.processes, isEmpty);
      expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
    },
  );

  for (final bool nextApproval in <bool>[false, true]) {
    test(
      'close drains an accepted patch through ${nextApproval ? 'a late next approval' : 'model settlement'} without UI updates',
      () async {
        final _ModelChannel model = fixture.registerModel();
        fixture.environment.replaceGate = Completer<void>();
        int notifications = 0;
        final ChatController controller = await fixture.createController(
          onChanged: () => notifications++,
        );
        expect(controller.submit('Drain this approved patch'), isTrue);
        final Future<void> starting = controller.activeRunFuture!;
        final _ModelCall call = await model.callAt(0);
        call.propose('drained-patch', 'apply_patch', _patchArguments);
        if (nextApproval) {
          call.propose('late-command', 'run_command', _commandArguments);
        }
        call.settle();
        await starting;
        final AgentRun run = controller.currentRun!.run;
        final PendingToolApproval approval = controller.pendingApproval!;
        expect(controller.resolveApproval(approval, approved: true), isTrue);
        final Future<void> active = controller.activeRunFuture!;
        await fixture.environment.replacementStarted.future;
        final ChatSessionSnapshot frozen = controller.snapshot;
        final int beforeClose = notifications;
        bool closed = false;
        final Future<void> closing = controller.close();
        unawaited(closing.then((_) => closed = true));
        expect(controller.close(), same(closing));
        expect(controller.resolveApproval(approval, approved: false), isFalse);
        expect(controller.resolveApproval(approval, approved: true), isFalse);
        expect(controller.submit('Closing cannot submit'), isFalse);
        expect(closed, isFalse);
        expect(fixture.environment.writeCount, 0);
        expect(controller.activeRunFuture, same(active));
        fixture.environment.replaceGate!.complete();
        if (!nextApproval) {
          final _ModelCall continuation = await model.callAt(1);
          expect(closed, isFalse);
          expect(fixture.environment.writeCount, 1);
          expect(continuation.outcomes.single['status'], 'success');
          continuation.output('Late approved patch answer.');
          continuation.settle();
        }
        await active;
        await closing;
        expect(closed, isTrue);
        expect(run.state, nextApproval ? RunState.waiting : RunState.completed);
        expect(fixture.environment.writeCount, 1);
        expect(fixture.environment.replacements, hasLength(1));
        expect(fixture.environment.processes, isEmpty);
        expect(controller.pendingApproval, same(approval));
        expect(controller.snapshot, same(frozen));
        expect(controller.failure, isNull);
        expect(controller.activeRunFuture, isNull);
        expect(notifications, beforeClose);
        expect(_events(run).whereType<RunInterruptionResolved>(), hasLength(1));
        expect(_events(run).whereType<ToolExecutionStarted>(), hasLength(1));
        if (nextApproval) {
          expect(model.calls, hasLength(1));
          expect(
            (run.interruptions.values.single as ToolApprovalInterruption)
                .invocation
                .proposal
                .providerCallId,
            'late-command',
          );
          expect(controller.resolveApproval(approval, approved: true), isFalse);
        }
        final ChatSessionSnapshot canonical = fixture.runtime.chat.sessions
            .obtain(controller.session.id)
            .snapshot();
        expect(canonical.entries, hasLength(nextApproval ? 1 : 2));
        if (!nextApproval) {
          expect(canonical.entries.last.content, 'Late approved patch answer.');
        }
      },
    );
  }

  test(
    'approval retains its exact retired Environment binding, never its replacement',
    () async {
      final _ModelChannel model = fixture.registerModel();
      final ChatController controller = await fixture.createController();
      expect(controller.submit('Do not migrate this pending patch'), isTrue);
      final Future<void> starting = controller.activeRunFuture!;
      final _ModelCall call = await model.callAt(0);
      call.propose('stale-patch', 'apply_patch', _patchArguments);
      call.settle();
      await starting;
      final AgentRun run = controller.currentRun!.run;
      final PendingToolApproval approval = controller.pendingApproval!;
      await fixture.environment.registration.close();
      final _EnvironmentChannel replacement = _EnvironmentChannel();
      fixture.registerEnvironment(replacement);
      expect(controller.resolveApproval(approval, approved: true), isTrue);
      await controller.activeRunFuture!;
      final ToolInvocationCompleted result = _events(
        run,
      ).whereType<ToolInvocationCompleted>().single;
      expect(result.invocationId, ToolInvocationId('run-test-1-tool-1'));
      expect(result.outcome.disposition, ToolOutcomeDisposition.failure);
      expect(result.outcome.failureKind, ToolFailureKind.staleBinding);
      expect(result.outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
      expect(replacement.establishments, isEmpty);
      expect(replacement.reads, isEmpty);
      expect(replacement.replacements, isEmpty);
      expect(replacement.processes, isEmpty);
      // Fresh continuation context must also reject the retired materialization.
      expect(model.calls, hasLength(1));
      expect(run.state, RunState.failed);
      expect(controller.failure, isNotNull);
      expect(controller.pendingApproval, isNull);
      expect(controller.isRunning, isFalse);
      expect(controller.isAdvancing, isFalse);
      expect(controller.activeRunFuture, isNull);
      await controller.close();
    },
  );

  for (final String? modelName in <String?>[null, ' \t ']) {
    test(
      'controller without model rejects work without allocating Run IDs ($modelName)',
      () async {
        final _ModelChannel model = fixture.registerModel();
        final Session session = await fixture.createSession();
        int notifications = 0;
        final ChatController controller = ChatController(
          runtime: fixture.runtime,
          session: session,
          providerId: stockChatGptProviderId,
          model: modelName,
          runIds: fixture.runIds,
          onChanged: () => notifications++,
        );
        expect(controller.unavailableReason, contains('no model'));
        expect(controller.submit('Unavailable'), isFalse);
        expect(controller.snapshot.entries, isEmpty);
        expect(controller.currentRun, isNull);
        expect(controller.activeRunFuture, isNull);
        expect(fixture.runIds.values, isEmpty);
        expect(model.calls, isEmpty);
        final int beforeClose = notifications;
        await controller.close();
        expect(controller.submit('Still unavailable after close'), isFalse);
        expect(notifications, beforeClose);
      },
    );
  }

  for (final bool duringPreparation in <bool>[false, true]) {
    for (final bool fails in <bool>[false, true]) {
      test(
        'controller close freezes notifications during ${duringPreparation ? 'preparation' : 'streaming'} and drains ${fails ? 'failure' : 'success'}',
        () async {
          final _ModelChannel model = fixture.registerModel();
          final Session session = await fixture.createSession();
          int notifications = 0;
          final ChatController controller = ChatController(
            runtime: fixture.runtime,
            session: session,
            providerId: stockChatGptProviderId,
            model: _configuration.model,
            runIds: fixture.runIds,
            onChanged: () => notifications++,
          );
          expect(controller.submit('Accepted before close'), isTrue);
          if (!duringPreparation) await model.started.future;
          final ChatSessionSnapshot frozen = controller.snapshot;
          final execution = controller.currentRun;
          final Future<void> active = controller.activeRunFuture!;
          final int frozenNotifications = notifications;
          expect(frozenNotifications, 1);
          bool closed = false;
          final Future<void> closing = controller.close();
          unawaited(closing.then((_) => closed = true));
          expect(controller.close(), same(closing));
          expect(controller.submit('Late duplicate'), isFalse);
          expect(controller.unavailableReason, contains('closing'));
          await model.started.future;
          expect(closed, isFalse);
          expect(model.calls, hasLength(1));
          model.calls.single.output('Late canonical answer.');
          model.calls.single.settle(fails: fails);
          await closing;
          await active;
          expect(closed, isTrue);
          expect(notifications, frozenNotifications);
          expect(controller.snapshot, same(frozen));
          expect(controller.currentRun, same(execution));
          expect(controller.activeRunFuture, isNull);
          expect(controller.failure, isNull);
          expect(controller.submit('After settlement'), isFalse);
          expect(fixture.runIds.values, hasLength(1));
          final canonical = fixture.runtime.chat.sessions
              .obtain(session.id)
              .snapshot();
          expect(canonical.entries, hasLength(fails ? 1 : 2));
          if (!fails) {
            expect(canonical.entries.last.content, 'Late canonical answer.');
          }
        },
      );
    }
  }
}

final class _Fixture {
  _Fixture() {
    runtime = AdeleRuntime(ids: ids);
    _selector = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.chat-project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Open Chat Test Project...',
        selectProject: () async => Uri.parse('file:///chat-test/source/'),
      ),
    );
    registerEnvironment(environment);
  }

  final _ProductIds ids = _ProductIds();
  final _RunIds runIds = _RunIds();
  final _EnvironmentChannel environment = _EnvironmentChannel();
  final List<_EnvironmentChannel> environments = <_EnvironmentChannel>[];
  final List<_ModelChannel> models = <_ModelChannel>[];
  late final AdeleRuntime runtime;
  late final ExtensionRegistration _selector;
  int runtimeCreations = 0;
  int bootstraps = 0;
  int configurationReads = 0;
  bool _closed = false;

  void registerEnvironment(_EnvironmentChannel channel) {
    channel.registration = runtime.registry.register(
      provider: ProviderDescriptor(
        id: ProviderId('dev.adele.test.chat-environment'),
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.test.chat-environment-plugin',
        displayName: 'Chat Test Environment',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: channel,
        serviceId: environmentProviderServiceId,
        isAvailable: () => true,
      ),
    );
    environments.add(channel);
  }

  AdeleApplication application({
    StockChatGptConfiguration? configuration = _configuration,
  }) => AdeleApplication(
    createRuntime: () {
      runtimeCreations++;
      return runtime;
    },
    bootstrapPlugins: (plugins) async {
      expect(plugins, same(runtime.plugins));
      bootstraps++;
    },
    readChatGptConfiguration: () {
      configurationReads++;
      return configuration;
    },
    runIds: runIds,
  );

  _ModelChannel registerModel({ProviderId? providerId, int rank = 0}) {
    final _ModelChannel model = _ModelChannel();
    model.registration = runtime.registry.register(
      provider: ProviderDescriptor(
        id: providerId ?? stockChatGptProviderId,
        capability: modelProviderCapability,
        pluginId: 'dev.adele.test.chat-model-plugin',
        displayName: 'Chat Test Model',
        serviceId: modelProviderServiceId,
        rank: rank,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: model,
        serviceId: modelProviderServiceId,
        isAvailable: () => true,
      ),
    );
    models.add(model);
    return model;
  }

  Future<Session> createSession() async {
    final Project project = runtime.lifecycle.createProject(
      Uri.parse('file:///chat-test/source/'),
    );
    final TaskCreationResult task = await runtime.lifecycle.createTask(
      projectId: project.id,
      title: 'Controller test',
    );
    return runtime.lifecycle.createSession(
      taskId: task.task.id,
      strategyId: chatStrategyId,
    );
  }

  Future<ChatController> createController({VoidCallback? onChanged}) async =>
      ChatController(
        runtime: runtime,
        session: await createSession(),
        providerId: stockChatGptProviderId,
        model: _configuration.model,
        runIds: runIds,
        onChanged: onChanged,
      );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final environment in environments) {
      for (final gate in <Completer<void>?>[
        environment.readGate,
        environment.replaceGate,
        environment.processGate,
      ]) {
        if (gate != null && !gate.isCompleted) gate.complete();
      }
    }
    for (final model in models) {
      for (final call in model.calls) {
        unawaited(call.events.close());
      }
      await model.registration.close();
    }
    for (final environment in environments) {
      await environment.registration.close();
    }
    await _selector.close();
    await runtime.close();
  }
}

final class _ProductIds implements ProductIdSource {
  final List<String> calls = <String>[];

  String _next(String kind) {
    calls.add(kind);
    return '$kind-${calls.where((call) => call == kind).length}';
  }

  @override
  ProjectId nextProjectId() => ProjectId(_next('project'));
  @override
  TaskId nextTaskId() => TaskId(_next('task'));
  @override
  EnvironmentId nextEnvironmentId() => EnvironmentId(_next('environment'));
  @override
  SessionId nextSessionId() => SessionId(_next('session'));
}

final class _RunIds implements RunIdSource {
  final List<RunId> values = <RunId>[];

  @override
  RunId nextRunId() {
    final RunId id = RunId('run-test-${values.length + 1}');
    values.add(id);
    return id;
  }
}

final class _EnvironmentChannel implements AdeleStreamChannel {
  static const String instructions = 'Use the deterministic Chat fixture only.';
  static const String sourcePath = 'lib/example.dart';
  static const String initialText = 'final value = "before";\n';
  static const String commandStdout = 'Checked the approved source.\n';
  static const String commandStderr = 'Fixture diagnostic.\n';
  late final CapabilityRegistration registration;
  final List<Map<String, Object?>> establishments = <Map<String, Object?>>[];
  final List<Map<String, Object?>> reads = <Map<String, Object?>>[];
  final List<Map<String, Object?>> directories = <Map<String, Object?>>[];
  final List<Map<String, Object?>> replacements = <Map<String, Object?>>[];
  final List<Map<String, Object?>> processes = <Map<String, Object?>>[];
  final Completer<void> replacementStarted = Completer<void>();
  Completer<void>? readGate;
  Completer<void>? replaceGate;
  Completer<void>? processGate;
  String sourceText = initialText;
  String sourceRevision = 'source-revision-0';
  int writeCount = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == environmentProviderServiceEstablishId) {
      establishments.add(payload);
      return <String, Object?>{
        'providerState': <String, Object?>{'fixture': 'chat-session'},
      };
    }
    expectSync(payload['environmentId'], 'environment-1');
    switch (method) {
      case environmentProviderServiceReadFileId:
        final String path = payload['relativePath']! as String;
        expectSync(path, isIn(<String>['AGENTS.md', sourcePath]));
        reads.add(payload);
        await readGate?.future;
        final String text = path == 'AGENTS.md' ? instructions : sourceText;
        return <String, Object?>{
          'relativePath': path,
          'text': text,
          'sizeBytes': utf8.encode(text).length,
          'revision': path == 'AGENTS.md'
              ? 'agents-test-revision'
              : sourceRevision,
        };
      case environmentProviderServiceReadDirectoryId:
        expectSync(payload['relativePath'], 'lib');
        directories.add(payload);
        return <String, Object?>{
          'relativePath': 'lib',
          'entries': <Object?>[
            <String, Object?>{
              'kind': 'file',
              'name': 'example.dart',
              'relativePath': sourcePath,
            },
          ],
        };
      case environmentProviderServiceReplaceExistingTextFileId:
        expectSync(payload['relativePath'], sourcePath);
        expectSync(payload['expectedRevision'], sourceRevision);
        replacements.add(payload);
        if (!replacementStarted.isCompleted) replacementStarted.complete();
        await replaceGate?.future;
        sourceText = payload['replacementText']! as String;
        writeCount++;
        sourceRevision = 'source-revision-$writeCount';
        return <String, Object?>{'revision': sourceRevision};
      default:
        throw StateError('Unexpected Environment request: $method');
    }
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    expectSync(method, environmentProviderServiceRunForegroundProcessId);
    expectSync(payload['environmentId'], 'environment-1');
    processes.add(payload);
    final StreamController<Object?> events = StreamController<Object?>(
      // Keep cancellation settlement in this test's async zone.
      onCancel: () async {},
    );
    unawaited(() async {
      await processGate?.future;
      for (final (String stream, String text) in <(String, String)>[
        ('stdout', commandStdout),
        ('stderr', commandStderr),
      ]) {
        events.add(<String, Object?>{
          'kind': 'output',
          'output': <String, Object?>{'stream': stream, 'text': text},
          'completed': null,
        });
      }
      events.add(<String, Object?>{
        'kind': 'completed',
        'output': null,
        'completed': <String, Object?>{
          'termination': 'exited',
          'exitCode': 0,
          'stdoutTruncated': false,
          'stderrTruncated': false,
        },
      });
      await events.close();
    }());
    return events.stream;
  }
}

final class _ModelChannel implements AdeleStreamChannel {
  final List<_ModelCall> calls = <_ModelCall>[];
  final Completer<void> started = Completer<void>();
  Completer<void> _changed = Completer<void>();
  late final CapabilityRegistration registration;

  Future<_ModelCall> callAt(int index) async {
    while (calls.length <= index) {
      await _changed.future;
    }
    return calls[index];
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw StateError('Chat must use generated streaming model transport.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    expectSync(method, modelProviderServiceInvokeId);
    expectSync(payload.keys, <String>['request']);
    final _ModelCall call = _ModelCall(
      payload['request']! as Map<String, Object?>,
    );
    calls.add(call);
    _changed.complete();
    _changed = Completer<void>();
    if (!started.isCompleted) started.complete();
    return call.events.stream;
  }
}

final class _ModelCall {
  _ModelCall(this.request);

  final Map<String, Object?> request;
  final StreamController<Object?> events = StreamController<Object?>();

  List<Map<String, Object?>> get outcomes => <Map<String, Object?>>[
    for (final item
        in (request['input']! as List<Object?>).cast<Map<String, Object?>>())
      if (item['kind'] == 'toolOutcome')
        item['toolOutcome']! as Map<String, Object?>,
  ];

  List<(String, String)> get messages => <(String, String)>[
    for (final item in request['input']! as List<Object?>)
      (() {
        final input = item! as Map<String, Object?>;
        expect(input['kind'], 'message');
        final message = input['message']! as Map<String, Object?>;
        final content =
            (message['content']! as List<Object?>).single!
                as Map<String, Object?>;
        return (message['role']! as String, content['text']! as String);
      })(),
  ];

  // Generated value codecs are library-private; retain only the tested shapes.
  void propose(String callId, String alias, Map<String, Object?> arguments) =>
      events.add(<String, Object?>{
        'kind': 'output',
        'observation': null,
        'output': <String, Object?>{
          'kind': 'toolProposal',
          'text': null,
          'toolProposal': <String, Object?>{
            'callId': callId,
            'name': alias,
            'arguments': arguments,
          },
          'itemId': callId,
          'nativeMetadata': null,
        },
        'terminal': null,
      });

  void output(String text) => events.add(<String, Object?>{
    'kind': 'output',
    'observation': null,
    'output': <String, Object?>{
      'kind': 'text',
      'text': text,
      'toolProposal': null,
      'itemId': 'answer',
      'nativeMetadata': null,
    },
    'terminal': null,
  });

  void settle({bool fails = false}) => events.add(<String, Object?>{
    'kind': 'terminal',
    'observation': null,
    'output': null,
    'terminal': <String, Object?>{
      'settlement': fails ? 'failed' : 'completed',
      'incompleteReason': null,
      'failure': fails
          ? <String, Object?>{
              'kind': 'rateLimited',
              'providerCode': '429',
              'providerMessage': 'Deterministic model failure.',
              'providerDetails': <String, Object?>{},
            }
          : null,
      'providerStopReason': fails ? 'error' : 'stop',
      'usage': null,
      'effectiveModel': 'gpt-6-astra',
      'responseId': 'test-response',
      'requestId': 'test-request',
      'nativeState': null,
    },
  });
}
