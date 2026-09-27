import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/terminal_surface_bridge.dart';
import 'package:adele_desktop/terminal/native_terminal_surface.dart';
import 'package:adele_ui/terminal_surface_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

const _library = 'package:terminal_probe/main.dart';
// Advance past the native terminal's multi-tap gesture window, not cursor blink.
const _frame = Duration(milliseconds: 350);

void main() {
  late Directory temporary;
  late File artifact;
  late Program program;
  late PreparedFrontend generation;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('adele-terminal-bridge-');
    artifact = File('${temporary.path}/terminal.evc');
    program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const TerminalSurfaceDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'terminal_probe': {
                'main.dart': await File(
                  'test/fixtures/terminal_frontend.dart',
                ).readAsString(),
              },
              'adele_ui': {
                'terminal_surface_bridge.dart': await File(
                  '${Directory.current.parent.path}/packages/ui/lib/terminal_surface_bridge.dart',
                ).readAsString(),
              },
            });
    await artifact.writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));
  setUp(() async {
    generation = await PreparedFrontend.load(artifact);
    expect(generation.failure, isNull);
  });
  tearDown(() => generation.invalidate());

  Widget presentation(
    NativeTerminalSurface surface, {
    PreparedFrontend? frontend,
    String entrypoint = 'buildView',
  }) => (frontend ?? generation).createPresentation(
    library: _library,
    entrypoint: entrypoint,
    createBridge: () =>
        TerminalSurfaceBridge(surface: surface, isActive: () => true),
  );

  Future<PreparedFrontend> freshGeneration(WidgetTester tester) async {
    final fresh = (await tester.runAsync(
      () => PreparedFrontend.load(artifact),
    ))!;
    expect(fresh.failure, isNull);
    addTearDown(fresh.invalidate);
    return fresh;
  }

  test('public native stubs grant no surface access', () {
    expect(public_bridge.requestTerminalSurface, throwsUnsupportedError);
    expect(
      () => public_bridge.buildTerminalSurface('fabricated'),
      throwsUnsupportedError,
    );
  });

  test(
    'standard Flutter bundle retains the published terminal MIT notice',
    () async {
      final bytes = await rootBundle.load('NOTICES.Z');
      final notices = utf8.decode(gzip.decode(bytes.buffer.asUint8List()));
      expect(notices, contains('xterm2'));
      expect(notices, contains('Copyright (c) 2020 xuty'));
      expect(notices, contains('The MIT License (MIT)'));
    },
  );

  testWidgets('prepared fixture routes native text, control, focus and paste', (
    tester,
  ) async {
    final input = <String>[];
    final responses = <String>[];
    final surface = NativeTerminalSurface(
      onInput: input.add,
      onResponse: responses.add,
    );
    addTearDown(surface.dispose);
    var clipboardReads = 0;
    _mockClipboard(tester, () async {
      clipboardReads++;
      return 'pasted text';
    });
    surface.write('native output\r\n');
    await tester.pumpWidget(_host(presentation(surface)));
    await tester.pump(_frame);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(_bufferText(tester), contains('native output'));

    Focus.of(_terminalContext(tester)).unfocus();
    await tester.pump();
    surface.write('\x1b[?1004h');
    input.clear();
    responses.clear();
    await _focusTerminal(tester);
    expect(input, ['\x1b[I']);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
    await _controlC(tester);
    _paste(tester);
    await tester.pump();
    expect(clipboardReads, 1);
    expect(input, ['\x1b[I', 'x', '\x03', 'pasted text']);
    expect(responses, isEmpty);

    surface.write('\x1b[?2004h\x1b[?1h');
    input.clear();
    _paste(tester);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(input, ['\x1b[200~pasted text\x1b[201~', '\x1bOA']);

    Focus.of(_terminalContext(tester)).unfocus();
    await tester.pump();
    expect(input.last, '\x1b[O');
    surface.write('\x1b[6n');
    expect(responses, ['\x1b[2;1R']);
    expect(input.last, '\x1b[O');

    surface.write('\x1b[?1004l\x1b[?1000h\x1b[?1006h');
    input.clear();
    await tester.tap(find.byType(TerminalView), kind: PointerDeviceKind.mouse);
    await tester.pump(_frame);
    expect(input, isNotEmpty);
    expect(input, everyElement(startsWith('\x1b[<')));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached native view rebuilds, resizes and remounts one buffer', (
    tester,
  ) async {
    final input = <String>[];
    final resizes = <(int, int)>[];
    final surface = NativeTerminalSurface(
      onInput: input.add,
      onResize: (columns, rows) => resizes.add((columns, rows)),
    );
    addTearDown(surface.dispose);
    surface.write('before hide\r\n');
    await tester.pumpWidget(_host(presentation(surface)));
    await tester.pump(_frame);
    final element = tester.element(find.byType(TerminalView));
    final nativeView = tester.widget<TerminalView>(find.byType(TerminalView));
    final engine = nativeView.terminal.buffer.terminal as Terminal;
    final listeners = nativeView.terminal.listeners.length;
    expect(engine.listeners, hasLength(1));
    final initialColumns = nativeView.terminal.viewWidth;
    expect(resizes, isNotEmpty);
    resizes.clear();

    for (var i = 1; i <= 3; i++) {
      await tester.tap(find.text('Rebuild'));
      await tester.pump(_frame);
      expect(find.text('Rebuilds: $i'), findsOneWidget);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(tester.element(find.byType(TerminalView)), same(element));
      expect(engine.listeners, hasLength(1));
      expect(nativeView.terminal.listeners, hasLength(listeners));
      await _focusTerminal(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
      expect(input, List.filled(i, 'x'));
    }
    expect(resizes, isEmpty);

    await tester.tap(find.text('Resize'));
    await tester.pump(_frame);
    final resized = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(tester.getSize(find.byType(TerminalView)).width, 560);
    expect(resized.terminal.viewWidth, greaterThan(initialColumns));
    expect(resizes, [
      (resized.terminal.viewWidth, resized.terminal.viewHeight),
    ]);

    await tester.tap(find.text('Toggle'));
    await tester.pump(_frame);
    expect(find.byType(TerminalView), findsNothing);
    expect(element.mounted, isFalse);
    expect(engine.listeners, isEmpty);
    expect(surface.isDisposed, isFalse);
    surface.write('while hidden\r\n');
    await tester.pump();
    await tester.tap(find.text('Toggle'));
    await tester.pump(_frame);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(_bufferText(tester), contains('before hide\nwhile hidden'));
    expect(
      tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal
          .buffer
          .terminal,
      same(engine),
    );
    expect(engine.listeners, hasLength(1));
    input.clear();
    await _focusTerminal(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
    expect(input, ['x']);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(surface.isDisposed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('host read-only mode blocks every sink through native events', (
    tester,
  ) async {
    final input = <String>[];
    final responses = <String>[];
    final resizes = <(int, int)>[];
    final surface = NativeTerminalSurface(
      readOnly: true,
      onInput: input.add,
      onResponse: responses.add,
      onResize: (columns, rows) => resizes.add((columns, rows)),
    );
    addTearDown(surface.dispose);
    var clipboardReads = 0;
    _mockClipboard(tester, () async {
      clipboardReads++;
      return 'must not escape';
    });
    surface.write(
      'obsolete\r\x1b[32mread-only output\x1b[K\x1b[0m\r\n'
      '\x1b[?1004h\x1b[?1000h\x1b[?1006h',
    );
    await tester.pumpWidget(_host(presentation(surface)));
    await tester.pump(_frame);
    final initialColumns = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .terminal
        .viewWidth;
    expect(_bufferText(tester), contains('read-only output'));
    await _focusTerminal(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
    await _controlC(tester);
    _paste(tester);
    await tester.pump();
    expect(clipboardReads, 1);
    Focus.of(_terminalContext(tester)).unfocus();
    await tester.pump();
    await tester.tap(find.byType(TerminalView), kind: PointerDeviceKind.mouse);
    await tester.pump(_frame);
    surface.write('\x1b[6n');
    await tester.tap(find.text('Resize'));
    await tester.pump(_frame);
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal.viewWidth,
      greaterThan(initialColumns),
    );
    expect(input, isEmpty);
    expect(responses, isEmpty);
    expect(resizes, isEmpty);
    expect(_bufferText(tester), contains('read-only output'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(input, isEmpty);
    expect(responses, isEmpty);
    expect(resizes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('generation retention revokes an already cached mounted widget', (
    tester,
  ) async {
    final input = <String>[];
    final resizes = <(int, int)>[];
    final surface = NativeTerminalSurface(
      onInput: input.add,
      onResize: (columns, rows) => resizes.add((columns, rows)),
    );
    addTearDown(surface.dispose);
    _mockClipboard(tester, () async => 'retired paste');
    await tester.pumpWidget(_host(presentation(surface)));
    await tester.pump(_frame);
    await _focusTerminal(tester);
    final element = tester.element(find.byType(TerminalView));
    final context = _terminalContext(tester);
    final focus = Focus.of(context);
    surface.write('\x1b[?1004h\x1b[?1000h\x1b[?1006h');
    input.clear();
    resizes.clear();

    // Neither the cached widget nor the bridge is rebuilt or directly invalidated.
    generation.retainPresentations();
    expect(element.mounted, isTrue);
    expect(tester.element(find.byType(TerminalView)), same(element));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
    await _controlC(tester);
    Actions.invoke(
      context,
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.tap(find.byType(TerminalView), kind: PointerDeviceKind.mouse);
    focus.unfocus();
    await tester.pump(_frame);
    await tester.tap(find.text('Resize'));
    await tester.pump(_frame);
    expect(input, isEmpty);
    expect(resizes, isEmpty);
    expect(surface.isDisposed, isFalse);
    expect(find.text('Rebuilds: 0'), findsOneWidget);
    generation.releasePresentations();
    await tester.pump(_frame);
    expect(find.byType(TerminalView), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('exit-retained attachment rejects a competing prepared view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    final retained = presentation(surface);
    Widget pair(Widget second) => _host(
      Row(
        children: [
          Expanded(child: retained),
          Expanded(child: second),
        ],
      ),
    );
    await tester.pumpWidget(pair(const SizedBox.shrink()));
    final element = tester.element(find.byType(TerminalView));
    generation.retainPresentations();
    final fresh = await freshGeneration(tester);
    await tester.pumpWidget(pair(presentation(surface, frontend: fresh)));
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(tester.element(find.byType(TerminalView)), same(element));
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(surface.isDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final retirement in ['retention', 'replacement', 'owner disposal']) {
    final replace = retirement == 'replacement';
    testWidgets('pending native paste is fenced after $retirement', (
      tester,
    ) async {
      final input = <String>[];
      final surface = NativeTerminalSurface(onInput: input.add);
      addTearDown(surface.dispose);
      final pending = Completer<String?>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(null);
      });
      var clipboardReads = 0;
      _mockClipboard(tester, () {
        clipboardReads++;
        return clipboardReads == 1
            ? pending.future
            : Future.value('fresh paste');
      });
      surface.write('retained buffer\r\n');
      await tester.pumpWidget(_host(presentation(surface)));
      await tester.pump(_frame);
      await _focusTerminal(tester);
      _paste(tester);
      await tester.pump();
      expect(clipboardReads, 1);
      expect(input, isEmpty);
      if (retirement == 'owner disposal') {
        surface.dispose();
      } else {
        generation.retainPresentations();
      }

      if (replace) {
        await tester.pumpWidget(const SizedBox.shrink());
        final fresh = await freshGeneration(tester);
        await tester.pumpWidget(_host(presentation(surface, frontend: fresh)));
        await tester.pump(_frame);
        expect(_bufferText(tester), contains('retained buffer'));
        await _focusTerminal(tester);
      }

      pending.complete('stale paste');
      await tester.pump(_frame);
      expect(input, isEmpty);
      expect(surface.isDisposed, retirement == 'owner disposal');
      if (replace) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
        _paste(tester);
        await tester.pump();
        expect(input, ['x', 'fresh paste']);
        expect(clipboardReads, 2);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final retirement in ['invalidate', 'dispose', 'failure']) {
    testWidgets('$retirement releases presentation but leaves owner reusable', (
      tester,
    ) async {
      final input = <String>[];
      final surface = NativeTerminalSurface(onInput: input.add);
      addTearDown(surface.dispose);
      surface.write('original output\r\n');
      await tester.pumpWidget(_host(presentation(surface)));
      await tester.pump(_frame);
      final element = tester.element(find.byType(TerminalView));

      switch (retirement) {
        case 'invalidate':
          generation.invalidate();
        case 'dispose':
          await tester.pumpWidget(const SizedBox.shrink());
        case 'failure':
          await tester.tap(find.text('Fail'));
      }
      await tester.pump(_frame);
      await tester.pump();
      expect(element.mounted, isFalse);
      expect(find.byType(TerminalView), findsNothing);
      if (retirement != 'dispose') {
        expect(find.text('Frontend unavailable.'), findsOneWidget);
      }
      expect(surface.isDisposed, isFalse);
      expect(tester.takeException(), isNull);
      surface.write('after $retirement\r\n');
      await tester.pumpWidget(const SizedBox.shrink());
      final next = retirement == 'invalidate'
          ? await freshGeneration(tester)
          : generation;
      await tester.pumpWidget(_host(presentation(surface, frontend: next)));
      await tester.pump(_frame);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(
        _bufferText(tester),
        contains('original output\nafter $retirement'),
      );
      await _focusTerminal(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
      expect(input, ['x']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(surface.isDisposed, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('fabricated handle fails only that prepared presentation', (
    tester,
  ) async {
    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    await tester.pumpWidget(
      _host(presentation(surface, entrypoint: 'buildFabricatedView')),
    );
    await tester.pump(_frame);
    expect(find.text('Frontend unavailable.'), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    expect(surface.isDisposed, isFalse);
    await tester.pumpWidget(_host(presentation(surface)));
    await tester.pump(_frame);
    expect(find.byType(TerminalView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime handles are stable and scoped to one presentation', (
    tester,
  ) async {
    final surface = NativeTerminalSurface();
    addTearDown(surface.dispose);
    final bridges = <TerminalSurfaceBridge>[];
    Runtime runtime() {
      final bridge = TerminalSurfaceBridge(
        surface: surface,
        isActive: () => true,
      );
      addTearDown(bridge.invalidate);
      bridges.add(bridge);
      return Runtime.ofProgram(program)
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(bridge);
    }

    String request(Runtime runtime) {
      final value = runtime.executeLib(_library, 'requestHandle');
      return (value is $Value ? value.$reified : value)! as String;
    }

    Widget build(Runtime runtime, String handle) {
      final value = runtime.executeLib(_library, 'buildHandle', [
        $String(handle),
      ]);
      return (value is $Value ? value.$reified : value)! as Widget;
    }

    final first = runtime();
    final second = runtime();
    expect(() => build(first, 'unknown'), throwsA(anything));
    final firstHandle = request(first);
    final secondHandle = request(second);
    expect(firstHandle, isNotEmpty);
    expect(secondHandle, isNot(firstHandle));
    expect(request(first), firstHandle);
    expect(request(second), secondHandle);
    expect(() => build(first, 'fabricated'), throwsA(anything));
    expect(() => build(first, secondHandle), throwsA(anything));
    expect(() => build(second, firstHandle), throwsA(anything));
    final firstView = build(first, firstHandle);
    expect(build(first, firstHandle), same(firstView));
    await tester.pumpWidget(_host(firstView));
    await tester.pump(_frame);
    expect(find.byType(TerminalView), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    bridges.first.invalidate();
    expect(() => request(first), throwsA(anything));
    expect(() => build(first, firstHandle), throwsA(anything));
    await tester.pumpWidget(_host(build(second, secondHandle)));
    await tester.pump(_frame);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(surface.isDisposed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

BuildContext _terminalContext(WidgetTester tester) => tester.element(
  find
      .descendant(
        of: find.byType(TerminalView),
        matching: find.byType(Scrollable),
      )
      .last, // Mouse-reporting mode can add an outer infinite scrollable.
);

String _bufferText(WidgetTester tester) {
  final buffer = tester
      .widget<TerminalView>(find.byType(TerminalView))
      .terminal
      .buffer;
  return [
    for (var i = 0; i < buffer.height; i++)
      buffer.lines[i].getText().trimRight(),
  ].join('\n');
}

Future<void> _focusTerminal(WidgetTester tester) async {
  await tester.tap(find.byType(TerminalView));
  await tester.pump(_frame);
  expect(Focus.of(_terminalContext(tester)).hasFocus, isTrue);
}

Future<void> _controlC(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  try {
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
}

void _paste(WidgetTester tester) => Actions.invoke(
  _terminalContext(tester),
  const PasteTextIntent(SelectionChangedCause.keyboard),
);

void _mockClipboard(WidgetTester tester, Future<String?> Function() read) {
  final messenger = tester.binding.defaultBinaryMessenger;
  final previous = messenger.allMessagesHandler;
  final channel = SystemChannels.platform;
  messenger.allMessagesHandler = (name, handler, message) {
    if (name == channel.name && message != null) {
      final call = channel.codec.decodeMethodCall(message);
      if (call.method == 'Clipboard.getData') {
        expect(call.arguments, Clipboard.kTextPlain);
        return read().then(
          (text) => channel.codec.encodeSuccessEnvelope(
            text == null ? null : {'text': text},
          ),
        );
      }
    }
    if (previous != null) return previous(name, handler, message);
    return handler != null
        ? handler(message)
        : messenger.delegate.send(name, message);
  };
  addTearDown(() => messenger.allMessagesHandler = previous);
}
