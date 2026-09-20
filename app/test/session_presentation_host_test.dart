import 'dart:async';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/ui/session/session_presentation_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final OrchestrationStrategyId strategyId = OrchestrationStrategyId(
    'dev.adele.test.strategy',
  );
  final OrchestrationStrategyId otherStrategyId = OrchestrationStrategyId(
    'dev.adele.test.other-strategy',
  );
  late ExtensionRegistry extensions;
  late Session session;

  setUp(() {
    extensions = ExtensionRegistry();
    session = Session(
      id: SessionId('session-1'),
      taskId: TaskId('task-1'),
      strategyId: strategyId,
    );
  });

  ExtensionRegistration register(
    SessionPresentationContribution contribution, {
    String id = 'dev.adele.test.presentation',
    ExtensionRegistry? registry,
  }) => (registry ?? extensions).register(
    point: sessionPresentationContributions,
    id: ExtensionId(id),
    value: contribution,
  );

  Widget host({Session? value, ExtensionRegistry? registry, Key? key}) =>
      MaterialApp(
        home: Scaffold(
          body: SessionPresentationHost(
            key: key,
            session: value ?? session,
            extensions: registry ?? extensions,
          ),
        ),
      );

  testWidgets(
    'exit retention never remounts or disposes a retired presentation',
    (tester) async {
      final retaining = ValueNotifier(false);
      final presenter = _Presenter('Original', strategyId);
      final registration = register(presenter.contribution);
      final binding = SessionPresentationResolver(
        extensions,
      ).resolve(strategyId);
      await tester.pumpWidget(
        PreparedFrontendRetention(notifier: retaining, child: host()),
      );
      final state = tester.state<_ProbeState>(find.byType(_Probe));
      await tester.enterText(find.byType(TextField), 'Retained draft');
      retaining.value = true;
      await registration.close();
      final replacement = _Presenter('Replacement', strategyId);
      register(replacement.contribution);
      await tester.pumpAndSettle();
      expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
      expect(tester.state(find.byType(_Probe)), same(state));
      expect(state.controller.text, 'Retained draft');
      expect(presenter.disposals, 0);
      expect(replacement.mounts, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(presenter.disposals, 1);
      retaining.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no presentation is unavailable and later registration is observed',
    (tester) async {
      await tester.pumpWidget(host());
      expect(find.text('Session presentation is unavailable.'), findsOneWidget);
      final _Presenter presenter = _Presenter('Presentation', strategyId);
      register(presenter.contribution);
      await tester.pumpAndSettle();

      expect(find.text('Presentation'), findsOneWidget);
      expect(presenter.sessions, <Session>[session]);
      expect(presenter.sessions.single, same(session));
      expect(presenter.mounts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an unrelated strategy cannot present the Session', (
    tester,
  ) async {
    final _Presenter unrelated = _Presenter('Unrelated', otherStrategyId);
    register(unrelated.contribution, id: 'dev.adele.test.unrelated');
    await tester.pumpWidget(host());
    expect(find.text('Session presentation is unavailable.'), findsOneWidget);
    expect(unrelated.sessions, isEmpty);

    final _Presenter exact = _Presenter(
      'Exact',
      OrchestrationStrategyId(strategyId.value),
    );
    register(exact.contribution);
    await tester.pumpAndSettle();
    expect(find.text('Exact'), findsOneWidget);
    expect(find.text('Unrelated'), findsNothing);
    expect(unrelated.sessions, isEmpty);
    expect(exact.sessions.single, same(session));
  });

  testWidgets(
    'rebuilds and unrelated registry changes retain widget and state',
    (tester) async {
      final _Presenter presenter = _Presenter('Presentation', strategyId);
      register(presenter.contribution);
      await tester.pumpWidget(host());
      final _ProbeState retained = tester.state<_ProbeState>(
        find.byType(_Probe),
      );
      final Widget retainedWidget = tester.widget(find.byType(_Probe));
      await tester.enterText(find.byType(TextField), 'Unsubmitted text');
      await tester.pumpWidget(host());
      await tester.pumpWidget(host());
      final ExtensionRegistration unrelated = extensions.register(
        point: ExtensionPoint<String>('dev.adele.test.other-point'),
        id: ExtensionId('dev.adele.test.other-extension'),
        value: 'unrelated',
      );
      await tester.pumpAndSettle();
      await unrelated.close();
      await tester.pumpAndSettle();

      expect(presenter.sessions, <Session>[session]);
      expect(presenter.mounts, 1);
      expect(presenter.disposals, 0);
      expect(tester.widget(find.byType(_Probe)), same(retainedWidget));
      expect(tester.state(find.byType(_Probe)), same(retained));
      expect(retained.controller.text, 'Unsubmitted text');
    },
  );

  testWidgets('initial ambiguity invokes neither factory', (tester) async {
    final _Presenter first = _Presenter('First', strategyId);
    final _Presenter second = _Presenter('Second', strategyId);
    register(first.contribution);
    register(second.contribution, id: 'dev.adele.test.second');
    await tester.pumpWidget(host());

    expect(
      find.textContaining('Session presentation is ambiguous'),
      findsOneWidget,
    );
    expect(first.sessions, isEmpty);
    expect(second.sessions, isEmpty);
    expect(find.byType(_Probe), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('added ambiguity disposes the subtree without a parent rebuild', (
    tester,
  ) async {
    final _Presenter first = _Presenter('First', strategyId);
    final _Presenter second = _Presenter('Second', strategyId);
    register(first.contribution);
    await tester.pumpWidget(host());
    final _ProbeState retained = tester.state<_ProbeState>(find.byType(_Probe));
    await tester.enterText(find.byType(TextField), 'Old local state');
    final ExtensionRegistration duplicate = register(
      second.contribution,
      id: 'dev.adele.test.second',
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Session presentation is ambiguous'),
      findsOneWidget,
    );
    expect(retained.mounted, isFalse);
    expect(first.disposals, 1);
    expect(first.sessions, <Session>[session]);
    expect(second.sessions, isEmpty);

    await duplicate.close();
    await tester.pumpAndSettle();
    final _ProbeState fresh = tester.state<_ProbeState>(find.byType(_Probe));
    expect(fresh, isNot(same(retained)));
    expect(fresh.controller.text, isEmpty);
    expect(first.sessions, <Session>[session, session]);
    expect(first.mounts, 2);
    expect(second.sessions, isEmpty);
  });

  testWidgets(
    'retirement disposes presentation and leaves canonical Session intact',
    (tester) async {
      final Session canonical = session;
      final SessionId id = session.id;
      final TaskId taskId = session.taskId;
      final OrchestrationStrategyId storedStrategyId = session.strategyId;
      final _Presenter presenter = _Presenter('Presentation', strategyId);
      final ExtensionRegistration registration = register(
        presenter.contribution,
      );
      await tester.pumpWidget(host());
      final _ProbeState retained = tester.state<_ProbeState>(
        find.byType(_Probe),
      );
      await registration.close();
      await tester.pumpAndSettle();
      await tester.pumpWidget(host());

      expect(find.text('Session presentation is unavailable.'), findsOneWidget);
      expect(retained.mounted, isFalse);
      expect(presenter.disposals, 1);
      expect(presenter.sessions, <Session>[canonical]);
      final Session presented = tester
          .widget<SessionPresentationHost>(find.byType(SessionPresentationHost))
          .session;
      expect(presented, same(canonical));
      expect(presented.id, same(id));
      expect(presented.taskId, same(taskId));
      expect(presented.strategyId, same(storedStrategyId));
      expect(tester.takeException(), isNull);
    },
  );

  for (final bool sameId in <bool>[true, false]) {
    testWidgets(
      'replacement with ${sameId ? 'same' : 'different'} ID and same value remounts',
      (tester) async {
        final _Presenter presenter = _Presenter('Presentation', strategyId);
        final ExtensionRegistration old = register(presenter.contribution);
        await tester.pumpWidget(host());
        final _ProbeState retained = tester.state<_ProbeState>(
          find.byType(_Probe),
        );
        await tester.enterText(find.byType(TextField), 'Old local state');

        // Retire and replace before any frame can display the unavailable state.
        final Future<void> closing = old.close();
        register(
          presenter.contribution,
          id: sameId
              ? 'dev.adele.test.presentation'
              : 'dev.adele.test.replacement',
        );
        await closing;
        await tester.pumpAndSettle();
        final _ProbeState fresh = tester.state<_ProbeState>(
          find.byType(_Probe),
        );

        expect(presenter.sessions, <Session>[session, session]);
        expect(presenter.mounts, 2);
        expect(presenter.disposals, 1);
        expect(retained.mounted, isFalse);
        expect(fresh, isNot(same(retained)));
        expect(fresh.controller.text, isEmpty);
        expect(tester.widget(find.byType(_Probe)), same(presenter.view));
      },
    );
  }

  testWidgets('a retired factory is never invoked when first mounting', (
    tester,
  ) async {
    int creations = 0;
    final ExtensionRegistration registration = register(
      SessionPresentationContribution(
        displayName: 'Fixture',
        strategyId: strategyId,
        createPresentation: (_) {
          creations++;
          throw StateError('Retired factory');
        },
      ),
    );
    await registration.close();
    await tester.pumpWidget(host());

    expect(creations, 0);
    expect(find.text('Session presentation is unavailable.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'factory failure is bounded and not retried by rebuilds or notifications',
    (tester) async {
      int creations = 0;
      final ExtensionRegistration failed = register(
        SessionPresentationContribution(
          displayName: 'Fixture',
          strategyId: strategyId,
          createPresentation: (received) {
            expect(received, same(session));
            creations++;
            throw StateError('Private unbounded factory details');
          },
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpWidget(host());
      final _Presenter unrelated = _Presenter('Unrelated', otherStrategyId);
      register(unrelated.contribution, id: 'dev.adele.test.unrelated');
      await tester.pumpAndSettle();

      expect(creations, 1);
      expect(
        find.text(
          'Session presentation is unavailable: the presentation could not be created.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Private unbounded'), findsNothing);
      expect(unrelated.sessions, isEmpty);
      expect(tester.takeException(), isNull);

      await failed.close();
      final _Presenter replacement = _Presenter('Replacement', strategyId);
      register(replacement.contribution);
      await tester.pumpAndSettle();
      expect(find.text('Replacement'), findsOneWidget);
      expect(replacement.sessions.single, same(session));
      expect(creations, 1);
    },
  );

  testWidgets('retirement during the factory prevents mounting its result', (
    tester,
  ) async {
    final _Presenter presenter = _Presenter('Retired', strategyId);
    int creations = 0;
    late ExtensionRegistration registration;
    registration = register(
      SessionPresentationContribution(
        displayName: 'Fixture',
        strategyId: strategyId,
        createPresentation: (_) {
          creations++;
          unawaited(registration.close());
          return presenter.view;
        },
      ),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(creations, 1);
    expect(presenter.mounts, 0);
    expect(find.byType(_Probe), findsNothing);
    expect(find.text('Session presentation is unavailable.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changing the canonical Session replaces local presentation state',
    (tester) async {
      final _Presenter presenter = _Presenter('Presentation', strategyId);
      register(presenter.contribution);
      await tester.pumpWidget(host());
      final _ProbeState retained = tester.state<_ProbeState>(
        find.byType(_Probe),
      );
      final Session next = Session(
        id: SessionId('session-2'),
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      await tester.pumpWidget(host(value: next));

      expect(presenter.sessions, <Session>[session, next]);
      expect(presenter.mounts, 2);
      expect(presenter.disposals, 1);
      expect(retained.mounted, isFalse);
      expect(tester.state(find.byType(_Probe)), isNot(same(retained)));
    },
  );

  testWidgets(
    'changing registries remounts and listens only to the new registry',
    (tester) async {
      final _Presenter presenter = _Presenter('Presentation', strategyId);
      final ExtensionRegistration old = register(presenter.contribution);
      await tester.pumpWidget(host());
      final ExtensionRegistry next = ExtensionRegistry();
      final ExtensionRegistration replacement = register(
        presenter.contribution,
        registry: next,
      );
      await tester.pumpWidget(host(registry: next));
      final _ProbeState retained = tester.state<_ProbeState>(
        find.byType(_Probe),
      );
      await old.close();
      await tester.pumpAndSettle();
      expect(presenter.sessions, <Session>[session, session]);
      expect(presenter.mounts, 2);
      expect(presenter.disposals, 1);
      expect(tester.state(find.byType(_Probe)), same(retained));

      await replacement.close();
      await tester.pumpAndSettle();
      expect(find.text('Session presentation is unavailable.'), findsOneWidget);
      expect(presenter.disposals, 2);
    },
  );

  testWidgets('host unmount disposes its subtree and cancels notifications', (
    tester,
  ) async {
    final _Presenter presenter = _Presenter('Presentation', strategyId);
    final ExtensionRegistration registration = register(presenter.contribution);
    await tester.pumpWidget(host());
    await tester.pumpWidget(const SizedBox.shrink());
    await registration.close();
    register(presenter.contribution);
    await tester.pumpAndSettle();

    expect(presenter.sessions, <Session>[session]);
    expect(presenter.mounts, 1);
    expect(presenter.disposals, 1);
    expect(tester.takeException(), isNull);
  });
}

class _Presenter {
  _Presenter(this.label, this.strategyId);

  final String label;
  final OrchestrationStrategyId strategyId;
  final List<Session> sessions = <Session>[];
  int mounts = 0;
  int disposals = 0;

  // Reusing this exact widget also exercises the host's instance key boundary.
  late final Widget view = _Probe(this);
  late final SessionPresentationContribution contribution =
      SessionPresentationContribution(
        displayName: 'Fixture',
        strategyId: strategyId,
        createPresentation: (session) {
          sessions.add(session);
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
  final TextEditingController controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.presenter.mounts++;
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(widget.presenter.label),
      TextField(controller: controller),
    ],
  );

  @override
  void dispose() {
    widget.presenter.disposals++;
    controller.dispose();
    super.dispose();
  }
}
