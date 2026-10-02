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
    Widget? strategy,
    String strategyTitle = 'Strategy',
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
            strategyContent: strategy ?? _Probe('strategy'),
            strategyTitle: strategyTitle,
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

  Finder probe(String id) => find.byKey(ValueKey(id));

  Future<void> wide(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets(
    'strategy and two panes each get one third, empty groups no width',
    (tester) async {
      await wide(tester);
      register('test.two', (access) {
        access.open(pane('a'));
        access.open(pane('b'));
      });
      register('test.empty', (_) {}, order: -1);
      await tester.pumpWidget(host());
      final expected = (1200 - 16 - 2) / 3;
      for (final id in ['a', 'b', 'strategy']) {
        expect(tester.getSize(probe(id)).width, closeTo(expected, 0.001));
        expect(tester.getSize(probe(id)).height, 400 - 16 - 32);
      }
      expect(
        tester.getTopLeft(probe('a')).dx,
        lessThan(tester.getTopLeft(probe('b')).dx),
      );
      expect(
        tester.getTopLeft(probe('b')).dx,
        lessThan(tester.getTopLeft(probe('strategy')).dx),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stable instances survive title, local order, width and registry changes',
    (tester) async {
      await wide(tester);
      late MainContentAccess access;
      var factories = 0;
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
      final strategy = tester.state<_ProbeState>(probe('strategy'));
      await tester.enterText(
        find.descendant(of: probe('a'), matching: find.byType(TextField)),
        'kept text',
      );
      access.setTitle('a', 'New title');
      access.setOrder(['b', 'a']);
      await tester.pumpWidget(
        host(
          width: 1050,
          strategy: _Probe('strategy', revision: 'updated'),
          strategyTitle: 'New strategy title',
        ),
      );
      register('test.before', (value) => value.open(pane('before')), order: -1);
      await tester.pumpAndSettle();
      expect(tester.state(probe('a')), same(a));
      expect(tester.widget(probe('a')), same(aWidget));
      expect(tester.state(probe('strategy')), same(strategy));
      expect(find.text('updated'), findsOneWidget);
      expect(find.text('New strategy title'), findsOneWidget);
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
    'legacy strategy display names cannot tear down independent panes',
    (tester) async {
      register('test.group', (access) => access.open(pane('healthy')));
      await tester.pumpWidget(
        host(width: 700, strategyTitle: 'Legacy\n${'x' * 200}'),
      );
      final healthy = tester.state(probe('healthy'));
      final strategy = tester.state(probe('strategy'));
      expect(find.textContaining(r'Legacy\n'), findsOneWidget);
      await tester.pumpWidget(
        host(width: 700, strategyTitle: '\u{1f680}' * 200),
      );
      expect(tester.state(probe('healthy')), same(healthy));
      expect(tester.state(probe('strategy')), same(strategy));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'minimum widths keep all panes mounted; focus reveals only local scroller',
    (tester) async {
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
                      strategyContent: _Probe('strategy'),
                      strategyTitle: 'Strategy',
                    ),
                  ),
                  const SizedBox(height: 600),
                ],
              ),
            ),
          ),
        ),
      );
      for (final id in ['a', 'b', 'strategy']) {
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
  _Probe(this.id, {this.revision = ''}) : super(key: ValueKey(id));

  final String id;
  final String revision;

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
      children: [
        Text(widget.revision),
        TextField(controller: text, focusNode: focus),
      ],
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
