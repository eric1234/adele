import 'package:adele_desktop/ui/activity/model_native_activity_compact_host.dart';
import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/activity_output_presentation.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/inspection/model_native_activity_inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('strategy'),
  );
  final modelId = ModelInvocationId('model');
  final supported = ToolId('dev.example.supported');
  late ExtensionRegistry extensions;
  late WindowInspection window;

  ProviderToolProposal proposal(int sequence) => ProviderToolProposal(
    providerCallId: 'same-provider-call',
    alias: 'proposal-$sequence',
    arguments: const {},
  );

  ToolInvocationActivity tool(
    int sequence, {
    bool done = false,
    String? alias,
    List<ToolActivityChange> changes = const [],
    ToolOutcomeActivity? outcome,
  }) => ToolInvocationActivity(
    id: ToolInvocationId('tool-$sequence'),
    preparedSequence: sequence + 10,
    modelInvocationId: modelId,
    proposalSequence: sequence,
    toolId: supported,
    alias: alias ?? 'tool-$sequence',
    providerCallId: 'same-provider-call',
    canonicalArguments: const {},
    changes: [
      ToolActivityChange(
        sequence: sequence + 10,
        kind: done ? ToolActivityKind.completed : ToolActivityKind.prepared,
      ),
      ...changes,
    ],
    outcome: outcome,
  );

  ModelOutputActivity native(int sequence, {bool safe = true}) =>
      ModelOutputActivity(
        sequence: sequence,
        item: ModelNativeOutput(
          providerItemId: 'same-provider-call',
          providerNativeMetadata: ModelNativeEnvelope(
            kind: 'dev.example.raw',
            compatibility: const {},
            data: const {'private': 'RAW-SECRET'},
          ),
          presentation: safe
              ? ModelNativePresentation(
                  kind: 'dev.example.safe',
                  compactText: 'Safe $sequence',
                  data: {'text': 'Rich $sequence'},
                )
              : null,
        ),
      );

  RunActivitySnapshot activity({
    String run = 'run',
    String? sessionId,
    String? invocationId,
    List<ModelOutputActivity>? outputs,
    List<ToolInvocationActivity> tools = const [],
    List<RejectedToolProposalActivity> rejected = const [],
    RunState state = RunState.waiting,
  }) => RunActivitySnapshot(
    runId: RunId(run),
    sessionId: sessionId == null ? session.id : SessionId(sessionId),
    state: state,
    sequence: 40,
    models: [
      ModelInvocationActivity(
        id: invocationId == null ? modelId : ModelInvocationId(invocationId),
        startSequence: 1,
        settlement: ModelSettlement.completed,
        terminalSequence: 10,
        outputs:
            outputs ??
            [
              for (final sequence in [2, 3, 4])
                ModelOutputActivity(
                  sequence: sequence,
                  item: ModelToolProposalOutput(proposal(sequence)),
                ),
            ],
      ),
    ],
    tools: tools,
    rejectedProposals: rejected,
  );

  ModelOutputInspectionTarget target(int sequence, {String run = 'run'}) =>
      ModelOutputInspectionTarget(
        sessionId: session.id,
        runId: RunId(run),
        modelInvocationId: modelId,
        outputSequence: sequence,
      );

  Widget frame(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  Widget card(
    RunActivitySnapshot? current, {
    ValueChanged<ModelOutputInspectionTarget>? inspect,
    SessionRunActivityStatus status = SessionRunActivityStatus.live,
  }) => InspectionHost(
    key: ValueKey(window.cards.first.id),
    card: window.cards.first,
    activity: current,
    status: status,
    heading: 'Ordered operations',
    extensions: extensions,
    onCollapse: () => window.collapse(window.cards.first.id),
    onExpand: () => window.expand(window.cards.first.id),
    onDismiss: () => window.dismiss(window.cards.first.id),
    onInspectOutput: inspect ?? (_) {},
  );

  setUp(() {
    extensions = ExtensionRegistry();
    window = WindowInspection()..presentSession(session);
    addTearDown(window.dispose);
  });

  testWidgets(
    'interrupted unfinished models retain exact Inspection admission',
    (tester) async {
      final current = RunActivitySnapshot(
        runId: RunId('interrupted'),
        sessionId: session.id,
        state: RunState.running,
        sequence: 5,
        models: [
          ModelInvocationActivity(
            id: modelId,
            startSequence: 1,
            outputs: [
              native(2),
              native(3, safe: false),
              ModelOutputActivity(
                sequence: 5,
                item: ModelToolProposalOutput(proposal(5)),
              ),
            ],
          ),
        ],
      );
      for (final status in [
        SessionRunActivityStatus.live,
        SessionRunActivityStatus.terminal,
      ]) {
        expect(
          window.inspectActivity(
            session: session,
            activity: current,
            modelInvocationId: modelId,
            status: status,
          ),
          isFalse,
        );
      }
      const status = SessionRunActivityStatus.interrupted;
      expect(
        window.inspectActivity(
          session: session,
          activity: current,
          modelInvocationId: modelId,
          status: status,
        ),
        isTrue,
      );
      final group = window.cards.single.id;
      expect(
        window.inspectOutput(
          session: session,
          activity: current,
          modelInvocationId: ModelInvocationId('wrong'),
          outputSequence: 2,
          status: status,
        ),
        isFalse,
      );
      for (final sequence in [3, 4, 6]) {
        expect(
          window.inspectOutput(
            session: session,
            activity: current,
            modelInvocationId: modelId,
            outputSequence: sequence,
            status: status,
          ),
          isFalse,
        );
      }
      final impostor = Session(
        id: session.id,
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      expect(
        window.inspectOutput(
          session: impostor,
          activity: current,
          modelInvocationId: modelId,
          outputSequence: 2,
          status: status,
        ),
        isFalse,
      );
      expect(
        window.inspectOutput(
          session: session,
          activity: current,
          modelInvocationId: modelId,
          outputSequence: 2,
          status: status,
          originCardId: group,
        ),
        isTrue,
      );
      await tester.pumpWidget(frame(card(current, status: status)));
      expect(find.text('Safe 2'), findsOneWidget);
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      expect(
        window.inspectOutput(
          session: session,
          activity: current,
          modelInvocationId: modelId,
          outputSequence: 5,
          status: status,
          originCardId: group,
        ),
        isTrue,
      );
      await tester.pumpWidget(frame(card(current, status: status)));
      expect(
        find.text('Interrupted Run. No proposal decision recorded.'),
        findsNWidgets(2),
      );
      expect(find.text('Waiting to be processed.'), findsNothing);
      expect(window.dismiss(group), isTrue);
      expect(
        window.inspectOutput(
          session: session,
          activity: current,
          modelInvocationId: modelId,
          outputSequence: 5,
          status: status,
          originCardId: group,
        ),
        isFalse,
      );
      window.presentSession(impostor);
      expect(window.cards, isEmpty);
      expect(
        window.inspectActivity(
          session: session,
          activity: current,
          modelInvocationId: modelId,
          status: status,
        ),
        isFalse,
      );
    },
  );

  testWidgets('groups contain compact rows in exact output order, never rich', (
    tester,
  ) async {
    int pluginActions = 0;
    final compactSources = <ToolActivityInspectionSource>[];
    final toolRegistration = extensions.register(
      point: toolActivityCompactPresentationContributions,
      id: ExtensionId('dev.example.compact-tool'),
      value: ToolActivityCompactPresentationContribution(
        toolId: supported,
        createPresentation: (source) {
          compactSources.add(source);
          return GestureDetector(
            onTap: () => pluginActions++,
            child: Text('Compact ${source.snapshot.id}'),
          );
        },
      ),
    );
    addTearDown(toolRegistration.close);
    final nativeRegistration = extensions.register(
      point: modelNativeActivityCompactPresentationContributions,
      id: ExtensionId('dev.example.compact-native'),
      value: ModelNativeActivityCompactPresentationContribution(
        presentationKind: 'dev.example.safe',
        createPresentation: (presentation) => TextButton(
          onPressed: () => pluginActions++,
          child: Text(presentation.compactText),
        ),
      ),
    );
    addTearDown(nativeRegistration.close);
    final current = activity(
      outputs: [
        native(8),
        ModelOutputActivity(
          sequence: 4,
          item: ModelToolProposalOutput(proposal(4)),
        ),
        native(2),
        native(5, safe: false),
        ModelOutputActivity(
          sequence: 3,
          item: ModelToolProposalOutput(proposal(3)),
        ),
      ],
      tools: [tool(4)],
    );
    window.inspectActivity(
      session: session,
      activity: current,
      modelInvocationId: modelId,
    );
    final selected = <ModelOutputInspectionTarget>[];
    await tester.pumpWidget(frame(card(current, inspect: selected.add)));
    expect(find.byType(ToolActivityInspectionHost), findsNothing);
    expect(find.byType(ModelNativeActivityInspectionHost), findsNothing);
    expect(find.byType(ModelNativeActivityCompactHost), findsNWidgets(2));
    expect(compactSources, hasLength(1));
    final labels = [
      'Safe 2',
      'Proposal: proposal-3',
      'Compact tool-4',
      'Safe 8',
    ];
    for (int i = 1; i < labels.length; i++) {
      expect(
        tester.getTopLeft(find.text(labels[i - 1])).dy,
        lessThan(tester.getTopLeft(find.text(labels[i])).dy),
      );
    }
    // Hit the body coordinates; only the enclosing row should receive the tap.
    await tester.tapAt(tester.getCenter(find.text('Proposal: proposal-3')));
    expect(selected.single.outputSequence, 3);
    expect(selected.single.runId, current.runId);
    expect(selected.single.modelInvocationId, modelId);
    await tester.tapAt(tester.getCenter(find.text('Compact tool-4')));
    await tester.tapAt(tester.getCenter(find.text('Safe 2')));
    expect(selected.map((target) => target.outputSequence), [3, 4, 2]);
    expect(
      pluginActions,
      0,
      reason: 'Compact bodies cannot intercept common row navigation.',
    );
    expect(find.textContaining('RAW-SECRET'), findsNothing);
    expect(find.text('Safe 5'), findsNothing);
    expect(current.tools.single.outcome, isNull);
  });

  testWidgets(
    'prepared rows retain logical position and compact source across updates',
    (tester) async {
      int creations = 0;
      final registration = extensions.register(
        point: toolActivityCompactPresentationContributions,
        id: ExtensionId('dev.example.compact'),
        value: ToolActivityCompactPresentationContribution(
          toolId: supported,
          createPresentation: (source) {
            creations++;
            return ListenableBuilder(
              listenable: source,
              builder: (_, _) => Text(
                '${source.snapshot.id}: ${source.snapshot.changes.last.kind.name}',
              ),
            );
          },
        ),
      );
      addTearDown(registration.close);
      var current = activity(tools: [tool(4), tool(2)]);
      window.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      await tester.pumpWidget(frame(card(current)));
      final occurrence = find.byWidgetPredicate(
        (widget) =>
            widget is ActivityOutputPresentation &&
            widget.target.outputSequence == 3,
      );
      final occurrenceElement = tester.element(occurrence);
      final retained = tester
          .widgetList<ToolActivityCompactHost>(
            find.byType(ToolActivityCompactHost),
          )
          .first
          .source;
      current = activity(tools: [tool(4), tool(3), tool(2, done: true)]);
      await tester.pumpWidget(frame(card(current)));
      await tester.pumpAndSettle();
      expect(tester.element(occurrence), same(occurrenceElement));
      expect(creations, 3);
      expect(
        tester
            .widgetList<ToolActivityCompactHost>(
              find.byType(ToolActivityCompactHost),
            )
            .first
            .source,
        same(retained),
      );
      expect(retained.snapshot, same(current.tools.last));
      expect(find.text('tool-2: completed'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('tool-3: prepared')).dy,
        lessThan(tester.getTopLeft(find.text('tool-4: prepared')).dy),
      );
      expect(find.byType(ToolActivityInspectionHost), findsNothing);
    },
  );

  testWidgets(
    'individual pending occurrence upgrades rich source without changing card',
    (tester) async {
      int creations = 0;
      final registration = extensions.register(
        point: toolActivityInspectionContributions,
        id: ExtensionId('dev.example.rich'),
        value: ToolActivityInspectionContribution(
          toolId: supported,
          createPresentation: (source) {
            creations++;
            return ListenableBuilder(
              listenable: source,
              builder: (_, _) =>
                  Text('Rich ${source.snapshot.changes.last.kind.name}'),
            );
          },
        ),
      );
      addTearDown(registration.close);
      var current = activity();
      window.inspectOutput(
        session: session,
        activity: current,
        modelInvocationId: modelId,
        outputSequence: 2,
      );
      final id = window.cards.single.id;
      await tester.pumpWidget(frame(card(current)));
      final hostElement = tester.element(find.byType(InspectionHost));
      expect(find.text('Waiting to be processed.'), findsNWidgets(2));
      current = activity(tools: [tool(2)]);
      await tester.pumpWidget(frame(card(current)));
      final richHost = tester.widget<ToolActivityInspectionHost>(
        find.byType(ToolActivityInspectionHost),
      );
      final richElement = tester.element(find.text('Rich prepared'));
      final compactSource = tester
          .widget<ToolActivityCompactHost>(find.byType(ToolActivityCompactHost))
          .source;
      expect(compactSource, isNot(same(richHost.source)));
      expect(find.text('Tool: tool-2'), findsOneWidget);
      window.collapse(id);
      await tester.pumpWidget(frame(card(current)));
      expect(find.text('Rich prepared'), findsNothing);
      expect(find.text('Tool: tool-2'), findsOneWidget);
      current = activity(tools: [tool(2, done: true)]);
      await tester.pumpWidget(frame(card(current)));
      window.expand(id);
      await tester.pumpWidget(frame(card(current)));
      await tester.pumpAndSettle();
      expect(creations, 1);
      expect(window.cards.single.id, same(id));
      expect(tester.element(find.byType(InspectionHost)), same(hostElement));
      expect(tester.element(find.text('Rich completed')), same(richElement));
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              find.byType(ToolActivityInspectionHost),
            )
            .source,
        same(richHost.source),
      );
      expect(richHost.source.snapshot, same(current.tools.single));
      expect(compactSource.snapshot, same(current.tools.single));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'individual native header is compact and body rich with safe data only',
    (tester) async {
      final received = <ModelNativePresentation>[];
      final registration = extensions.register(
        point: modelNativeActivityPresentationContributions,
        id: ExtensionId('dev.example.native-rich'),
        value: ModelNativeActivityPresentationContribution(
          presentationKind: 'dev.example.safe',
          createInspection: (presentation) {
            received.add(presentation);
            return Text(presentation.data['text']! as String);
          },
        ),
      );
      addTearDown(registration.close);
      final current = activity(outputs: [native(2)]);
      window.inspectOutput(
        session: session,
        activity: current,
        modelInvocationId: modelId,
        outputSequence: 2,
      );
      await tester.pumpWidget(frame(card(current)));
      expect(find.text('Safe 2'), findsOneWidget);
      expect(find.text('Rich 2'), findsOneWidget);
      expect(received, hasLength(1));
      expect(received.single.data, {'text': 'Rich 2'});
      expect(find.textContaining('RAW-SECRET'), findsNothing);
      window.collapse(window.cards.single.id);
      await tester.pumpWidget(frame(card(current)));
      expect(find.text('Safe 2'), findsOneWidget);
      expect(find.text('Rich 2'), findsNothing);
      window.expand(window.cards.single.id);
      await tester.pumpWidget(frame(card(current)));
      expect(received, hasLength(1));
    },
  );

  testWidgets('rejected and terminal unprocessed occurrences remain factual', (
    tester,
  ) async {
    final current = activity(
      state: RunState.failed,
      rejected: [
        RejectedToolProposalActivity(
          sequence: 39,
          modelInvocationId: modelId,
          proposalSequence: 3,
          proposal: proposal(3),
          kind: ToolProposalFailureKind.unknownAlias,
          message: 'PRIVATE-ERROR',
        ),
      ],
    );
    window.inspectActivity(
      session: session,
      activity: current,
      modelInvocationId: modelId,
    );
    await tester.pumpWidget(frame(card(current)));
    expect(find.text('Proposal rejected: unknownAlias.'), findsOneWidget);
    expect(find.text('Not processed before the Run ended.'), findsNWidgets(2));
    expect(find.textContaining('PRIVATE-ERROR'), findsNothing);
  });

  testWidgets(
    'Run failure labels rich waiting evidence without synthesizing an outcome',
    (tester) async {
      int creations = 0;
      final registration = extensions.register(
        point: toolActivityInspectionContributions,
        id: ExtensionId('dev.example.waiting'),
        value: ToolActivityInspectionContribution(
          toolId: supported,
          createPresentation: (_) {
            creations++;
            return const Text('Waiting for approval');
          },
        ),
      );
      addTearDown(registration.close);
      final waiting = tool(2);
      var current = activity(tools: [waiting]);
      window.inspectOutput(
        session: session,
        activity: current,
        modelInvocationId: modelId,
        outputSequence: 2,
      );
      await tester.pumpWidget(frame(card(current)));
      final element = tester.element(find.byType(ToolActivityInspectionHost));
      current = activity(tools: [waiting], state: RunState.failed);
      await tester.pumpWidget(frame(card(current)));
      expect(find.textContaining('Last observed activity:'), findsOneWidget);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(
        tester.element(find.byType(ToolActivityInspectionHost)),
        same(element),
      );
      expect(creations, 1);
      expect(waiting.outcome, isNull);
    },
  );

  for (final surface in ['direct', 'group', 'collapsed']) {
    testWidgets(
      'terminal $surface compact evidence is qualified without replacement',
      (tester) async {
        final registration = extensions.register(
          point: toolActivityCompactPresentationContributions,
          id: ExtensionId('dev.example.waiting-compact'),
          value: ToolActivityCompactPresentationContribution(
            toolId: supported,
            createPresentation: (_) => const Text('Waiting for approval'),
          ),
        );
        addTearDown(registration.close);
        final waiting = tool(2);
        var current = activity(
          tools: [waiting],
          outputs: [
            ModelOutputActivity(
              sequence: 2,
              item: ModelToolProposalOutput(proposal(2)),
            ),
          ],
        );
        if (surface == 'group') {
          window.inspectActivity(
            session: session,
            activity: current,
            modelInvocationId: modelId,
          );
        } else if (surface == 'collapsed') {
          window.inspectOutput(
            session: session,
            activity: current,
            modelInvocationId: modelId,
            outputSequence: 2,
          );
          window.collapse(window.cards.single.id);
        }
        Widget view() => frame(
          surface == 'direct'
              ? ActivityOutputPresentation(
                  extensions: extensions,
                  activity: current,
                  target: target(2),
                  compact: true,
                )
              : card(current),
        );
        await tester.pumpWidget(view());
        final source = tester
            .widget<ToolActivityCompactHost>(
              find.byType(ToolActivityCompactHost),
            )
            .source;
        final cards = window.cards;
        expect(find.text('Run ended; last observed activity.'), findsNothing);
        current = activity(
          tools: [waiting],
          outputs: current.models.single.outputs,
          state: RunState.failed,
        );
        await tester.pumpWidget(view());
        expect(find.text('Run ended; last observed activity.'), findsOneWidget);
        expect(find.text('Waiting for approval'), findsOneWidget);
        expect(
          tester
              .widget<ToolActivityCompactHost>(
                find.byType(ToolActivityCompactHost),
              )
              .source,
          same(source),
        );
        expect(window.cards, same(cards));
        expect(waiting.outcome, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'interrupted proposals retain decisions without appearing queued',
    (tester) async {
      final current = activity(
        rejected: [
          RejectedToolProposalActivity(
            sequence: 39,
            modelInvocationId: modelId,
            proposalSequence: 3,
            proposal: proposal(3),
            kind: ToolProposalFailureKind.unknownAlias,
            message: 'PRIVATE-ERROR',
          ),
        ],
      );
      window.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      await tester.pumpWidget(
        frame(card(current, status: SessionRunActivityStatus.interrupted)),
      );
      expect(find.text('INTERRUPTED ACTIVITY'), findsOneWidget);
      expect(
        find.text(
          'Last observed Run state: waiting. '
          'No authoritative Run outcome recorded.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Interrupted Run. No proposal decision recorded.'),
        findsNWidgets(2),
      );
      expect(find.text('Proposal rejected: unknownAlias.'), findsOneWidget);
      expect(find.text('Waiting to be processed.'), findsNothing);
      expect(find.textContaining('PRIVATE-ERROR'), findsNothing);
      expect(current.state, RunState.waiting);
      expect(current.tools, isEmpty);
    },
  );

  testWidgets(
    'interrupted approval evidence stays historical across collapse',
    (tester) async {
      int creations = 0;
      final registration = extensions.register(
        point: toolActivityInspectionContributions,
        id: ExtensionId('dev.example.interrupted-waiting'),
        value: ToolActivityInspectionContribution(
          toolId: supported,
          createPresentation: (_) {
            creations++;
            return const Text('Waiting for approval');
          },
        ),
      );
      addTearDown(registration.close);
      final waiting = tool(
        2,
        changes: [
          const ToolActivityChange(
            sequence: 13,
            kind: ToolActivityKind.policyEvaluated,
            policyDecision: ToolActivityPolicyDecision.ask,
          ),
          ToolActivityChange(
            sequence: 14,
            kind: ToolActivityKind.approvalRequested,
            interruptionId: RunInterruptionId('approval'),
          ),
        ],
      );
      final current = activity(tools: [waiting]);
      window.inspectOutput(
        session: session,
        activity: current,
        modelInvocationId: modelId,
        outputSequence: 2,
      );
      final id = window.cards.single.id;
      Widget view() =>
          frame(card(current, status: SessionRunActivityStatus.interrupted));
      await tester.pumpWidget(view());
      final source = tester
          .widget<ToolActivityInspectionHost>(
            find.byType(ToolActivityInspectionHost),
          )
          .source;
      expect(source.snapshot, same(waiting));
      expect(source.sessionId, session.id);
      expect(source.runId, current.runId);
      expect(
        find.text(
          'Interrupted Run; tool prepared, no execution start recorded.',
        ),
        findsNWidgets(2),
      );
      expect(
        find.text(
          'Recorded approvals are historical, not actionable. '
          'Last observed activity:',
        ),
        findsNWidgets(2),
      );
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.text('Allow once'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      window.collapse(id);
      await tester.pumpWidget(view());
      expect(find.text('Waiting for approval'), findsNothing);
      expect(
        find.text(
          'Interrupted Run; tool prepared, no execution start recorded.',
        ),
        findsOneWidget,
      );
      window.expand(id);
      await tester.pumpWidget(view());
      expect(window.cards.single.id, same(id));
      expect(creations, 1);
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              find.byType(ToolActivityInspectionHost),
            )
            .source,
        same(source),
      );
      expect(waiting.changes.last.kind, ToolActivityKind.approvalRequested);
      expect(waiting.changes.last.approved, isNull);
      expect(waiting.outcome, isNull);
      expect(current.state, RunState.waiting);
      expect(tester.takeException(), isNull);
    },
  );

  for (final compact in [true, false]) {
    testWidgets(
      'interrupted prepared and started evidence differ compact=$compact',
      (tester) async {
        final prepared = tool(2);
        final started = tool(
          3,
          changes: [
            const ToolActivityChange(
              sequence: 14,
              kind: ToolActivityKind.executionStarted,
            ),
            ToolActivityChange(
              sequence: 15,
              kind: ToolActivityKind.progress,
              progress: ToolProgress(content: 'Working'),
            ),
          ],
        );
        final current = activity(
          state: RunState.running,
          tools: [prepared, started],
        );
        await tester.pumpWidget(
          frame(
            Column(
              children: [
                for (final sequence in [2, 3])
                  ActivityOutputPresentation(
                    extensions: extensions,
                    activity: current,
                    status: SessionRunActivityStatus.interrupted,
                    target: target(sequence),
                    compact: compact,
                  ),
              ],
            ),
          ),
        );
        expect(
          find.text(
            'Interrupted Run; tool prepared, no execution start recorded.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Interrupted Run; execution started, no outcome recorded. '
            'Effects may have occurred.',
          ),
          findsOneWidget,
        );
        final sources = compact
            ? tester
                  .widgetList<ToolActivityCompactHost>(
                    find.byType(ToolActivityCompactHost),
                  )
                  .map((host) => host.source)
            : tester
                  .widgetList<ToolActivityInspectionHost>(
                    find.byType(ToolActivityInspectionHost),
                  )
                  .map((host) => host.source);
        expect(sources.first.snapshot, same(prepared));
        expect(sources.last.snapshot, same(started));
        expect(started.changes.last.progress?.content, 'Working');
        expect(
          sources.every((source) => source.snapshot.outcome == null),
          isTrue,
        );
        expect(current.state, RunState.running);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('interrupted Run preserves actual tool outcome facts', (
    tester,
  ) async {
    final registration = extensions.register(
      point: toolActivityInspectionContributions,
      id: ExtensionId('dev.example.outcome'),
      value: ToolActivityInspectionContribution(
        toolId: supported,
        createPresentation: (source) => ListenableBuilder(
          listenable: source,
          builder: (_, _) {
            final outcome = source.snapshot.outcome!;
            return Text(
              '${outcome.disposition.name}: ${outcome.effectCertainty.name}: '
              '${outcome.modelContent}',
            );
          },
        ),
      ),
    );
    addTearDown(registration.close);
    for (final (disposition, certainty) in [
      (ToolOutcomeDisposition.success, EffectCertainty.knownOccurred),
      (ToolOutcomeDisposition.policyDenied, EffectCertainty.knownNotOccurred),
      (ToolOutcomeDisposition.failure, EffectCertainty.uncertain),
    ]) {
      final outcome = ToolOutcomeActivity(
        disposition: disposition,
        effectCertainty: certainty,
        modelContent: 'Recorded result',
        failureKind: disposition == ToolOutcomeDisposition.failure
            ? ToolFailureKind.infrastructure
            : null,
      );
      final completed = tool(
        2,
        outcome: outcome,
        changes: [
          ToolActivityChange(
            sequence: 20,
            kind: ToolActivityKind.completed,
            outcome: outcome,
          ),
        ],
      );
      await tester.pumpWidget(
        frame(
          ActivityOutputPresentation(
            extensions: extensions,
            activity: activity(state: RunState.running, tools: [completed]),
            status: SessionRunActivityStatus.interrupted,
            target: target(2),
            compact: false,
          ),
        ),
      );
      final source = tester
          .widget<ToolActivityInspectionHost>(
            find.byType(ToolActivityInspectionHost),
          )
          .source;
      expect(source.snapshot, same(completed));
      expect(source.snapshot.outcome, same(outcome));
      expect(
        find.text('Interrupted Run; recorded tool outcome.'),
        findsOneWidget,
      );
      expect(
        find.text('${disposition.name}: ${certainty.name}: Recorded result'),
        findsOneWidget,
      );
      expect(find.textContaining('Effects may have occurred.'), findsNothing);
      expect(find.textContaining('no outcome recorded'), findsNothing);
    }
  });

  testWidgets(
    'interrupted native evidence retains safe fallbacks and exact retirement',
    (tester) async {
      final current = activity(outputs: [native(2)]);
      window.inspectOutput(
        session: session,
        activity: current,
        modelInvocationId: modelId,
        outputSequence: 2,
      );
      final id = window.cards.single.id;
      Widget view() =>
          frame(card(current, status: SessionRunActivityStatus.interrupted));
      await tester.pumpWidget(view());
      expect(find.text('Safe 2'), findsOneWidget);
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      expect(
        find.text('Interrupted Run; historical model activity.'),
        findsNWidgets(2),
      );
      int creations = 0;
      final received = <ModelNativePresentation>[];
      final contribution = ModelNativeActivityPresentationContribution(
        presentationKind: 'dev.example.safe',
        createInspection: (presentation) {
          received.add(presentation);
          return Text('Rich ${++creations}');
        },
      );
      final registration = extensions.register(
        point: modelNativeActivityPresentationContributions,
        id: ExtensionId('dev.example.interrupted-native'),
        value: contribution,
      );
      addTearDown(registration.close);
      await tester.pumpAndSettle();
      expect(find.text('Rich 1'), findsOneWidget);
      expect(received.single.data, {'text': 'Rich 2'});
      window.collapse(id);
      await tester.pumpWidget(view());
      window.expand(id);
      await tester.pumpWidget(view());
      expect(creations, 1);
      registration.close();
      await tester.pumpAndSettle();
      expect(find.text('Rich 1'), findsNothing);
      expect(find.text('Safe 2'), findsOneWidget);
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      final replacement = extensions.register(
        point: modelNativeActivityPresentationContributions,
        id: ExtensionId('dev.example.interrupted-native'),
        value: contribution,
      );
      addTearDown(replacement.close);
      await tester.pumpAndSettle();
      expect(find.text('Rich 2'), findsOneWidget);
      expect(creations, 2);
      expect(received.last, same(received.first));
      expect(window.cards.single.id, same(id));
      expect(find.textContaining('RAW-SECRET'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exact occurrence rejects mismatched Run, Session, model, or sequence',
    (tester) async {
      for (final status in SessionRunActivityStatus.values) {
        for (final current in [
          activity(run: 'wrong'),
          activity(sessionId: 'wrong'),
          activity(invocationId: 'wrong'),
          activity(outputs: [native(9)]),
          activity(outputs: [native(2, safe: false)]),
          null,
        ]) {
          await tester.pumpWidget(
            frame(
              ActivityOutputPresentation(
                extensions: extensions,
                activity: current,
                status: status,
                target: target(2),
                compact: true,
              ),
            ),
          );
          expect(find.text('Activity output is unavailable.'), findsOneWidget);
          expect(find.textContaining('RAW-SECRET'), findsNothing);
        }
      }
      final current = activity();
      window.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      await tester.pumpWidget(
        frame(
          card(
            activity(run: 'wrong'),
            status: SessionRunActivityStatus.interrupted,
          ),
        ),
      );
      expect(find.text('Activity is unavailable.'), findsOneWidget);
      expect(find.text('INTERRUPTED ACTIVITY'), findsNothing);
      expect(find.text('Ordered operations'), findsNothing);
      expect(find.byType(ActivityOutputPresentation), findsNothing);
    },
  );

  testWidgets('same tool identity in a different Run gets a fresh source', (
    tester,
  ) async {
    Widget output(String run) => frame(
      ActivityOutputPresentation(
        extensions: extensions,
        activity: activity(run: run, tools: [tool(2)]),
        target: target(2, run: run),
        compact: true,
      ),
    );
    await tester.pumpWidget(output('first'));
    final source = tester
        .widget<ToolActivityCompactHost>(find.byType(ToolActivityCompactHost))
        .source;
    expect(source.sessionId, session.id);
    expect(source.runId, RunId('first'));
    expect(source.snapshot.id, ToolInvocationId('tool-2'));
    await tester.pumpWidget(output('second'));
    final nextSource = tester
        .widget<ToolActivityCompactHost>(find.byType(ToolActivityCompactHost))
        .source;
    expect(nextSource.sessionId, session.id);
    expect(nextSource.runId, RunId('second'));
    expect(nextSource.snapshot.id, source.snapshot.id);
    expect(
      tester
          .widget<ToolActivityCompactHost>(find.byType(ToolActivityCompactHost))
          .source,
      isNot(same(source)),
    );
    expect(tester.takeException(), isNull);
  });

  for (final compact in [true, false]) {
    testWidgets(
      'terminal source preserves each canonical occurrence compact=$compact',
      (tester) async {
        final snapshot = activity(
          run: 'retained',
          state: RunState.completed,
          tools: [
            tool(2, alias: 'same-alias'),
            tool(3, alias: 'same-alias'),
          ],
        );
        await tester.pumpWidget(
          frame(
            Column(
              children: [
                for (final sequence in [2, 3])
                  ActivityOutputPresentation(
                    extensions: extensions,
                    activity: snapshot,
                    target: target(sequence, run: 'retained'),
                    compact: compact,
                  ),
              ],
            ),
          ),
        );
        final sources = compact
            ? tester
                  .widgetList<ToolActivityCompactHost>(
                    find.byType(ToolActivityCompactHost),
                  )
                  .map((host) => host.source)
                  .toList()
            : tester
                  .widgetList<ToolActivityInspectionHost>(
                    find.byType(ToolActivityInspectionHost),
                  )
                  .map((host) => host.source)
                  .toList();
        expect(sources.map((source) => source.sessionId), [
          session.id,
          session.id,
        ]);
        expect(sources.map((source) => source.runId), [
          RunId('retained'),
          RunId('retained'),
        ]);
        expect(sources.map((source) => source.snapshot.id), [
          ToolInvocationId('tool-2'),
          ToolInvocationId('tool-3'),
        ]);
        expect(
          sources.map((source) => source.snapshot.providerCallId).toSet(),
          {'same-provider-call'},
        );
      },
    );
  }

  testWidgets(
    'missing compact presenters use bounded escaped factual fallbacks',
    (tester) async {
      final label = 'Visible\n${'x' * 100000}';
      final current = activity(
        outputs: [
          ModelOutputActivity(
            sequence: 2,
            item: ModelToolProposalOutput(
              ProviderToolProposal(
                providerCallId: 'call',
                alias: label,
                arguments: const {},
              ),
            ),
          ),
          ModelOutputActivity(
            sequence: 3,
            item: ModelNativeOutput(
              providerNativeMetadata: ModelNativeEnvelope(
                kind: 'raw',
                compatibility: const {},
                data: const {'private': 'RAW-SECRET'},
              ),
              presentation: ModelNativePresentation(
                kind: 'unknown-safe-kind',
                compactText: label,
                data: const {
                  'summaryParts': ['DO-NOT-RENDER'],
                },
              ),
            ),
          ),
          ModelOutputActivity(
            sequence: 4,
            item: ModelToolProposalOutput(proposal(4)),
          ),
        ],
        tools: [tool(4, alias: label)],
      );
      window.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      await tester.pumpWidget(frame(card(current)));
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .where((text) => text.contains('Visible'))
          .toList();
      expect(labels, hasLength(3));
      for (final text in labels) {
        expect(text, contains(r'Visible\n'));
        expect(text, endsWith('...'));
        expect(text.length, lessThanOrEqualTo(170));
      }
      expect(find.textContaining('RAW-SECRET'), findsNothing);
      expect(find.textContaining('DO-NOT-RENDER'), findsNothing);
      expect(find.byType(ModelNativeActivityInspectionHost), findsNothing);
    },
  );
}
