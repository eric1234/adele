import 'dart:async';
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
    for (final bool fails in <bool>[false, true]) {
      testWidgets(
        '${exit ? 'exit' : 'disposal'} freezes Chat and drains Run ${fails ? 'failure' : 'success'} before runtime close',
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
          model.calls.single.settle(fails: fails);
          await tester.pumpAndSettle();
          await active;
          if (exiting != null) expect(await exiting, AppExitResponse.exit);
          expect(run.state, fails ? RunState.failed : RunState.completed);
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
          expect(canonical, hasLength(fails ? 1 : 2));
          if (!fails) expect(canonical.last.content, 'Late answer.');
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
          expect(controller.activeRunFuture, same(active));
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
    _environmentRegistration = runtime.registry.register(
      provider: ProviderDescriptor(
        id: ProviderId('dev.adele.test.chat-environment'),
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.test.chat-environment-plugin',
        displayName: 'Chat Test Environment',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: environment,
        serviceId: environmentProviderServiceId,
        isAvailable: () => true,
      ),
    );
  }

  final _ProductIds ids = _ProductIds();
  final _RunIds runIds = _RunIds();
  final _EnvironmentChannel environment = _EnvironmentChannel();
  final List<_ModelChannel> models = <_ModelChannel>[];
  late final AdeleRuntime runtime;
  late final ExtensionRegistration _selector;
  late final CapabilityRegistration _environmentRegistration;
  int runtimeCreations = 0;
  int bootstraps = 0;
  int configurationReads = 0;
  bool _closed = false;

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

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (environment.readGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    for (final model in models) {
      for (final call in model.calls) {
        unawaited(call.events.close());
      }
      await model.registration.close();
    }
    await _environmentRegistration.close();
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

final class _EnvironmentChannel implements AdeleRequestChannel {
  static const String instructions = 'Use the deterministic Chat fixture only.';
  final List<Map<String, Object?>> establishments = <Map<String, Object?>>[];
  final List<Map<String, Object?>> reads = <Map<String, Object?>>[];
  Completer<void>? readGate;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == environmentProviderServiceEstablishId) {
      establishments.add(payload);
      return <String, Object?>{
        'providerState': <String, Object?>{'fixture': 'chat-session'},
      };
    }
    expectSync(method, environmentProviderServiceReadFileId);
    expectSync(payload['relativePath'], 'AGENTS.md');
    reads.add(payload);
    await readGate?.future;
    return <String, Object?>{
      'relativePath': 'AGENTS.md',
      'text': instructions,
      'sizeBytes': instructions.length,
      'revision': 'agents-test-revision',
    };
  }
}

final class _ModelChannel implements AdeleStreamChannel {
  final List<_ModelCall> calls = <_ModelCall>[];
  final Completer<void> started = Completer<void>();
  late final CapabilityRegistration registration;

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
    if (!started.isCompleted) started.complete();
    return call.events.stream;
  }
}

final class _ModelCall {
  _ModelCall(this.request);

  final Map<String, Object?> request;
  final StreamController<Object?> events = StreamController<Object?>();

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

  // Generated value codecs are library-private; keep only these two wire shapes.
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
