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
    await controller.close();
    controller.dispose();
  });

  Widget host({double width = 600, double height = 360}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: height,
          child: WorkbenchConsole(controller: controller),
        ),
      ),
    ),
  );

  void contribute(List<_Evidence> contents) {
    var next = 0;
    registry.register(
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

class _Evidence {
  _Evidence(this.title, {this.warning, this.noConfirmation = false});

  final String title;
  final String? warning;
  final bool noConfirmation;
  final List<ConsolePresentationAccess> mounts = [];
  late ConsoleTabRegistration registration;
  var releases = 0;

  void open(ConsoleCreationAccess access) {
    registration = access.open(
      ConsoleContent(
        metadata: ConsoleMetadata(title: title, status: ConsoleStatus.running),
        isEligible: (_) => true,
        createPresentation: (access) {
          mounts.add(access);
          return SizedBox.expand(
            key: const ValueKey('evidence-body'),
            child: Text('Evidence for $title'),
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
