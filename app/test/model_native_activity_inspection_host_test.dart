import 'dart:async';

import 'package:adele_desktop/ui/inspection/model_native_activity_inspection_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const kind = 'dev.example.native';
  late ExtensionRegistry extensions;
  late ModelNativePresentation presentation;
  late ModelNativeActivityPresentationContribution contribution;
  late Widget view;
  int factories = 0;
  int disposals = 0;

  setUp(() {
    extensions = ExtensionRegistry();
    presentation = ModelNativePresentation(
      kind: kind,
      compactText: 'Safe compact',
      data: const {'text': 'Safe detail'},
    );
    factories = disposals = 0;
    view = _Probe(onDispose: () => disposals++);
    contribution = ModelNativeActivityPresentationContribution(
      presentationKind: kind,
      createInspection: (received) {
        factories++;
        expect(received, same(presentation));
        expect(received.data, {'text': 'Safe detail'});
        return view;
      },
    );
  });

  ExtensionRegistration register({
    ModelNativeActivityPresentationContribution? value,
    String id = 'dev.example.presenter',
    ExtensionRegistry? registry,
  }) => (registry ?? extensions).register(
    point: modelNativeActivityPresentationContributions,
    id: ExtensionId(id),
    value: value ?? contribution,
  );

  Widget host({ExtensionRegistry? registry}) => MaterialApp(
    home: Scaffold(
      body: ModelNativeActivityInspectionHost(
        extensions: registry ?? extensions,
        presentation: presentation,
      ),
    ),
  );

  testWidgets(
    'missing and unrelated presenters show bounded rich-unavailable state',
    (tester) async {
      await tester.pumpWidget(host());
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      register(
        value: ModelNativeActivityPresentationContribution(
          presentationKind: 'unrelated',
          createInspection: (_) => throw _OpaqueFailure(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(host());
      expect(factories, 0);
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      register(id: 'dev.example.exact');
      await tester.pumpAndSettle();
      expect(find.byType(_Probe), findsOneWidget);
      expect(factories, 1);
    },
  );

  testWidgets(
    'rebuild and unrelated registry changes retain safe evidence and widget',
    (tester) async {
      register();
      await tester.pumpWidget(host());
      final state = tester.state<_ProbeState>(find.byType(_Probe));
      state.localValue = 'Retained';
      final unrelated = register(
        id: 'dev.example.other',
        value: ModelNativeActivityPresentationContribution(
          presentationKind: 'other',
          createInspection: (_) => const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
      await unrelated.close();
      await tester.pumpAndSettle();
      await tester.pumpWidget(host());
      expect(tester.state(find.byType(_Probe)), same(state));
      expect(state.localValue, 'Retained');
      expect(tester.widget(find.byType(_Probe)), same(view));
      expect(factories, 1);
      expect(disposals, 0);
    },
  );

  testWidgets('ambiguity calls no factory', (tester) async {
    register();
    register(id: 'dev.example.second');
    await tester.pumpWidget(host());
    expect(find.textContaining('ambiguous'), findsOneWidget);
    expect(factories, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new safe evidence remounts even with the same kind and widget', (
    tester,
  ) async {
    register();
    await tester.pumpWidget(host());
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    state.localValue = 'Discard';
    presentation = ModelNativePresentation(
      kind: kind,
      compactText: 'New safe compact',
      data: const {'text': 'Safe detail'},
    );
    await tester.pumpWidget(host());
    final fresh = tester.state<_ProbeState>(find.byType(_Probe));
    expect(fresh, isNot(same(state)));
    expect(fresh.localValue, isEmpty);
    expect(factories, 2);
    expect(disposals, 1);
  });

  testWidgets('added ambiguity disposes state and removal freshly resolves', (
    tester,
  ) async {
    register();
    await tester.pumpWidget(host());
    final state = tester.state<_ProbeState>(find.byType(_Probe));
    final duplicate = register(id: 'dev.example.second');
    await tester.pumpAndSettle();
    expect(find.textContaining('ambiguous'), findsOneWidget);
    expect(state.mounted, isFalse);
    expect(disposals, 1);
    await duplicate.close();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(_Probe)), isNot(same(state)));
    expect(factories, 2);
  });

  testWidgets(
    'retirement disposes presentation without changing safe evidence',
    (tester) async {
      final registration = register();
      await tester.pumpWidget(host());
      await registration.close();
      await tester.pumpAndSettle();
      expect(find.byType(_Probe), findsNothing);
      expect(disposals, 1);
      expect(
        find.text('Model native activity rich inspection is unavailable.'),
        findsOneWidget,
      );
      expect(presentation.data, {'text': 'Safe detail'});
    },
  );

  for (final sameId in [true, false]) {
    testWidgets(
      'replacement with ${sameId ? 'same' : 'different'} ID remounts same widget/value',
      (tester) async {
        final registration = register();
        await tester.pumpWidget(host());
        final state = tester.state<_ProbeState>(find.byType(_Probe));
        state.localValue = 'Discard';
        final closing = registration.close();
        register(
          id: sameId ? 'dev.example.presenter' : 'dev.example.replacement',
        );
        await closing;
        await tester.pumpAndSettle();
        final fresh = tester.state<_ProbeState>(find.byType(_Probe));
        expect(fresh, isNot(same(state)));
        expect(fresh.localValue, isEmpty);
        expect(disposals, 1);
        expect(factories, 2);
      },
    );
  }

  testWidgets(
    'factory failure is bounded and retried only on fresh generation',
    (tester) async {
      final failed = register(
        value: ModelNativeActivityPresentationContribution(
          presentationKind: kind,
          createInspection: (_) {
            factories++;
            throw _OpaqueFailure();
          },
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpWidget(host());
      expect(factories, 1);
      expect(
        find.text('Model native activity inspection could not be created.'),
        findsOneWidget,
      );
      expect(find.textContaining('secret'), findsNothing);
      expect(tester.takeException(), isNull);
      await failed.close();
      register();
      await tester.pumpAndSettle();
      expect(find.byType(_Probe), findsOneWidget);
    },
  );
  testWidgets('retirement during factory prevents mounting', (tester) async {
    late ExtensionRegistration registration;
    registration = register(
      value: ModelNativeActivityPresentationContribution(
        presentationKind: kind,
        createInspection: (_) {
          factories++;
          unawaited(registration.close());
          return view;
        },
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byType(_Probe), findsNothing);
    expect(factories, 1);
    expect(disposals, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'registry replacement detaches old notifications and unmount disposes',
    (tester) async {
      final original = register();
      await tester.pumpWidget(host());
      final next = ExtensionRegistry();
      final replacement = register(registry: next);
      await tester.pumpWidget(host(registry: next));
      final state = tester.state<_ProbeState>(find.byType(_Probe));
      await original.close();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Probe)), same(state));
      expect(disposals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await replacement.close();
      register(registry: next);
      await tester.pumpAndSettle();
      expect(disposals, 2);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _OpaqueFailure {
  @override
  String toString() => throw StateError('Never stringify opaque exceptions.');
}

final class _Probe extends StatefulWidget {
  const _Probe({required this.onDispose});
  final VoidCallback onDispose;

  @override
  State<_Probe> createState() => _ProbeState();
}

final class _ProbeState extends State<_Probe> {
  String localValue = '';

  @override
  Widget build(BuildContext context) => const Text('Safe detail');

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}
