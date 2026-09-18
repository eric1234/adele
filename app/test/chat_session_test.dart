import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/run_id_source.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/plugins/chat_frontend_bridge.dart';
import 'package:adele_desktop/plugins/stock_chat_execution_status.dart';
import 'package:adele_desktop/plugins/stock_chat_frontend.dart';
import 'package:adele_desktop/plugins/temporary_chatgpt_selection.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/chat/chat_controller.dart';
import 'package:adele_desktop/ui/execution/approval_display.dart';
import 'package:adele_desktop/ui/execution/pending_tool_approval.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/activity_output_presentation.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/inspection_display.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart' show $Value;
import 'package:dart_eval/stdlib/core.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_eval/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_contract/openai_contract.dart'
    show openAiReasoningSummaryPresentationKind;
import 'package:plugin_runtime/plugin_runtime.dart';

import '../tool/chat_frontend_compiler.dart';
import '../tool/tool_inspection_frontend_compiler.dart';
import 'support/prepared_frontend_installations.dart';

late File _frontendArtifact;
late File _filesystemFrontendArtifact;
late Directory _frontendInstallations;

const StockChatGptConfiguration _configuration = StockChatGptConfiguration(
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

  setUpAll(() async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'adele-chat-presentation-',
    );
    addTearDown(() => directory.delete(recursive: true));
    _frontendArtifact = File('${directory.path}/chat.evc');
    await compileChatFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: _frontendArtifact,
    );
    _filesystemFrontendArtifact = File('${directory.path}/filesystem.evc');
    await compileToolInspectionFrontend(
      repositoryRoot: Directory.current.parent,
      artifact: _filesystemFrontendArtifact,
      frontend: ToolInspectionFrontend.filesystem,
    );
    _frontendInstallations = await prepareFrontendInstallations(
      root: Directory('${directory.path}/installed'),
      artifacts: {'dev.adele.plugin.chat-strategy': _frontendArtifact},
    );
  });

  setUp(() {
    fixture = _Fixture();
    addTearDown(fixture.close);
  });

  AdeleShell shell(WidgetTester tester) =>
      tester.widget<AdeleShell>(find.byType(AdeleShell));

  ChatController chat(WidgetTester tester) => tester
      .widget<StockChatExecutionStatus>(find.byType(StockChatExecutionStatus))
      .controller;

  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );

  VoidCallback? action(WidgetTester tester, String label) =>
      button(label).evaluate().isEmpty
      ? null
      : tester.widget<ButtonStyleButton>(button(label)).onPressed;

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.ensureVisible(button(label));
    await tester.tap(button(label));
    await tester.pumpAndSettle();
  }

  Future<void> openTask(
    WidgetTester tester, {
    StockChatGptConfiguration? configuration = _configuration,
    String? installationRoot,
  }) async {
    // Start file IO in real async; frame settling cannot await activation.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        fixture.application(
          configuration: configuration,
          installationRoot: installationRoot,
        ),
      );
      if (fixture.runtime.plugins.state != ApplicationPluginState.ready) {
        await fixture.runtime.plugins.changes
            .firstWhere((state) => state == ApplicationPluginState.ready)
            .timeout(const Duration(seconds: 10));
      }
      expect(fixture.runtime.plugins.host, isNull);
      expect(fixture.runtime.plugins.backends, isEmpty);
      if (installationRoot == null) {
        bool activated() => fixture.runtime.extensions
            .discover(sessionPresentationContributions)
            .isNotEmpty;
        if (!activated()) {
          await fixture.runtime.extensions.changes
              .firstWhere((_) => activated())
              .timeout(const Duration(seconds: 10));
        }
      }
    });
    await tester.pumpAndSettle();
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
    expect(find.byType(SessionPresentationHost), findsOneWidget);
    expect(find.text('Ask ADELE...'), findsOneWidget);
  }

  Future<void> send(WidgetTester tester, String prompt) async {
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), prompt);
    await tap(tester, 'Send');
  }

  Future<void> disposeApplication(WidgetTester tester) async {
    // Startup owns real-async catalog I/O; shutdown must drain that same future.
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.runtime.close();
      await fixture.close();
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  ExtensionRegistration registerNativePresentation({
    String id = 'dev.example.native-presentation',
    String presentationKind = 'dev.example.safe',
    Widget Function(ModelNativePresentation)? createInspection,
  }) => fixture.runtime.extensions.register(
    point: modelNativeActivityPresentationContributions,
    id: ExtensionId(id),
    value: ModelNativeActivityPresentationContribution(
      presentationKind: presentationKind,
      createInspection:
          createInspection ??
          (presentation) => Text('Detail: ${presentation.data['text']}'),
    ),
  );

  testWidgets(
    'native groups exist without frontend and activation leaves retained groups and history unchanged',
    (tester) async {
      final model = fixture.registerModel();
      await openChat(tester);
      final controller = chat(tester);
      for (final prompt in ['First', 'Follow-up']) {
        await send(tester, prompt);
        model.calls.last.native('$prompt reasoning');
        model.calls.last.output('$prompt canonical answer.');
        model.calls.last.settle();
        await tester.pumpAndSettle();
      }
      final groups = controller.timeline
          .whereType<ChatActivitySummary>()
          .toList();
      expect(groups.map((group) => group.content), [
        'First reasoning',
        'Follow-up reasoning',
      ]);
      final history = controller.snapshot;
      final evidence = controller.activitySnapshots;
      final run = controller.currentRun!.run;
      final journal = run.journal.records;
      final registration = registerNativePresentation();
      addTearDown(registration.close);
      await tester.pumpAndSettle();
      expect(controller.timeline.whereType<ChatActivitySummary>(), groups);
      expect(
        groups.map((group) => group.runId),
        evidence.map((activity) => activity.runId),
      );
      expect(controller.snapshot, same(history));
      expect(history.entries.map((entry) => entry.content), [
        'First',
        'First canonical answer.',
        'Follow-up',
        'Follow-up canonical answer.',
      ]);
      for (final activity in evidence) {
        expect(controller.activityForRun(activity.runId), same(activity));
        final native = activity.models.single.outputs
            .map((output) => output.item)
            .whereType<ModelNativeOutput>()
            .single;
        expect(native.presentation!.data, {
          'text': native.presentation!.compactText,
        });
        expect(native.providerNativeMetadata.data, {
          'approvedText': 'Raw text is not approved for display',
          'private': 'opaque-secret-data',
        });
        expect(native.providerNativeMetadata.compatibility, {
          'private': 'opaque-secret-compatibility',
        });
      }
      expect(run.journal.records, journal);
      expect(find.text('First reasoning'), findsOneWidget);
      expect(find.text('Follow-up reasoning'), findsOneWidget);
      expect(groups.every((entry) => !entry.isGroup), isTrue);
      expect(groups.map((entry) => entry.activityCount), [1, 1]);
      await tap(tester, 'First reasoning');
      final inspection = tester.widget<InspectionHost>(
        find.byType(InspectionHost),
      );
      expect(inspection.card.target.runId, groups.first.runId);
      expect(
        inspection.card.target.modelInvocationId,
        groups.first.invocationId,
      );
      expect(
        (inspection.card.target as ModelOutputInspectionTarget).outputSequence,
        groups.first.outputSequence,
      );
      expect(find.text('Detail: First reasoning'), findsOneWidget);
      expect(controller.snapshot, same(history));
      expect(model.calls, hasLength(2));
      expect(fixture.runIds.values, hasLength(2));
      await disposeApplication(tester);
    },
  );

  for (final mode in ['ambiguous', 'failed', 'missing']) {
    testWidgets(
      '$mode frontend registration and retirement cannot alter safe Chat groups or notify observers',
      (tester) async {
        final model = fixture.registerModel();
        int factories = 0;
        int chatNotifications = 0;
        int activityNotifications = 0;
        final contribution = ModelNativeActivityPresentationContribution(
          presentationKind: 'dev.example.safe',
          createInspection: (_) {
            factories++;
            if (mode == 'failed') throw _OpaquePresentationFailure();
            return const Text('Rich detail');
          },
        );
        ExtensionRegistration activate() => fixture.runtime.extensions.register(
          point: modelNativeActivityPresentationContributions,
          id: ExtensionId('dev.example.presenter'),
          value: contribution,
        );
        final registration = mode == 'missing' ? null : activate();
        if (registration != null) addTearDown(registration.close);
        final duplicate = mode == 'ambiguous'
            ? registerNativePresentation(id: 'dev.example.duplicate')
            : null;
        if (duplicate != null) addTearDown(duplicate.close);
        final controller = await fixture.createController(
          onChanged: () => chatNotifications++,
          onActivityChanged: () => activityNotifications++,
        );
        expect(controller.submit('Retain safe reasoning'), isTrue);
        final running = controller.activeRunFuture!;
        final call = await model.callAt(0);
        call.native('Native evidence');
        call.output('Canonical answer.');
        call.settle();
        await running;
        await tester.pumpAndSettle();
        final history = controller.snapshot;
        final activity = controller.activitySnapshots.single;
        final run = controller.currentRun!.run;
        final journal = run.journal.records;
        final before = (chatNotifications, activityNotifications);
        final summary = controller.timeline
            .whereType<ChatActivitySummary>()
            .single;
        expect(summary.content, 'Native evidence');
        expect(factories, 0);

        final unrelated = registerNativePresentation(
          id: 'dev.example.unrelated',
          presentationKind: 'dev.example.other',
          createInspection: (_) =>
              throw StateError('Unrelated kind must not run.'),
        );
        final otherPoint = fixture.runtime.extensions.register(
          point: toolActivityInspectionContributions,
          id: ExtensionId('dev.example.other-point'),
          value: ToolActivityInspectionContribution(
            toolId: ToolId('dev.example.other'),
            createPresentation: (_) => const SizedBox.shrink(),
          ),
        );
        await tester.pumpAndSettle();
        await unrelated.close();
        await otherPoint.close();
        await tester.pumpAndSettle();
        expect(
          controller.timeline.whereType<ChatActivitySummary>().single,
          same(summary),
        );
        expect(factories, 0);
        expect((chatNotifications, activityNotifications), before);

        await duplicate?.close();
        await registration?.close();
        final replacement = activate();
        addTearDown(replacement.close);
        await tester.pumpAndSettle();
        expect(
          controller.timeline.whereType<ChatActivitySummary>().single,
          same(summary),
        );
        expect(summary.runId, activity.runId);
        expect(summary.invocationId, activity.models.single.id);
        expect(factories, 0);
        expect((chatNotifications, activityNotifications), before);
        expect(controller.snapshot, same(history));
        expect(controller.activityForRun(activity.runId), same(activity));
        expect(run.journal.records, journal);
        expect(controller.failure, isNull);

        final addedAmbiguity = registerNativePresentation(
          id: 'dev.example.new-ambiguity',
        );
        await tester.pumpAndSettle();
        await addedAmbiguity.close();
        await tester.pumpAndSettle();
        expect(
          controller.activitySummary(summary.runId, summary.invocationId),
          same(summary),
        );
        expect(factories, 0);
        expect((chatNotifications, activityNotifications), before);
        expect(model.calls, hasLength(1));
        await controller.close();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'corrupt native EVC and retirement leave safe Chat activity intact',
    (tester) async {
      final model = fixture.registerModel();
      await openChat(tester);
      final controller = chat(tester);
      final corrupt = File(
        '${_frontendArtifact.parent.path}/corrupt-native.evc',
      );
      final activation = (await tester.runAsync(() async {
        await corrupt.writeAsBytes([1, 2, 3]);
        final root = await prepareFrontendInstallations(
          root: Directory('${corrupt.parent.path}/corrupt-native-installed'),
          artifacts: {'dev.adele.openai': corrupt},
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        final bootstrap = ApplicationFrontendBootstrap(
          extensions: fixture.runtime.extensions,
        );
        await bootstrap.start(catalog);
        expect(
          bootstrap.generations.single.state,
          InstalledFrontendState.active,
        );
        return bootstrap;
      }))!;
      addTearDown(() => tester.runAsync(activation.close));
      await send(tester, 'Safe evidence despite corrupt UI');
      model.calls.single.native(
        'Retained safe summary',
        presentationKind: openAiReasoningSummaryPresentationKind,
        data: const {
          'summaryParts': ['Retained safe summary'],
          'truncated': false,
        },
      );
      model.calls.single.output('Canonical answer.');
      model.calls.single.settle();
      await tester.pumpAndSettle();
      final group = controller.timeline.whereType<ChatActivitySummary>().single;
      final history = controller.snapshot;
      final evidence = controller.activitySnapshots.single;
      final slot = find.descendant(
        of: find.byType(SessionPresentationHost),
        matching: find.byType(ActivityOutputPresentation),
      );
      final button = find.ancestor(of: slot, matching: find.byType(TextButton));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Frontend unavailable.'), findsWidgets);
      expect(
        controller.activitySummary(group.runId, group.invocationId),
        same(group),
      );
      await tester.runAsync(activation.close);
      await tester.pumpAndSettle();
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      expect(
        controller.activitySummary(group.runId, group.invocationId),
        same(group),
      );
      expect(controller.snapshot, same(history));
      expect(controller.activityForRun(group.runId), same(evidence));
      expect(controller.failure, isNull);
      expect(model.calls, hasLength(1));
      await disposeApplication(tester);
    },
  );

  for (final queued in [true, false]) {
    testWidgets(
      'closed Chat ignores ${queued ? 'queued' : 'later'} frontend activation',
      (tester) async {
        final model = fixture.registerModel();
        int factories = 0;
        int notifications = 0;
        final controller = await fixture.createController(
          onChanged: () => notifications++,
          onActivityChanged: () => notifications++,
        );
        expect(controller.submit('Close before presentation'), isTrue);
        final running = controller.activeRunFuture!;
        final call = await model.callAt(0);
        call.native('Retained native');
        call.output('Canonical final.');
        call.settle();
        await running;
        await tester.pumpAndSettle();
        final history = controller.snapshot;
        final before = notifications;
        ExtensionRegistration activate() => registerNativePresentation(
          createInspection: (_) {
            factories++;
            return const Text('Must not create after close');
          },
        );
        final registration = queued ? activate() : null;
        await controller.close();
        final active = registration ?? activate();
        await tester.pumpAndSettle();
        await active.close();
        final replacement = activate();
        addTearDown(replacement.close);
        await tester.pumpAndSettle();
        expect(factories, 0);
        expect(notifications, before);
        expect(controller.snapshot, same(history));
        expect(
          controller.timeline.whereType<ChatActivitySummary>().single.content,
          'Retained native',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('frontend registration never invokes failing Chat observers', (
    tester,
  ) async {
    final model = fixture.registerModel();
    bool failObservers = false;
    int chatNotifications = 0;
    final failures = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = failures.add;
    addTearDown(() => FlutterError.onError = previous);
    final controller = await fixture.createController(
      onChanged: () {
        chatNotifications++;
        if (failObservers) throw StateError('Chat observer failure');
      },
      onActivityChanged: () {
        if (failObservers) throw StateError('Inspection observer failure');
      },
    );
    expect(controller.submit('Recover despite observers'), isTrue);
    final running = controller.activeRunFuture!;
    final call = await model.callAt(0);
    call.native('Recovered');
    call.output('Canonical answer.');
    call.settle();
    await running;
    await tester.pumpAndSettle();
    final history = controller.snapshot;
    final before = chatNotifications;
    failObservers = true;
    final registration = registerNativePresentation();
    addTearDown(registration.close);
    await tester.pumpAndSettle();
    expect(
      controller.timeline.whereType<ChatActivitySummary>().single.content,
      'Recovered',
    );
    expect(controller.snapshot, same(history));
    expect(controller.failure, isNull);
    expect(chatNotifications, before);
    expect(failures, isEmpty);
    await controller.close();
    FlutterError.onError = previous;
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reasoning-only activity keeps final text canonical and survives presenter retirement and follow-up',
    (tester) async {
      final model = fixture.registerModel();
      final presenter = registerNativePresentation();
      addTearDown(presenter.close);
      await openChat(tester);
      final controller = chat(tester);
      await send(tester, 'Think without tools');
      model.calls.single.native('Approved reasoning summary');
      model.calls.single.output('Canonical final answer.');
      await tester.pumpAndSettle();
      expect(controller.timeline.whereType<ChatActivitySummary>(), isEmpty);
      expect(controller.snapshot.entries, hasLength(1));
      model.calls.single.settle();
      await tester.pumpAndSettle();
      expect(controller.failure, isNull);
      final group = controller.timeline.whereType<ChatActivitySummary>().single;
      expect(group.content, 'Approved reasoning summary');
      expect(controller.timeline.map((entry) => entry.content), [
        'Think without tools',
        'Approved reasoning summary',
        'Canonical final answer.',
      ]);
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        'Think without tools',
        'Canonical final answer.',
      ]);
      final execution = controller.currentRun!;
      final evidence = controller.activityForRun(group.runId)!;
      final journal = execution.run.journal.records;
      final history = controller.snapshot;
      expect(evidence.tools, isEmpty);
      final retained = action(tester, group.content)!;
      await tap(tester, group.content);
      expect(find.text('Detail: Approved reasoning summary'), findsOneWidget);
      final inspection = tester.widget<InspectionHost>(
        find.byType(InspectionHost),
      );
      expect(inspection.heading, group.content);
      expect(inspection.card.target.runId, group.runId);
      expect(inspection.card.target.modelInvocationId, group.invocationId);
      expect(
        (inspection.card.target as ModelOutputInspectionTarget).outputSequence,
        group.outputSequence,
      );
      await presenter.close();
      await tester.pumpAndSettle();
      expect(find.text('Detail: Approved reasoning summary'), findsNothing);
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      expect(find.byType(InspectionHost), findsOneWidget);
      expect(
        controller.activitySummary(group.runId, group.invocationId),
        same(group),
      );
      expect(controller.snapshot, same(history));
      expect(execution.run.journal.records, journal);
      await tester.ensureVisible(find.byTooltip('Dismiss Inspection'));
      await tester.tap(find.byTooltip('Dismiss Inspection'));
      await tester.pumpAndSettle();
      retained();
      await tester.pumpAndSettle();
      expect(find.byType(InspectionHost), findsOneWidget);
      final replacement = registerNativePresentation(
        createInspection: (presentation) {
          expect(presentation.compactText, 'Approved reasoning summary');
          expect(presentation.data, {'text': 'Approved reasoning summary'});
          return const Text('Detail: Replacement detail');
        },
      );
      addTearDown(replacement.close);
      await tester.pumpAndSettle();
      expect(find.text('Detail: Replacement detail'), findsOneWidget);
      expect(
        controller.activitySummary(group.runId, group.invocationId),
        same(group),
      );
      await send(tester, 'Follow up');
      expect(controller.activityForRun(group.runId), same(evidence));
      expect(model.calls.last.messages, [
        ('user', 'Think without tools'),
        ('assistant', 'Canonical final answer.'),
        ('user', 'Follow up'),
      ]);
      model.calls.last.output('Follow-up final.');
      model.calls.last.settle();
      await tester.pumpAndSettle();
      expect(
        controller.timeline.whereType<ChatActivitySummary>().single,
        same(group),
      );
      expect(
        controller.activitySummary(group.runId, ModelInvocationId('unknown')),
        isNull,
      );
      expect(
        controller.activitySummary(RunId('unknown'), group.invocationId),
        isNull,
      );
      expect(find.textContaining('opaque-secret'), findsNothing);
      expect(fixture.environment.processes, isEmpty);
      await disposeApplication(tester);
      retained();
      await tester.pumpAndSettle();
      expect(find.byType(InspectionHost), findsNothing);
      expect(
        controller.activitySummary(group.runId, group.invocationId),
        isNull,
      );
      expect(model.calls, hasLength(2));
      expect(execution.run.journal.records, journal);
      expect(tester.takeException(), isNull);
    },
  );

  for (final narrated in [true, false]) {
    test(
      'native compact precedes tool count but ${narrated ? 'not narration' : 'uses the first safe output'}',
      () async {
        final model = fixture.registerModel();
        final controller = await fixture.createController();
        addTearDown(controller.close);
        expect(controller.submit('Inspect with native activity'), isTrue);
        final running = controller.activeRunFuture!;
        final first = await model.callAt(0);
        first.native(null);
        first.native('First compact');
        first.native('Second compact');
        if (narrated) first.output('Preferred tool narration.');
        first.propose('read', 'read_file', {
          'relativePath': _EnvironmentChannel.sourcePath,
        });
        first.settle();
        final continuation = await model.callAt(1);
        continuation.output('Canonical result.');
        continuation.settle();
        await running;
        expect(controller.failure, isNull);
        expect(
          controller.timeline.whereType<ChatActivitySummary>().single.content,
          narrated ? 'Preferred tool narration.' : 'First compact',
        );
        expect(controller.snapshot.entries.map((entry) => entry.content), [
          'Inspect with native activity',
          'Canonical result.',
        ]);
        expect(controller.activitySnapshots.single.tools, hasLength(1));
        final summary = controller.timeline
            .whereType<ChatActivitySummary>()
            .single;
        expect(summary.activityCount, 3);
        expect(summary.isGroup, isTrue);
        expect(summary.outputSequence, isNull);
      },
    );
  }

  test(
    'two safe native outputs group without treating text as an activity',
    () async {
      final model = fixture.registerModel();
      final controller = await fixture.createController();
      addTearDown(controller.close);
      expect(controller.submit('Two safe native outputs'), isTrue);
      final running = controller.activeRunFuture!;
      final call = await model.callAt(0);
      call.native(null);
      call.native('First safe compact');
      call.output('Canonical answer, not group narration.');
      call.native('Second safe compact');
      call.settle();
      await running;
      final summary = controller.timeline
          .whereType<ChatActivitySummary>()
          .single;
      expect(summary.content, 'First safe compact');
      expect(summary.activityCount, 2);
      expect(summary.isGroup, isTrue);
      expect(summary.outputSequence, isNull);
      expect(
        controller.snapshot.entries.last.content,
        'Canonical answer, not group narration.',
      );
    },
  );

  for (final safe in [false, true]) {
    for (final withTool in [false, true]) {
      test(
        '${safe ? 'Safe' : 'Unknown raw'} native output ${withTool ? 'with tools' : 'without tools'} groups only by evidence',
        () async {
          final model = fixture.registerModel();
          final controller = await fixture.createController();
          addTearDown(controller.close);
          expect(controller.submit('Native output without display'), isTrue);
          final running = controller.activeRunFuture!;
          final call = await model.callAt(0);
          call.native(safe ? 'Safe without rich frontend' : null);
          if (withTool) {
            call.propose('read', 'read_file', {
              'relativePath': _EnvironmentChannel.sourcePath,
            });
            call.settle();
            final continuation = await model.callAt(1);
            continuation.output('Canonical final.');
            continuation.settle();
          } else {
            call.output('Canonical final.');
            call.settle();
          }
          await running;
          expect(controller.failure, isNull);
          expect(controller.currentRun!.run.state, RunState.completed);
          expect(controller.snapshot.entries.last.content, 'Canonical final.');
          final groups = controller.timeline.whereType<ChatActivitySummary>();
          if (safe || withTool) {
            expect(
              groups.single.activityCount,
              (safe ? 1 : 0) + (withTool ? 1 : 0),
            );
            expect(groups.single.isGroup, safe && withTool);
            final outputs =
                controller.activitySnapshots.single.models.first.outputs;
            final visible = outputs.where(
              (output) =>
                  output.item is ModelToolProposalOutput ||
                  (output.item is ModelNativeOutput &&
                      (output.item as ModelNativeOutput).presentation != null),
            );
            expect(
              groups.single.outputSequence,
              groups.single.isGroup ? null : visible.single.sequence,
            );
          }
          if (safe) {
            expect(groups.single.content, 'Safe without rich frontend');
          } else if (withTool) {
            expect(groups.single.content, 'read_file');
          } else {
            expect(groups, isEmpty);
            final activity = controller.activitySnapshots.single;
            expect(
              controller.activitySummary(
                activity.runId,
                activity.models.single.id,
              ),
              isNull,
            );
          }
          final before = groups.toList();
          final history = controller.snapshot;
          final registration = registerNativePresentation();
          await Future<void>.delayed(Duration.zero);
          expect(controller.timeline.whereType<ChatActivitySummary>(), before);
          await registration.close();
          await Future<void>.delayed(Duration.zero);
          expect(controller.timeline.whereType<ChatActivitySummary>(), before);
          expect(controller.snapshot, same(history));
        },
      );
    }
  }

  for (final narrated in [false, true]) {
    testWidgets(
      '${narrated ? 'Tool narration' : 'Safe native compact'} escapes controls and bounds the retained Chat summary',
      (tester) async {
        final model = fixture.registerModel();
        await openChat(tester);
        final controller = chat(tester);
        for (final text in [
          'Unicode \u00E9 \u{1F600}\n\r\t\u001B\u202E\u200B\\n',
          'Unicode \u00E9 \u{1F600} ${List.filled(150, '\u202E').join()}',
          '${'x' * 158}\u{1F600}yz',
        ]) {
          await send(tester, 'Check display');
          final call = model.calls.last;
          call.native(narrated ? 'Lower priority safe compact' : text);
          if (narrated) {
            call.output(text);
            call.propose('read', 'read_file', {
              'relativePath': _EnvironmentChannel.sourcePath,
            });
            call.settle();
            await tester.pumpAndSettle();
            model.calls.last.output('Canonical answer.');
            model.calls.last.settle();
          } else {
            call.output('Canonical answer.');
            call.settle();
          }
          await tester.pumpAndSettle();
          final compact = controller.timeline
              .whereType<ChatActivitySummary>()
              .last
              .content;
          final escaped = inspectionDisplayText(text);
          expect(
            compact,
            escaped.runes.length <= 160
                ? escaped
                : '${String.fromCharCodes(escaped.runes.take(159))}\u2026',
          );
          expect(compact.runes.length, lessThanOrEqualTo(160));
          expect(
            find.text(
              narrated ? 'ACTIVITY: $compact' : compactDisplayText(text),
            ),
            findsOneWidget,
          );
          final outputs = controller.activitySnapshots.last.models.first.outputs
              .map((output) => output.item);
          if (narrated) {
            expect(outputs.whereType<ModelTextOutput>().single.content, text);
          } else {
            final native = outputs.whereType<ModelNativeOutput>().single;
            expect(native.presentation!.compactText, text);
            expect(native.presentation!.data, {'text': text});
          }
          expect(controller.snapshot.entries.last.content, 'Canonical answer.');
          expect(controller.failure, isNull);
        }
        expect(model.calls, hasLength(narrated ? 6 : 3));
        await disposeApplication(tester);
      },
    );
  }

  for (final revoked in ['controller', 'source', 'generation']) {
    testWidgets(
      'reasoning-only emitted token is rejected after $revoked closes',
      (tester) async {
        final model = fixture.registerModel();
        final presenter = registerNativePresentation();
        addTearDown(presenter.close);
        final controller = await fixture.createController();
        final inspected = <(Session, RunId, ModelInvocationId)>[];
        final frontend = StockChatFrontend(
          extensions: fixture.runtime.extensions,
          controllerForSession: (_) => controller,
          inspectActivity: (session, run, model) {
            inspected.add((session, run, model));
            return true;
          },
        );
        final frontends = ApplicationFrontendBootstrap(
          extensions: fixture.runtime.extensions,
          sessionAdapters: {'stock-chat-controller-v1': frontend},
        );
        addTearDown(() => tester.runAsync(frontends.close));
        await tester.runAsync(() async {
          final catalog = await PreparedPluginCatalog.discover(
            _frontendInstallations.path,
          );
          expect(catalog.issues, isEmpty);
          await frontends.start(catalog);
        });
        final presentation = fixture.runtime.extensions
            .discover(sessionPresentationContributions)
            .single
            .value
            .createPresentation(controller.session);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: presentation)),
        );
        expect(controller.submit('Reasoning token'), isTrue);
        final running = controller.activeRunFuture!;
        final call = await model.callAt(0);
        call.native('Native group');
        call.output('Canonical final.');
        call.settle();
        await running;
        frontend.refresh();
        await tester.pumpAndSettle();
        final retained = action(tester, 'Native group')!;
        final group = controller.timeline
            .whereType<ChatActivitySummary>()
            .single;
        final history = controller.snapshot;
        final run = controller.currentRun!.run;
        final journal = run.journal.records;
        retained();
        expect(inspected, [
          (controller.session, group.runId, group.invocationId),
        ]);
        await presenter.close();
        frontend.refresh();
        await tester.pumpAndSettle();
        retained();
        expect(inspected, hasLength(2));
        switch (revoked) {
          case 'controller':
            await controller.close();
          case 'source':
            await tester.pumpWidget(const SizedBox.shrink());
          case 'generation':
            await tester.runAsync(frontends.generations.single.close);
        }
        retained();
        expect(inspected, hasLength(2));
        expect(controller.snapshot, same(history));
        expect(run.journal.records, journal);
        expect(model.calls, hasLength(1));
        expect(fixture.runIds.values, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.close();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'native Chat actions revoke on slot unmount and guarded parent failure, not siblings',
    (tester) async {
      final root =
          '${Directory.current.parent.path}/plugins/chat_strategy/packages/frontend/lib';
      final source = File(
        '$root/chat_strategy_frontend.dart',
      ).readAsStringSync();
      const snapshotRead =
          'final ChatPresentationSnapshot snapshot = readChatSnapshot();';
      const activityBuild = 'children.add(activity(entry));';
      expect(source, contains(snapshotRead));
      expect(source, contains(activityBuild));
      final compiler = Compiler()
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(const ChatFrontendDeclarations())
        ..entrypoints.add(chatFrontendLibrary);
      final program = compiler.compile({
        'chat_strategy_frontend': {
          'chat_strategy_frontend.dart':
              '${source.replaceFirst(snapshotRead, "$snapshotRead\nif (_testFail) throw StateError('parent build failure');").replaceFirst(activityBuild, 'if (!_testHide) $activityBuild')}\n'
              'bool _testHide = false;\n'
              'bool _testFail = false;\n'
              'void hideSlots() { _testHide = true; }\n'
              'void showSlots() { _testHide = false; }\n'
              'void failChat() { _testFail = true; }\n',
          'src/chat_frontend_bridge.dart': File(
            '$root/src/chat_frontend_bridge.dart',
          ).readAsStringSync(),
        },
      });
      final artifact = File(
        '${_frontendArtifact.parent.path}/chat-revocation.evc',
      );
      await tester.runAsync(() => artifact.writeAsBytes(program.write()));
      final model = fixture.registerModel();
      final controller = await fixture.createController();
      addTearDown(controller.close);
      expect(controller.submit('Retain the native action'), isTrue);
      final running = controller.activeRunFuture!;
      final call = await model.callAt(0);
      call.native('One safe activity');
      call.output('Canonical answer.');
      call.settle();
      await running;
      int inspected = 0;
      final frontend = StockChatFrontend(
        extensions: fixture.runtime.extensions,
        controllerForSession: (_) => controller,
        inspectActivity: (_, _, _) {
          inspected++;
          return true;
        },
      );
      final frontends = ApplicationFrontendBootstrap(
        extensions: fixture.runtime.extensions,
        sessionAdapters: {'stock-chat-controller-v1': frontend},
      );
      addTearDown(() => tester.runAsync(frontends.close));
      await tester.runAsync(() async {
        final root = await prepareFrontendInstallations(
          root: Directory('${artifact.parent.path}/chat-revocation-installed'),
          artifacts: {'dev.adele.plugin.chat-strategy': artifact},
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        await frontends.start(catalog);
      });
      final contribution = fixture.runtime.extensions
          .discover(sessionPresentationContributions)
          .single
          .value;
      final first = contribution.createPresentation(controller.session);
      final second = contribution.createPresentation(controller.session);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: first),
                Expanded(child: second),
              ],
            ),
          ),
        ),
      );
      final chatWidgets = tester
          .widgetList<$StatefulWidget$bridge>(
            find.byWidgetPredicate(
              (widget) => widget is $StatefulWidget$bridge,
            ),
          )
          .toList();
      expect(chatWidgets, hasLength(2));
      final firstRuntime = chatWidgets.first.$runtime;
      void mode(int value) =>
          firstRuntime.executeLib(chatFrontendLibrary, switch (value) {
            0 => 'showSlots',
            1 => 'hideSlots',
            _ => 'failChat',
          });
      Finder slot(Widget view) => find.descendant(
        of: find.byWidget(view),
        matching: find.byType(ActivityOutputPresentation),
      );
      VoidCallback inspect(Widget view) => tester
          .widget<TextButton>(
            find.ancestor(of: slot(view), matching: find.byType(TextButton)),
          )
          .onPressed!;
      final removedAction = inspect(first);
      final siblingAction = inspect(second);
      await tester.enterText(find.byType(TextField).at(1), 'Sibling draft');
      final history = controller.snapshot;
      final journal = controller.currentRun!.run.journal.records;
      removedAction();
      expect(inspected, 1);

      mode(1);
      frontend.refresh();
      await tester.pumpAndSettle();
      expect(slot(first), findsNothing);
      expect(find.text('Frontend unavailable.'), findsNothing);
      expect(find.text('Chat'), findsNWidgets(2));
      expect(find.byWidget(first), findsOneWidget);
      removedAction();
      expect(inspected, 1);
      siblingAction();
      expect(inspected, 2);
      mode(0);
      frontend.refresh();
      await tester.pumpAndSettle();
      expect(slot(first), findsOneWidget);
      removedAction();
      expect(inspected, 2);
      final failedAction = inspect(first);
      failedAction();
      expect(inspected, 3);

      final slotElement = tester.element(slot(first));
      final parent = tester.state(find.byWidget(chatWidgets.first));
      mode(2);
      // Invoke the actual guarded lifecycle before Flutter can unmount the slot.
      // The source and registration remain live, but the bridge must revoke now.
      // ignore: invalid_use_of_protected_member
      parent.build(parent.context);
      expect(slotElement.mounted, isTrue);
      failedAction();
      expect(inspected, 3);
      siblingAction();
      expect(inspected, 4);
      await tester.pumpAndSettle();
      expect(slot(first), findsNothing);
      expect(find.byWidget(first), findsOneWidget);
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.text('Chat'), findsOneWidget);
      failedAction();
      removedAction();
      expect(inspected, 4);
      siblingAction();
      expect(inspected, 5);
      frontend.refresh();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Sibling draft',
      );
      expect(controller.isClosed, isFalse);
      expect(controller.snapshot, same(history));
      expect(controller.currentRun!.run.journal.records, journal);
      expect(controller.failure, isNull);
      expect(
        fixture.runtime.extensions.discover(sessionPresentationContributions),
        hasLength(1),
      );
      expect(model.calls, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      siblingAction();
      expect(inspected, 5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stock Chat tokens are exact, view-local, stable and revocable', (
    tester,
  ) async {
    const probeLibrary = 'package:chat_probe/main.dart';
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const ChatFrontendDeclarations())
      ..entrypoints.addAll([chatFrontendLibrary, probeLibrary]);
    final root =
        '${Directory.current.parent.path}/plugins/chat_strategy/packages/frontend/lib';
    final program = compiler.compile({
      'chat_strategy_frontend': {
        'chat_strategy_frontend.dart': File(
          '$root/chat_strategy_frontend.dart',
        ).readAsStringSync(),
        'src/chat_frontend_bridge.dart': File(
          '$root/src/chat_frontend_bridge.dart',
        ).readAsStringSync(),
      },
      'chat_probe': {
        'main.dart': '''
import 'package:flutter/widgets.dart';
import 'package:chat_strategy_frontend/src/chat_frontend_bridge.dart';

String activityId() {
  for (final entry in readChatSnapshot().entries) {
    if (entry.kind == 'activity') return entry.id!;
  }
  return '';
}
Widget? buildSlot(String id) => buildChatActivity(id);
bool inspect(String id) => inspectChatActivity(id);
''',
      },
    });
    final artifact = File('${_frontendArtifact.parent.path}/chat-probe.evc');
    await tester.runAsync(() => artifact.writeAsBytes(program.write()));
    final model = fixture.registerModel();
    final controller = await fixture.createController();
    addTearDown(controller.close);
    final inspected = <(RunId, ModelInvocationId)>[];
    final frontend = StockChatFrontend(
      extensions: fixture.runtime.extensions,
      controllerForSession: (_) => controller,
      inspectActivity: (_, run, model) {
        inspected.add((run, model));
        return true;
      },
    );
    final frontends = ApplicationFrontendBootstrap(
      extensions: fixture.runtime.extensions,
      sessionAdapters: {'stock-chat-controller-v1': frontend},
    );
    addTearDown(() => tester.runAsync(frontends.close));
    await tester.runAsync(() async {
      final root = await prepareFrontendInstallations(
        root: Directory('${artifact.parent.path}/chat-probe-installed'),
        artifacts: {'dev.adele.plugin.chat-strategy': artifact},
      );
      final catalog = await PreparedPluginCatalog.discover(root.path);
      expect(catalog.issues, isEmpty);
      await frontends.start(catalog);
    });
    final contribution = fixture.runtime.extensions
        .discover(sessionPresentationContributions)
        .single
        .value;
    final first = contribution.createPresentation(controller.session);
    final second = contribution.createPresentation(controller.session);
    Widget host(bool showFirst) => MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            Expanded(
              key: const ValueKey('first'),
              child: showFirst ? first : const SizedBox.shrink(),
            ),
            Expanded(key: const ValueKey('second'), child: second),
          ],
        ),
      ),
    );
    await tester.pumpWidget(host(true));
    expect(controller.submit('Same evidence, separate views'), isTrue);
    final running = controller.activeRunFuture!;
    final call = await model.callAt(0);
    call.native('Visible compact');
    call.output('Canonical answer.');
    call.settle();
    await running;
    frontend.refresh();
    await tester.pumpAndSettle();
    final runtimes = tester
        .widgetList<$StatefulWidget$bridge>(
          find.byWidgetPredicate((widget) => widget is $StatefulWidget$bridge),
        )
        .map((widget) => widget.$runtime)
        .toList();
    expect(runtimes, hasLength(2));
    Object? probe(Runtime runtime, String function, [String? id]) {
      final result = runtime.executeLib(
        probeLibrary,
        function,
        id == null ? [] : [$String(id)],
      );
      return result is $Value ? result.$reified : result;
    }

    final idA = probe(runtimes[0], 'activityId')! as String;
    final idB = probe(runtimes[1], 'activityId')! as String;
    expect(idA, isNot(idB));
    expect(idA, isNotEmpty);
    for (final (runtime, own, foreign) in [
      (runtimes[0], idA, idB),
      (runtimes[1], idB, idA),
    ]) {
      final root = probe(runtime, 'buildSlot', own)! as Widget;
      expect(root, isNot(isA<$Value>()));
      expect(root.key, (probe(runtime, 'buildSlot', own)! as Widget).key);
      expect(probe(runtime, 'inspect', own), isTrue);
      for (final rejected in [
        '',
        foreign,
        '$own/forged',
        '["run-test-1","model-1"]',
      ]) {
        expect(probe(runtime, 'buildSlot', rejected), isNull);
        expect(probe(runtime, 'inspect', rejected), isFalse);
      }
    }
    expect(inspected, hasLength(2));
    await tester.enterText(find.byType(TextField).at(0), 'First draft');
    await tester.enterText(find.byType(TextField).at(1), 'Second draft');
    frontend.refresh();
    await tester.pumpAndSettle();
    expect(probe(runtimes[0], 'activityId'), idA);
    expect(probe(runtimes[1], 'activityId'), idB);
    await tester.pumpWidget(host(false));
    expect(probe(runtimes[0], 'buildSlot', idA), isNull);
    expect(probe(runtimes[0], 'inspect', idA), isFalse);
    expect(probe(runtimes[1], 'inspect', idB), isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Second draft',
    );
    await tester.runAsync(frontends.generations.single.close);
    expect(probe(runtimes[1], 'buildSlot', idB), isNull);
    expect(probe(runtimes[1], 'inspect', idB), isFalse);
    expect(inspected, hasLength(3));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.failure, isNull);
    expect(model.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final missingArtifact in [false, true]) {
    testWidgets(
      '${missingArtifact ? 'missing artifact' : 'empty installation root'} retains canonical product',
      (tester) async {
        final _ModelChannel model = fixture.registerModel();
        final root = (await tester.runAsync(() async {
          final root = await prepareFrontendInstallations(
            root: Directory(
              '${_frontendArtifact.parent.path}/missing-$missingArtifact',
            ),
            artifacts: {
              if (missingArtifact)
                'dev.adele.plugin.chat-strategy': _frontendArtifact,
            },
          );
          if (missingArtifact) {
            await File(
              '${root.path}/dev.adele.plugin.chat-strategy/frontend.evc',
            ).delete();
          }
          return root;
        }))!;
        await openTask(tester, installationRoot: root.path);
        expect(
          fixture.runtime.plugins.catalog!.installations,
          hasLength(missingArtifact ? 1 : 0),
        );
        expect(
          fixture.runtime.plugins.catalog!.installations.map(
            (installation) => installation.frontend,
          ),
          everyElement(isNull),
        );
        expect(
          fixture.runtime.plugins.catalog!.issues,
          hasLength(missingArtifact ? 1 : 0),
        );
        final Task task = shell(tester).task!;
        final Environment environment = shell(tester).environment!;
        await tap(tester, 'New Session');
        final Session session = chat(tester).session;
        expect(fixture.runtime.store.session(session.id), same(session));
        expect(session.taskId, task.id);
        expect(shell(tester).environment, same(environment));
        expect(shell(tester).environmentReady, isTrue);
        expect(chat(tester).unavailableReason, isNull);
        expect(find.textContaining('presentation'), findsWidgets);
        expect(find.text('Send'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('New Session'), findsNothing);
        expect(model.calls, isEmpty);
        expect(fixture.runIds.values, isEmpty);
        await disposeApplication(tester);
      },
    );
  }

  testWidgets('interpreted composer survives normal application rebuilds', (
    tester,
  ) async {
    fixture.registerModel();
    await openChat(tester);
    await tester.enterText(find.byType(TextField), 'Unsubmitted draft');
    await tester.pumpWidget(fixture.application());
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Unsubmitted draft',
    );
    expect(chat(tester).snapshot.entries, isEmpty);
    await disposeApplication(tester);
  });

  testWidgets(
    'retired stock presentation cannot submit through retained UI',
    (tester) async => tester.runAsync(() async {
      final _ModelChannel model = fixture.registerModel();
      final Session session = await fixture.createSession();
      final ChatController controller = ChatController(
        runtime: fixture.runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: _configuration.model,
        runIds: fixture.runIds,
      );
      addTearDown(controller.close);
      final frontend = StockChatFrontend(
        extensions: fixture.runtime.extensions,
        controllerForSession: (_) => controller,
      );
      final frontends = ApplicationFrontendBootstrap(
        extensions: fixture.runtime.extensions,
        sessionAdapters: {'stock-chat-controller-v1': frontend},
      );
      addTearDown(frontends.close);
      final catalog = await PreparedPluginCatalog.discover(
        _frontendInstallations.path,
      );
      expect(catalog.issues, isEmpty);
      await frontends.start(catalog);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionPresentationHost(
              session: session,
              extensions: fixture.runtime.extensions,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Retired submission');
      final VoidCallback retained = action(tester, 'Send')!;
      final generation = frontends.generations.single;
      final Future<void> closing = generation.close();
      expect(generation.close(), same(closing));
      retained();
      await closing;
      await tester.pumpAndSettle();
      retained();
      expect(find.text('Session presentation is unavailable.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(controller.snapshot.entries, isEmpty);
      expect(model.calls, isEmpty);
      expect(fixture.runIds.values, isEmpty);
      expect(fixture.runtime.store.session(session.id), same(session));
      expect(controller.unavailableReason, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.close();
      await fixture.close();
      expect(tester.takeException(), isNull);
    }),
  );

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
        final VoidCallback retained = action(tester, 'New Session')!;
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
        expect(action(tester, 'Send'), isNull);
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
    'single apply_patch hosts real Filesystem compact inside stock Chat without authority',
    (tester) async {
      final model = fixture.registerModel();
      final frontend = ApplicationFrontendBootstrap(
        extensions: fixture.runtime.extensions,
      );
      addTearDown(() => tester.runAsync(frontend.close));
      await tester.runAsync(() async {
        final root = await prepareFrontendInstallations(
          root: Directory(
            '${_frontendArtifact.parent.path}/filesystem-installed',
          ),
          artifacts: {
            'dev.adele.plugin.filesystem-tools': _filesystemFrontendArtifact,
          },
        );
        final catalog = await PreparedPluginCatalog.discover(root.path);
        expect(catalog.issues, isEmpty);
        await frontend.start(catalog);
      });
      await openChat(tester);
      final controller = chat(tester);
      await send(tester, 'Review one patch before executing it');
      final starting = controller.activeRunFuture!;
      final run = controller.currentRun!.run;
      model.calls.single.output(
        'Narration does not make this single patch a group.',
      );
      model.calls.single.propose(
        'single-patch',
        'apply_patch',
        _patchArguments,
      );
      model.calls.single.settle();
      await tester.pumpAndSettle();
      await starting;

      final approval = controller.pendingApproval!;
      final history = controller.snapshot;
      final evidence = controller.activityForRun(run.id)!;
      final tool = evidence.tools.single;
      final summary = controller.timeline
          .whereType<ChatActivitySummary>()
          .single;
      expect(run.state, RunState.waiting);
      expect(controller.isAdvancing, isFalse);
      expect(summary.activityCount, 1);
      expect(summary.isGroup, isFalse);
      expect(summary.content, 'apply_patch');
      expect(summary.outputSequence, tool.proposalSequence);
      expect(summary.invocationId, tool.modelInvocationId);
      expect(history.entries, hasLength(1));

      final chatView = find.byType(SessionPresentationHost);
      final slot = find.descendant(
        of: chatView,
        matching: find.byType(ActivityOutputPresentation),
      );
      expect(slot, findsOneWidget);
      final occurrence = tester.widget<ActivityOutputPresentation>(slot);
      expect(occurrence.compact, isTrue);
      expect(occurrence.target.sessionId, controller.session.id);
      expect(occurrence.target.runId, run.id);
      expect(occurrence.target.modelInvocationId, tool.modelInvocationId);
      expect(occurrence.target.outputSequence, tool.proposalSequence);
      final slotElement = tester.element(slot);
      final compactHost = find.descendant(
        of: slot,
        matching: find.byType(ToolActivityCompactHost),
      );
      expect(compactHost, findsOneWidget);
      final source = tester.widget<ToolActivityCompactHost>(compactHost).source;
      expect(source.snapshot, same(tool));
      final compactLabel = find.descendant(
        of: compactHost,
        matching: find.textContaining(
          'Apply Patch: "${_EnvironmentChannel.sourcePath}"',
        ),
      );
      expect(compactLabel, findsOneWidget);
      expect(
        tester.widget<Text>(compactLabel).data!.runes.length,
        lessThanOrEqualTo(200),
      );
      for (final forbidden in [
        'ACTIVITY',
        '1 tool operation',
        'Narration does not',
        'Allow once',
        'Deny',
      ]) {
        expect(
          find.descendant(
            of: chatView,
            matching: find.textContaining(forbidden),
          ),
          findsNothing,
        );
      }
      expect(
        find.descendant(
          of: chatView,
          matching: find.byType(ToolActivityInspectionHost),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: compactHost,
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
          ),
        ),
        findsNothing,
      );

      Finder evalWithin(Finder parent) => find.descendant(
        of: parent,
        matching: find.byWidgetPredicate(
          (widget) => widget is $StatefulWidget$bridge,
        ),
      );
      final compactEval = evalWithin(compactHost);
      expect(compactEval, findsOneWidget);
      final compactRuntime = tester
          .widget<$StatefulWidget$bridge>(compactEval)
          .$runtime;
      final compactState = tester.state(compactEval);
      final chatRuntimes = tester
          .widgetList<$StatefulWidget$bridge>(evalWithin(chatView))
          .map((widget) => widget.$runtime)
          .toSet();
      expect(chatRuntimes, hasLength(2));
      expect(chatRuntimes, contains(compactRuntime));
      final journal = run.journal.records;
      final reads = List.of(fixture.environment.reads);
      final inspectButton = find.ancestor(
        of: slot,
        matching: find.byType(TextButton),
      );
      expect(inspectButton, findsOneWidget);
      await tester.ensureVisible(inspectButton);
      await tester.tap(inspectButton);
      await tester.pumpAndSettle();

      final inspection = tester.widget<InspectionHost>(
        find.byType(InspectionHost),
      );
      expect(inspection.card.target, isA<ModelOutputInspectionTarget>());
      final target = inspection.card.target as ModelOutputInspectionTarget;
      expect(target.sessionId, controller.session.id);
      expect(target.runId, run.id);
      expect(target.modelInvocationId, tool.modelInvocationId);
      expect(target.outputSequence, tool.proposalSequence);
      final detailHost = find.descendant(
        of: find.byType(InspectionHost),
        matching: find.byType(ToolActivityInspectionHost),
      );
      expect(detailHost, findsOneWidget);
      expect(
        tester.widget<ToolActivityInspectionHost>(detailHost).source,
        isNot(same(source)),
      );
      expect(
        find.descendant(of: detailHost, matching: find.text('Apply Patch')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: detailHost,
          matching: find.text('Status: Waiting for approval'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: detailHost,
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
          ),
        ),
        findsNothing,
      );
      final mountedRuntimes = tester
          .widgetList<$StatefulWidget$bridge>(
            find.byWidgetPredicate(
              (widget) => widget is $StatefulWidget$bridge,
            ),
          )
          .map((widget) => widget.$runtime)
          .toSet();
      // Chat, its compact, the card's compact header, and the rich body are separate.
      expect(mountedRuntimes, hasLength(4));
      expect(controller.pendingApproval, same(approval));
      expect(controller.snapshot, same(history));
      expect(run.journal.records, journal);
      expect(fixture.environment.reads, reads);
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.processes, isEmpty);
      expect(fixture.environment.writeCount, 0);
      expect(_events(run).whereType<RunInterruptionResolved>(), isEmpty);
      expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
      expect(model.calls, hasLength(1));

      // Only the separate host approval control changes authority. Its real
      // settlement updates the existing compact source/runtime, not the timeline.
      await tap(tester, 'Deny');
      expect(model.calls, hasLength(2));
      await tester.pumpAndSettle();
      expect(
        controller.activitySummary(run.id, summary.invocationId),
        same(summary),
      );
      expect(tester.element(slot), same(slotElement));
      expect(
        tester.widget<ToolActivityCompactHost>(compactHost).source,
        same(source),
      );
      expect(source.snapshot, isNot(same(tool)));
      expect(
        source.snapshot.outcome!.disposition,
        ToolOutcomeDisposition.userRejected,
      );
      expect(
        tester.widget<$StatefulWidget$bridge>(compactEval).$runtime,
        same(compactRuntime),
      );
      expect(tester.state(compactEval), same(compactState));
      expect(
        find.descendant(
          of: detailHost,
          matching: find.text('Status: User rejected'),
        ),
        findsOneWidget,
      );
      expect(_events(run).whereType<RunInterruptionResolved>(), hasLength(1));
      expect(_events(run).whereType<ToolExecutionStarted>(), isEmpty);
      model.calls.last.output('The patch was declined.');
      model.calls.last.settle();
      await tester.pumpAndSettle();
      expect(run.state, RunState.completed);
      expect(
        controller.timeline.whereType<ChatActivitySummary>().single,
        same(summary),
      );
      expect(
        tester.widget<$StatefulWidget$bridge>(compactEval).$runtime,
        same(compactRuntime),
      );
      expect(tester.state(compactEval), same(compactState));
      expect(controller.failure, isNull);
      expect(fixture.environment.replacements, isEmpty);
      expect(fixture.environment.processes, isEmpty);
      expect(fixture.environment.writeCount, 0);
      expect(fixture.environment.sourceText, _EnvironmentChannel.initialText);
      expect(find.text('Frontend unavailable.'), findsNothing);
      await disposeApplication(tester);
    },
  );

  testWidgets(
    'normal application activity clicks inspect exact outputs without changing Chat',
    (tester) async {
      final _ModelChannel model = fixture.registerModel();
      await openChat(tester);
      final ChatController controller = chat(tester);
      expect(shell(tester).inspection, isNull);
      await send(tester, 'Read the source and propose validation');
      final execution = controller.currentRun!;
      model.calls.single.output('Reading the requested source.');
      model.calls.single.propose('read', 'read_file', {
        'relativePath': _EnvironmentChannel.sourcePath,
      });
      model.calls.single.settle();
      await tester.pumpAndSettle();
      expect(model.calls, hasLength(2));
      model.calls.last.output('Reviewing the proposed validation.');
      model.calls.last.propose('command', 'run_command', _commandArguments);
      model.calls.last.settle();
      await tester.pumpAndSettle();
      expect(controller.pendingApproval, isNotNull);
      await tap(tester, 'Deny');
      expect(model.calls, hasLength(3));
      model.calls.last.output('Read the source; validation was declined.');
      model.calls.last.settle();
      await tester.pumpAndSettle();
      expect(execution.run.state, RunState.completed);
      final ChatSessionSnapshot history = controller.snapshot;
      final List<ExecutionEventRecord> journal = execution.run.journal.records;
      final List<ChatActivitySummary> groups = controller.timeline
          .whereType<ChatActivitySummary>()
          .toList();
      expect(groups, hasLength(2));
      expect(groups.first.invocationId, isNot(groups.last.invocationId));
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Keep my next question');
      final TextEditingController composer = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      final VoidCallback retained = action(
        tester,
        'Tool: ${groups.first.content}',
      )!;

      for (final ChatActivitySummary group in [groups.last, groups.first]) {
        await tap(tester, 'Tool: ${group.content}');
        final InspectionHost inspection = tester.widget<InspectionHost>(
          find.byType(InspectionHost),
        );
        expect(shell(tester).inspection, isNotNull);
        expect(inspection.card.target.sessionId, controller.session.id);
        expect(inspection.card.target.runId, group.runId);
        expect(inspection.card.target.modelInvocationId, group.invocationId);
        expect(
          (inspection.card.target as ModelOutputInspectionTarget)
              .outputSequence,
          group.outputSequence,
        );
        expect(inspection.heading, group.content);
        expect(
          inspection.activity,
          same(controller.activityForRun(group.runId)),
        );
        expect(
          tester
              .widgetList<ToolActivityInspectionHost>(
                find.descendant(
                  of: find.byType(InspectionHost),
                  matching: find.byType(ToolActivityInspectionHost),
                ),
              )
              .map((host) => host.source.snapshot),
          inspection.activity!.tools.where(
            (tool) => tool.modelInvocationId == group.invocationId,
          ),
        );
        expect(
          find.text('Tool activity inspection is unavailable.'),
          findsOneWidget,
        );
        expect(controller.currentRun, same(execution));
        expect(controller.snapshot, same(history));
        expect(execution.run.journal.records, journal);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(composer),
        );
        expect(composer.text, 'Keep my next question');
        await tester.ensureVisible(find.byTooltip('Dismiss Inspection'));
        await tester.tap(find.byTooltip('Dismiss Inspection'));
        await tester.pumpAndSettle();
      }

      expect(shell(tester).inspection, isNull);
      expect(find.byType(InspectionHost), findsNothing);
      expect(controller.currentRun, same(execution));
      expect(controller.snapshot, same(history));
      expect(execution.run.journal.records, journal);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(composer),
      );
      expect(composer.text, 'Keep my next question');
      expect(
        fixture.runtime.chat.sessions
            .obtain(controller.session.id)
            .snapshot()
            .entries,
        history.entries,
      );
      expect(fixture.runIds.values, hasLength(1));
      expect(model.calls, hasLength(3));
      expect(fixture.environment.processes, isEmpty);

      await tap(tester, 'Tool: ${groups.first.content}');
      expect(find.byType(InspectionHost), findsOneWidget);
      await disposeApplication(tester);
      expect(controller.isClosed, isTrue);
      retained();
      await tester.pumpAndSettle();
      expect(find.byType(InspectionHost), findsNothing);
      expect(controller.currentRun, same(execution));
      expect(controller.snapshot, same(history));
      expect(execution.run.journal.records, journal);
      expect(fixture.runIds.values, hasLength(1));
      expect(model.calls, hasLength(3));
      expect(fixture.environment.processes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final bool narrated in [true, false]) {
    testWidgets(
      'live ${narrated ? 'narrated' : 'fallback'} batches stay ordered across tools and follow-up',
      (tester) async {
        final _ModelChannel model = fixture.registerModel();
        await openChat(tester);
        final ChatController controller = chat(tester);
        await send(tester, 'Inspect and validate');
        final Future<void> starting = controller.activeRunFuture!;
        final execution = controller.currentRun!;
        final _ModelCall first = model.calls.single;
        fixture.environment.readGate = Completer<void>();
        if (narrated) {
          first.output('Inspecting resolver ownership.');
          first.output('Checking retry behavior.');
        }
        for (int i = 0; i < 4; i++) {
          first.propose('read-$i', 'read_file', {
            'relativePath': _EnvironmentChannel.sourcePath,
          });
        }
        await tester.pumpAndSettle();
        // Output is evidence, but an unsettled turn is not a processable batch.
        expect(controller.timeline.whereType<ChatActivitySummary>(), isEmpty);
        first.settle();
        await tester.pumpAndSettle();
        final String compact = narrated
            ? r'Inspecting resolver ownership.\nChecking retry behavior.'
            : '4 operations';
        final ChatActivitySummary initial = controller.timeline
            .whereType<ChatActivitySummary>()
            .single;
        expect(initial.content, compact);
        expect(initial.activityCount, 4);
        expect(initial.isGroup, isTrue);
        expect(initial.outputSequence, isNull);
        expect(initial.runId, execution.run.id);
        expect(controller.isAdvancing, isTrue);
        expect(controller.activeRunFuture, same(starting));
        expect(model.calls, hasLength(1));
        expect(controller.snapshot.entries.single, isA<ChatUserMessage>());
        expect(find.textContaining(compact), findsOneWidget);
        expect(find.textContaining('ACTIVITY'), findsOneWidget);

        fixture.environment.readGate!.complete();
        await tester.pumpAndSettle();
        expect(model.calls, hasLength(2));
        expect(model.calls.last.outcomes, hasLength(4));
        expect(
          controller.timeline.whereType<ChatActivitySummary>(),
          hasLength(1),
        );
        final RunActivitySnapshot readEvidence =
            controller.activitySnapshots.single;
        expect(
          readEvidence.models.first.outputs.where(
            (item) => item.item is ModelToolProposalOutput,
          ),
          hasLength(4),
        );
        expect(readEvidence.tools, hasLength(4));
        expect(
          readEvidence.tools.map((tool) => tool.modelInvocationId).toSet(),
          {initial.invocationId},
        );
        expect(readEvidence.tools.map((tool) => tool.id).toSet(), hasLength(4));
        model.calls.last.output('Validating the implementation.');
        model.calls.last.propose('validate', 'run_command', _commandArguments);
        model.calls.last.settle();
        await tester.pumpAndSettle();
        await starting;
        final summaries = controller.timeline
            .whereType<ChatActivitySummary>()
            .toList();
        expect(summaries.map((entry) => entry.content), [
          compact,
          'run_command',
        ]);
        expect(summaries.first.invocationId, initial.invocationId);
        expect(summaries.last.invocationId, isNot(initial.invocationId));
        expect(find.textContaining('ACTIVITY'), findsOneWidget);
        expect(summaries.last.isGroup, isFalse);
        expect(summaries.last.activityCount, 1);
        expect(summaries.last.outputSequence, isNotNull);
        expect(find.text('Approval required'), findsOneWidget);
        expect(controller.currentRun, same(execution));
        expect(controller.isRunning, isTrue);
        expect(controller.isAdvancing, isFalse);
        expect(fixture.environment.processes, isEmpty);
        expect(
          find.descendant(
            of: find.byType(SessionPresentationHost),
            matching: find.text('Allow once'),
          ),
          findsNothing,
        );
        final PendingToolApproval approval = controller.pendingApproval!;
        expect(controller.resolveApproval(approval, approved: false), isTrue);
        final Future<void> finishing = controller.activeRunFuture!;
        await tester.pumpAndSettle();
        expect(model.calls, hasLength(3));
        expect(model.calls.last.outcomes.last['status'], 'rejected');
        model.calls.last.output('Inspected; validation was declined.');
        model.calls.last.settle();
        await tester.pumpAndSettle();
        await finishing;
        expect(controller.failure, isNull);
        expect(controller.activitySnapshots.single.state, RunState.completed);
        expect(controller.activitySnapshots.single.tools, hasLength(5));
        expect(controller.timeline.map((entry) => entry.content), [
          'Inspect and validate',
          compact,
          'run_command',
          'Inspected; validation was declined.',
        ]);
        expect(controller.snapshot.entries.map((entry) => entry.content), [
          'Inspect and validate',
          'Inspected; validation was declined.',
        ]);
        expect(fixture.environment.processes, isEmpty);
        expect(
          tester.getTopLeft(find.text('Inspect and validate')).dy,
          lessThan(tester.getTopLeft(find.textContaining(compact)).dy),
        );
        expect(
          tester.getTopLeft(find.textContaining(compact)).dy,
          lessThan(tester.getTopLeft(find.text('Tool: run_command')).dy),
        );
        expect(
          tester.getTopLeft(find.text('Tool: run_command')).dy,
          lessThan(
            tester
                .getTopLeft(find.text('Inspected; validation was declined.'))
                .dy,
          ),
        );

        final retained = controller.activitySnapshots.single;
        await send(tester, 'Follow up');
        expect(controller.activitySnapshots.first, same(retained));
        expect(
          controller.timeline.whereType<ChatActivitySummary>(),
          hasLength(2),
        );
        expect(find.textContaining(compact), findsOneWidget);
        expect(model.calls, hasLength(4));
        expect(model.calls.last.messages, [
          ('user', 'Inspect and validate'),
          ('assistant', 'Inspected; validation was declined.'),
          ('user', 'Follow up'),
        ]);
        model.calls.last.output('Follow-up answer.');
        model.calls.last.settle();
        await tester.pumpAndSettle();
        expect(controller.timeline.map((entry) => entry.content), [
          'Inspect and validate',
          compact,
          'run_command',
          'Inspected; validation was declined.',
          'Follow up',
          'Follow-up answer.',
        ]);
        expect(
          controller.timeline.whereType<ChatActivitySummary>(),
          hasLength(2),
        );
        expect(model.calls, hasLength(4));
        expect(
          () => controller.activitySnapshots.clear(),
          throwsUnsupportedError,
        );
        expect(() => controller.timeline.clear(), throwsUnsupportedError);
        await disposeApplication(tester);
      },
    );
  }

  testWidgets(
    'controller coalesces progress reads and drops a queued capture on close',
    (tester) async {
      final _ModelChannel model = fixture.registerModel();
      int notifications = 0;
      int activityNotifications = 0;
      int liveNotifications = 0;
      final ChatController controller = await fixture.createController(
        onChanged: () => notifications++,
        onActivityChanged: () => activityNotifications++,
      );
      controller.activityChanges.addListener(() => liveNotifications++);
      expect(controller.submit('Read with progress'), isTrue);
      final _ModelCall call = await model.callAt(0);
      fixture.environment.readGate = Completer<void>();
      call.output('Inspecting the source.');
      call.propose('read', 'read_file', {
        'relativePath': _EnvironmentChannel.sourcePath,
      });
      call.settle();
      await tester.pump();
      final AgentRun run = controller.currentRun!.run;
      final RunActivitySnapshot before = controller.activitySnapshots.single;
      final ToolInvocationId tool = before.tools.single.id;
      final compactSources = <ToolActivityInspectionSource>[];
      final compact = fixture.runtime.extensions.register(
        point: toolActivityCompactPresentationContributions,
        id: ExtensionId('dev.example.live-chat-compact'),
        value: ToolActivityCompactPresentationContribution(
          toolId: before.tools.single.toolId,
          createPresentation: (source) {
            compactSources.add(source);
            return ListenableBuilder(
              listenable: source,
              builder: (_, _) =>
                  Text('Live changes: ${source.snapshot.changes.length}'),
            );
          },
        ),
      );
      addTearDown(compact.close);
      final frontend = StockChatFrontend(
        extensions: fixture.runtime.extensions,
        controllerForSession: (_) => controller,
      );
      final frontends = ApplicationFrontendBootstrap(
        extensions: fixture.runtime.extensions,
        sessionAdapters: {'stock-chat-controller-v1': frontend},
      );
      addTearDown(() => tester.runAsync(frontends.close));
      await tester.runAsync(() async {
        final catalog = await PreparedPluginCatalog.discover(
          _frontendInstallations.path,
        );
        expect(catalog.issues, isEmpty);
        await frontends.start(catalog);
      });
      final presentation = fixture.runtime.extensions
          .discover(sessionPresentationContributions)
          .single
          .value
          .createPresentation(controller.session);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: presentation)));
      expect(compactSources, hasLength(1));
      final source = compactSources.single;
      final compactElement = tester.element(
        find.text('Live changes: ${source.snapshot.changes.length}'),
      );
      final chatElement = tester.element(find.text('Chat'));
      final int beforeNotifications = notifications;
      final int beforeActivityNotifications = activityNotifications;
      final int beforeLiveNotifications = liveNotifications;
      for (int i = 0; i < 1000; i++) {
        run.record(
          ToolProgressObserved(
            invocationId: tool,
            progress: ToolProgress(content: 'x'),
          ),
        );
        await Future<void>.value();
      }
      expect(controller.activitySnapshots.single, same(before));
      expect(notifications, beforeNotifications);
      expect(activityNotifications, beforeActivityNotifications);
      expect(liveNotifications, beforeLiveNotifications);
      await tester.pump();
      await tester.pump();
      final RunActivitySnapshot captured = controller.activitySnapshots.single;
      expect(captured.sequence, before.sequence + 1000);
      expect(
        captured.tools.single.changes.where(
          (change) => change.kind == ToolActivityKind.progress,
        ),
        hasLength(1000),
      );
      expect(notifications, beforeNotifications);
      expect(activityNotifications, beforeActivityNotifications + 1);
      expect(liveNotifications, beforeLiveNotifications + 1);
      expect(compactSources, [source]);
      expect(source.snapshot, same(captured.tools.single));
      expect(
        tester.element(
          find.text('Live changes: ${source.snapshot.changes.length}'),
        ),
        same(compactElement),
      );
      expect(tester.element(find.text('Chat')), same(chatElement));
      expect(controller.activityForRun(run.id), same(captured));
      await tester.pump();
      expect(activityNotifications, beforeActivityNotifications + 1);
      expect(liveNotifications, beforeLiveNotifications + 1);
      run.record(
        ToolProgressObserved(
          invocationId: tool,
          progress: ToolProgress(content: 'late'),
        ),
      );
      await Future<void>.value();
      final Future<void> closing = controller.close();
      fixture.environment.readGate!.complete();
      final _ModelCall finalCall = await model.callAt(1);
      finalCall.output('Late final response.');
      finalCall.settle();
      await closing;
      await tester.pumpAndSettle();
      expect(controller.activitySnapshots.single, same(captured));
      expect(notifications, beforeNotifications);
      expect(activityNotifications, beforeActivityNotifications + 1);
      expect(controller.activityForRun(run.id), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        controller.activitySummary(run.id, captured.models.first.id),
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'controller activity lookups retain exact evidence through waits and follow-up',
    (tester) async {
      final _ModelChannel model = fixture.registerModel();
      final List<RunActivitySnapshot> observed = [];
      late ChatController controller;
      controller = await fixture.createController(
        onActivityChanged: () =>
            observed.add(controller.activitySnapshots.last),
      );
      final RunId unknownRun = RunId('unknown');
      final ModelInvocationId unknownModel = ModelInvocationId('unknown');
      expect(controller.activityForRun(unknownRun), isNull);
      expect(controller.activitySummary(unknownRun, unknownModel), isNull);
      expect(
        controller.submit('Propose a read-only inspection target'),
        isTrue,
      );
      final Future<void> starting = controller.activeRunFuture!;
      final _ModelCall call = await model.callAt(0);
      call.output('Reviewing the proposed command.');
      call.propose('command', 'run_command', _commandArguments);
      await tester.pump();
      final AgentRun run = controller.currentRun!.run;
      final RunActivitySnapshot unsettled = controller.activityForRun(run.id)!;
      final ModelInvocationId invocationId = unsettled.models.single.id;
      expect(controller.activitySummary(run.id, invocationId), isNull);
      call.settle();
      // No frame is needed for the final capture of the waiting advancement.
      await starting;
      final RunActivitySnapshot waiting = controller.activityForRun(run.id)!;
      expect(waiting.state, RunState.waiting);
      expect(observed.last, same(waiting));
      final ChatActivitySummary summary = controller.activitySummary(
        RunId(run.id.value),
        ModelInvocationId(invocationId.value),
      )!;
      expect(summary.runId, same(waiting.runId));
      expect(summary.invocationId, same(waiting.models.single.id));
      expect(summary.content, 'run_command');
      expect(summary.isGroup, isFalse);
      expect(controller.activitySummary(run.id, unknownModel), isNull);
      final int notifications = observed.length;
      final int sequence = run.journal.lastSequence;
      final PendingToolApproval approval = controller.pendingApproval!;
      for (int i = 0; i < 5; i++) {
        expect(controller.activityForRun(run.id), same(waiting));
        expect(controller.activitySummary(run.id, invocationId), isNotNull);
      }
      await tester.pumpAndSettle();
      expect(observed, hasLength(notifications));
      expect(run.journal.lastSequence, sequence);
      expect(controller.pendingApproval, same(approval));
      expect(controller.isRunning, isTrue);
      expect(controller.submit('Not a navigation operation'), isFalse);
      expect(fixture.environment.processes, isEmpty);
      expect(controller.snapshot.entries, hasLength(1));

      expect(controller.resolveApproval(approval, approved: false), isTrue);
      final Future<void> finishing = controller.activeRunFuture!;
      final _ModelCall finalCall = await model.callAt(1);
      finalCall.output('Declined command.');
      finalCall.settle();
      await finishing;
      final RunActivitySnapshot completed = controller.activityForRun(run.id)!;
      expect(completed.state, RunState.completed);
      expect(observed.last, same(completed));
      expect(
        controller.activitySummary(run.id, completed.models.last.id),
        isNull,
      );
      expect(controller.submit('Follow-up'), isTrue);
      final Future<void> followUp = controller.activeRunFuture!;
      final _ModelCall nextCall = await model.callAt(2);
      expect(controller.activityForRun(run.id), same(completed));
      expect(
        controller.activitySummary(run.id, invocationId)!.content,
        summary.content,
      );
      nextCall.output('Follow-up answer.');
      nextCall.settle();
      await followUp;
      expect(controller.activitySnapshots, hasLength(2));
      expect(controller.activityForRun(run.id), same(completed));
      await controller.close();
      expect(controller.activityForRun(run.id), isNull);
      expect(controller.activitySummary(run.id, invocationId), isNull);
      expect(fixture.environment.processes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final String revoked in ['controller', 'source', 'generation']) {
    testWidgets(
      'controller adapter inspects retained IDs until $revoked closes',
      (tester) async {
        final _ModelChannel model = fixture.registerModel();
        final ChatController controller = await fixture.createController();
        final List<(Session, RunId, ModelInvocationId)> inspected = [];
        final frontend = StockChatFrontend(
          extensions: fixture.runtime.extensions,
          controllerForSession: (_) => controller,
          inspectActivity: (session, run, invocation) {
            inspected.add((session, run, invocation));
            return true;
          },
        );
        final frontends = ApplicationFrontendBootstrap(
          extensions: fixture.runtime.extensions,
          sessionAdapters: {'stock-chat-controller-v1': frontend},
        );
        addTearDown(() => tester.runAsync(frontends.close));
        await tester.runAsync(() async {
          final catalog = await PreparedPluginCatalog.discover(
            _frontendInstallations.path,
          );
          expect(catalog.issues, isEmpty);
          await frontends.start(catalog);
        });
        final Widget presentation = fixture.runtime.extensions
            .discover(sessionPresentationContributions)
            .single
            .value
            .createPresentation(controller.session);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: presentation)),
        );
        expect(controller.submit('Review the proposed command'), isTrue);
        final Future<void> starting = controller.activeRunFuture!;
        final _ModelCall first = await model.callAt(0);
        first.output('Inspect this command batch.');
        first.propose('command', 'run_command', _commandArguments);
        first.settle();
        await starting;
        frontend.refresh();
        await tester.pumpAndSettle();
        final Finder activity = find.text('Tool: run_command');
        expect(activity, findsOneWidget);
        final VoidCallback retained = tester
            .widget<TextButton>(
              find.ancestor(of: activity, matching: find.byType(TextButton)),
            )
            .onPressed!;
        final RunActivitySnapshot evidence =
            controller.activitySnapshots.single;
        final AgentRun run = controller.currentRun!.run;
        final int sequence = run.journal.lastSequence;
        final PendingToolApproval approval = controller.pendingApproval!;
        await tester.tap(
          find.ancestor(of: activity, matching: find.byType(TextButton)),
        );
        expect(inspected, hasLength(1));
        expect(inspected.last.$1, same(controller.session));
        expect(inspected.last.$2, same(evidence.runId));
        expect(inspected.last.$3, same(evidence.models.single.id));
        expect(controller.pendingApproval, same(approval));
        expect(run.journal.lastSequence, sequence);
        expect(controller.isRunning, isTrue);
        expect(controller.isAdvancing, isFalse);
        expect(controller.snapshot.entries, hasLength(1));
        expect(fixture.runIds.values, hasLength(1));
        expect(model.calls, hasLength(1));
        expect(fixture.environment.processes, isEmpty);
        expect(
          tester.widget<TextField>(find.byType(TextField)).enabled,
          isFalse,
        );

        expect(controller.resolveApproval(approval, approved: false), isTrue);
        final Future<void> finishing = controller.activeRunFuture!;
        final _ModelCall continuation = await model.callAt(1);
        expect(controller.isAdvancing, isTrue);
        retained();
        expect(inspected, hasLength(2));
        continuation.output('Command declined.');
        continuation.settle();
        await finishing;
        expect(controller.submit('Follow up'), isTrue);
        final Future<void> following = controller.activeRunFuture!;
        final _ModelCall followUp = await model.callAt(2);
        frontend.refresh();
        await tester.pumpAndSettle();
        expect(activity, findsOneWidget);
        retained();
        expect(inspected, hasLength(3));
        expect(inspected.every((target) => target == inspected.first), isTrue);
        followUp.output('Follow-up answer.');
        followUp.settle();
        await following;

        switch (revoked) {
          case 'controller':
            await controller.close();
          case 'source':
            await tester.pumpWidget(const SizedBox.shrink());
          case 'generation':
            await tester.runAsync(frontends.generations.single.close);
        }
        retained();
        expect(inspected, hasLength(3));
        expect(fixture.runIds.values, hasLength(2));
        expect(model.calls, hasLength(3));
        expect(fixture.environment.processes, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.close();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('activity observer failures do not fail controller execution', (
    tester,
  ) async {
    final _ModelChannel model = fixture.registerModel();
    final List<FlutterErrorDetails> failures = [];
    final void Function(FlutterErrorDetails)? previous = FlutterError.onError;
    FlutterError.onError = failures.add;
    addTearDown(() => FlutterError.onError = previous);
    final ChatController controller = await fixture.createController(
      onActivityChanged: () => throw StateError('Observer failure'),
    );
    expect(controller.submit('Answer despite broken observation'), isTrue);
    final Future<void> running = controller.activeRunFuture!;
    final _ModelCall call = await model.callAt(0);
    call.output('Execution still succeeds.');
    call.settle();
    await running;
    expect(controller.failure, isNull);
    expect(controller.isAdvancing, isFalse);
    expect(controller.currentRun!.run.state, RunState.completed);
    expect(controller.activitySnapshots.single.state, RunState.completed);
    expect(
      controller.snapshot.entries.last.content,
      'Execution still succeeds.',
    );
    expect(failures.length, greaterThanOrEqualTo(2));
    expect(
      failures.every((failure) => failure.exception is StateError),
      isTrue,
    );
    await controller.close();
    await tester.pumpAndSettle();
    FlutterError.onError = previous;
    expect(tester.takeException(), isNull);
  });

  test(
    'controller preserves explicit Session instructions and narration protocol',
    () async {
      final _ModelChannel model = fixture.registerModel();
      final Session session = await fixture.createSession();
      fixture.runtime.chat.sessions.obtain(session.id).instructions =
          'Do not narrate operations; follow my concise output format.';
      final ChatController controller = ChatController(
        runtime: fixture.runtime,
        session: session,
        providerId: stockChatGptProviderId,
        model: _configuration.model,
        runIds: fixture.runIds,
      );
      expect(controller.submit('Answer without tools'), isTrue);
      final Future<void> running = controller.activeRunFuture!;
      final _ModelCall call = await model.callAt(0);
      expect(call.request['instructions'], contains(chatToolNarrationGuidance));
      expect(
        call.request['instructions'],
        contains('Do not narrate operations; follow my concise output format.'),
      );
      expect(
        call.request['instructions'],
        contains(_EnvironmentChannel.instructions),
      );
      call.output('Final answer.');
      call.settle();
      await running;
      expect(controller.timeline.whereType<ChatActivitySummary>(), isEmpty);
      expect(controller.snapshot.entries.map((entry) => entry.content), [
        'Answer without tools',
        'Final answer.',
      ]);
      await controller.close();
    },
  );

  test(
    'failed model output remains evidence, not Chat activity narration',
    () async {
      final _ModelChannel model = fixture.registerModel();
      int factories = 0;
      final presenter = registerNativePresentation(
        createInspection: (_) {
          factories++;
          throw StateError('Failed turns must not create a presenter.');
        },
      );
      addTearDown(presenter.close);
      final ChatController controller = await fixture.createController();
      expect(controller.submit('Incomplete proposal'), isTrue);
      final Future<void> running = controller.activeRunFuture!;
      final _ModelCall call = await model.callAt(0);
      call.output('This batch did not settle successfully.');
      call.native('Failed native summary');
      call.propose('never-run', 'read_file', {
        'relativePath': _EnvironmentChannel.sourcePath,
      });
      call.settle(fails: true);
      await running;
      expect(controller.failure, isNotNull);
      expect(controller.timeline.whereType<ChatActivitySummary>(), isEmpty);
      expect(factories, 0);
      expect(controller.activitySnapshots, hasLength(1));
      expect(controller.activitySnapshots.single.state, RunState.failed);
      expect(
        controller.activitySnapshots.single.models.single.outputs,
        hasLength(3),
      );
      expect(controller.snapshot.entries.single.content, 'Incomplete proposal');
      expect(
        _events(controller.currentRun!.run).whereType<ToolInvocationPrepared>(),
        isEmpty,
      );
      await controller.close();
    },
  );

  testWidgets(
    'missing configuration disables only execution with a provider present',
    (tester) async {
      final _ModelChannel model = fixture.registerModel();
      await openChat(tester, configuration: null);
      final ChatController controller = chat(tester);
      expect(controller.unavailableReason, contains('not configured'));
      expect(shell(tester).environmentReady, isTrue);
      expect(shell(tester).task!.id, controller.session.taskId);
      expect(action(tester, 'Send'), isNull);
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
    final VoidCallback retained = action(tester, 'Send')!;
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
    expect(action(tester, 'Send'), isNull);
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
    expect(action(tester, 'Send'), isNotNull);
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
    expect(action(tester, 'Send'), isNotNull);
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
    final VoidCallback retained = action(tester, 'Send')!;
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
    expect(action(tester, 'Send'), isNull);
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
          final VoidCallback retained = action(tester, 'Send')!;
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
          await tester.runAsync(() async {
            if (exit) {
              exiting = tester.binding.handleRequestAppExit().then((response) {
                exitCompleted = true;
                return response;
              });
            } else {
              await tester.pumpWidget(const SizedBox.shrink());
            }
          });
          expect(controller.submit('Closing duplicate'), isFalse);
          retained();
          await tester.pumpAndSettle();
          expect(exitCompleted, isFalse);
          expect(backendClosingStates, isEmpty);
          expect(fixture.runtime.plugins.state, ApplicationPluginState.ready);
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
          await tester.runAsync(() async {
            bool retired() => fixture.runtime.extensions
                .discover(orchestrationStrategyContributions)
                .isEmpty;
            if (!retired()) {
              await fixture.runtime.extensions.changes
                  .firstWhere((_) => retired())
                  .timeout(const Duration(seconds: 10));
            }
            if (exiting != null) expect(await exiting, AppExitResponse.exit);
          });
          await tester.pumpAndSettle();
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
            expect(find.byType(SessionPresentationHost), findsNothing);
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
        final VoidCallback retainedAllow = action(tester, 'Allow once')!;
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
        await tester.runAsync(() async {
          if (exit) {
            exiting = tester.binding.handleRequestAppExit();
          } else {
            await tester.pumpWidget(const SizedBox.shrink());
          }
        });
        await tester.pump();
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
        await tester.runAsync(() async {
          bool retired() => fixture.runtime.extensions
              .discover(orchestrationStrategyContributions)
              .isEmpty;
          if (!retired()) {
            await fixture.runtime.extensions.changes
                .firstWhere((_) => retired())
                .timeout(const Duration(seconds: 10));
          }
          if (exiting != null) expect(await exiting, AppExitResponse.exit);
        });
        await tester.pumpAndSettle();
        // Assert application-owned shutdown before any fixture cleanup can close it.
        expect(fixture.runtime.plugins.state, ApplicationPluginState.closed);
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
          expect(find.byType(SessionPresentationHost), findsNothing);
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
    await tester.ensureVisible(button('Send'));
    expect(action(tester, 'Send'), isNotNull);
    expect(chat(tester).snapshot.entries, hasLength(2));
    expect(tester.takeException(), isNull);
    await disposeApplication(tester);
  });

  testWidgets('stock reads proceed without installed Search', (tester) async {
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
      <ToolPolicyDecision>[ToolPolicyDecision.allow],
    );
    expect(fixture.environment.directories, isEmpty);
    expect(
      fixture.environment.reads.where(
        (read) => read['relativePath'] == _EnvironmentChannel.sourcePath,
      ),
      hasLength(1),
    );
    expect(fixture.environment.replacements, isEmpty);
    expect(fixture.environment.processes, isEmpty);
    expect(
      model.calls.last.outcomes.map(
        (outcome) => (outcome['callId'], outcome['status']),
      ),
      <(String, String)>[('read-1', 'success'), ('search-1', 'failed')],
    );
    expect(
      model.calls.last.outcomes.first['content'],
      contains('source-revision-0'),
    );
    expect(
      _events(run).whereType<ToolProposalRejected>().single.failure.kind,
      ToolProposalFailureKind.unknownAlias,
    );
    expect(
      model.calls.last.outcomes.last['content'],
      'The proposed model tool alias is not available.',
    );
    expect(
      controller.snapshot.entries.single.content,
      'Read and search the source',
    );
    model.calls.last.output('Read complete; Search is not installed.');
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
      'Read complete; Search is not installed.',
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
      expect(action(tester, 'Send'), isNull);
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
        find.textContaining('Intermediate proposal text stays Run-local.'),
        findsOneWidget,
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

      final VoidCallback retainedAllow = action(tester, 'Allow once')!;
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
      expect(action(tester, 'Allow once'), isNull);
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
      expect(action(tester, 'Allow once'), isNull);
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
      expect(action(tester, 'Allow once'), isNull);
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
      expect(action(tester, 'Send'), isNotNull);
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
        expect(action(tester, 'Allow once'), isNotNull);
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
        expect(action(tester, 'Allow once'), isNull);
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
      expect(action(tester, 'Allow once'), isNull);
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
      final activityBeforeClose = controller.activitySnapshots;
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
      expect(controller.activitySnapshots, activityBeforeClose);
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
        final activityBeforeClose = controller.activitySnapshots;
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
        expect(controller.activitySnapshots, activityBeforeClose);
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
    // Controller/widget unit fixtures inject semantic tools explicitly. Installed
    // execution is covered by normal_chatgpt_run_integration_test.dart.
    _filesystem = const FilesystemToolsPlugin().activate(runtime.extensions);
    _command = const CommandToolsPlugin().activate(runtime.extensions);
    _selector = runtime.extensions.register(
      point: projectSelectorContributions,
      id: ExtensionId('dev.adele.test.chat-project-selector'),
      value: ProjectSelectorContribution(
        displayName: 'Open Chat Test Project...',
        selectProject: () async => Uri.parse('file:///chat-test/source/'),
      ),
    );
    registerEnvironment(environment);
    // Widget/controller tests supply their own gated source. Remote AGENTS.md
    // activation is exercised separately through prepared backend integration.
    _contextSource = runtime.extensions.register(
      point: inferenceContextSources,
      id: ExtensionId('dev.adele.test.chat-context'),
      value: InferenceContextSourceContribution(
        failureMode: InferenceContextFailureMode.required,
        snapshot: (context) async {
          final files = await context
              .requireHostService<AuthorizedEnvironmentFileReadFacet>();
          final file = await files.readFile('AGENTS.md');
          files.validateBinding();
          return [
            InferenceInstructionMaterial(
              key: 'fixture-instructions',
              text: file.text,
              revision: file.revision,
            ),
          ];
        },
      ),
    );
  }

  final _ProductIds ids = _ProductIds();
  final _RunIds runIds = _RunIds();
  final _EnvironmentChannel environment = _EnvironmentChannel();
  final List<_EnvironmentChannel> environments = <_EnvironmentChannel>[];
  final List<_ModelChannel> models = <_ModelChannel>[];
  late final AdeleRuntime runtime;
  late final ExtensionRegistration _selector;
  late final ExtensionRegistration _contextSource;
  late final ExtensionRegistration _filesystem;
  late final ExtensionRegistration _command;
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
    String? installationRoot,
  }) => AdeleApplication(
    createRuntime: () {
      runtimeCreations++;
      return runtime;
    },
    bootstrapPlugins: (plugins) async {
      expect(plugins, same(runtime.plugins));
      bootstraps++;
      await plugins.start(
        installationRoot: installationRoot ?? _frontendInstallations.path,
      );
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

  Future<ChatController> createController({
    VoidCallback? onChanged,
    VoidCallback? onActivityChanged,
  }) async => ChatController(
    runtime: runtime,
    session: await createSession(),
    providerId: stockChatGptProviderId,
    model: _configuration.model,
    runIds: runIds,
    onChanged: onChanged,
    onActivityChanged: onActivityChanged,
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
    await _contextSource.close();
    await _command.close();
    await _filesystem.close();
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
          'nativePresentation': null,
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
      'nativePresentation': null,
    },
    'terminal': null,
  });

  void native(
    String? approvedText, {
    String presentationKind = 'dev.example.safe',
    Map<String, Object?>? data,
  }) => events.add(<String, Object?>{
    'kind': 'output',
    'observation': null,
    'output': <String, Object?>{
      'kind': 'nativeItem',
      'text': null,
      'toolProposal': null,
      'itemId': 'same-native-provider-id',
      'nativePresentation': approvedText == null
          ? null
          : <String, Object?>{
              'kind': presentationKind,
              'compactText': approvedText,
              'data': data ?? <String, Object?>{'text': approvedText},
            },
      'nativeMetadata': <String, Object?>{
        'kind': 'dev.example.native',
        'compatibility': <String, Object?>{
          'private': 'opaque-secret-compatibility',
        },
        'data': <String, Object?>{
          'approvedText': 'Raw text is not approved for display',
          'private': 'opaque-secret-data',
        },
      },
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

final class _OpaquePresentationFailure {
  @override
  String toString() =>
      throw StateError('Opaque presentation errors must not be printed.');
}
