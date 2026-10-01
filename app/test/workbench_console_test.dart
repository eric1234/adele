import 'dart:async';

import 'package:adele_desktop/ui/console/console_controller.dart';
import 'package:adele_desktop/ui/console/workbench_console.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ExtensionRegistry registry;
  late ConsoleController controller;

  setUp(() {
    registry = ExtensionRegistry();
    controller = ConsoleController(registry)
      ..setSession(
        Session(
          id: SessionId('session'),
          taskId: TaskId('task'),
          strategyId: OrchestrationStrategyId('test.strategy'),
        ),
      );
  });

  tearDown(() async {
    // Shutdown exercised inside a widget test is joined in its fake-async zone.
    if (!controller.isClosed) await controller.close();
    controller.dispose();
  });

  Widget host({
    double width = 600,
    double height = 360,
    bool showConsole = true,
    ConsoleController? console,
  }) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: height,
          child: showConsole
              ? WorkbenchConsole(controller: console ?? controller)
              : const Text('Other work area'),
        ),
      ),
    ),
  );

  ExtensionRegistration contribute(List<_Evidence> contents) {
    var next = 0;
    return registry.register(
      point: consoleContributions,
      id: ExtensionId('test.evidence'),
      value: ConsoleContribution(
        actions: [
          ConsoleCreationAction(
            id: 'new',
            label: 'New evidence',
            create: (access) async => contents[next++].open(access),
          ),
        ],
      ),
    );
  }

  testWidgets(
    'zero contributions and hidden console have sensible native chrome',
    (tester) async {
      await tester.pumpWidget(host());
      expect(
        find.text('No console contributions are available.'),
        findsOneWidget,
      );
      expect(find.byTooltip('New console'), findsNothing);
      expect(find.byType(Scaffold), findsOneWidget);
      await tester.tap(find.byTooltip('Hide console'));
      await tester.pump();
      expect(
        find.text('No console contributions are available.'),
        findsNothing,
      );
      expect(find.byTooltip('Show console'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'menu invokes contribution; only selected visible content mounts',
    (tester) async {
      final one = _Evidence('One');
      final two = _Evidence('Two');
      contribute([one, two]);
      await tester.pumpWidget(host());
      await tester.pump();
      expect(find.text('Create a console from the + menu.'), findsOneWidget);
      await tester.tap(find.byTooltip('New console'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New evidence'));
      await tester.pumpAndSettle();
      expect(find.text('Evidence for One'), findsOneWidget);
      expect(one.mounts, hasLength(1));
      expect(two.mounts, isEmpty);
      await controller.invoke(controller.actions.single);
      await tester.pump();
      expect(one.mounts.single.isActive, isFalse);
      expect(find.text('Evidence for One'), findsNothing);
      expect(find.text('Evidence for Two'), findsOneWidget);
      expect(two.mounts, hasLength(1));
      await tester.tap(find.widgetWithText(TextButton, 'One'));
      await tester.pump();
      expect(one.mounts, hasLength(2));
      expect(two.mounts.single.isActive, isFalse);
      final access = one.mounts.last;
      await tester.tap(find.byTooltip('Hide console'));
      expect(access.isActive, isFalse);
      await tester.pump();
      expect(find.text('Evidence for One'), findsNothing);
      one.registration.updateMetadata(
        ConsoleMetadata(title: 'One', status: ConsoleStatus.completed),
      );
      await tester.tap(find.byTooltip('Show console'));
      await tester.pump();
      expect(one.mounts, hasLength(3));
      expect(find.widgetWithText(TextButton, 'One'), findsOneWidget);
      expect(find.text('completed'), findsOneWidget);
      expect(one.releases, 0);
      expect(two.releases, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rebuilds retain mount; removing widget revokes without releasing content',
    (tester) async {
      final evidence = _Evidence('One');
      contribute([evidence]);
      await tester.pumpWidget(host());
      await tester.pump();
      await controller.invoke(controller.actions.single);
      await tester.pump();
      final access = evidence.mounts.single;
      await tester.pumpWidget(host(width: 400));
      expect(evidence.mounts, hasLength(1));
      expect(access.isActive, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(access.isActive, isFalse);
      expect(evidence.releases, 0);
      await tester.pumpWidget(host());
      expect(evidence.mounts, hasLength(2));
      expect(evidence.mounts.last.isActive, isTrue);
    },
  );

  testWidgets('opted-in hidden content keeps stable state and finite layout', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final one = _Evidence(
      'One',
      keepAlive: true,
      body: () =>
          TextField(key: const ValueKey('resident-input'), focusNode: focus),
    );
    final two = _Evidence('Two', keepAlive: true);
    contribute([one, two]);
    await tester.pumpWidget(host());
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    final input = find.byKey(const ValueKey('resident-input'));
    final inputState = tester.state(input);
    final inputSize = tester.getSize(input);
    await tester.tap(input);
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    final epoch = one.mounts.single.interaction!;
    await controller.invoke(controller.actions.single);
    expect(epoch.isActive, isFalse);
    expect(one.mounts.single.isActive, isTrue);
    expect(focus.canRequestFocus, isFalse);
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    expect(input, findsNothing);
    final hidden = find.byKey(
      const ValueKey('resident-input'),
      skipOffstage: false,
    );
    expect(tester.state(hidden), same(inputState));
    expect(tester.getSize(hidden), inputSize);
    expect(TickerMode.of(tester.element(hidden)), isFalse);
    await tester.tap(find.widgetWithText(TextButton, 'One'));
    await tester.pump();
    expect(tester.state(input), same(inputState));
    expect(one.mounts, hasLength(1));
    expect(two.mounts, hasLength(1));
    expect(epoch.isActive, isFalse);
    expect(one.mounts.single.interaction!.isActive, isTrue);
    expect(TickerMode.of(tester.element(input)), isTrue);
    expect(focus.hasFocus, isFalse);
    await tester.tap(find.byTooltip('Hide console'));
    expect(one.mounts.single.isActive, isFalse);
    expect(two.mounts.single.isActive, isFalse);
    await tester.pump();
    expect(hidden, findsNothing);
    expect(one.releases, 0);
    expect(two.releases, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two-slot churn disposes only LRU views and preserves tabs', (
    tester,
  ) async {
    await controller.close();
    controller.dispose();
    controller = ConsoleController(registry, presentationLimit: 2)
      ..setSession(
        Session(
          id: SessionId('session'),
          taskId: TaskId('task'),
          strategyId: OrchestrationStrategyId('test.strategy'),
        ),
      );
    final contents = List.generate(
      4,
      (index) => _Evidence('Tab $index', keepAlive: true),
    );
    contribute(contents);
    await tester.pumpWidget(host());
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    final tabs = controller.eligibleTabs;
    final first = contents[0].mounts.single;
    controller.select(tabs[0]);
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    expect(contents[1].mounts.single.isActive, isFalse);
    expect(first.isActive, isTrue);
    expect(controller.eligibleTabs, hasLength(3));
    expect(
      find.byKey(const ValueKey('evidence-body'), skipOffstage: false),
      findsNWidgets(2),
    );
    expect(find.text('Evidence for Tab 2'), findsOneWidget);
    // Several synchronous changes before Flutter disposes removed children must
    // not resurrect an old grant or create an unvisited fourth presentation.
    controller.select(tabs[1]);
    controller.selectedPresentation;
    controller.select(tabs[0]);
    controller.selectedPresentation;
    controller.select(tabs[1]);
    await tester.pump();
    expect(first.isActive, isFalse);
    expect(contents[1].mounts, hasLength(2));
    expect(contents[1].mounts.first.isActive, isFalse);
    expect(contents[3].mounts, isEmpty);
    expect(controller.residentPresentations, hasLength(2));
    expect(contents.every((content) => content.releases == 0), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      contents
          .expand((content) => content.mounts)
          .every((access) => !access.isActive),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('warm selection withdraws exact close dialog', (tester) async {
    final one = _Evidence('One', keepAlive: true);
    final two = _Evidence('Two', keepAlive: true);
    contribute([one, two]);
    await tester.pumpWidget(host(width: 800));
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    await tester.tap(find.byTooltip('Close Two'));
    await tester.pumpAndSettle();
    final lateAccept = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Close'))
        .onPressed!;
    controller.select(controller.eligibleTabs.first);
    expect(two.mounts.single.isActive, isTrue);
    expect(two.mounts.single.interaction, isNull);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(_dialogBarriers(), findsNothing);
    lateAccept();
    await tester.pump();
    expect(two.releases, 0);
    expect(controller.eligibleTabs, hasLength(2));
    expect(one.mounts, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final keepAlive in [false, true]) {
    for (final failure in ['false', 'throw']) {
      testWidgets(
        'eligibility $failure withdraws selected keepAlive=$keepAlive dialog without cooling sibling',
        (tester) async {
          final one = _Evidence(
            'One',
            keepAlive: true,
            body: () => const TextField(key: ValueKey('healthy-input')),
          );
          final two = _Evidence('Two', keepAlive: keepAlive);
          contribute([one, two]);
          await tester.pumpWidget(host(width: 800));
          await tester.pump();
          await controller.invoke(controller.actions.single);
          await tester.pump();
          final healthyTab = controller.selectedTab!;
          final healthyAccess = one.mounts.single;
          final input = find.byKey(const ValueKey('healthy-input'));
          final healthyState = tester.state(input);
          await tester.enterText(input, 'retained draft');
          await controller.invoke(controller.actions.single);
          await tester.pump();
          final lostTab = controller.selectedTab!;
          final lostAccess = two.mounts.single;
          final lostInteraction = lostAccess.interaction!;
          final workbench = tester.state(find.byType(WorkbenchConsole));
          final navigator = tester.state<NavigatorState>(
            find.byType(Navigator),
          );
          await tester.tap(find.byTooltip('Close Two'));
          await tester.pumpAndSettle();
          final lateAccept = tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Close'))
              .onPressed!;
          var settled = false;
          unawaited(
            controller
                .closeTab(lostTab, (_) async {
                  fail('The exact close request must coalesce.');
                })
                .then((_) => settled = true),
          );

          two.eligible = false;
          two.throwEligibility = failure == 'throw';
          two.registration.updateMetadata(ConsoleMetadata(title: 'Two'));
          // Mutable predicates are reconciled when evaluated, not by observing
          // arbitrary captured fields. No frame may precede exact revocation.
          expect(controller.selectedTab, same(healthyTab));
          expect(lostAccess.isActive, isFalse);
          expect(lostInteraction.isActive, isFalse);
          expect(healthyAccess.isActive, isTrue);
          expect(two.registration.isActive, isTrue);
          expect(two.releases, 0);
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(WorkbenchConsole)), same(workbench));
          expect(tester.state(find.byType(Navigator)), same(navigator));
          expect(find.byType(AlertDialog), findsNothing);
          expect(_dialogBarriers(), findsNothing);
          expect(settled, isTrue);
          expect(
            find.text('Evidence for Two', skipOffstage: false),
            findsNothing,
          );
          expect(tester.state(input), same(healthyState));
          expect(find.text('retained draft'), findsOneWidget);
          expect(one.mounts, hasLength(1));

          two.eligible = true;
          two.throwEligibility = false;
          two.registration.updateMetadata(ConsoleMetadata(title: 'Two'));
          await tester.pump();
          expect(controller.eligibleTabs, [healthyTab, lostTab]);
          expect(controller.selectedTab, same(healthyTab));
          expect(two.mounts, hasLength(1));
          lateAccept();
          await tester.pump();
          expect(two.releases, 0);
          await tester.tap(find.widgetWithText(TextButton, 'Two'));
          await tester.pump();
          expect(two.mounts, hasLength(2));
          expect(two.mounts.last.isActive, isTrue);
          expect(lostAccess.isActive, isFalse);
          expect(lostInteraction.isActive, isFalse);
          await tester.tap(find.byTooltip('Close Two'));
          await tester.pumpAndSettle();
          lateAccept();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(two.releases, 0);
          expect(one.releases, 0);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'close cancellation is inert and confirmation leaves warning outside tab',
    (tester) async {
      final evidence = _Evidence('One', warning: 'Cleanup needs attention.');
      contribute([evidence]);
      await tester.pumpWidget(host());
      await tester.pump();
      await controller.invoke(controller.actions.single);
      await tester.pump();
      final access = evidence.mounts.single;
      await tester.tap(find.byTooltip('Close One'));
      await tester.pumpAndSettle();
      expect(find.text('Close this console?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(access.isActive, isTrue);
      expect(evidence.releases, 0);
      await tester.tap(find.byTooltip('Close One'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Close'));
      await tester.pumpAndSettle();
      expect(access.isActive, isFalse);
      expect(evidence.releases, 1);
      expect(find.text('Evidence for One'), findsNothing);
      expect(find.text('Cleanup needs attention.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'automatic removal withdraws its dialog under a surviving Navigator',
    (tester) async {
      final one = _Evidence('One');
      final two = _Evidence('Two', noConfirmation: true);
      contribute([one, two]);
      await tester.pumpWidget(host());
      await tester.pump();
      await controller.invoke(controller.actions.single);
      await controller.invoke(controller.actions.single);
      await tester.pump();
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await tester.tap(find.byTooltip('Close One'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(_dialogBarriers(), findsOneWidget);

      await one.registration.requestRemoval();
      await tester.pumpAndSettle();
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)),
        same(navigator),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(_dialogBarriers(), findsNothing);
      expect(find.byTooltip('Close One'), findsNothing);
      expect(one.releases, 1);
      expect(two.releases, 0);
      await tester.tap(find.byTooltip('Close Two'));
      await tester.pumpAndSettle();
      expect(two.releases, 1);
      expect(one.releases, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final departure in [
    'session',
    'clear',
    'hide',
    'unmount',
    'replacement',
    'retirement',
    'close',
    'dispose',
  ]) {
    testWidgets(
      'withdraws confirmation on $departure without disposing Navigator',
      (tester) async {
        final evidence = _Evidence('One');
        final contribution = contribute([evidence]);
        final originalSession = controller.session;
        await tester.pumpWidget(host());
        await tester.pump();
        await controller.invoke(controller.actions.single);
        await tester.pump();
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        await tester.tap(find.byTooltip('Close One'));
        await tester.pumpAndSettle();
        final lateAccept = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Close'))
            .onPressed!;
        var settled = false;
        var shutdownSettled = false;
        unawaited(
          controller
              .closeTab(controller.selectedTab!, (_) async {
                fail('The exact close request must coalesce.');
              })
              .then((_) => settled = true),
        );
        switch (departure) {
          case 'session':
            controller.setSession(
              Session(
                id: SessionId('second'),
                taskId: TaskId('task'),
                strategyId: OrchestrationStrategyId('test.strategy'),
              ),
            );
          case 'clear':
            controller.setSession(null);
          case 'hide':
            controller.setVisible(false);
          case 'unmount':
            await tester.pumpWidget(host(showConsole: false));
          case 'replacement':
            final replacement = ConsoleController(registry)
              ..setSession(originalSession);
            addTearDown(replacement.dispose);
            await tester.pumpWidget(host(console: replacement));
          case 'retirement':
            await contribution.close();
          case 'close':
            unawaited(controller.close().then((_) => shutdownSettled = true));
          case 'dispose':
            controller.dispose();
            unawaited(controller.close().then((_) => shutdownSettled = true));
        }
        await tester.pumpAndSettle();
        expect(
          tester.state<NavigatorState>(find.byType(Navigator)),
          same(navigator),
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(_dialogBarriers(), findsNothing);
        expect(settled, isTrue);
        if (departure == 'close' || departure == 'dispose') {
          expect(shutdownSettled, isTrue);
        }
        final removes = ['retirement', 'close', 'dispose'].contains(departure);
        expect(evidence.releases, removes ? 1 : 0);
        expect(evidence.registration.isActive, !removes);
        if (!removes) {
          controller.setSession(originalSession);
          controller.setVisible(true);
          await tester.pumpWidget(host());
          await tester.tap(find.byTooltip('Close One'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          // Cached callbacks from the withdrawn route cannot answer the new one.
          lateAccept();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(evidence.releases, 0);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(_dialogBarriers(), findsNothing);
          expect(evidence.mounts.last.isActive, isTrue);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('withdrawal removes only its own route below another route', (
    tester,
  ) async {
    final evidence = _Evidence('One');
    contribute([evidence]);
    await tester.pumpWidget(host());
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await tester.tap(find.byTooltip('Close One'));
    await tester.pumpAndSettle();
    final dialog = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
    final unrelated = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Unrelated route')),
    );
    var unrelatedPopped = false;
    unawaited(navigator.push(unrelated).then((_) => unrelatedPopped = true));
    await tester.pumpAndSettle();
    await evidence.registration.requestRemoval();
    await tester.pumpAndSettle();
    expect(unrelatedPopped, isFalse);
    expect(unrelated.isCurrent, isTrue);
    expect(dialog.isActive, isFalse);
    expect(find.text('Unrelated route'), findsOneWidget);
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    expect(_dialogBarriers(), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(unrelatedPopped, isTrue);
    expect(find.byType(WorkbenchConsole), findsOneWidget);
    expect(evidence.releases, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'metadata and ordinary rebuilds preserve the exact confirmation',
    (tester) async {
      final evidence = _Evidence('One');
      contribute([evidence]);
      await tester.pumpWidget(host());
      await tester.pump();
      await controller.invoke(controller.actions.single);
      await tester.pump();
      final access = evidence.mounts.single;
      await tester.tap(find.byTooltip('Close One'));
      await tester.pumpAndSettle();
      final route = ModalRoute.of(tester.element(find.byType(AlertDialog)));
      evidence.registration.updateMetadata(
        ConsoleMetadata(
          title: 'Renamed',
          description: 'Changed detail',
          status: ConsoleStatus.completed,
        ),
      );
      await tester.pumpWidget(host(width: 480));
      await tester.pumpAndSettle();
      expect(
        ModalRoute.of(tester.element(find.byType(AlertDialog))),
        same(route),
      );
      expect(_dialogBarriers(), findsOneWidget);
      expect(access.isActive, isTrue);
      expect(evidence.releases, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_dialogBarriers(), findsNothing);
      expect(evidence.releases, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unselected close is native chrome only and never mounts content',
    (tester) async {
      final one = _Evidence('One', noConfirmation: true);
      final two = _Evidence('Two');
      contribute([one, two]);
      await tester.pumpWidget(host());
      await tester.pump();
      await controller.invoke(controller.actions.single);
      await controller.invoke(controller.actions.single);
      await tester.pump();
      expect(one.mounts, isEmpty);
      expect(two.mounts, hasLength(1));
      await tester.tap(find.byTooltip('Close One'));
      await tester.pump();
      expect(one.mounts, isEmpty);
      expect(one.releases, 1);
      expect(two.mounts.single.isActive, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'long labels and many tabs overflow horizontally, content stays finite',
    (tester) async {
      final contents = List.generate(
        12,
        (index) => _Evidence('Tab $index ${'x' * 200}'),
      );
      contribute(contents);
      await tester.pumpWidget(host(width: 240, height: 180));
      await tester.pump();
      for (final _ in contents) {
        await controller.invoke(controller.actions.single);
      }
      await tester.pump();
      expect(
        contents.take(11).every((content) => content.mounts.isEmpty),
        isTrue,
      );
      final box = tester.getSize(find.byKey(const ValueKey('evidence-body')));
      expect(box.width, lessThanOrEqualTo(240));
      expect(box.height, lessThanOrEqualTo(132));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-400, 0),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unbounded parent height is capped before allocating flex', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(children: [WorkbenchConsole(controller: controller)]),
      ),
    );
    expect(
      tester.getSize(find.byType(WorkbenchConsole)).height,
      lessThanOrEqualTo(368),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short constrained console keeps cleanup warning overflow-safe', (
    tester,
  ) async {
    final evidence = _Evidence('One', warning: 'Warning ${'x' * 300}');
    contribute([evidence]);
    await tester.pumpWidget(host(width: 240, height: 90));
    await tester.pump();
    await controller.invoke(controller.actions.single);
    await tester.pump();
    await evidence.registration.requestRemoval();
    await tester.pump();
    expect(find.textContaining('Warning'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'process-like titles cannot replace or hide authoritative status',
    (tester) async {
      final evidence = _Evidence('Forged (completed) ${'x' * 200}');
      contribute([evidence]);
      await tester.pumpWidget(host(width: 300));
      await tester.pump();
      await controller.invoke(controller.actions.single);
      await tester.pump();
      final title = find.text(controller.selectedTab!.metadata.title);
      final status = find.text('running');
      expect(title, findsOneWidget);
      expect(status, findsOneWidget);
      expect(tester.widget<Text>(title).overflow, TextOverflow.ellipsis);
      expect(tester.widget<Text>(status).overflow, isNull);
      expect(
        tester.getRect(status).left,
        greaterThan(tester.getRect(title).left),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

// The Navigator's base PageRoute also owns a non-dismissible barrier. Assert
// there is no outstanding dialog barrier without conflating those lifetimes.
Finder _dialogBarriers() => find.byWidgetPredicate(
  (widget) => widget is ModalBarrier && widget.dismissible,
);

class _Evidence {
  _Evidence(
    this.title, {
    this.warning,
    this.noConfirmation = false,
    this.keepAlive = false,
    this.body,
  });

  final String title;
  final String? warning;
  final bool noConfirmation;
  final bool keepAlive;
  final Widget Function()? body;
  final List<ConsolePresentationAccess> mounts = [];
  late ConsoleTabRegistration registration;
  var releases = 0;
  var eligible = true;
  var throwEligibility = false;

  void open(ConsoleCreationAccess access) {
    registration = access.open(
      ConsoleContent(
        metadata: ConsoleMetadata(title: title, status: ConsoleStatus.running),
        isEligible: (_) {
          if (throwEligibility) throw StateError('Eligibility unavailable.');
          return eligible;
        },
        keepAlive: keepAlive,
        createPresentation: (access) {
          mounts.add(access);
          return SizedBox.expand(
            key: const ValueKey('evidence-body'),
            child: body?.call() ?? Text('Evidence for $title'),
          );
        },
        closeAdvice: () =>
            noConfirmation ? const ConsoleCloseAdvice.noConfirmation() : null,
        release: () async {
          releases++;
          return ConsoleCleanupResult(warning: warning);
        },
      ),
    );
  }
}
