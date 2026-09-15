import 'dart:async';

import 'package:adele_desktop/ui/activity/model_native_activity_compact_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const kind = 'dev.example.safe';
  late ExtensionRegistry registry;
  late ModelNativePresentation evidence;
  int factories = 0;
  int disposals = 0;
  setUp(() {
    registry = ExtensionRegistry();
    evidence = ModelNativePresentation(
      kind: kind,
      compactText: 'Safe summary',
      data: const {},
    );
    factories = 0;
    disposals = 0;
  });

  ExtensionRegistration register({
    String id = 'dev.example.compact',
    ModelNativeActivityCompactPresentationContribution? value,
    ExtensionRegistry? into,
  }) => (into ?? registry).register(
    point: modelNativeActivityCompactPresentationContributions,
    id: ExtensionId(id),
    value:
        value ??
        ModelNativeActivityCompactPresentationContribution(
          presentationKind: kind,
          createPresentation: (received) {
            factories++;
            return _Probe(
              text: received.compactText,
              onDispose: () => disposals++,
            );
          },
        ),
  );
  Widget host({
    ExtensionRegistry? extensions,
    ModelNativePresentation? presentation,
    String fallback = 'Factual safe evidence',
  }) => MaterialApp(
    home: ModelNativeActivityCompactHost(
      extensions: extensions ?? registry,
      presentation: presentation ?? evidence,
      fallback: Text(fallback),
    ),
  );

  testWidgets('missing and rich-only contributions preserve safe evidence', (
    tester,
  ) async {
    registry.register(
      point: modelNativeActivityPresentationContributions,
      id: ExtensionId('dev.example.rich'),
      value: ModelNativeActivityPresentationContribution(
        presentationKind: kind,
        createInspection: (_) => throw StateError('Not compact'),
      ),
    );
    await tester.pumpWidget(host());
    expect(find.text('Factual safe evidence'), findsOneWidget);
    register();
    await tester.pumpAndSettle();
    expect(find.text('Safe summary'), findsOneWidget);
    expect(factories, 1);
  });

  testWidgets('rebuild retains the view while new evidence remounts', (
    tester,
  ) async {
    register();
    await tester.pumpWidget(host());
    final state = tester.state(find.byType(_Probe));
    await tester.pumpWidget(host(fallback: 'New fallback'));
    expect(tester.state(find.byType(_Probe)), same(state));
    expect(factories, 1);
    await tester.pumpWidget(
      host(
        presentation: ModelNativePresentation(
          kind: kind,
          compactText: 'New summary',
          data: const {},
        ),
      ),
    );
    expect(state.mounted, isFalse);
    expect(disposals, 1);
    expect(find.text('New summary'), findsOneWidget);
  });

  testWidgets(
    'ambiguity retains fallback, disposes old view and invokes no competitor',
    (tester) async {
      register();
      await tester.pumpWidget(host());
      final duplicate = register(id: 'dev.example.duplicate');
      await tester.pumpAndSettle();
      expect(find.text('Factual safe evidence'), findsOneWidget);
      expect(
        find.text('Model native activity compact presentation is ambiguous.'),
        findsOneWidget,
      );
      expect(factories, 1);
      expect(disposals, 1);
      await duplicate.close();
      await tester.pumpAndSettle();
      expect(factories, 2);
    },
  );

  for (final sameId in [true, false]) {
    testWidgets(
      'retired ${sameId ? 'same' : 'different'} ID cannot retain old state',
      (tester) async {
        final first = register();
        final value = ModelNativeActivityCompactPresentationResolver(
          registry,
        ).resolve(kind).value;
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
        expect(evidence.compactText, 'Safe summary');
      },
    );
  }

  testWidgets(
    'factory failures retain binding and refreshed factual fallback',
    (tester) async {
      final failed = register(
        value: ModelNativeActivityCompactPresentationContribution(
          presentationKind: kind,
          createPresentation: (_) {
            factories++;
            throw _OpaqueFailure();
          },
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpWidget(host(fallback: 'Updated facts'));
      expect(factories, 1);
      expect(find.text('Updated facts'), findsOneWidget);
      await failed.close();
      register();
      await tester.pumpAndSettle();
      expect(factories, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('retirement inside a factory never mounts its result', (
    tester,
  ) async {
    late ExtensionRegistration registration;
    registration = register(
      value: ModelNativeActivityCompactPresentationContribution(
        presentationKind: kind,
        createPresentation: (_) {
          unawaited(registration.close());
          return const Text('Must never mount');
        },
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('Must never mount'), findsNothing);
    expect(find.text('Factual safe evidence'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('registry replacement and unmount detach old notifications', (
    tester,
  ) async {
    final first = register();
    await tester.pumpWidget(host());
    final next = ExtensionRegistry();
    final second = register(into: next);
    await tester.pumpWidget(host(extensions: next));
    final state = tester.state(find.byType(_Probe));
    await first.close();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(_Probe)), same(state));
    expect(disposals, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await second.close();
    register(into: next);
    await tester.pumpAndSettle();
    expect(disposals, 2);
    expect(tester.takeException(), isNull);
  });
}

class _OpaqueFailure {
  @override
  String toString() => throw StateError('Never expose this exception.');
}

class _Probe extends StatefulWidget {
  const _Probe({required this.text, required this.onDispose});
  final String text;
  final VoidCallback onDispose;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => Text(widget.text);
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}
