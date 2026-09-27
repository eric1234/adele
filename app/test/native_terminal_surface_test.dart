import 'package:adele_desktop/terminal/native_terminal_surface.dart';
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

void main() {
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
