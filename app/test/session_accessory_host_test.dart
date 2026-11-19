import 'dart:async';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const location = SessionAccessoryLocation.executionConfiguration;
  late ExtensionRegistry extensions;
  late Session session;
  Session makeSession(String id) => Session(
    id: SessionId(id),
    taskId: TaskId('t'),
    strategyId: OrchestrationStrategyId('example.other-strategy'),
  );
  setUp(() {
    extensions = ExtensionRegistry();
    session = makeSession('a');
  });

  Widget host({bool Function()? isCurrent}) => MaterialApp(
    home: MainContentHost(
      session: session,
      extensions: extensions,
      isCurrent: isCurrent,
    ),
  );

  ExtensionRegistration pane(Widget Function(MainContentAccess) build) =>
      extensions.register(
        point: mainContentContributions,
        id: ExtensionId('example.presentation'),
        value: MainContentContribution(
          order: 1,
          attach: (access) => access.open(
            MainContentPane(
              id: 'main',
              title: 'Example',
              createPresentation: () => build(access),
            ),
          ),
        ),
      );

  ExtensionRegistration accessory(
    String id,
    int order,
    Widget Function(SessionAccessoryAccess) build, {
    void Function(SessionAccessoryAccess)? detach,
  }) => extensions.register(
    point: sessionAccessoryContributions,
    id: ExtensionId(id),
    value: SessionAccessoryContribution(
      location: location,
      order: order,
      createPresentation: build,
      detach: detach,
    ),
  );

  testWidgets('no pane or no explicit mount never creates a control', (
    tester,
  ) async {
    var count = 0;
    accessory('example.unused', 0, (_) => Text('control ${++count}'));
    await tester.pumpWidget(host());
    expect(
      find.text('No Main Content is available for this Session.'),
      findsOneWidget,
    );
    pane((_) => const Text('plain presentation'));
    await tester.pumpAndSettle();
    expect(find.text('plain presentation'), findsOneWidget);
    expect(count, 0);
  });

  testWidgets(
    'one mount, zero empty extent, stable ordered independent registrations',
    (tester) async {
      final attached = <String, SessionAccessoryAccess>{};
      final detached = <SessionAccessoryAccess>[];
      final buildOrder = <String>[];
      Widget control(String id, SessionAccessoryAccess access) {
        buildOrder.add(id);
        attached[id] = access;
        if (id == 'bad') throw StateError('fixture');
        return TextButton(onPressed: () {}, child: Text(id));
      }

      ExtensionRegistration add(String id, int order) => accessory(
        'example.$id',
        order,
        (access) => control(id, access),
        detach: detached.add,
      );

      const first = ValueKey('first');
      const duplicate = ValueKey('duplicate');
      late MainContentAccess group;
      pane((access) {
        group = access;
        return Column(
          children: [
            for (final key in [first, duplicate])
              SizedBox(
                key: key,
                child: access.buildSessionAccessoryLocation(location),
              ),
          ],
        );
      });
      await tester.pumpWidget(host());
      expect(tester.getSize(find.byKey(first)), Size.zero);
      final z = add('z', 1);
      add('b', -1);
      add('bad', -1);
      add('a', 1);
      await tester.pumpAndSettle();
      expect(buildOrder, ['b', 'bad', 'a', 'z']);
      expect(detached, [same(attached['bad'])]);
      expect(tester.getSize(find.byKey(duplicate)), Size.zero);
      double x(String label) => tester.getTopLeft(find.text(label)).dx;
      expect(x('b'), lessThan(x('a')));
      expect(x('a'), lessThan(x('z')));
      final retained = tester.state(find.widgetWithText(TextButton, 'a'));
      final old = attached['z']!;
      await z.close();
      expect(old.isActive, isFalse);
      expect(() => old.session, throwsStateError);
      add('z', -2);
      group.setTitle('main', 'New title');
      await tester.pumpAndSettle();
      expect(x('z'), lessThan(x('b')));
      expect(detached, [same(attached['bad']), same(old)]);
      expect(buildOrder, ['b', 'bad', 'a', 'z', 'z']);
      expect(attached['z'], isNot(same(old)));
      expect(
        tester.state(find.widgetWithText(TextButton, 'a')),
        same(retained),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'departure fences admitted results; B and returning A get fresh access',
    (tester) async {
      final a = session;
      var current = true;
      final accesses = <SessionAccessoryAccess>[];
      final detached = <SessionAccessoryAccess>[];
      final gate = Completer<void>();
      final published = <Session>[];
      accessory('example.pending', 0, (access) {
        accesses.add(access);
        final captured = access.session;
        return TextButton(
          onPressed: () async {
            await gate.future;
            if (access.isActive) published.add(captured);
          },
          child: Text('start ${captured.id.value}'),
        );
      }, detach: detached.add);
      pane((access) => access.buildSessionAccessoryLocation(location));
      await tester.pumpWidget(host(isCurrent: () => current));
      await tester.tap(find.text('start a'));
      current = false;
      expect(accesses.single.isActive, isFalse);
      session = makeSession('b');
      await tester.pumpWidget(host());
      expect(accesses.last.session, same(session));
      expect(find.text('start b'), findsOneWidget);
      session = a;
      await tester.pumpWidget(host());
      expect(accesses, hasLength(3));
      expect(accesses.last.session, same(a));
      expect(accesses.last, isNot(same(accesses.first)));
      gate.complete();
      await tester.pump();
      expect(published, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(detached, accesses);
      expect(accesses.where((access) => access.isActive), isEmpty);
    },
  );

  testWidgets('accepted exit keeps mounted display but no executable access', (
    tester,
  ) async {
    final retaining = ValueNotifier(false);
    addTearDown(retaining.dispose);
    final accesses = <SessionAccessoryAccess>[];
    var detached = 0;
    final registration = accessory('example.retained', 0, (access) {
      accesses.add(access);
      return TextButton(onPressed: () {}, child: const Text('retained'));
    }, detach: (_) => detached++);
    pane((access) => access.buildSessionAccessoryLocation(location));
    await tester.pumpWidget(
      PreparedFrontendRetention(notifier: retaining, child: host()),
    );
    final original = tester.state(find.byType(TextButton));
    retaining.value = true;
    await registration.close();
    await tester.pumpAndSettle();
    expect(accesses.single.isActive, isFalse);
    expect(tester.state(find.byType(TextButton)), same(original));
    expect(detached, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(detached, 1);
  });
}
