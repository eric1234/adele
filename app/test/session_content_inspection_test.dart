import 'dart:async';

import 'package:adele_desktop/ui/inspection/activity_inspection_selection.dart';
import 'package:adele_desktop/ui/inspection/inspection_host.dart';
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
  final kind = SessionContentKind('dev.example.note');
  final id = ExtensionId('dev.example.inspector');
  late WindowInspection window;
  late ExtensionRegistry extensions;

  ExtensionRegistration register(
    FutureOr<Widget> Function(SessionContentInspectionContext) factory, {
    ExtensionId? registrationId,
  }) => extensions.register(
    point: sessionContentInspectionContributions,
    id: registrationId ?? id,
    value: SessionContentInspectionContribution(
      kind: kind,
      createPresentation: factory,
    ),
  );

  bool open(String occurrence, {Session? from}) => window.inspectContent(
    session: from ?? session,
    kind: kind,
    occurrenceId: SessionContentOccurrenceId(occurrence),
    extensions: extensions,
  );

  Widget frame() => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ListenableBuilder(
          listenable: window,
          builder: (_, _) => InspectionStackHost(
            cards: window.cards,
            cardBuilder: (_, card) => InspectionHost(
              card: card,
              activity: null,
              heading: 'Unused activity heading',
              extensions: extensions,
              onCollapse: () => window.collapse(card.id),
              onExpand: () => window.expand(card.id),
              onDismiss: () => window.dismiss(card.id),
              onInspectOutput: (_) => fail('Semantic cards have no outputs'),
            ),
          ),
        ),
      ),
    ),
  );

  setUp(() {
    window = WindowInspection()..presentSession(session);
    extensions = ExtensionRegistry();
    addTearDown(window.dispose);
  });

  test(
    'no activity identities; canonical Session cannot be selected by ID',
    () {
      register((_) => const Text('detail'));
      final copiedSession = Session(
        id: session.id,
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      expect(open('first', from: copiedSession), isFalse);
      expect(open('first'), isTrue);
      final card = window.cards.single;
      final target = card.target as SessionContentInspectionTarget;
      expect(target.sessionId, session.id);
      expect(target.kind, kind);
      expect(target.occurrenceId.value, 'first');
      expect(target, isNot(isA<ActivityInspectionTarget>()));
      expect(card.content!.session, same(session));
      window.presentSession(copiedSession);
      expect(card.content!.isActive, isFalse);
      expect(window.cards, isEmpty);
      expect(open('first'), isFalse);
      expect(open('first', from: copiedSession), isTrue);
    },
  );

  test('missing and ambiguous resolution do not publish invented content', () {
    expect(
      () => open('first'),
      throwsA(isA<SessionContentInspectionUnavailable>()),
    );
    register((_) => const Text('one'));
    register(
      (_) => const Text('two'),
      registrationId: ExtensionId('dev.example.other'),
    );
    expect(
      () => open('first'),
      throwsA(isA<AmbiguousSessionContentInspection>()),
    );
    expect(window.cards, isEmpty);
  });

  testWidgets('collapse retains exact view; dismiss revokes only that card', (
    tester,
  ) async {
    var created = 0;
    register((context) {
      created++;
      return Text('Detail ${context.occurrenceId.value}');
    });
    open('one');
    final first = window.cards.single;
    await tester.pumpWidget(frame());
    await tester.pumpAndSettle();
    final element = tester.element(find.text('Detail one'));
    open('two');
    final second = window.cards.first;
    await tester.pumpAndSettle();
    expect(window.cards.last.id, same(first.id));
    expect(created, 2);
    window.collapse(first.id);
    await tester.pumpAndSettle();
    expect(find.text('Detail one'), findsNothing);
    expect(first.content!.isActive, isTrue);
    window.expand(first.id);
    await tester.pumpAndSettle();
    expect(tester.element(find.text('Detail one')), same(element));
    expect(created, 2);
    window.dismiss(first.id);
    expect(first.content!.isActive, isFalse);
    expect(second.content!.isActive, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Detail two'), findsOneWidget);
    open('one');
    expect(window.cards.first.id, isNot(same(first.id)));
    await tester.pumpAndSettle();
    expect(created, 3);
    expect(find.text('Detail one'), findsOneWidget);
  });

  testWidgets('retirement never follows same-ID replacement; fresh open can', (
    tester,
  ) async {
    final original = register((_) => const Text('Original'));
    open('one');
    final first = window.cards.single;
    await tester.pumpWidget(frame());
    await tester.pumpAndSettle();
    await original.close();
    expect(first.content!.isActive, isFalse);
    register((_) => const Text('Replacement'));
    await tester.pumpAndSettle();
    expect(find.text('Original'), findsNothing);
    expect(find.text('Replacement'), findsNothing);
    expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
    open('one');
    await tester.pumpAndSettle();
    expect(find.text('Replacement'), findsOneWidget);
    expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
  });

  testWidgets('remounting one card never retries or recaptures its factory', (
    tester,
  ) async {
    var attempts = 0;
    register((_) => Text('Captured ${++attempts}'));
    open('one');
    expect(
      attempts,
      1,
      reason: 'Capture belongs to admission, not first mount.',
    );
    await tester.pumpWidget(frame());
    await tester.pumpAndSettle();
    expect(find.text('Captured 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(frame());
    await tester.pumpAndSettle();
    expect(find.text('Captured 1'), findsOneWidget);
    expect(attempts, 1);
  });

  test(
    'factory failure is observed even if dismissed before first mount',
    () async {
      register((_) => throw StateError('private diagnostic'));
      open('unmounted');
      final card = window.cards.single;
      window.dismiss(card.id);
      // Let the failure settle with no mounted host or test consumer attached.
      await Future<void>.delayed(Duration.zero);
      await expectLater(card.content!.presentation, throwsStateError);
    },
  );

  testWidgets('accepted shutdown revokes contexts but retains card identity', (
    tester,
  ) async {
    final delayed = Completer<Widget>();
    register((_) => delayed.future);
    open('one');
    final card = window.cards.single;
    await tester.pumpWidget(frame());
    window.retire();
    expect(window.cards.single, same(card));
    expect(card.content!.isActive, isFalse);
    expect(open('one'), isFalse);
    expect(window.dismiss(card.id), isFalse);
    window.presentSession(session);
    expect(open('one'), isFalse);
    delayed.complete(const Text('Late shutdown detail'));
    await tester.pumpAndSettle();
    expect(find.text('Late shutdown detail'), findsNothing);
    expect(find.text('one'), findsOneWidget);
    expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
  });

  for (final departure in ['dismiss', 'session', 'retire']) {
    testWidgets('late factory cannot publish after $departure', (tester) async {
      final delayed = Completer<Widget>();
      final registration = register(
        (context) => context.occurrenceId.value == 'slow'
            ? delayed.future
            : const Text('Healthy'),
      );
      open('healthy');
      open('slow');
      final slow = window.cards.first;
      await tester.pumpWidget(frame());
      await tester.pump();
      switch (departure) {
        case 'dismiss':
          window.dismiss(slow.id);
        case 'session':
          window.presentSession(null);
          window.presentSession(session);
          open('healthy');
        case 'retire':
          await registration.close();
          register((_) => const Text('Fresh'));
          open('healthy');
      }
      delayed.complete(const Text('Late detail'));
      await tester.pumpAndSettle();
      expect(find.text('Late detail'), findsNothing);
      expect(slow.content!.isActive, isFalse);
      expect(
        find.text(departure == 'retire' ? 'Fresh' : 'Healthy'),
        findsOneWidget,
      );
    });
  }

  testWidgets('failed factories are contained and never retried on rebuild', (
    tester,
  ) async {
    var attempts = 0;
    register((context) {
      if (context.occurrenceId.value == 'bad') {
        attempts++;
        throw StateError('private diagnostic');
      }
      return const Text('Independent detail');
    });
    open('good');
    open('bad');
    await tester.pumpWidget(frame());
    await tester.pumpAndSettle();
    expect(find.text('Independent detail'), findsOneWidget);
    expect(find.text('Content Inspection is unavailable.'), findsOneWidget);
    expect(find.textContaining('private diagnostic'), findsNothing);
    window.collapse(window.cards.first.id);
    window.expand(window.cards.first.id);
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(tester.takeException(), isNull);
  });
}
