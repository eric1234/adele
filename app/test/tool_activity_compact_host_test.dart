import 'dart:async';

import 'package:adele_desktop/ui/activity/tool_activity_compact_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final toolId = ToolId('dev.example.tool');
  late ExtensionRegistry registry;
  late _Source source;
  int factories = 0;
  int disposals = 0;

  setUp(() {
    registry = ExtensionRegistry();
    source = _Source(toolId);
    factories = 0;
    disposals = 0;
  });
  tearDown(() => source.dispose());

  ExtensionRegistration register({
    String id = 'dev.example.compact',
    ToolActivityCompactPresentationContribution? value,
    ExtensionRegistry? into,
  }) => (into ?? registry).register(
    point: toolActivityCompactPresentationContributions,
    id: ExtensionId(id),
    value:
        value ??
        ToolActivityCompactPresentationContribution(
          toolId: toolId,
          createPresentation: (received) {
            factories++;
            return _Probe(source: received, onDispose: () => disposals++);
          },
        ),
  );

  Widget host({
    _Source? value,
    ExtensionRegistry? extensions,
    String fallback = 'Factual tool evidence',
  }) => MaterialApp(
    home: ToolActivityCompactHost(
      extensions: extensions ?? registry,
      source: value ?? source,
      fallback: Text(fallback),
    ),
  );

  testWidgets('zero and rich-only matches preserve factual fallback', (
    tester,
  ) async {
    registry.register(
      point: toolActivityInspectionContributions,
      id: ExtensionId('dev.example.rich'),
      value: ToolActivityInspectionContribution(
        toolId: toolId,
        createPresentation: (_) => throw StateError('Not compact'),
      ),
    );
    await tester.pumpWidget(host());
    expect(find.text('Factual tool evidence'), findsOneWidget);
    expect(factories, 0);
    register();
    await tester.pumpAndSettle();
    expect(find.text('Prepared'), findsOneWidget);
    expect(find.text('Factual tool evidence'), findsNothing);
  });

  testWidgets('updates retain source, factory and view; unmount detaches', (
    tester,
  ) async {
    register();
    await tester.pumpWidget(host());
    final state = tester.state(find.byType(_Probe));
    source.update('Running');
    await tester.pumpWidget(host(fallback: 'New fallback'));
    expect(tester.state(find.byType(_Probe)), same(state));
    expect(find.text('Running'), findsOneWidget);
    expect(factories, 1);
    expect(source.hasObservers, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    source.update('Late');
    await tester.pump();
    expect(disposals, 1);
    expect(source.hasObservers, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ambiguity is explicit beside fallback and removal remounts', (
    tester,
  ) async {
    register();
    await tester.pumpWidget(host());
    final state = tester.state(find.byType(_Probe));
    final duplicate = register(id: 'dev.example.other');
    await tester.pumpAndSettle();
    expect(find.text('Factual tool evidence'), findsOneWidget);
    expect(
      find.text('Tool compact presentation is ambiguous.'),
      findsOneWidget,
    );
    expect(state.mounted, isFalse);
    expect(factories, 1);
    expect(disposals, 1);
    await duplicate.close();
    await tester.pumpAndSettle();
    expect(factories, 2);
    expect(tester.state(find.byType(_Probe)), isNot(same(state)));
  });

  for (final sameId in [true, false]) {
    testWidgets(
      'retirement and ${sameId ? 'same' : 'new'} ID remount the same value',
      (tester) async {
        final first = register();
        final value = ToolActivityCompactPresentationResolver(
          registry,
        ).resolve(toolId).value;
        await tester.pumpWidget(host());
        final state = tester.state(find.byType(_Probe));
        await first.close();
        register(
          id: sameId ? 'dev.example.compact' : 'dev.example.new',
          value: value,
        );
        await tester.pumpAndSettle();
        expect(state.mounted, isFalse);
        expect(disposals, 1);
        expect(factories, 2);
        expect(source.snapshot.canonicalArguments['label'], 'Prepared');
      },
    );
  }

  testWidgets(
    'failed factory is retained with current fallback, never retried',
    (tester) async {
      final failed = register(
        value: ToolActivityCompactPresentationContribution(
          toolId: toolId,
          createPresentation: (_) {
            factories++;
            throw StateError('PRIVATE-FACTORY-ERROR');
          },
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpWidget(host(fallback: 'Updated evidence'));
      expect(factories, 1);
      expect(find.text('Updated evidence'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      await failed.close();
      register();
      await tester.pumpAndSettle();
      expect(factories, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source failure and retirement inside factory preserve fallback',
    (tester) async {
      source.broken = true;
      register();
      await tester.pumpWidget(host());
      expect(find.text('Factual tool evidence'), findsOneWidget);
      expect(factories, 0);
      source.broken = false;
      final next = ExtensionRegistry();
      late ExtensionRegistration retired;
      retired = register(
        into: next,
        value: ToolActivityCompactPresentationContribution(
          toolId: toolId,
          createPresentation: (_) {
            unawaited(retired.close());
            return const Text('Must never mount');
          },
        ),
      );
      await tester.pumpWidget(host(extensions: next));
      await tester.pumpAndSettle();
      expect(find.text('Must never mount'), findsNothing);
      expect(find.text('Factual tool evidence'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source and registry replacements remount and detach old observation',
    (tester) async {
      final first = register();
      await tester.pumpWidget(host());
      final other = _Source(toolId);
      addTearDown(other.dispose);
      await tester.pumpWidget(host(value: other));
      expect(disposals, 1);
      expect(source.hasObservers, isFalse);
      final next = ExtensionRegistry();
      register(into: next);
      await tester.pumpWidget(host(value: other, extensions: next));
      expect(disposals, 2);
      final state = tester.state(find.byType(_Probe));
      await first.close();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Probe)), same(state));
    },
  );
}

class _Source extends ChangeNotifier implements ToolActivityInspectionSource {
  _Source(this.toolId) {
    update('Prepared');
  }
  final ToolId toolId;
  late ToolInvocationActivity _snapshot;
  bool broken = false;
  bool get hasObservers => hasListeners;
  @override
  ToolInvocationActivity get snapshot {
    if (broken) throw StateError('PRIVATE-SOURCE');
    return _snapshot;
  }

  void update(String label) {
    _snapshot = ToolInvocationActivity(
      id: ToolInvocationId('invocation'),
      preparedSequence: 2,
      modelInvocationId: ModelInvocationId('model'),
      proposalSequence: 1,
      toolId: toolId,
      alias: 'alias',
      providerCallId: 'call',
      canonicalArguments: {'label': label},
      changes: const [],
    );
    notifyListeners();
  }
}

class _Probe extends StatefulWidget {
  const _Probe({required this.source, required this.onDispose});
  final ToolActivityInspectionSource source;
  final VoidCallback onDispose;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  void changed() => setState(() {});
  @override
  void initState() {
    super.initState();
    widget.source.addListener(changed);
  }

  @override
  Widget build(BuildContext context) =>
      Text(widget.source.snapshot.canonicalArguments['label']! as String);
  @override
  void dispose() {
    widget.source.removeListener(changed);
    widget.onDispose();
    super.dispose();
  }
}
