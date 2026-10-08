import 'dart:async';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ExtensionRegistry extensions;
  late Session session;
  late MainContentActionCoordinator coordinator;

  setUp(() {
    extensions = ExtensionRegistry();
    coordinator = MainContentActionCoordinator();
    session = Session(
      id: SessionId('session'),
      taskId: TaskId('task'),
      strategyId: OrchestrationStrategyId('test.strategy'),
    );
  });

  ExtensionRegistration register(
    String id,
    FutureOr<void> Function(MainContentAccess) attach, {
    int order = 0,
    List<MainContentAction> actions = const [],
  }) => extensions.register(
    point: mainContentContributions,
    id: ExtensionId(id),
    value: MainContentContribution(
      order: order,
      attach: attach,
      actions: actions,
    ),
  );

  Widget host({
    double width = 1200,
    Session? current,
    bool Function()? isCurrent,
    MainContentActionCoordinator? actionCoordinator,
  }) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: 400,
          child: MainContentHost(
            session: current ?? session,
            extensions: extensions,
            isCurrent: isCurrent,
            actionCoordinator: actionCoordinator ?? coordinator,
          ),
        ),
      ),
    ),
  );

  MainContentPane pane(
    String id, {
    VoidCallback? release,
    VoidCallback? onClose,
    VoidCallback? requestFocus,
    Widget Function()? create,
  }) => MainContentPane(
    id: id,
    title: id,
    createPresentation: create ?? () => _Probe(id),
    release: release,
    onClose: onClose,
    requestFocus: requestFocus,
  );

  ExtensionRegistration registerChat({int order = 100}) => register(
    'test.chat',
    (access) => access.open(pane('chat')),
    order: order,
  );

  Finder probe(String id) => find.byKey(ValueKey(id));

  Future<void> wide(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('zero panes show generic empty content with no reserved width', (
    tester,
  ) async {
    await tester.pumpWidget(host(width: 700));
    final empty = find.text('No Main Content is available for this Session.');
    expect(empty, findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byType(_Probe), findsNothing);
    late MainContentAccess access;
    register('test.empty', (value) => access = value, order: 100);
    await tester.pumpAndSettle();
    expect(empty, findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
    access.open(pane('a'));
    access.open(pane('b'));
    await tester.pump();
    expect(empty, findsNothing);
    expect(find.byType(_Probe), findsNWidgets(2));
    expect(tester.getTopLeft(probe('a')).dx, 8);
    for (final id in ['a', 'b']) {
      expect(tester.getSize(probe(id)).width, (700 - 16 - 1) / 2);
    }
    access.remove('a');
    access.remove('b');
    await tester.pumpWidget(host(width: 300));
    expect(empty, findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byType(_Probe), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'button and coordinator share fresh bounded input and close reenables admission',
    (tester) async {
      late MainContentAccess attached;
      final inputs = <MainContentAccess>[];
      register(
        'test.resources',
        (access) => attached = access,
        actions: [
          MainContentAction(
            id: 'choose',
            label: 'Choose resource',
            createPresentation: (access) {
              inputs.add(access);
              return _Probe('input');
            },
          ),
        ],
      );
      final owner = extensions.discover(mainContentContributions).single;
      final action = owner.value.actions.single;
      expect(coordinator.hasSession, isFalse);
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(() => coordinator.open(owner, action), throwsStateError);
      await tester.pumpWidget(host(width: 700));
      expect(coordinator.hasSession, isTrue);
      expect(coordinator.canOpen(owner, action), isTrue);
      expect(find.text('Choose resource'), findsOneWidget);
      expect(
        find.text('No Main Content is available for this Session.'),
        findsOneWidget,
      );
      expect(attached.panes, isEmpty);
      expect(inputs, isEmpty);
      expect(find.byType(_Probe), findsNothing);

      await tester.tap(find.text('Choose resource'));
      await tester.pumpAndSettle();
      expect(inputs, [same(attached)]);
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(() => coordinator.open(owner, action), throwsStateError);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Choose resource'),
            )
            .onPressed,
        isNull,
      );
      expect(inputs.single.session, same(session));
      expect(attached.panes, isEmpty);
      expect(find.byType(Dialog), findsOneWidget);
      final box = find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.width == 480 && widget.height == 260,
        ),
      );
      expect(tester.getSize(box), const Size(480, 260));
      final first = tester.state<_ProbeState>(probe('input'));
      await tester.enterText(find.byType(TextField), 'temporary input');
      inputs.single.open(pane('opened'));
      await tester.pump();
      await tester.tap(find.byTooltip('Close input'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(first.disposed, isTrue);
      expect(coordinator.canOpen(owner, action), isTrue);
      expect(attached.panes.single.id, 'opened');
      final opened = tester.state(probe('opened'));

      coordinator.open(owner, action);
      expect(inputs, [same(attached), same(attached)]);
      expect(coordinator.canOpen(owner, action), isFalse);
      await tester.pumpAndSettle();
      expect(inputs, [same(attached), same(attached)]);
      final second = tester.state<_ProbeState>(probe('input'));
      expect(second, isNot(same(first)));
      expect(second.text.text, isEmpty);
      expect(tester.getSize(box), const Size(480, 260));
      await tester.tap(find.byTooltip('Close input'));
      await tester.pumpAndSettle();
      expect(tester.state(probe('opened')), same(opened));
      expect(coordinator.canOpen(owner, action), isTrue);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Choose resource'),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'navigation revokes and removes old input without mounting a pane',
    (tester) async {
      var current = true;
      final inputs = <MainContentAccess>[];
      register(
        'test.resources',
        (_) {},
        actions: [
          MainContentAction(
            id: 'choose',
            label: 'Choose resource',
            createPresentation: (access) {
              inputs.add(access);
              return _Probe('input');
            },
          ),
        ],
      );
      final owner = extensions.discover(mainContentContributions).single;
      final action = owner.value.actions.single;
      await tester.pumpWidget(host(isCurrent: () => current));
      await tester.tap(find.text('Choose resource'));
      await tester.pumpAndSettle();
      final original = tester.state<_ProbeState>(probe('input'));
      final old = inputs.single;
      current = false;
      expect(coordinator.hasSession, isFalse);
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(() => coordinator.open(owner, action), throwsStateError);
      expect(old.isActive, isFalse);
      expect(() => old.open(pane('late')), throwsStateError);
      current = true;
      expect(coordinator.hasSession, isFalse);
      final other = Session(
        id: session.id,
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      await tester.pumpWidget(host(current: other));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(_Probe), findsNothing);
      expect(original.disposed, isTrue);
      expect(inputs, hasLength(1));
      expect(coordinator.hasSession, isTrue);
      expect(coordinator.canOpen(owner, action), isTrue);
      coordinator.open(owner, action);
      await tester.pumpAndSettle();
      expect(inputs.last, isNot(same(old)));
      expect(inputs.last.session, same(other));
      expect(inputs.last.panes, isEmpty);
      expect(old.isActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(inputs.last.isActive, isFalse);
      expect(coordinator.hasSession, isFalse);
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retiring actions removes input while preserving pane state and width',
    (tester) async {
      registerChat();
      final action = MainContentAction(
        id: 'choose',
        label: 'Choose resource',
        createPresentation: (_) => _Probe('input'),
      );
      await tester.pumpWidget(host(width: 700));
      final chat = tester.state(probe('chat'));
      final originalSize = tester.getSize(probe('chat'));
      final registration = register(
        'test.resources',
        (_) {},
        actions: [action],
      );
      final owner = extensions
          .discover(mainContentContributions)
          .singleWhere((item) => item.id.value == 'test.resources');
      await tester.pumpAndSettle();
      expect(tester.state(probe('chat')), same(chat));
      expect(tester.getSize(probe('chat')).width, originalSize.width);
      coordinator.open(owner, action);
      await tester.pumpAndSettle();
      final input = tester.state<_ProbeState>(probe('input'));
      await registration.close();
      expect(coordinator.hasSession, isTrue);
      expect(coordinator.canOpen(owner, action), isFalse);
      final replacement = register('test.resources', (_) {}, actions: [action]);
      final replacementOwner = extensions
          .discover(mainContentContributions)
          .singleWhere((item) => item.id.value == 'test.resources');
      expect(coordinator.canOpen(replacementOwner, action), isFalse);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(input.disposed, isTrue);
      expect(tester.state(probe('chat')), same(chat));
      expect(find.text('Choose resource'), findsOneWidget);
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(() => coordinator.open(owner, action), throwsStateError);
      expect(coordinator.canOpen(replacementOwner, action), isTrue);
      await replacement.close();
      await tester.pumpAndSettle();
      expect(tester.state(probe('chat')), same(chat));
      expect(tester.getSize(probe('chat')), originalSize);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'input dialog fits a small viewport and contains factory failure',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 280));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      register(
        'test.resources',
        (_) {},
        actions: [
          MainContentAction(
            id: 'choose',
            label: 'Choose resource',
            createPresentation: (_) => throw StateError('fixture failure'),
          ),
        ],
      );
      final owner = extensions.discover(mainContentContributions).single;
      final action = owner.value.actions.single;
      await tester.pumpWidget(host(width: 300));
      await tester.tap(find.text('Choose resource'));
      await tester.pumpAndSettle();
      expect(find.text('Main Content input is unavailable.'), findsOneWidget);
      final box = find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.width == 480 && widget.height == 260,
        ),
      );
      final bounds = tester.getRect(box);
      expect(bounds.left, greaterThanOrEqualTo(16));
      expect(bounds.right, lessThanOrEqualTo(304));
      expect(bounds.top, greaterThanOrEqualTo(16));
      expect(bounds.bottom, lessThanOrEqualTo(264));
      await tester.tap(find.byTooltip('Close input'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(coordinator.canOpen(owner, action), isTrue);
      coordinator.open(owner, action);
      await tester.pumpAndSettle();
      expect(find.text('Main Content input is unavailable.'), findsOneWidget);
      expect(coordinator.canOpen(owner, action), isFalse);
      await tester.tap(find.byTooltip('Close input'));
      await tester.pumpAndSettle();
      expect(coordinator.canOpen(owner, action), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'coordinator rejects foreign matching actions without calling factories',
    (tester) async {
      var factories = 0;
      MainContentAction action() => MainContentAction(
        id: 'choose',
        label: 'Choose resource',
        createPresentation: (_) {
          factories++;
          return const SizedBox.shrink();
        },
      );

      final exact = action();
      final foreign = action();
      register('test.owner', (_) {}, actions: [exact]);
      register('test.foreign', (_) {}, actions: [foreign]);
      final bindings = extensions.discover(mainContentContributions);
      final owner = bindings.singleWhere(
        (item) => item.id.value == 'test.owner',
      );
      final other = bindings.singleWhere(
        (item) => item.id.value == 'test.foreign',
      );
      await tester.pumpWidget(host());
      for (final (binding, candidate) in [
        (owner, foreign),
        (other, exact),
        (owner, action()),
      ]) {
        expect(coordinator.canOpen(binding, candidate), isFalse);
        expect(() => coordinator.open(binding, candidate), throwsStateError);
      }
      expect(coordinator.canOpen(owner, exact), isTrue);
      expect(coordinator.canOpen(other, foreign), isTrue);
      expect(factories, 0);
      coordinator.open(owner, exact);
      expect(factories, 1);
      expect(coordinator.canOpen(other, foreign), isFalse);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close input'));
      await tester.pumpAndSettle();
      expect(coordinator.canOpen(other, foreign), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Session remains present while unattached and failed actions stay disabled',
    (tester) async {
      final ready = Completer<void>();
      final failed = Completer<void>();
      var attachments = 0;
      var factories = 0;
      final action = MainContentAction(
        id: 'choose',
        label: 'Choose resource',
        createPresentation: (_) {
          factories++;
          return const SizedBox.shrink();
        },
      );
      await tester.pumpWidget(host());
      expect(coordinator.hasSession, isTrue);
      register('test.pending', (_) {
        attachments++;
        return ready.future;
      }, actions: [action]);
      register('test.failed', (_) {
        attachments++;
        return failed.future;
      }, actions: [action]);
      final bindings = extensions.discover(mainContentContributions);
      final owner = bindings.singleWhere(
        (item) => item.id.value == 'test.pending',
      );
      final failing = bindings.singleWhere(
        (item) => item.id.value == 'test.failed',
      );
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(() => coordinator.open(owner, action), throwsStateError);
      expect(attachments, 0);
      await tester.pumpAndSettle();
      expect(coordinator.hasSession, isTrue);
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(coordinator.canOpen(failing, action), isFalse);
      expect(attachments, 2);
      expect(factories, 0);
      expect(
        tester
            .widgetList<TextButton>(find.byType(TextButton))
            .every((button) => button.onPressed == null),
        isTrue,
      );
      failed.completeError(StateError('fixture attachment failure'));
      ready.complete();
      await tester.pumpAndSettle();
      expect(coordinator.hasSession, isTrue);
      expect(coordinator.canOpen(owner, action), isTrue);
      expect(coordinator.canOpen(failing, action), isFalse);
      expect(() => coordinator.open(failing, action), throwsStateError);
      expect(factories, 0);
      expect(attachments, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('input factory cannot admit a reentrant input route', (
    tester,
  ) async {
    late ExtensionBinding<MainContentContribution> owner;
    late MainContentAction action;
    var factories = 0;
    action = MainContentAction(
      id: 'choose',
      label: 'Choose resource',
      createPresentation: (_) {
        factories++;
        expect(coordinator.canOpen(owner, action), isFalse);
        expect(() => coordinator.open(owner, action), throwsStateError);
        return _Probe('input');
      },
    );
    register('test.owner', (_) {}, actions: [action]);
    owner = extensions.discover(mainContentContributions).single;
    await tester.pumpWidget(host());
    coordinator.open(owner, action);
    await tester.pumpAndSettle();
    expect(factories, 1);
    expect(find.byType(Dialog), findsOneWidget);
    expect(probe('input'), findsOneWidget);
    await tester.tap(find.byTooltip('Close input'));
    await tester.pumpAndSettle();
    expect(coordinator.canOpen(owner, action), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final staleByRetirement in [false, true]) {
    testWidgets(
      'input factory stale before or after admission by ${staleByRetirement ? 'retirement' : 'Session guard'} never mounts',
      (tester) async {
        var current = true;
        var factories = 0;
        late ExtensionRegistration registration;
        final action = MainContentAction(
          id: 'choose',
          label: 'Choose resource',
          createPresentation: (_) {
            factories++;
            if (staleByRetirement) {
              unawaited(registration.close());
            } else {
              current = false;
            }
            return _Probe('input');
          },
        );
        registration = register('test.owner', (_) {}, actions: [action]);
        final owner = extensions.discover(mainContentContributions).single;
        await tester.pumpWidget(host(isCurrent: () => current));
        expect(coordinator.canOpen(owner, action), isTrue);
        expect(() => coordinator.open(owner, action), throwsStateError);
        expect(factories, 1);
        expect(coordinator.canOpen(owner, action), isFalse);
        expect(() => coordinator.open(owner, action), throwsStateError);
        expect(factories, 1);
        await tester.pumpAndSettle();
        expect(coordinator.hasSession, staleByRetirement);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(_Probe), findsNothing);
        expect(find.text('Main Content input is unavailable.'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'old host teardown cannot unmount the current coordinator attachment',
    (tester) async {
      final inputs = <MainContentAccess>[];
      final action = MainContentAction(
        id: 'choose',
        label: 'Choose resource',
        createPresentation: (access) {
          inputs.add(access);
          return _Probe('input');
        },
      );
      register('test.owner', (_) {}, actions: [action]);
      final owner = extensions.discover(mainContentContributions).single;
      final next = Session(
        id: session.id,
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      Widget hosts({required bool old, required bool current}) => MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final value in [if (old) session, if (current) next])
                SizedBox(
                  key: ObjectKey(value),
                  width: 350,
                  height: 400,
                  child: MainContentHost(
                    session: value,
                    extensions: extensions,
                    actionCoordinator: coordinator,
                  ),
                ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(hosts(old: true, current: false));
      coordinator.open(owner, action);
      await tester.pumpAndSettle();
      final original = tester.state<_ProbeState>(probe('input'));
      await tester.pumpWidget(hosts(old: true, current: true));
      await tester.pumpAndSettle();
      expect(original.disposed, isTrue);
      expect(coordinator.hasSession, isTrue);
      await tester.pumpWidget(hosts(old: false, current: true));
      expect(coordinator.canOpen(owner, action), isTrue);
      coordinator.open(owner, action);
      await tester.pumpAndSettle();
      expect(inputs.last.session, same(next));
      expect(inputs.first.isActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(coordinator.hasSession, isFalse);
      expect(coordinator.canOpen(owner, action), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing coordinators removes the old window bridge', (
    tester,
  ) async {
    final replacement = MainContentActionCoordinator();
    await tester.pumpWidget(host());
    expect(coordinator.hasSession, isTrue);
    expect(replacement.hasSession, isFalse);
    await tester.pumpWidget(host(actionCoordinator: replacement));
    expect(coordinator.hasSession, isFalse);
    expect(replacement.hasSession, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(replacement.hasSession, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final chatOrder in [100, 400]) {
    testWidgets(
      'Chat order $chatOrder and two Source panes get thirds in declared order',
      (tester) async {
        await wide(tester);
        registerChat(order: chatOrder);
        register('test.source', (access) {
          access.open(pane('a'));
          access.open(pane('b'));
        }, order: 300);
        register('test.empty', (_) {}, order: -1);
        await tester.pumpWidget(host());
        final expected = (1200 - 16 - 2) / 3;
        final ids = chatOrder == 100 ? ['chat', 'a', 'b'] : ['a', 'b', 'chat'];
        for (var i = 0; i < ids.length; i++) {
          expect(tester.getSize(probe(ids[i])).width, closeTo(expected, 0.001));
          expect(tester.getSize(probe(ids[i])).height, 400 - 16 - 32);
          expect(
            tester.getTopLeft(probe(ids[i])).dx,
            closeTo(8 + i * (expected + 1), 0.001),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'stable instances survive title, local order, width and registry changes',
    (tester) async {
      await wide(tester);
      late MainContentAccess access;
      late MainContentAccess chatAccess;
      var factories = 0;
      register('test.chat', (value) {
        chatAccess = value;
        value.open(pane('chat'));
      }, order: 100);
      register('test.group', (value) {
        access = value;
        for (final id in ['a', 'b']) {
          access.open(
            pane(
              id,
              create: () {
                factories++;
                return _Probe(id);
              },
            ),
          );
        }
      });
      await tester.pumpWidget(host());
      final a = tester.state<_ProbeState>(probe('a'));
      final aWidget = tester.widget(probe('a'));
      final chat = tester.state<_ProbeState>(probe('chat'));
      final chatWidget = tester.widget(probe('chat'));
      await tester.enterText(
        find.descendant(of: probe('a'), matching: find.byType(TextField)),
        'kept text',
      );
      access.setTitle('a', 'New title');
      access.setOrder(['b', 'a']);
      chatAccess.setTitle('chat', 'New Chat title');
      await tester.pumpWidget(host(width: 1050));
      register('test.before', (value) => value.open(pane('before')), order: -1);
      await tester.pumpAndSettle();
      expect(tester.state(probe('a')), same(a));
      expect(tester.widget(probe('a')), same(aWidget));
      expect(tester.state(probe('chat')), same(chat));
      expect(tester.widget(probe('chat')), same(chatWidget));
      expect(find.text('New Chat title'), findsOneWidget);
      expect(a.text.text, 'kept text');
      expect(factories, 2);
      expect(find.text('New title'), findsOneWidget);
      expect(
        tester.getTopLeft(probe('before')).dx,
        lessThan(tester.getTopLeft(probe('b')).dx),
      );
      expect(
        tester.getTopLeft(probe('b')).dx,
        lessThan(tester.getTopLeft(probe('a')).dx),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'minimum widths keep all panes mounted; focus reveals only local scroller',
    (tester) async {
      registerChat();
      late MainContentAccess access;
      var nativeFocus = 0;
      register('test.group', (value) {
        access = value;
        access.open(pane('a'));
        access.open(pane('b', requestFocus: () => nativeFocus++));
      });
      final outer = ScrollController(initialScrollOffset: 100);
      addTearDown(outer.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: outer,
              child: Column(
                children: [
                  const SizedBox(height: 300),
                  SizedBox(
                    width: 500,
                    height: 400,
                    child: MainContentHost(
                      session: session,
                      extensions: extensions,
                    ),
                  ),
                  const SizedBox(height: 600),
                ],
              ),
            ),
          ),
        ),
      );
      for (final id in ['a', 'b', 'chat']) {
        expect(tester.getSize(probe(id)).width, 320);
      }
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.descendant(
              of: find.byType(MainContentHost),
              matching: find.byType(SingleChildScrollView),
            ),
          )
          .controller!;
      final outerOffset = outer.offset;
      expect(scroll.offset, 0);
      access.focus('b');
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(outer.offset, outerOffset);
      expect(nativeFocus, 0);
      access.focus('b', keyboardFocus: true);
      await tester.pump();
      expect(nativeFocus, 1);
      expect(outer.offset, outerOffset);
      access.focus('a', keyboardFocus: true);
      await tester.pump();
      await tester.pump();
      expect(tester.state<_ProbeState>(probe('a')).focus.hasFocus, isTrue);
      expect(scroll.offset, 0);
      expect(outer.offset, outerOffset);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed pane factory is cached locally across unrelated rebuilds',
    (tester) async {
      registerChat();
      var attempts = 0;
      late MainContentAccess access;
      register('test.failed', (value) {
        access = value;
        value.open(
          pane(
            'bad',
            create: () {
              attempts++;
              throw StateError('fixture factory failure');
            },
          ),
        );
        value.open(pane('healthy'));
      });
      await tester.pumpWidget(host(width: 700));
      final healthy = tester.state(probe('healthy'));
      access.setTitle('bad', 'Failed pane');
      access.setOrder(['healthy', 'bad']);
      register('test.empty', (_) {});
      await tester.pumpWidget(host(width: 650));
      await tester.pump();
      expect(attempts, 1);
      expect(
        find.text('Main Content presentation is unavailable.'),
        findsOneWidget,
      );
      expect(tester.state(probe('healthy')), same(healthy));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'close is owner-driven; removal releases synchronously with siblings healthy',
    (tester) async {
      registerChat();
      await wide(tester);
      late MainContentAccess access;
      var closeRequests = 0;
      var releases = 0;
      late _ProbeState removed;
      register('test.group', (value) {
        access = value;
        value.open(
          pane(
            'a',
            onClose: () => closeRequests++,
            release: () {
              expect(removed.disposed, isFalse);
              releases++;
            },
          ),
        );
        value.open(pane('b'));
      });
      await tester.pumpWidget(host());
      removed = tester.state<_ProbeState>(probe('a'));
      final sibling = tester.state(probe('b'));
      await tester.tap(find.byTooltip('Close a'));
      expect(closeRequests, 1);
      expect(access.panes, hasLength(2));
      access.remove('a');
      expect(releases, 1);
      access.remove('a');
      await tester.pump();
      expect(releases, 1);
      expect(removed.disposed, isTrue);
      expect(tester.state(probe('b')), same(sibling));
      expect(find.byTooltip('Close b'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(releases, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-ID replacement retires old access and preserves sibling state',
    (tester) async {
      registerChat();
      final accesses = <MainContentAccess>[];
      var releases = 0;
      void attach(MainContentAccess access) {
        accesses.add(access);
        access.open(pane('owned', release: () => releases++));
      }

      final oldRegistration = register('test.owner', attach);
      register('test.sibling', (access) => access.open(pane('sibling')));
      await tester.pumpWidget(host(width: 700));
      final original = tester.state(probe('owned'));
      final sibling = tester.state(probe('sibling'));
      final close = oldRegistration.close();
      expect(() => accesses.single.focus('owned'), throwsStateError);
      register('test.owner', attach);
      await close;
      await tester.pumpAndSettle();
      expect(accesses, hasLength(2));
      expect(tester.state(probe('owned')), isNot(same(original)));
      expect(tester.state(probe('sibling')), same(sibling));
      expect(releases, 1);
      expect(accesses.first.isActive, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'canonical Session departure never retargets old access, even same ID',
    (tester) async {
      registerChat();
      final accesses = <MainContentAccess>[];
      final sessions = <Session>[];
      var releases = 0;
      register('test.group', (access) {
        accesses.add(access);
        sessions.add(access.session);
        access.open(pane('a', release: () => releases++));
      });
      await tester.pumpWidget(host(width: 700));
      final other = Session(
        id: session.id,
        taskId: session.taskId,
        strategyId: session.strategyId,
      );
      await tester.pumpWidget(host(width: 700, current: other));
      expect(sessions, [same(session), same(other)]);
      expect(accesses.first.isActive, isFalse);
      expect(() => accesses.first.open(pane('late')), throwsStateError);
      expect(releases, 1);
      await tester.pumpWidget(host(width: 700));
      expect(accesses, hasLength(3));
      expect(sessions.last, same(session));
      expect(accesses.first.isActive, isFalse);
      expect(releases, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shutdown retention preserves views without reviving access', (
    tester,
  ) async {
    registerChat();
    final retaining = ValueNotifier(false);
    addTearDown(retaining.dispose);
    late MainContentAccess access;
    var releases = 0;
    var replacements = 0;
    final action = MainContentAction(
      id: 'choose',
      label: 'Choose resource',
      createPresentation: (_) => _Probe('input'),
    );
    final registration = register('test.group', (value) {
      access = value;
      access.open(pane('a', release: () => releases++));
    }, actions: [action]);
    final owner = extensions
        .discover(mainContentContributions)
        .singleWhere((item) => item.id.value == 'test.group');
    await tester.pumpWidget(
      PreparedFrontendRetention(notifier: retaining, child: host(width: 700)),
    );
    final original = tester.state(probe('a'));
    coordinator.open(owner, action);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    retaining.value = true;
    await registration.close();
    register('test.group', (_) => replacements++);
    await tester.pumpAndSettle();
    expect(coordinator.hasSession, isFalse);
    expect(coordinator.canOpen(owner, action), isFalse);
    expect(() => coordinator.open(owner, action), throwsStateError);
    expect(find.byType(Dialog), findsNothing);
    expect(access.isActive, isFalse);
    expect(() => access.remove('a'), throwsStateError);
    expect(tester.state(probe('a')), same(original));
    expect(replacements, 0);
    expect(releases, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(releases, 1);
    expect(tester.takeException(), isNull);
  });
}

class _Probe extends StatefulWidget {
  _Probe(this.id) : super(key: ValueKey(id));

  final String id;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final text = TextEditingController();
  final focus = FocusNode();
  bool disposed = false;

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: Column(
      children: [TextField(controller: text, focusNode: focus)],
    ),
  );

  @override
  void dispose() {
    disposed = true;
    text.dispose();
    focus.dispose();
    super.dispose();
  }
}
