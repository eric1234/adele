import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
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
  late WindowInspection window;
  late ExtensionRegistry extensions;
  RunActivitySnapshot activity({
    String run = 'run',
    ModelSettlement? settlement = ModelSettlement.completed,
  }) => RunActivitySnapshot(
    runId: RunId(run),
    sessionId: session.id,
    state: RunState.waiting,
    sequence: 20,
    models: [
      ModelInvocationActivity(
        id: modelId,
        startSequence: 1,
        terminalSequence: 5,
        settlement: settlement,
        outputs: [
          ModelOutputActivity(
            sequence: 2,
            item: ModelToolProposalOutput(
              ProviderToolProposal(
                providerCallId: 'same-provider-call',
                alias: 'read_file',
                arguments: const {},
              ),
            ),
          ),
          ModelOutputActivity(
            sequence: 3,
            item: ModelTextOutput('Final answer'),
          ),
          ModelOutputActivity(
            sequence: 4,
            item: ModelNativeOutput(
              providerNativeMetadata: ModelNativeEnvelope(
                kind: 'raw',
                compatibility: const {},
                data: const {'private': 'secret'},
              ),
            ),
          ),
        ],
      ),
    ],
    tools: [
      ToolInvocationActivity(
        id: ToolInvocationId('same-tool-id'),
        preparedSequence: 10,
        modelInvocationId: modelId,
        proposalSequence: 2,
        toolId: ToolId('dev.example.tool'),
        alias: 'read_file',
        providerCallId: 'same-provider-call',
        canonicalArguments: const {},
        changes: const [
          ToolActivityChange(sequence: 10, kind: ToolActivityKind.prepared),
        ],
      ),
    ],
  );
  bool group(RunActivitySnapshot current, {Session? from}) =>
      window.inspectActivity(
        session: from ?? session,
        activity: current,
        modelInvocationId: modelId,
      );
  bool output(
    RunActivitySnapshot current, {
    Session? from,
    InspectionCardId? origin,
    int sequence = 2,
  }) => window.inspectOutput(
    session: from ?? session,
    activity: current,
    modelInvocationId: modelId,
    outputSequence: sequence,
    originCardId: origin,
  );

  setUp(() {
    window = WindowInspection()..presentSession(session);
    extensions = ExtensionRegistry();
    addTearDown(window.dispose);
  });

  test(
    'every explicit open prepends a fresh immutable card, including duplicates',
    () {
      final current = activity();
      expect(group(current), isTrue);
      final first = window.cards;
      expect(group(current), isTrue);
      expect(output(current), isTrue);
      expect(window.cards, hasLength(3));
      expect(window.cards.last, same(first.single));
      expect(window.cards.map((card) => card.id).toSet(), hasLength(3));
      expect(window.cards.first.target, isA<ModelOutputInspectionTarget>());
      expect(
        window.cards.last.target,
        isA<ActivityGroupInspectionTarget>(),
        reason:
            'An explicitly requested group remains a group even with one output.',
      );
      expect(first, hasLength(1));
      expect(() => window.cards.clear(), throwsUnsupportedError);
      expect(() => first.add(window.cards.first), throwsUnsupportedError);
      final target = window.cards.first.target as ModelOutputInspectionTarget;
      expect(target.sessionId, session.id);
      expect(target.runId, current.runId);
      expect(target.modelInvocationId, modelId);
      expect(target.outputSequence, 2);
    },
  );

  test(
    'collapse expand dismiss target exact IDs and do not mutate old snapshots',
    () {
      final current = activity();
      group(current);
      output(current);
      final before = window.cards;
      final groupId = before.last.id;
      final individualId = before.first.id;
      int changes = 0;
      window.addListener(() => changes++);
      expect(window.collapse(groupId), isTrue);
      expect(window.cards.last.isCollapsed, isTrue);
      expect(window.cards.first, same(before.first));
      expect(before.last.isCollapsed, isFalse);
      expect(window.collapse(groupId), isTrue);
      expect(changes, 1);
      expect(window.expand(groupId), isTrue);
      expect(window.cards.last.isCollapsed, isFalse);
      expect(window.dismiss(groupId), isTrue);
      expect(window.cards.single.id, same(individualId));
      expect(window.dismiss(groupId), isFalse);
      expect(window.collapse(groupId), isFalse);
      expect(window.expand(groupId), isFalse);
      expect(changes, 3);
      expect(current.state, RunState.waiting);
      expect(current.tools.single.outcome, isNull);
    },
  );

  test(
    'group-origin callbacks cannot reopen after dismissal or target a different group',
    () {
      final current = activity();
      group(current);
      final original = window.cards.single.id;
      expect(output(activity(run: 'wrong-run'), origin: original), isFalse);
      expect(output(current, origin: original), isTrue);
      final individual = window.cards.first.id;
      expect(output(current, origin: individual), isFalse);
      window.dismiss(original);
      group(current);
      expect(
        output(current, origin: original),
        isFalse,
        reason: 'A new identical group must not revive the old callback.',
      );
      expect(window.cards, hasLength(2));
      window.clear();
      expect(output(current, origin: original), isFalse);
    },
  );

  test(
    'Session object replacement clears cards and rejects stale controls and opens',
    () {
      final current = activity();
      group(current);
      final oldId = window.cards.single.id;
      final replacement = Session(
        id: session.id,
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      window.presentSession(replacement);
      expect(window.cards, isEmpty);
      expect(group(current), isFalse);
      expect(output(current), isFalse);
      expect(group(current, from: replacement), isTrue);
      final replacementId = window.cards.single.id;
      expect(replacementId, isNot(same(oldId)));
      expect(output(current, from: replacement, origin: oldId), isFalse);
      expect(window.dismiss(oldId), isFalse);
      expect(window.collapse(oldId), isFalse);
      expect(window.expand(oldId), isFalse);
      window.presentSession(null);
      expect(window.cards, isEmpty);
      window.presentSession(session);
      group(current);
      expect(window.cards.single.id, isNot(same(oldId)));
      expect(window.cards.single.id, isNot(same(replacementId)));
    },
  );

  test(
    'unknown nonpresentable unsettled and disposed targets are rejected',
    () {
      final current = activity();
      expect(group(activity(settlement: null)), isFalse);
      expect(output(activity(settlement: ModelSettlement.incomplete)), isFalse);
      for (final sequence in [3, 4, 99]) {
        expect(output(current, sequence: sequence), isFalse);
      }
      expect(
        window.inspectActivity(
          session: session,
          activity: current,
          modelInvocationId: ModelInvocationId('unknown'),
        ),
        isFalse,
      );
      final disposed = WindowInspection()..presentSession(session);
      disposed.inspectActivity(
        session: session,
        activity: current,
        modelInvocationId: modelId,
      );
      final id = disposed.cards.single.id;
      disposed.dispose();
      expect(
        disposed.inspectOutput(
          session: session,
          activity: current,
          modelInvocationId: modelId,
          outputSequence: 2,
        ),
        isFalse,
      );
      expect(disposed.collapse(id), isFalse);
      expect(disposed.expand(id), isFalse);
      expect(disposed.dismiss(id), isFalse);
      expect(disposed.cards, isEmpty);
    },
  );

  testWidgets(
    'stack prepends independent cards and stale row callbacks cannot repopulate it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final current = activity();
      final registration = extensions.register(
        point: toolActivityInspectionContributions,
        id: ExtensionId('dev.example.rich'),
        value: ToolActivityInspectionContribution(
          toolId: current.tools.single.toolId,
          createPresentation: (_) => const Text('Rich detail'),
        ),
      );
      addTearDown(registration.close);
      group(current);
      final groupId = window.cards.single.id;
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: window,
            builder: (_, _) => AdeleShell(
              project: Project(
                id: ProjectId('project'),
                sourceLocation: Uri.parse('file:///project'),
              ),
              selectors: const [],
              onSelectProject: (_) {},
              sessionControls: const TextField(),
              inspection: window.cards.isEmpty
                  ? null
                  : InspectionStackHost(
                      cards: window.cards,
                      cardBuilder: (context, retained) => InspectionHost(
                        card: retained,
                        activity: current,
                        heading: 'Group',
                        extensions: extensions,
                        onCollapse: () => window.collapse(retained.id),
                        onExpand: () => window.expand(retained.id),
                        onDismiss: () => window.dismiss(retained.id),
                        onInspectOutput: (target) => window.inspectOutput(
                          session: session,
                          activity: current,
                          modelInvocationId: target.modelInvocationId,
                          outputSequence: target.outputSequence,
                          originCardId: retained.id,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Retained draft');
      final editor = find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      );
      final composer = tester.widget<EditableText>(editor).controller;
      final retainedAction = tester
          .widget<TextButton>(find.byType(TextButton))
          .onPressed!;
      retainedAction();
      await tester.pumpAndSettle();
      final firstIndividual = window.cards.first.id;
      final source = tester
          .widget<ToolActivityInspectionHost>(
            find.byType(ToolActivityInspectionHost),
          )
          .source;
      final richElement = tester.element(find.text('Rich detail'));
      expect(window.cards.last.id, same(groupId));
      expect(
        tester.getTopLeft(find.byKey(ValueKey(firstIndividual))).dy,
        lessThan(tester.getTopLeft(find.byKey(ValueKey(groupId))).dy),
      );
      retainedAction();
      await tester.pumpAndSettle();
      expect(window.cards, hasLength(3));
      expect(find.text('Rich detail'), findsNWidgets(2));
      final newestId = window.cards.first.id;
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(firstIndividual)),
          matching: find.byTooltip('Collapse Inspection'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Rich detail'), findsOneWidget);
      expect(window.cards.first.isCollapsed, isFalse);
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(newestId)),
          matching: find.byTooltip('Dismiss Inspection'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey(firstIndividual)),
          matching: find.byTooltip('Expand Inspection'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.element(find.text('Rich detail')), same(richElement));
      expect(
        tester
            .widget<ToolActivityInspectionHost>(
              find.byType(ToolActivityInspectionHost),
            )
            .source,
        same(source),
      );
      window.dismiss(groupId);
      retainedAction();
      await tester.pumpAndSettle();
      expect(window.cards.single.id, same(firstIndividual));
      window.dismiss(firstIndividual);
      await tester.pumpAndSettle();
      retainedAction();
      await tester.pumpAndSettle();
      expect(window.cards, isEmpty);
      expect(find.byType(InspectionHost), findsNothing);
      expect(tester.widget<EditableText>(editor).controller, same(composer));
      expect(find.text('Retained draft'), findsOneWidget);
      expect(current.tools.single.outcome, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide and narrow stack is independently scrollable and preserves composer on resize',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final current = activity();
      for (int i = 0; i < 8; i++) {
        group(current);
      }
      Widget shell() => MaterialApp(
        home: AdeleShell(
          project: Project(
            id: ProjectId('project'),
            sourceLocation: Uri.parse('file:///project'),
          ),
          selectors: const [],
          onSelectProject: (_) {},
          sessionControls: const Column(
            children: [Text('Main Session'), TextField()],
          ),
          inspectionScrollController: scroll,
          inspection: InspectionStackHost(
            cards: window.cards,
            cardBuilder: (context, retained) => InspectionHost(
              card: retained,
              activity: current,
              heading: 'A long activity heading that wraps on narrow windows',
              extensions: extensions,
              onCollapse: () {},
              onExpand: () {},
              onDismiss: () {},
              onInspectOutput: (_) {},
            ),
          ),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      await tester.pumpWidget(shell());
      await tester.enterText(find.byType(TextField), 'Draft across resize');
      final composer = tester.element(find.byType(TextField));
      final firstCard = find.byKey(ValueKey(window.cards.first.id));
      expect(
        tester.getTopLeft(firstCard).dx,
        greaterThan(tester.getTopRight(find.text('Main Session')).dx),
      );
      await tester.binding.setSurfaceSize(const Size(360, 640));
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsNWidgets(2));
      expect(tester.element(find.byType(TextField)), same(composer));
      expect(find.text('Draft across resize'), findsOneWidget);
      expect(
        tester.getTopLeft(firstCard).dy,
        greaterThan(
          tester.getTopLeft(find.byType(SingleChildScrollView).first).dy,
        ),
      );
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      final firstElement = tester.element(firstCard);
      final mainScroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(SingleChildScrollView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final mainOffset = mainScroll.pixels;
      group(current);
      await tester.pumpWidget(shell());
      await tester.pumpAndSettle();
      expect(
        scroll.offset,
        0,
        reason: 'Explicit prepend reveals the newest card.',
      );
      expect(mainScroll.pixels, mainOffset);
      expect(tester.element(firstCard), same(firstElement));
      expect(
        find.byKey(ValueKey(window.cards.first.id)).hitTestable(),
        findsOneWidget,
      );
      scroll.jumpTo(100);
      window.collapse(window.cards.last.id);
      await tester.pumpWidget(shell());
      await tester.pumpAndSettle();
      expect(
        scroll.offset,
        100,
        reason: 'Collapse does not reset the viewport.',
      );
      window.dismiss(window.cards.first.id);
      await tester.pumpWidget(shell());
      await tester.pumpAndSettle();
      expect(
        scroll.offset,
        100,
        reason: 'Dismissal does not count as a new open.',
      );
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(TextField)), same(composer));
      expect(tester.takeException(), isNull);
    },
  );
}
