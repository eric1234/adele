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

  setUp(() {
    extensions = ExtensionRegistry();
    session = Session(
      id: SessionId('session'),
      taskId: TaskId('task'),
      strategyId: OrchestrationStrategyId('test.strategy'),
    );
  });

  ExtensionRegistration register(
    String id,
    void Function(MainContentAccess) attach, {
    int order = 0,
  }) => extensions.register(
    point: mainContentContributions,
    id: ExtensionId(id),
    value: MainContentContribution(order: order, attach: attach),
  );

  Widget host({
    double width = 1200,
    Session? current,
    bool Function()? isCurrent,
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
    final registration = register('test.group', (value) {
      access = value;
      access.open(pane('a', release: () => releases++));
    });
    await tester.pumpWidget(
      PreparedFrontendRetention(notifier: retaining, child: host(width: 700)),
    );
    final original = tester.state(probe('a'));
    retaining.value = true;
    await registration.close();
    register('test.group', (_) => replacements++);
    await tester.pumpAndSettle();
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
