import 'dart:async';

import 'package:adele_desktop/ui/inspection/tool_activity_inspection_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ToolId toolId = ToolId('dev.adele.test.tool');
  late ExtensionRegistry extensions;
  late _Source source;

  setUp(() {
    extensions = ExtensionRegistry();
    source = _Source(toolId);
  });

  ExtensionRegistration register(
    ToolActivityInspectionContribution contribution, {
    String id = 'dev.adele.test.inspection',
    ExtensionRegistry? registry,
  }) => (registry ?? extensions).register(
    point: toolActivityInspectionContributions,
    id: ExtensionId(id),
    value: contribution,
  );

  Widget host({_Source? value, ExtensionRegistry? registry}) => MaterialApp(
    home: Scaffold(
      body: ToolActivityInspectionHost(
        source: value ?? source,
        extensions: registry ?? extensions,
      ),
    ),
  );

  testWidgets(
    'zero and unrelated matches are unavailable; exact registration updates',
    (tester) async {
      final unrelated = _Presenter(
        'Unrelated',
        ToolId('${toolId.value}.other'),
      );
      register(unrelated.contribution);
      await tester.pumpWidget(host());
      expect(
        find.text('Tool activity inspection is unavailable.'),
        findsOneWidget,
      );
      expect(unrelated.sources, isEmpty);
      final exact = _Presenter('Exact', ToolId(toolId.value));
      register(exact.contribution, id: 'dev.adele.test.exact');
      await tester.pumpAndSettle();
      expect(find.text('Exact'), findsOneWidget);
      expect(exact.sources.single, same(source));
    },
  );

  testWidgets(
    'source updates, rebuilds and unrelated registry changes retain widget/state',
    (tester) async {
      final presenter = _Presenter('Inspection', toolId);
      register(presenter.contribution);
      await tester.pumpWidget(host());
      final state = tester.state<_ProbeState>(find.byType(_Probe));
      final Widget view = tester.widget(find.byType(_Probe));
      await tester.enterText(find.byType(TextField), 'Local state');
      source.update('Live outcome');
      await tester.pumpAndSettle();
      await tester.pumpWidget(host());
      final unrelated = register(
        _Presenter('Unrelated', ToolId('other')).contribution,
        id: 'dev.adele.test.other',
      );
      await tester.pumpAndSettle();
      await unrelated.close();
      await tester.pumpAndSettle();
      expect(presenter.sources, [source]);
      expect(presenter.mounts, 1);
      expect(presenter.disposals, 0);
      expect(tester.widget(find.byType(_Probe)), same(view));
      expect(tester.state(find.byType(_Probe)), same(state));
      expect(state.controller.text, 'Local state');
      expect(find.text('Live outcome'), findsOneWidget);
    },
  );

  testWidgets('initial ambiguity invokes neither factory', (tester) async {
    final first = _Presenter('First', toolId);
    final second = _Presenter('Second', toolId);
    register(first.contribution);
    register(second.contribution, id: 'dev.adele.test.second');
    await tester.pumpWidget(host());
    expect(
      find.textContaining('Tool activity inspection is ambiguous'),
      findsOneWidget,
    );
    expect(first.sources, isEmpty);
    expect(second.sources, isEmpty);
  });

  testWidgets('source read failure is bounded without invoking a factory', (
    tester,
  ) async {
    final presenter = _Presenter('Inspection', toolId);
    register(presenter.contribution);
    source.fail = true;
    await tester.pumpWidget(host());
    expect(find.textContaining('the source could not be read'), findsOneWidget);
    expect(find.textContaining('private source detail'), findsNothing);
    expect(presenter.sources, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('added ambiguity disposes old state; removal freshly resolves', (
    tester,
  ) async {
    final first = _Presenter('First', toolId);
    final second = _Presenter('Second', toolId);
    register(first.contribution);
    await tester.pumpWidget(host());
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    await tester.enterText(find.byType(TextField), 'Discard me');
    final duplicate = register(
      second.contribution,
      id: 'dev.adele.test.second',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Tool activity inspection is ambiguous'),
      findsOneWidget,
    );
    expect(state.mounted, isFalse);
    expect(first.disposals, 1);
    expect(second.sources, isEmpty);
    expect(source.listening, isFalse);
    await duplicate.close();
    await tester.pumpAndSettle();
    final fresh = tester.state<_ProbeState>(find.byType(_Probe));
    expect(fresh, isNot(same(state)));
    expect(fresh.controller.text, isEmpty);
    expect(first.sources, [source, source]);
  });

  testWidgets(
    'retirement disposes presentation but preserves observation data',
    (tester) async {
      final presenter = _Presenter('Inspection', toolId);
      final registration = register(presenter.contribution);
      await tester.pumpWidget(host());
      final snapshot = source.snapshot;
      await registration.close();
      await tester.pumpAndSettle();
      expect(
        find.text('Tool activity inspection is unavailable.'),
        findsOneWidget,
      );
      expect(presenter.disposals, 1);
      expect(source.listening, isFalse);
      expect(source.snapshot, same(snapshot));
    },
  );

  for (final bool sameId in [true, false]) {
    testWidgets(
      'replacement with ${sameId ? 'same' : 'different'} ID and same widget remounts',
      (tester) async {
        final presenter = _Presenter('Inspection', toolId);
        final old = register(presenter.contribution);
        await tester.pumpWidget(host());
        final state = tester.state<_ProbeState>(find.byType(_Probe));
        await tester.enterText(find.byType(TextField), 'Discard me');
        final closing = old.close();
        register(
          presenter.contribution,
          id: sameId
              ? 'dev.adele.test.inspection'
              : 'dev.adele.test.replacement',
        );
        await closing;
        await tester.pumpAndSettle();
        final fresh = tester.state<_ProbeState>(find.byType(_Probe));
        expect(state.mounted, isFalse);
        expect(fresh, isNot(same(state)));
        expect(fresh.controller.text, isEmpty);
        expect(presenter.mounts, 2);
        expect(presenter.disposals, 1);
        expect(presenter.sources, [source, source]);
        expect(tester.widget(find.byType(_Probe)), same(presenter.view));
      },
    );
  }

  testWidgets('failed factory is bounded and retried only for a fresh binding', (
    tester,
  ) async {
    int attempts = 0;
    final failed = register(
      ToolActivityInspectionContribution(
        toolId: toolId,
        createPresentation: (received) {
          expect(received, same(source));
          attempts++;
          throw StateError('Private unbounded factory detail');
        },
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpWidget(host());
    source.update('New outcome');
    register(
      _Presenter('Other', ToolId('other')).contribution,
      id: 'dev.adele.test.other',
    );
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(
      find.text(
        'Tool activity inspection is unavailable: the presentation could not be created.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Private unbounded'), findsNothing);
    expect(tester.takeException(), isNull);
    await failed.close();
    register(_Presenter('Replacement', toolId).contribution);
    await tester.pumpAndSettle();
    expect(find.text('Replacement'), findsOneWidget);
  });

  testWidgets('retirement before/during factory prevents mounting', (
    tester,
  ) async {
    final presenter = _Presenter('Retired', toolId);
    final retired = register(presenter.contribution);
    await retired.close();
    await tester.pumpWidget(host());
    expect(presenter.sources, isEmpty);
    late ExtensionRegistration registration;
    registration = register(
      ToolActivityInspectionContribution(
        toolId: toolId,
        createPresentation: (_) {
          unawaited(registration.close());
          return presenter.view;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(presenter.mounts, 0);
    expect(find.byType(_Probe), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('different source identity remounts even for the same snapshot', (
    tester,
  ) async {
    final presenter = _Presenter('Inspection', toolId);
    register(presenter.contribution);
    await tester.pumpWidget(host());
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    final next = _Source(toolId)..value = source.snapshot;
    await tester.pumpWidget(host(value: next));
    expect(presenter.sources, [source, next]);
    expect(state.mounted, isFalse);
    expect(source.listening, isFalse);
    expect(next.listening, isTrue);
    expect(presenter.disposals, 1);
  });

  testWidgets(
    'registry identity remounts and old registry notifications detach',
    (tester) async {
      final presenter = _Presenter('Inspection', toolId);
      final old = register(presenter.contribution);
      await tester.pumpWidget(host());
      final next = ExtensionRegistry();
      final replacement = register(presenter.contribution, registry: next);
      await tester.pumpWidget(host(registry: next));
      final state = tester.state<_ProbeState>(find.byType(_Probe));
      await old.close();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Probe)), same(state));
      expect(presenter.sources, [source, source]);
      await replacement.close();
      await tester.pumpAndSettle();
      expect(presenter.disposals, 2);
    },
  );

  testWidgets(
    'unmount disposes listeners; late registry/source changes are harmless',
    (tester) async {
      final presenter = _Presenter('Inspection', toolId);
      final registration = register(presenter.contribution);
      await tester.pumpWidget(host());
      await tester.pumpWidget(const SizedBox.shrink());
      await registration.close();
      register(presenter.contribution);
      source.update('Late');
      await tester.pumpAndSettle();
      expect(presenter.disposals, 1);
      expect(source.listening, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Source extends ChangeNotifier implements ToolActivityInspectionSource {
  _Source(ToolId toolId)
    : value = ToolInvocationActivity(
        id: ToolInvocationId('tool-1'),
        preparedSequence: 2,
        modelInvocationId: ModelInvocationId('model-1'),
        proposalSequence: 1,
        toolId: toolId,
        alias: 'arbitrary_alias',
        providerCallId: 'call-1',
        canonicalArguments: const {},
        changes: const [],
      );

  ToolInvocationActivity value;
  bool fail = false;
  bool get listening => hasListeners;
  @override
  ToolInvocationActivity get snapshot {
    if (fail) throw StateError('private source detail');
    return value;
  }

  void update(String content) {
    value = ToolInvocationActivity(
      id: value.id,
      preparedSequence: value.preparedSequence,
      modelInvocationId: value.modelInvocationId,
      proposalSequence: value.proposalSequence,
      toolId: value.toolId,
      alias: value.alias,
      providerCallId: value.providerCallId,
      canonicalArguments: value.canonicalArguments,
      changes: value.changes,
      outcome: ToolOutcomeActivity(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: content,
      ),
    );
    notifyListeners();
  }
}

class _Presenter {
  _Presenter(this.label, this.toolId);
  final String label;
  final ToolId toolId;
  final List<ToolActivityInspectionSource> sources = [];
  int mounts = 0;
  int disposals = 0;
  late final Widget view = _Probe(this);
  late final contribution = ToolActivityInspectionContribution(
    toolId: toolId,
    createPresentation: (source) {
      sources.add(source);
      return view;
    },
  );
}

class _Probe extends StatefulWidget {
  const _Probe(this.presenter);
  final _Presenter presenter;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final controller = TextEditingController();
  late final ToolActivityInspectionSource source;
  @override
  void initState() {
    super.initState();
    widget.presenter.mounts++;
    source = widget.presenter.sources.last;
    source.addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(widget.presenter.label),
      Text(source.snapshot.outcome?.modelContent ?? 'Pending'),
      TextField(controller: controller),
    ],
  );
  @override
  void dispose() {
    source.removeListener(_changed);
    widget.presenter.disposals++;
    controller.dispose();
    super.dispose();
  }
}
