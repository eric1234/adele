import 'package:adele_desktop/terminal/native_terminal_surface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

Widget _host(Widget view, {double width = 480, double height = 240}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: view),
        ),
      ),
    );

Terminal _terminal(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

String _text(Terminal terminal) => [
  for (var i = 0; i < terminal.buffer.lines.length; i++)
    terminal.buffer.lines[i].getText().trimRight(),
].join('\n');

void _expectProjectionRowVisible(WidgetTester tester, int row) {
  final render = tester
      .state<TerminalViewState>(find.byType(TerminalView))
      .renderTerminal;
  final top = render.getOffset(CellOffset(0, row)).dy;
  expect(top, greaterThanOrEqualTo(-0.01));
  expect(top + render.lineHeight, lessThanOrEqualTo(render.size.height + 0.01));
}

void main() {
  for (final following in [false, true]) {
    testWidgets('reveal paints only settled ${following ? 'tail' : 'offset'}', (
      tester,
    ) async {
      final surface = NativeTerminalSurface.projection(rows: 20, maxLines: 40);
      addTearDown(surface.dispose);
      surface.hideProjection();
      final view = surface.buildView(isActive: () => true);
      await tester.pumpWidget(_host(view, height: 130));
      _feedProjection(surface, '${'row\n' * 60}TAIL');
      if (!following) surface.scrollProjection(120);
      var revealed = false;
      final reveal = surface.revealProjection().then(
        (value) => revealed = value,
      );
      final gate = find.ancestor(
        of: find.byType(TerminalView),
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(gate).opacity, 0);
      expect(surface.readProjection()['ready'], isFalse);
      expect(find.byType(TerminalView).hitTestable(), findsNothing);
      var sawPaint = false;
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump();
        if (tester.widget<Opacity>(gate).opacity == 0) {
          expect(revealed, isFalse);
          continue;
        }
        sawPaint = true;
        final terminal = _terminal(tester);
        expect(_text(terminal), contains('TAIL'));
        if (following) {
          _expectProjectionRowVisible(tester, terminal.buffer.absoluteCursorY);
        } else {
          expect(surface.readProjection()['scrollOffset'], 120.0);
          final render = tester
              .state<TerminalViewState>(find.byType(TerminalView))
              .renderTerminal;
          expect(
            render.getOffset(const CellOffset(0, 0)).dy,
            closeTo(-120, .01),
          );
        }
      }
      await reveal;
      expect(sawPaint, isTrue);
      expect(revealed, isTrue);
      // Ordinary accepted output does not close the readiness gate again.
      if (following) {
        surface.feedProjection('-live', 20);
        await tester.pump();
        expect(tester.widget<Opacity>(gate).opacity, 1);
        expect(surface.readProjection()['ready'], isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('hide and detach cancel pending reveal without stale paint', (
    tester,
  ) async {
    final surface = NativeTerminalSurface.projection(rows: 20);
    addTearDown(surface.dispose);
    surface.hideProjection();
    await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
    final first = surface.revealProjection();
    surface.hideProjection();
    expect(await first, isFalse);
    await tester.pump();
    expect(surface.readProjection()['ready'], isFalse);
    final second = surface.revealProjection();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(await second, isFalse);
    expect(surface.readProjection()['ready'], isFalse);
    final third = surface.revealProjection();
    surface.dispose();
    expect(await third, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('projection retains its last offset after native detach', (
    tester,
  ) async {
    final surface = NativeTerminalSurface.projection(rows: 20, maxLines: 40);
    addTearDown(surface.dispose);
    var active = true;
    _feedProjection(surface, 'row\n' * 60);
    await tester.pumpWidget(
      _host(surface.buildView(isActive: () => active), height: 130),
    );
    await tester.pump();
    surface.scrollProjection(120);
    final before = surface.readProjection();
    expect(before['scrollOffset'], 120.0);
    expect(before['maxScrollOffset'], greaterThan(120));
    active = false;
    await tester.pumpWidget(const SizedBox.shrink());
    final detached = surface.readProjection();
    expect(detached['scrollOffset'], before['scrollOffset']);
    expect(detached['maxScrollOffset'], before['maxScrollOffset']);
    expect(detached['following'], isFalse);
    expect(detached['acceptedCodeUnits'], before['acceptedCodeUnits']);
    expect(tester.takeException(), isNull);
  });

  test(
    'native projection checkpoints synchronously record accepted prefixes',
    () {
      final surface = NativeTerminalSurface.projection(rows: 6, maxLines: 24);
      addTearDown(surface.dispose);
      final snapshots = <Map<String, Object>>[];
      final detach = surface.observeProjection(
        () => snapshots.add(surface.readProjection()),
      );
      final accepted = surface.feedProjection('x' * 5000, 2);
      expect(accepted, 161);
      expect(snapshots, hasLength(1));
      expect(snapshots.single['acceptedCodeUnits'], accepted);
      expect(snapshots.single['lineAdvances'], 2);
      surface.setProjectionFollow(false, resumeAtEnd: false);
      expect(snapshots.last['following'], isFalse);
      expect(snapshots.last['resumeAtEnd'], isFalse);
      detach();
      final count = snapshots.length;
      surface.resetProjection();
      expect(snapshots, hasLength(count));
    },
  );

  for (final rows in [6, 20]) {
    testWidgets(
      'always-follow policy with $rows rows bubbles scroll and keeps copy local',
      (tester) async {
        final surface = NativeTerminalSurface.projection(
          rows: rows,
          alwaysFollow: true,
          maxLines: 40,
        );
        addTearDown(surface.dispose);
        _feedProjection(surface, '${'row\n' * 60}TAIL');
        final outer = ScrollController();
        addTearDown(outer.dispose);
        final copied = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 250,
                height: 300,
                child: ListView(
                  controller: outer,
                  children: [
                    const SizedBox(height: 100),
                    SizedBox(
                      height: 100,
                      child: surface.buildView(isActive: () => true),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final view = tester.widget<TerminalView>(find.byType(TerminalView));
        final terminal = view.terminal;
        final cursor = terminal.buffer.absoluteCursorY;
        view.controller!.setSelection(
          terminal.buffer.createAnchor(0, cursor),
          terminal.buffer.createAnchor(4, cursor),
        );
        expect(surface.readProjection()['following'], isTrue);
        final context = tester.element(
          find
              .descendant(
                of: find.byType(TerminalView),
                matching: find.byType(Scrollable),
              )
              .last,
        );
        Actions.invoke(context, CopySelectionTextIntent.copy);
        await tester.pump();
        expect(copied, ['TAIL']);
        final offset = view.scrollController!.offset;
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position:
                tester.getTopLeft(find.byType(TerminalView)) +
                const Offset(40, 50),
            scrollDelta: const Offset(0, 60),
          ),
        );
        expect(outer.offset, 60);
        expect(view.scrollController!.offset, offset);
        expect(surface.readProjection()['following'], isTrue);
        await tester.pump();
        await tester.dragFrom(
          tester.getTopLeft(find.byType(TerminalView)) + const Offset(40, 50),
          const Offset(0, -40),
        );
        await tester.pumpAndSettle();
        expect(outer.offset, greaterThan(60));
        surface.setProjectionFollow(false, resumeAtEnd: false);
        surface.scrollProjection(0);
        expect(surface.readProjection()['following'], isTrue);
        expect(surface.feedProjection('\nNEXT', rows), 5);
        await tester.pump();
        await tester.pump();
        expect(_text(_terminal(tester)), endsWith('TAIL\nNEXT'));
        view.controller!.clearSelection();
        expect(surface.readProjection()['following'], isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'explicit history cannot auto-resume at bottom across reset or remount',
    (tester) async {
      final surface = NativeTerminalSurface.projection(rows: 6, maxLines: 40);
      addTearDown(surface.dispose);
      surface.setProjectionFollow(false, resumeAtEnd: false);
      surface.resetProjection();
      expect(surface.readProjection()['resumeAtEnd'], isFalse);
      _feedProjection(surface, '${'row\n' * 60}HISTORY');
      surface.setProjectionFollow(false, resumeAtEnd: false);
      surface.scrollProjection(0);
      await tester.pumpWidget(
        _host(surface.buildView(isActive: () => true), height: 100),
      );
      await tester.pump();
      final point =
          tester.getTopLeft(find.byType(TerminalView)) + const Offset(50, 50);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 5000)),
      );
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.feedProjection('blocked', 6), 0);
      final position = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .scrollController!
          .position;
      expect(position.pixels, position.maxScrollExtent);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(surface.buildView(isActive: () => true), height: 100),
      );
      await tester.pump();
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.readProjection()['resumeAtEnd'], isFalse);
      surface.setProjectionFollow(true);
      expect(surface.readProjection()['following'], isTrue);
      expect(surface.feedProjection('\nLIVE', 6), 5);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final gesture in ['wheel', 'drag']) {
    testWidgets('user $gesture return to live end resumes frozen feed', (
      tester,
    ) async {
      final surface = NativeTerminalSurface.projection(rows: 20, maxLines: 40);
      addTearDown(surface.dispose);
      _feedProjection(surface, '${'row\n' * 60}TAIL');
      await tester.pumpWidget(
        _host(surface.buildView(isActive: () => true), height: 130),
      );
      await tester.pump();
      final point =
          tester.getTopLeft(find.byType(TerminalView)) + const Offset(50, 60);
      if (gesture == 'wheel') {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: point,
            scrollDelta: const Offset(0, -60),
          ),
        );
      } else {
        await tester.dragFrom(point, const Offset(0, 60));
        await tester.pumpAndSettle();
      }
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.feedProjection('\nqueued', 20), 0);
      if (gesture == 'wheel') {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: point,
            scrollDelta: const Offset(0, 5000),
          ),
        );
      } else {
        await tester.dragFrom(point, const Offset(0, -1000));
        await tester.pumpAndSettle();
      }
      expect(surface.readProjection()['following'], isTrue);
      expect(surface.feedProjection('\nqueued', 20), 7);
      await tester.pump();
      await tester.pump();
      expect(_text(_terminal(tester)), endsWith('TAIL\nqueued'));
      _expectProjectionRowVisible(
        tester,
        _terminal(tester).buffer.absoluteCursorY,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'live-end return uses rendered cursor before blank padding and protects selection',
    (tester) async {
      final surface = NativeTerminalSurface.projection(rows: 20);
      addTearDown(surface.dispose);
      _feedProjection(surface, '${'row\n' * 9}TAIL');
      await tester.pumpWidget(
        _host(surface.buildView(isActive: () => true), height: 80),
      );
      await tester.pump();
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      final end = view.scrollController!.offset;
      expect(end, greaterThan(0));
      expect(end, lessThan(view.scrollController!.position.maxScrollExtent));
      final point =
          tester.getTopLeft(find.byType(TerminalView)) + const Offset(50, 40);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: point,
          scrollDelta: const Offset(0, -5000),
        ),
      );
      expect(surface.readProjection()['following'], isFalse);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: Offset(0, end)),
      );
      expect(surface.readProjection()['following'], isTrue);
      _expectProjectionRowVisible(tester, 9);
      final terminal = view.terminal;
      view.controller!.setSelection(
        terminal.buffer.createAnchor(0, 9),
        terminal.buffer.createAnchor(4, 9),
      );
      expect(surface.readProjection()['following'], isFalse);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: point,
          scrollDelta: const Offset(0, -5000),
        ),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: Offset(0, end)),
      );
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.feedProjection('blocked', 20), 0);
      view.controller!.clearSelection();
      await tester.pump();
      expect(surface.readProjection()['following'], isFalse);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, -20)),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 20)),
      );
      expect(surface.readProjection()['following'], isTrue);
      surface.dispose();
      await tester.pump();
      expect(find.byType(TerminalView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'programmatic movement layout and remount do not resume a paused tail',
    (tester) async {
      final surface = NativeTerminalSurface.projection(rows: 20, maxLines: 40);
      addTearDown(surface.dispose);
      _feedProjection(surface, 'row\n' * 60);
      final view = surface.buildView(isActive: () => true);
      await tester.pumpWidget(_host(view, height: 130));
      await tester.pump();
      surface.scrollProjection(0);
      await tester.pump();
      final controller = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .scrollController!;
      controller.jumpTo(controller.position.maxScrollExtent);
      expect(surface.readProjection()['following'], isFalse);
      controller.jumpTo(0);
      final animation = controller.animateTo(
        controller.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear,
      );
      await tester.pumpAndSettle();
      await animation;
      expect(surface.readProjection()['following'], isFalse);
      await tester.pumpWidget(_host(view, height: 300));
      await tester.pump();
      expect(surface.readProjection()['following'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(surface.buildView(isActive: () => true), height: 130),
      );
      await tester.pump();
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.feedProjection('blocked', 20), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'short projection output stays painted above fixed screen padding',
    (tester) async {
      final surface = NativeTerminalSurface.projection(rows: 20, maxLines: 24);
      addTearDown(surface.dispose);
      final view = surface.buildView(isActive: () => true);
      await tester.pumpWidget(_host(view, width: 250, height: 130));
      await tester.pump();
      expect(surface.feedProjection('BEGIN\nPART', 20), 10);
      await tester.pump();
      await tester.pump();
      final terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );
      expect(terminalView.terminal.viewHeight, 20);
      expect(terminalView.terminal.viewWidth, 80);
      expect(
        terminalView.scrollController!.position.maxScrollExtent,
        greaterThan(0),
      );
      expect(terminalView.scrollController!.offset, 0);
      _expectProjectionRowVisible(tester, 0);
      _expectProjectionRowVisible(tester, 1);
      expect(_text(_terminal(tester)), startsWith('BEGIN\nPART'));

      // Explicit follow, layout changes and complete remount must use the same
      // rendered cursor geometry, not the blank rows' physical scroll extent.
      surface.scrollProjection(
        terminalView.scrollController!.position.maxScrollExtent,
      );
      await tester.pump();
      surface.setProjectionFollow(true);
      await tester.pump();
      await tester.pump();
      _expectProjectionRowVisible(tester, 0);
      _expectProjectionRowVisible(tester, 1);
      await tester.pumpWidget(_host(view, width: 250, height: 40));
      await tester.pump();
      _expectProjectionRowVisible(tester, 1);
      expect(surface.readProjection()['following'], isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _host(surface.buildView(isActive: () => true), width: 250, height: 130),
      );
      await tester.pump();
      _expectProjectionRowVisible(tester, 0);
      _expectProjectionRowVisible(tester, 1);
      final horizontal = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .singleWhere((state) => state.position.axis == Axis.horizontal);
      expect(horizontal.position.maxScrollExtent, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'projection follows painted cursor through full scrollback and resize',
    (tester) async {
      final surface = NativeTerminalSurface.projection(rows: 20, maxLines: 24);
      addTearDown(surface.dispose);
      var active = true;
      final view = surface.buildView(isActive: () => active);
      await tester.pumpWidget(_host(view, height: 130));
      _feedProjection(
        surface,
        '${List.generate(70, (index) => 'row $index\n').join()}TAIL',
      );
      await tester.pump();
      await tester.pump();
      expect(_terminal(tester).buffer.height, 24);
      _expectProjectionRowVisible(
        tester,
        _terminal(tester).buffer.absoluteCursorY,
      );
      expect(_text(_terminal(tester)), endsWith('TAIL'));
      await tester.pumpWidget(_host(view, height: 60));
      await tester.pump();
      _expectProjectionRowVisible(
        tester,
        _terminal(tester).buffer.absoluteCursorY,
      );
      expect(surface.readProjection()['following'], isTrue);

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position:
              tester.getTopLeft(find.byType(TerminalView)) +
              const Offset(40, 30),
          scrollDelta: const Offset(0, -40),
        ),
      );
      expect(surface.readProjection()['following'], isFalse);
      final frozen = surface.readProjection()['scrollOffset'];
      expect(surface.feedProjection('\nblocked', 20), 0);
      await tester.pump();
      expect(surface.readProjection()['scrollOffset'], frozen);
      surface.setProjectionFollow(true);
      _feedProjection(surface, '\nNEW TAIL');
      await tester.pump();
      await tester.pump();
      _expectProjectionRowVisible(
        tester,
        _terminal(tester).buffer.absoluteCursorY,
      );
      expect(_text(_terminal(tester)), endsWith('NEW TAIL'));

      // A queued output-follow correction cannot move a retired mount.
      _feedProjection(surface, '\nqueued');
      final offset = surface.readProjection()['scrollOffset'];
      active = false;
      await tester.pump();
      expect(surface.readProjection()['scrollOffset'], offset);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pipe projection fixes geometry and LF policy without changing PTY',
    (tester) async {
      final pipe = NativeTerminalSurface.projection(rows: 6, maxLines: 24);
      addTearDown(pipe.dispose);
      _feedProjection(pipe, 'first\nsecond\n\x1b[20lthird\n\x1b[31mred\x1b[0m');
      await tester.pumpWidget(
        _host(pipe.buildView(isActive: () => true), width: 250),
      );
      expect(_terminal(tester).viewWidth, 80);
      expect(_terminal(tester).viewHeight, 6);
      expect(_text(_terminal(tester)), startsWith('first\nsecond\nthird\nred'));
      expect(
        _terminal(tester).buffer.lines[3].getForeground(0) &
            CellColor.valueMask,
        1,
      );
      final scrolls = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .toList();
      final horizontal = scrolls.singleWhere(
        (state) => state.position.axis == Axis.horizontal,
      );
      expect(horizontal.position.maxScrollExtent, greaterThan(0));
      _feedProjection(pipe, '\x1b[8;999;999t');
      pipe.resize(100, 30);
      await tester.pump();
      expect(_terminal(tester).viewWidth, 80);
      expect(_terminal(tester).viewHeight, 6);
      await tester.pumpWidget(const SizedBox.shrink());

      final pty = NativeTerminalSurface();
      addTearDown(pty.dispose);
      await tester.pumpWidget(_host(pty.buildView(isActive: () => true)));
      pty.write('first\nsecond');
      expect(_terminal(tester).buffer.lines[1].getCodePoint(0), 0);
      expect(
        _terminal(tester).buffer.lines[1].getCodePoint(5),
        's'.codeUnitAt(0),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('bounded row replay reaches every character of one huge chunk', (
    tester,
  ) async {
    final surface = NativeTerminalSurface.projection(rows: 6, maxLines: 24);
    addTearDown(surface.dispose);
    final text = List.generate(
      18000,
      (index) => String.fromCharCode(33 + index % 90),
    ).join();
    final view = surface.buildView(isActive: () => true);
    await tester.pumpWidget(_host(view));
    var previousEnd = 0;
    var endpoint = 16;
    while (previousEnd < text.length) {
      surface.resetProjection();
      var offset = 0;
      while (offset < text.length &&
          (surface.readProjection()['lineAdvances']! as int) < endpoint) {
        final remaining =
            endpoint - (surface.readProjection()['lineAdvances']! as int);
        final accepted = surface.feedProjection(
          text.substring(offset),
          remaining,
        );
        expect(
          accepted,
          inInclusiveRange(1, NativeTerminalSurface.maxProjectionFeedCodeUnits),
        );
        offset += accepted;
      }
      surface.setProjectionFollow(false);
      await tester.pump();
      final terminal = _terminal(tester);
      expect(terminal.buffer.height, lessThanOrEqualTo(24));
      final rendered = [
        for (var i = 0; i < terminal.buffer.height; i++)
          terminal.buffer.lines[i].getText().trimRight(),
      ].join();
      expect(rendered, contains(text.substring(previousEnd, offset)));
      expect(surface.readProjection()['acceptedCodeUnits'], offset);
      expect(surface.feedProjection('not accepted', 6), 0);
      previousEnd = offset;
      endpoint += 16;
    }
    expect(previousEnd, text.length);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'feed character bound is Unicode safe and reset drops split parser state',
    (tester) async {
      final surface = NativeTerminalSurface.projection(rows: 20);
      addTearDown(surface.dispose);
      final prefix = 'a' * 1023;
      final input = '$prefix\u{1f642}tail';
      expect(surface.feedProjection(input, 20), 1023);
      expect(surface.feedProjection(input.substring(1023), 20), 6);
      await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
      expect(_text(_terminal(tester)), contains('\u{1f642}tail'));
      surface.resetProjection();
      expect(surface.feedProjection('\ud83d', 20), 1);
      expect(surface.feedProjection('\ude42', 20), 1);
      await tester.pump();
      expect(_text(_terminal(tester)).trim(), '\u{1f642}');
      surface.feedProjection('\x1b]2;incomplete', 20);
      surface.resetProjection();
      surface.feedProjection('clean\nnext', 20);
      await tester.pump();
      expect(_text(_terminal(tester)).trimRight(), 'clean\nnext');
      expect(surface.title, isNull);
      expect(surface.readProjection()['lineAdvances'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('projection preserves supported REP without silent truncation', (
    tester,
  ) async {
    final surface = NativeTerminalSurface.projection(rows: 6, maxLines: 24);
    addTearDown(surface.dispose);
    const input = 'x\x1b[160b';
    expect(surface.feedProjection(input, 6), input.length);
    expect(surface.readProjection()['lineAdvances'], 2);
    expect(surface.readProjection()['acceptedCodeUnits'], input.length);
    await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
    expect(_text(_terminal(tester)).replaceAll('\n', ''), 'x' * 161);
    expect(_terminal(tester).buffer.height, lessThanOrEqualTo(24));
    surface.resetProjection();
    const boundary = 'x\x1b[1024b';
    expect(surface.feedProjection(boundary, 6), boundary.length);
    expect(surface.readProjection()['acceptedCodeUnits'], boundary.length);
    await tester.pump();
    expect(_text(_terminal(tester)).replaceAll('\n', ''), 'x' * 1025);
    surface.resetProjection();
    _feedProjection(
      surface,
      'a\x1b]2;${'x' * 9000}\x07b\x1bP${'y' * 9000}\x1b\\c',
    );
    await tester.pump();
    expect(_text(_terminal(tester)).trim(), 'abc');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unsupported REP retires projection without acknowledging source',
    (tester) async {
      for (final count in [1025, 999999999]) {
        final surface = NativeTerminalSurface.projection(rows: 6, maxLines: 24);
        addTearDown(surface.dispose);
        expect(surface.feedProjection('prior', 6), 5);
        await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
        expect(surface.feedProjection('x\x1b[${count}bmust not render', 6), -1);
        expect(surface.isDisposed, isTrue);
        expect(surface.readProjection, throwsStateError);
        expect(surface.resetProjection, throwsStateError);
        expect(() => surface.feedProjection('late', 6), throwsStateError);
        await tester.pump();
        expect(find.byType(TerminalView), findsNothing);
        expect(find.text('Terminal surface unavailable.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'scroll-away freezes before observation and selection remains local',
    (tester) async {
      final surface = NativeTerminalSurface.projection(rows: 6, maxLines: 40);
      addTearDown(surface.dispose);
      var notifications = 0;
      surface.observeProjection(() => notifications++);
      _feedProjection(
        surface,
        List.generate(70, (index) => 'line $index\n').join(),
      );
      await tester.pumpWidget(
        _host(surface.buildView(isActive: () => true), height: 100),
      );
      await tester.pump();
      expect(surface.readProjection()['following'], isTrue);
      final before = _text(_terminal(tester));
      await tester.dragFrom(
        tester.getTopLeft(find.byType(TerminalView)) + const Offset(80, 50),
        const Offset(0, 80),
      );
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.feedProjection('new\n' * 100, 6), 0);
      expect(_text(_terminal(tester)), before);
      await tester.pump();
      expect(notifications, greaterThan(0));
      final copied = <String>[];
      final clipboardQueries = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          if (call.method == 'Clipboard.getData') {
            clipboardQueries.add(call.method);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final context = tester.element(
        find
            .descendant(
              of: find.byType(TerminalView),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      Actions.invoke(context, CopySelectionTextIntent.copy);
      Actions.invoke(
        context,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();
      expect(copied.single, contains('line 69'));
      expect(clipboardQueries, isEmpty);
      surface.setProjectionFollow(true);
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position:
              tester.getTopLeft(find.byType(TerminalView)) +
              const Offset(80, 50),
          scrollDelta: const Offset(0, -40),
        ),
      );
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.feedProjection('wheel-frozen', 6), 0);
      surface.setProjectionFollow(true);
      _feedProjection(
        surface,
        '\x1b[?1000h\x1b[?1004h\x1b[6n\x1b]52;c;?\x07\x1b]8;;https://example.test\x07link',
      );
      expect(clipboardQueries, isEmpty);
      expect(_terminal(tester).mouseMode, MouseMode.none);
      expect(_terminal(tester).keyInput(TerminalKey.keyA), isFalse);
      _terminal(tester).paste('denied');
      expect(_text(_terminal(tester)), isNot(contains('denied')));
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      expect(surface.readProjection()['following'], isFalse);
      expect(surface.feedProjection('selection-frozen', 6), 0);
      surface.dispose();
      final count = notifications;
      await tester.pump();
      expect(notifications, count);
      expect(() => surface.feedProjection('late', 6), throwsStateError);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test('native title parser handles every split of OSC 0 and OSC 2', () async {
    for (final sequence in ['\x1b]0;first\x07', '\x1b]2;second\x1b\\']) {
      for (var split = 1; split < sequence.length; split++) {
        final surface = NativeTerminalSurface();
        final titles = <String?>[];
        surface.observeTitle(() => titles.add(surface.title));
        surface.write(sequence.substring(0, split));
        expect(surface.title, isNull);
        surface.write(sequence.substring(split));
        final expected = sequence.contains('first') ? 'first' : 'second';
        expect(surface.title, expected);
        await Future<void>.delayed(Duration.zero);
        expect(titles, [expected]);
        surface.dispose();
      }
    }

    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    surface.write('\x1b]0;original\x07\x1b[22;2t');
    surface.write('\x1b]2;temporary\x07');
    expect(surface.title, 'temporary');
    surface.write('\x1b[23;2t');
    expect(surface.title, 'original');
    surface.write('\x1b]1;icon only\x07');
    expect(surface.title, 'original');
  });

  test('untrusted titles become bounded single-line labels or null', () {
    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    surface.write(
      '\x1b]2;  work\u2028\u202e  \u2066tree\u2069\u007f label\ufeff  \x07',
    );
    expect(surface.title, 'work tree label');
    surface.write('\x1b]2;${'a' * 159}\u{1f642}tail\x07');
    expect(surface.title, 'a' * 159);
    surface.write('\x1b]2;${'a' * 158}\u{1f642}tail\x07');
    expect(surface.title, '${'a' * 158}\u{1f642}');
    expect(surface.title!.length, NativeTerminalSurface.maxTitleCodeUnits);
    surface.write('\x1b]2;  \u2028\u202e\u2066\ufeff \x07');
    expect(surface.title, isNull);
  });

  test(
    'title observers coalesce, isolate failure and detach deterministically',
    () async {
      final surface = NativeTerminalSurface();
      addTearDown(surface.dispose);
      final titles = <String?>[];
      var suppressed = 0;
      late VoidCallback detachLater;
      surface.observeTitle(() => throw StateError('Observer failed.'));
      surface.observeTitle(() => detachLater());
      detachLater = surface.observeTitle(() => suppressed++);
      void record() => titles.add(surface.title);
      final detachFirst = surface.observeTitle(record);
      final detachSecond = surface.observeTitle(record);
      detachFirst();
      detachFirst();
      surface.write('ordinary output\x1b]2;one\x07\x1b]2;two\x07');
      await Future<void>.delayed(Duration.zero);
      expect(titles, ['two']);
      expect(suppressed, 0);
      surface.write('more output\x1b]2;  two  \x07');
      await Future<void>.delayed(Duration.zero);
      expect(titles, ['two']);
      surface.write('\x1b]2;three\x07');
      detachSecond();
      await Future<void>.delayed(Duration.zero);
      expect(titles, ['two']);
      surface.observeTitle(record);
      surface.write('\x1b]2;retained\x07');
      surface.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(titles, ['two']);
      expect(surface.title, 'retained');
      expect(() => surface.observeTitle(record), throwsStateError);
    },
  );

  testWidgets('title observation survives complete unmount and remount', (
    tester,
  ) async {
    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    final titles = <String?>[];
    surface.observeTitle(() => titles.add(surface.title));
    surface.write('\x1b]2;before mount\x07');
    await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
    await tester.pumpWidget(const SizedBox.shrink());
    surface.write('\x1b]2;while ');
    await tester.pump();
    expect(titles, ['before mount']);
    surface.write('hidden\x07');
    await tester.pump();
    expect(titles, ['before mount', 'while hidden']);
    await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
    expect(surface.title, 'while hidden');
    expect(titles, ['before mount', 'while hidden']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'ordered parsing retains controls, split escapes, style and Unicode',
    (tester) async {
      final surface = NativeTerminalSurface();
      addTearDown(surface.dispose);
      await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
      final terminal = _terminal(tester);
      surface.write('obsolete status\rOK\x1b[');
      surface.write('K\r\nabc\x1b[2DXY\r\n\x1b[1;3');
      surface.write('1mred\x1b[0m \u03bb\u754c e\u0301');
      await tester.pump();
      expect(terminal.buffer.lines[0].getText().trimRight(), 'OK');
      expect(terminal.buffer.lines[1].getText().trimRight(), 'aXY');
      expect(
        terminal.buffer.lines[2].getText().trimRight(),
        'red \u03bb\u754c e\u0301',
      );
      final styled = terminal.buffer.lines[2];
      expect(styled.getForeground(0) & CellColor.valueMask, 1);
      expect(styled.getAttributes(0) & CellAttr.bold, isNonZero);
      expect(styled.getAttributes(3) & CellAttr.bold, 0);
      expect(styled.getWidth(5), 2);
      surface.write('\x1b[1;2H!');
      await tester.pump();
      expect(terminal.buffer.lines[0].getText().trimRight(), 'O!');
      surface.write('\x1b[?25l\x1b]10;#112233\x07');
      expect(terminal.cursorVisibleMode, isFalse);
      expect(terminal.foregroundColorOverride, 0x112233);
      surface.write('\x1b[?1049hALT');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(_text(terminal), contains('ALT'));
      surface.write('\x1b[?1049l\x1b[?25h');
      expect(terminal.isUsingAltBuffer, isFalse);
      expect(terminal.cursorVisibleMode, isTrue);
      expect(terminal.buffer.lines[0].getText().trimRight(), 'O!');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('finite buffer parses the full stream and retains recent state', (
    tester,
  ) async {
    final surface = NativeTerminalSurface(maxLines: 40);
    addTearDown(surface.dispose);
    surface.write('\x1b[31m');
    for (var i = 0; i < 150; i++) {
      surface.write('line $i\r\n');
    }
    surface.write('recent\rDONE\x1b[K');
    await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
    final terminal = _terminal(tester);
    expect(terminal.buffer.lines.length, lessThanOrEqualTo(40));
    expect(_text(terminal), isNot(contains('line 0\n')));
    expect(_text(terminal), contains('line 149\nDONE'));
    final line = terminal.buffer.lines[terminal.buffer.absoluteCursorY];
    expect(line.getForeground(0) & CellColor.valueMask, 1);
    expect(terminal.buffer.scrollBack, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    surface.write('\r\nwhile hidden');
    await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
    expect(_text(_terminal(tester)), contains('DONE\nwhile hidden'));
    expect(_terminal(tester).buffer.lines.length, lessThanOrEqualTo(40));
    surface.write('\x1b[8;99999;99999t');
    expect(_terminal(tester).viewWidth, 1000);
    expect(_terminal(tester).viewHeight, 40);
    expect(_terminal(tester).buffer.lines.length, lessThanOrEqualTo(40));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'read-only output still supports local scroll, selection and copy',
    (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final surface = NativeTerminalSurface(readOnly: true);
      addTearDown(surface.dispose);
      for (var i = 0; i < 60; i++) {
        surface.write('line $i\r\n');
      }
      surface.write('\x1b[?1000h\x1b[?1006h');
      await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
      final scrollable = find.descendant(
        of: find.byType(TerminalView),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsOneWidget);
      final position = tester.state<ScrollableState>(scrollable).position;
      final before = position.pixels;
      await tester.drag(find.byType(TerminalView), const Offset(0, 100));
      await tester.pump();
      expect(position.pixels, lessThan(before));
      final context = tester.element(scrollable);
      Actions.invoke(
        context,
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      Actions.invoke(context, CopySelectionTextIntent.copy);
      await tester.pump();
      expect(copied.single, contains('line 0'));
      expect(copied.single, contains('line 59'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('hidden replies belong to the owner, never to a mounted widget', () {
    final input = <String>[];
    final response = <String>[];
    final surface = NativeTerminalSurface(
      onInput: input.add,
      onResponse: response.add,
    );
    addTearDown(surface.dispose);
    surface.write('abc\x1b[6');
    expect(response, isEmpty);
    surface.write('n');
    expect(response, ['\x1b[1;4R']);
    expect(input, isEmpty);
    expect(() => NativeTerminalSurface(maxLines: 23), throwsArgumentError);
  });

  testWidgets(
    'native host platform selects macOS Option-arrow encoding',
    (tester) async {
      final input = <String>[];
      final surface = NativeTerminalSurface(onInput: input.add);
      addTearDown(surface.dispose);
      await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(input, ['\x1bb']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'reparented mounts fail unavailable rather than silently reconnect',
    (tester) async {
      final surface = NativeTerminalSurface();
      addTearDown(surface.dispose);
      final key = GlobalKey();
      var unavailable = 0;
      final view = KeyedSubtree(
        key: key,
        child: surface.buildView(
          isActive: () => true,
          onUnavailable: () => unavailable++,
        ),
      );
      Widget layout(bool moved) => _host(
        Row(
          children: [
            Expanded(child: moved ? const SizedBox.shrink() : view),
            Expanded(child: moved ? view : const SizedBox.shrink()),
          ],
        ),
      );
      await tester.pumpWidget(layout(false));
      final engine = _terminal(tester).buffer.terminal as Terminal;
      await tester.pumpWidget(layout(true));
      expect(find.byType(TerminalView), findsNothing);
      expect(find.text('Terminal surface unavailable.'), findsOneWidget);
      expect(unavailable, 1);
      expect(engine.listeners, isEmpty);
      surface.write('owner still live');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
      expect(_text(_terminal(tester)), contains('owner still live'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'one mounted attachment, no stealing, and fresh attachment after unmount',
    (tester) async {
      final surface = NativeTerminalSurface();
      addTearDown(surface.dispose);
      var rejected = 0;
      final first = surface.buildView(isActive: () => true);
      final second = surface.buildView(
        isActive: () => true,
        onUnavailable: () => rejected++,
      );
      await tester.pumpWidget(
        _host(
          Row(
            children: [
              Expanded(child: first),
              Expanded(child: second),
            ],
          ),
        ),
      );
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.text('Terminal surface unavailable.'), findsOneWidget);
      expect(rejected, 1);
      surface.write('still first');
      expect(_text(_terminal(tester)), contains('still first'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
      expect(_text(_terminal(tester)), contains('still first'));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'zero layout preserves geometry and resize notifications are distinct',
    (tester) async {
      final sizes = <(int, int)>[];
      final surface = NativeTerminalSurface(
        onResize: (c, r) => sizes.add((c, r)),
      );
      addTearDown(surface.dispose);
      final view = surface.buildView(isActive: () => true);
      await tester.pumpWidget(_host(view));
      final terminal = _terminal(tester);
      final previous = (terminal.viewWidth, terminal.viewHeight);
      expect(sizes, [previous]);
      await tester.pumpWidget(_host(view, width: 0, height: 0));
      expect((terminal.viewWidth, terminal.viewHeight), previous);
      expect(sizes, [previous]);
      await tester.pumpWidget(_host(view, width: 600));
      await tester.pump();
      expect(sizes.length, 2);
      expect(sizes.last.$1, greaterThan(previous.$1));
      expect(sizes.every((s) => s.$1 > 0 && s.$2 > 0), isTrue);
      await tester.pumpWidget(_host(view, width: 600));
      expect(sizes.length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('output cannot acquire clipboard or ambient desktop authority', (
    tester,
  ) async {
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method.startsWith('Clipboard.')) clipboard.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    surface.write(
      '\x1b]52;c;c2VjcmV0\x07\x1b]52;c;?\x07'
      '\x1b]8;;https://example.invalid\x07link\x1b]8;;\x07'
      '\x1b]777;notify;title;body\x07',
    );
    await tester.pump();
    expect(clipboard, isEmpty);
    expect(_text(_terminal(tester)), contains('link'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'owner disposal rejects late use, detaches view, and isolates siblings',
    (tester) async {
      final input = <String>[];
      final responses = <String>[];
      final sizes = <(int, int)>[];
      final surface = NativeTerminalSurface(
        onInput: input.add,
        onResponse: responses.add,
        onResize: (c, r) => sizes.add((c, r)),
      );
      final siblingResponses = <String>[];
      final sibling = NativeTerminalSurface(onResponse: siblingResponses.add);
      addTearDown(surface.dispose);
      addTearDown(sibling.dispose);
      final view = surface.buildView(isActive: () => true);
      await tester.pumpWidget(_host(view));
      final oldTerminal = _terminal(tester);
      final engine = oldTerminal.buffer.terminal as Terminal;
      final base = oldTerminal.buffer.createAnchor(0, 0);
      final extent = oldTerminal.buffer.createAnchor(2, 0);
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .controller!
          .setSelection(base, extent);
      final viewState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );
      sizes.clear();
      surface.write(
        '\x1b[?2026h',
      ); // Disposal must cancel synchronized-update timers.
      surface.dispose();
      surface.dispose();
      expect(surface.isDisposed, isTrue);
      expect(() => surface.write('late'), throwsStateError);
      expect(() => surface.buildView(isActive: () => true), throwsStateError);
      oldTerminal.textInput('late');
      oldTerminal.paste('late paste');
      oldTerminal.resize(100, 30);
      expect(input, isEmpty);
      expect(responses, isEmpty);
      expect(sizes, isEmpty);
      await tester.pump();
      expect(base.attached, isFalse);
      expect(extent.attached, isFalse);
      expect(engine.listeners, isEmpty);
      expect(viewState.mounted, isFalse);
      expect(find.byType(TerminalView), findsNothing);
      sibling.write('ok\x1b[6n');
      expect(siblingResponses, ['\x1b[1;3R']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(view));
      expect(find.byType(TerminalView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'owner disposal from layout callback defers Flutter teardown safely',
    (tester) async {
      late NativeTerminalSurface surface;
      surface = NativeTerminalSurface(onResize: (_, _) => surface.dispose());
      addTearDown(surface.dispose);
      await tester.pumpWidget(_host(surface.buildView(isActive: () => true)));
      await tester.pump();
      expect(surface.isDisposed, isTrue);
      expect(find.byType(TerminalView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

void _feedProjection(NativeTerminalSurface surface, String text) {
  var offset = 0;
  while (offset < text.length) {
    final accepted = surface.feedProjection(text.substring(offset), 20);
    expect(accepted, greaterThan(0));
    offset += accepted;
  }
}
