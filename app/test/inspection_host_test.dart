import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/inspection/model_native_activity_inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final Session session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('strategy'),
  );
  final ModelInvocationId modelId = ModelInvocationId('model');
  final ToolId supported = ToolId('dev.example.supported');
  late ExtensionRegistry extensions;
  late WindowInspection window;

  ProviderToolProposal proposal(String alias) => ProviderToolProposal(
    providerCallId: 'same-provider-call',
    alias: alias,
    arguments: const {},
  );

  ToolInvocationActivity tool(
    int sequence, {
    ToolId? toolId,
    bool done = false,
  }) => ToolInvocationActivity(
    id: ToolInvocationId('tool-$sequence'),
    preparedSequence: sequence + 10,
    modelInvocationId: modelId,
    proposalSequence: sequence,
    toolId: toolId ?? supported,
    alias: 'same-alias',
    providerCallId: 'same-provider-call',
    canonicalArguments: const {},
    changes: [
      ToolActivityChange(
        sequence: sequence + 10,
        kind: done ? ToolActivityKind.completed : ToolActivityKind.prepared,
      ),
    ],
  );

  RunActivitySnapshot activity({
    String run = 'run',
    List<ToolInvocationActivity> tools = const [],
    List<RejectedToolProposalActivity> rejected = const [],
    RunState state = RunState.waiting,
  }) => RunActivitySnapshot(
    runId: RunId(run),
    sessionId: session.id,
    state: state,
    sequence: 40,
    models: [
      ModelInvocationActivity(
        id: modelId,
        startSequence: 1,
        settlement: ModelSettlement.completed,
        terminalSequence: 5,
        outputs: [
          for (final sequence in [2, 3, 4])
            ModelOutputActivity(
              sequence: sequence,
              item: ModelToolProposalOutput(proposal('proposal-$sequence')),
            ),
        ],
      ),
    ],
    tools: tools,
    rejectedProposals: rejected,
  );

  setUp(() {
    extensions = ExtensionRegistry();
    window = WindowInspection()..presentSession(session);
    addTearDown(window.dispose);
  });

  testWidgets('window opens, replaces, and closes only exact selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = activity();
    final second = activity(run: 'other-run');
    RunActivitySnapshot current = first;
    StateSetter? refresh;
    window.addListener(() => refresh?.call(() {}));
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return AdeleShell(
              project: Project(
                id: ProjectId('project'),
                sourceLocation: Uri.parse('file:///project'),
              ),
              selectors: const [],
              onSelectProject: (_) {},
              sessionControls: Column(
                children: [
                  const Text('Main Session'),
                  const TextField(),
                  TextButton(
                    onPressed: () => window.inspectActivity(
                      session: session,
                      activity: current,
                      modelInvocationId: modelId,
                    ),
                    child: const Text('Inspect group'),
                  ),
                ],
              ),
              inspection: window.selection == null
                  ? null
                  : InspectionHost(
                      selection: window.selection!,
                      activity: current,
                      heading: current.runId == first.runId
                          ? 'First group'
                          : 'Second group',
                      extensions: extensions,
                      onClose: window.clear,
                    ),
            );
          },
        ),
      ),
    );
    expect(find.byType(InspectionHost), findsNothing);
    await tester.enterText(find.byType(TextField), 'Retained draft');
    await tester.tap(find.text('Inspect group'));
    await tester.pumpAndSettle();
    expect(find.text('First group'), findsOneWidget);
    expect(find.text('Waiting to be processed.'), findsNWidgets(3));
    expect(
      tester.getTopLeft(find.byType(InspectionHost)).dx,
      greaterThan(tester.getTopRight(find.text('Main Session')).dx),
    );
    final selected = window.selection;
    expect(
      window.inspectActivity(
        session: session,
        activity: first,
        modelInvocationId: modelId,
      ),
      isTrue,
    );
    expect(window.selection, same(selected));
    current = second;
    await tester.tap(find.text('Inspect group'));
    await tester.pumpAndSettle();
    expect(find.text('First group'), findsNothing);
    expect(find.text('Second group'), findsOneWidget);
    expect(window.selection!.runId, second.runId);
    expect(window.selection!.modelInvocationId, modelId);
    await tester.tap(find.byTooltip('Close Inspection'));
    await tester.pumpAndSettle();
    expect(find.byType(InspectionHost), findsNothing);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byType(TextField),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      'Retained draft',
    );
    expect(first.state, RunState.waiting);
    expect(second.tools, isEmpty);
    refresh = null;
  });

  testWidgets('proposal order includes unresolved and rejected occurrences', (
    tester,
  ) async {
    int creations = 0;
    final registration = extensions.register(
      point: toolActivityInspectionContributions,
      id: ExtensionId('dev.example.presenter'),
      value: ToolActivityInspectionContribution(
        toolId: supported,
        createPresentation: (source) {
          creations++;
          return ListenableBuilder(
            listenable: source,
            builder: (context, _) => Text(
              '${source.snapshot.id.value}: ${source.snapshot.changes.last.kind.name}',
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
    Widget host() => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: InspectionHost(
            selection: window.selection!,
            activity: current,
            heading: 'Ordered operations',
            extensions: extensions,
            onClose: window.clear,
          ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    expect(creations, 2);
    expect(
      tester.getTopLeft(find.text('tool-2: prepared')).dy,
      lessThan(tester.getTopLeft(find.text('Proposal: proposal-3')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Proposal: proposal-3')).dy,
      lessThan(tester.getTopLeft(find.text('tool-4: prepared')).dy),
    );
    current = activity(
      tools: [tool(4), tool(2, done: true)],
      rejected: [
        RejectedToolProposalActivity(
          sequence: 39,
          modelInvocationId: modelId,
          proposalSequence: 3,
          proposal: proposal('proposal-3'),
          kind: ToolProposalFailureKind.unknownAlias,
          message: 'Unknown proposal',
        ),
      ],
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(
      creations,
      2,
      reason: 'Live snapshots retain presentation resources.',
    );
    expect(find.text('tool-2: completed'), findsOneWidget);
    expect(find.textContaining('Proposal rejected:'), findsOneWidget);
    expect(find.byType(ToolActivityInspectionHost), findsNWidgets(2));
  });

  testWidgets(
    'unsupported tool and terminal unprocessed proposal stay bounded',
    (tester) async {
      final current = activity(
        tools: [tool(2, toolId: ToolId('unsupported'))],
        state: RunState.failed,
      );
      window.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InspectionHost(
              selection: window.selection!,
              activity: current,
              heading: 'Failed Run',
              extensions: extensions,
              onClose: window.clear,
            ),
          ),
        ),
      );
      expect(find.textContaining('unavailable'), findsOneWidget);
      expect(
        find.text(
          'Run ended without a terminal tool result. Last observed activity:',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Not processed before the Run ended.'),
        findsNWidgets(2),
      );
      expect(current.tools.single.toolId, ToolId('unsupported'));
    },
  );

  testWidgets('Run failure marks retained waiting tool state as historical', (
    tester,
  ) async {
    int creations = 0;
    final registration = extensions.register(
      point: toolActivityInspectionContributions,
      id: ExtensionId('dev.example.waiting-presentation'),
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
    window.inspectActivity(
      session: session,
      activity: current,
      modelInvocationId: modelId,
    );
    final selection = window.selection;
    Widget host() => MaterialApp(
      home: Scaffold(
        body: InspectionHost(
          selection: selection!,
          activity: current,
          heading: 'Retained group',
          extensions: extensions,
          onClose: window.clear,
        ),
      ),
    );
    await tester.pumpWidget(host());
    final Element presentation = find
        .byType(ToolActivityInspectionHost)
        .evaluate()
        .single;
    expect(find.textContaining('Last observed activity:'), findsNothing);
    current = activity(tools: [waiting], state: RunState.failed);
    await tester.pumpWidget(host());
    expect(find.textContaining('Last observed activity:'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(
      find.byType(ToolActivityInspectionHost).evaluate().single,
      same(presentation),
    );
    expect(creations, 1);
    expect(window.selection, same(selection));
    expect(
      waiting.outcome,
      isNull,
      reason: 'Presentation must not synthesize a terminal tool result.',
    );
  });

  testWidgets(
    'narrow Inspection and main Session remain scrollable without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final current = activity();
      window.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AdeleShell(
            project: Project(
              id: ProjectId('project'),
              sourceLocation: Uri.parse('file:///project'),
            ),
            selectors: const [],
            onSelectProject: (_) {},
            sessionControls: const TextField(),
            inspection: InspectionHost(
              selection: window.selection!,
              activity: current,
              heading:
                  'A longer heading that wraps in a narrow Inspection surface',
              extensions: extensions,
              onClose: window.clear,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InspectionHost), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Proposal: proposal-4'));
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'Session change, unknown groups, and disposal reject stale selection',
    () {
      final current = activity();
      expect(
        window.inspectActivity(
          session: session,
          activity: current,
          modelInvocationId: ModelInvocationId('missing'),
        ),
        isFalse,
      );
      window.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      final other = Session(
        id: SessionId('other'),
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      window.presentSession(other);
      expect(window.selection, isNull);
      expect(
        window.inspectActivity(
          session: session,
          activity: current,
          modelInvocationId: modelId,
        ),
        isFalse,
      );
      window.presentSession(null);
      expect(window.selection, isNull);
      final disposed = WindowInspection()..presentSession(session);
      disposed.dispose();
      expect(
        disposed.inspectActivity(
          session: session,
          activity: current,
          modelInvocationId: modelId,
        ),
        isFalse,
      );
    },
  );

  testWidgets('mismatched retained Run cannot retarget selected group', (
    tester,
  ) async {
    final current = activity();
    window.inspectActivity(
      session: session,
      activity: current,
      modelInvocationId: modelId,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: InspectionHost(
          selection: window.selection!,
          activity: activity(run: 'wrong-run'),
          heading: 'Never retarget',
          extensions: extensions,
          onClose: window.clear,
        ),
      ),
    );
    expect(find.text('Activity is unavailable.'), findsOneWidget);
    expect(find.text('Never retarget'), findsNothing);
  });

  testWidgets(
    'native and tool occurrences interleave by sequence, not provider IDs',
    (tester) async {
      final received = <ModelNativePresentation>[];
      final nativeRegistration = extensions.register(
        point: modelNativeActivityPresentationContributions,
        id: ExtensionId('dev.example.native'),
        value: ModelNativeActivityPresentationContribution(
          presentationKind: 'dev.example.safe',
          createInspection: (presentation) {
            received.add(presentation);
            return Text(presentation.data['text']! as String);
          },
        ),
      );
      addTearDown(nativeRegistration.close);
      final toolRegistration = extensions.register(
        point: toolActivityInspectionContributions,
        id: ExtensionId('dev.example.tool'),
        value: ToolActivityInspectionContribution(
          toolId: supported,
          createPresentation: (source) => Text('Tool ${source.snapshot.id}'),
        ),
      );
      addTearDown(toolRegistration.close);
      ModelOutputActivity native(int sequence, String? presentationKind) =>
          ModelOutputActivity(
            sequence: sequence,
            item: ModelNativeOutput(
              providerItemId: 'same-provider-call',
              presentation: presentationKind == null
                  ? null
                  : ModelNativePresentation(
                      kind: presentationKind,
                      compactText: 'Native',
                      data: {'text': 'Native $sequence'},
                    ),
              providerNativeMetadata: ModelNativeEnvelope(
                kind: 'dev.example.safe',
                compatibility: const {},
                data: {
                  'approvedText': 'Raw must never classify $sequence',
                  'private': 'opaque secret',
                },
              ),
            ),
          );
      final outputs = [
        native(8, 'dev.example.safe'),
        native(2, 'dev.example.safe'),
        native(5, null),
        native(6, 'unknown-safe-kind'),
        ModelOutputActivity(
          sequence: 4,
          item: ModelToolProposalOutput(proposal('tool')),
        ),
      ];
      RunActivitySnapshot current(String run) => RunActivitySnapshot(
        runId: RunId(run),
        sessionId: session.id,
        state: RunState.completed,
        sequence: 20,
        models: [
          ModelInvocationActivity(
            id: modelId,
            startSequence: 1,
            settlement: ModelSettlement.completed,
            terminalSequence: 9,
            outputs: outputs,
          ),
        ],
        tools: [tool(4, done: true)],
      );
      Widget host(String run) => MaterialApp(
        home: Scaffold(
          body: InspectionHost(
            selection: ActivityInspectionSelection(
              sessionId: session.id,
              runId: RunId(run),
              modelInvocationId: modelId,
            ),
            activity: current(run),
            heading: 'Mixed',
            extensions: extensions,
            onClose: () {},
          ),
        ),
      );
      await tester.pumpWidget(host('first'));
      expect(received, hasLength(2));
      expect(
        tester.getTopLeft(find.text('Native 2')).dy,
        lessThan(tester.getTopLeft(find.text('Tool tool-4')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Tool tool-4')).dy,
        lessThan(tester.getTopLeft(find.text('Native 8')).dy),
      );
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      expect(find.byType(ModelNativeActivityInspectionHost), findsNWidgets(3));
      expect(
        tester.getTopLeft(find.text('Tool tool-4')).dy,
        lessThan(tester.getTopLeft(find.textContaining('rich inspection')).dy),
      );
      expect(
        tester.getTopLeft(find.textContaining('rich inspection')).dy,
        lessThan(tester.getTopLeft(find.text('Native 8')).dy),
      );
      expect(find.textContaining('opaque'), findsNothing);
      expect(find.text('Native 5'), findsNothing);
      expect(find.text('Native 6'), findsNothing);
      expect(find.textContaining('Raw must never classify'), findsNothing);
      for (final output in outputs) {
        if (output.item case final ModelNativeOutput native) {
          expect(
            native.providerNativeMetadata.data['private'],
            'opaque secret',
          );
        }
      }
      await tester.pumpWidget(host('first'));
      expect(received, hasLength(2));
      await tester.pumpWidget(host('second'));
      expect(
        received,
        hasLength(4),
        reason: 'Run identity changes remount each native occurrence.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'window accepts exact completed native-only evidence, not unknown or unsettled models',
    () {
      RunActivitySnapshot evidence(ModelSettlement? settlement) =>
          RunActivitySnapshot(
            runId: RunId('native-run'),
            sessionId: session.id,
            state: RunState.completed,
            sequence: 4,
            models: [
              ModelInvocationActivity(
                id: modelId,
                startSequence: 1,
                settlement: settlement,
                outputs: [
                  ModelOutputActivity(
                    sequence: 2,
                    item: ModelNativeOutput(
                      providerNativeMetadata: ModelNativeEnvelope(
                        kind: 'fixture',
                        compatibility: const {},
                        data: const {},
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
      expect(
        window.inspectActivity(
          session: session,
          activity: evidence(null),
          modelInvocationId: modelId,
        ),
        isFalse,
      );
      expect(
        window.inspectActivity(
          session: session,
          activity: evidence(ModelSettlement.completed),
          modelInvocationId: ModelInvocationId('unknown'),
        ),
        isFalse,
      );
      expect(
        window.inspectActivity(
          session: session,
          activity: evidence(ModelSettlement.completed),
          modelInvocationId: modelId,
        ),
        isTrue,
      );
      expect(window.selection!.runId, RunId('native-run'));
    },
  );
}
