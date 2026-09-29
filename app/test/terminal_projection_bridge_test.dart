import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/terminal_projection_bridge.dart';
import 'package:adele_ui/terminal_projection_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

const _library = 'package:projection_probe/main.dart';

void main() {
  late Directory temporary;
  late File artifact;
  late Program program;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp(
      'adele-projection-bridge-',
    );
    artifact = File('${temporary.path}/projection.evc');
    program =
        (Compiler()
              ..addPlugin(flutterEvalPlugin)
              ..addPlugin(const TerminalProjectionDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'projection_probe': {
                'main.dart': await File(
                  'test/fixtures/terminal_projection_frontend.dart',
                ).readAsString(),
              },
              'adele_ui': {
                'terminal_projection_bridge.dart': await File(
                  '../packages/ui/lib/terminal_projection_bridge.dart',
                ).readAsString(),
              },
            });
    await artifact.writeAsBytes(program.write());
  });
  tearDownAll(() => temporary.delete(recursive: true));

  test('native public stubs confer no projection or feed authority', () {
    expect(
      () => public_bridge.requestTerminalProjection(6, false),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.buildTerminalProjection('fake'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.feedTerminalProjection('fake', 'output', 6),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.resetTerminalProjection('fake'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.yieldTerminalProjection('fake'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.readTerminalProjection('fake'),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.setTerminalProjectionFollow('fake', true, true),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.scrollTerminalProjection('fake', 0),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.subscribeTerminalProjection('fake', () {}),
      throwsUnsupportedError,
    );
    expect(
      () => public_bridge.unsubscribeTerminalProjection('fake', () {}),
      throwsUnsupportedError,
    );
  });

  test('replay yields fence exact presentation before resumption', () async {
    final bridge = TerminalProjectionBridge(isActive: () => true);
    addTearDown(bridge.invalidate);
    final runtime = Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(bridge);
    final handle = _invoke(runtime, 'requestRows', [$int(6)]) as String;
    expect(
      await (_invoke(runtime, 'yieldHandle', [$String(handle)]) as Future),
      isTrue,
    );
    final pending =
        _invoke(runtime, 'yieldHandle', [$String(handle)]) as Future;
    bridge.invalidate();
    expect(await pending, isFalse);
    expect(
      () => _invoke(runtime, 'yieldHandle', [$String(handle)]),
      throwsA(anything),
    );
  });

  for (final gesture in ['wheel', 'drag']) {
    testWidgets(
      'actual EVC observes user $gesture return and accepts exactly the frozen suffix',
      (tester) async {
        final bridge = TerminalProjectionBridge(
          isActive: () => true,
          maxLines: 40,
        );
        addTearDown(bridge.invalidate);
        final runtime = Runtime.ofProgram(program)
          ..addPlugin(flutterEvalPlugin)
          ..addPlugin(bridge);
        final handle = _invoke(runtime, 'requestRows', [$int(20)]) as String;
        final args = [$String(handle)];
        for (var i = 0; i < 60; i++) {
          expect(
            _invoke(runtime, 'feedHandle', [
              ...args,
              $String('row\n'),
              $int(20),
            ]),
            4,
          );
        }
        final view = _invoke(runtime, 'buildHandle', args) as Widget;
        await tester.pumpWidget(_host(view));
        await tester.pump();
        final observedStates = <Map<dynamic, dynamic>>[];
        _invoke(runtime, 'observeHandle', [
          ...args,
          $Closure((_, _, values) {
            observedStates.add(values.single!.$reified as Map);
            return null;
          }),
        ]);
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
        }
        expect(
          (_invoke(runtime, 'readHandle', args) as Map)['following'],
          isFalse,
        );
        await tester.pumpAndSettle();
        expect(observedStates.last, containsPair('following', false));
        final applied =
            (_invoke(runtime, 'readHandle', args) as Map)['acceptedCodeUnits'];
        expect(
          _invoke(runtime, 'feedHandle', [
            ...args,
            $String('suffix'),
            $int(20),
          ]),
          0,
        );
        final scroll = tester
            .widget<TerminalView>(find.byType(TerminalView))
            .scrollController!;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          (_invoke(runtime, 'readHandle', args) as Map)['following'],
          isFalse,
        );
        expect(observedStates.last, containsPair('following', false));
        scroll.jumpTo(0);
        if (gesture == 'wheel') {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: point,
              scrollDelta: const Offset(0, 5000),
            ),
          );
        } else {
          await tester.dragFrom(point, const Offset(0, -5000));
        }
        expect(
          (_invoke(runtime, 'readHandle', args) as Map)['following'],
          isTrue,
        );
        expect(
          (_invoke(runtime, 'readHandle', args) as Map)['acceptedCodeUnits'],
          applied,
        );
        await tester.pumpAndSettle();
        final observed = observedStates.last;
        expect(observed['following'], isTrue);
        expect(observed['acceptedCodeUnits'], applied);
        expect(
          _invoke(runtime, 'feedHandle', [
            ...args,
            $String('suffix'),
            $int(20),
          ]),
          6,
        );
        await tester.pump();
        expect('suffix'.allMatches(_text(tester)), hasLength(1));
        _invoke(runtime, 'followHandle', [...args, $bool(false)]);
        final count = observedStates.length;
        bridge.invalidate();
        await tester.pump();
        expect(observedStates.length, count);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'actual EVC history policy rejects user-bottom resume and survives reset',
    (tester) async {
      final bridge = TerminalProjectionBridge(
        isActive: () => true,
        maxLines: 40,
      );
      addTearDown(bridge.invalidate);
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(bridge);
      final handle = _invoke(runtime, 'requestRows', [$int(6)]) as String;
      final args = [$String(handle)];
      _invoke(runtime, 'followPolicy', [...args, $bool(false), $bool(false)]);
      _invoke(runtime, 'resetHandle', args);
      expect(
        (_invoke(runtime, 'readHandle', args) as Map)['resumeAtEnd'],
        isFalse,
      );
      for (var i = 0; i < 60; i++) {
        _invoke(runtime, 'feedHandle', [...args, $String('row\n'), $int(6)]);
      }
      final view = _invoke(runtime, 'buildHandle', args) as Widget;
      await tester.pumpWidget(_host(view));
      await tester.pump();
      final observedStates = <Map<dynamic, dynamic>>[];
      _invoke(runtime, 'observeHandle', [
        ...args,
        $Closure((_, _, values) {
          observedStates.add(values.single!.$reified as Map);
          return null;
        }),
      ]);
      _invoke(runtime, 'followPolicy', [...args, $bool(false), $bool(false)]);
      _invoke(runtime, 'scrollHandle', [...args, $double(0)]);
      await tester.pumpAndSettle();
      final point =
          tester.getTopLeft(find.byType(TerminalView)) + const Offset(50, 60);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: point, scrollDelta: const Offset(0, 5000)),
      );
      await tester.pumpAndSettle();
      expect(
        (_invoke(runtime, 'readHandle', args) as Map)['following'],
        isFalse,
      );
      expect(observedStates.last, containsPair('following', false));
      expect(
        _invoke(runtime, 'feedHandle', [...args, $String('blocked'), $int(6)]),
        0,
      );
      _invoke(runtime, 'followPolicy', [...args, $bool(true), $bool(true)]);
      expect(
        _invoke(runtime, 'feedHandle', [...args, $String('LIVE'), $int(6)]),
        4,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'actual EVC explicitly chooses always-follow independent of rows',
    (tester) async {
      final bridge = TerminalProjectionBridge(
        isActive: () => true,
        maxLines: 40,
      );
      addTearDown(bridge.invalidate);
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(bridge);
      final handle =
          _invoke(runtime, 'requestPolicy', [$int(20), $bool(true)]) as String;
      final args = [$String(handle)];
      expect(
        _invoke(runtime, 'requestPolicy', [$int(20), $bool(true)]),
        handle,
      );
      expect(
        () => _invoke(runtime, 'requestPolicy', [$int(20), $bool(false)]),
        throwsA(anything),
      );
      final outer = ScrollController();
      addTearDown(outer.dispose);
      for (var i = 0; i < 60; i++) {
        _invoke(runtime, 'feedHandle', [...args, $String('row\n'), $int(20)]);
      }
      final view = _invoke(runtime, 'buildHandle', args) as Widget;
      await tester.pumpWidget(
        _host(
          ListView(
            controller: outer,
            children: [
              SizedBox(height: 130, child: view),
              const SizedBox(height: 1000),
            ],
          ),
        ),
      );
      await tester.pump();
      final native = tester.widget<TerminalView>(find.byType(TerminalView));
      final buffer = native.terminal.buffer;
      native.controller!.setSelection(
        buffer.createAnchor(0, 0),
        buffer.createAnchor(3, 0),
      );
      _invoke(runtime, 'followPolicy', [...args, $bool(false), $bool(false)]);
      _invoke(runtime, 'scrollHandle', [...args, $double(0)]);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position:
              tester.getTopLeft(find.byType(TerminalView)) +
              const Offset(50, 60),
          scrollDelta: const Offset(0, 60),
        ),
      );
      expect(outer.offset, 60);
      expect(
        (_invoke(runtime, 'readHandle', args) as Map)['following'],
        isTrue,
      );
      expect(
        (_invoke(runtime, 'readHandle', args) as Map)['alwaysFollow'],
        isTrue,
      );
      expect(
        _invoke(runtime, 'feedHandle', [...args, $String('LIVE'), $int(20)]),
        4,
      );
      await tester.pump();
      expect(_text(tester), endsWith('LIVE'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'actual EVC owns independent handles and bounded coherent feeds',
    (tester) async {
      Runtime runtime() {
        final bridge = TerminalProjectionBridge(
          isActive: () => true,
          maxLines: 24,
        );
        addTearDown(bridge.invalidate);
        return Runtime.ofProgram(program)
          ..addPlugin(flutterEvalPlugin)
          ..addPlugin(bridge);
      }

      final first = runtime();
      final second = runtime();
      final handle = _invoke(first, 'requestRows', [$int(6)]) as String;
      final other = _invoke(second, 'requestRows', [$int(6)]) as String;
      expect(handle, isNot(other));
      expect(_invoke(first, 'requestRows', [$int(6)]), handle);
      expect(
        () => _invoke(first, 'requestRows', [$int(20)]),
        throwsA(anything),
      );
      expect(
        () => _invoke(first, 'buildHandle', [$String(other)]),
        throwsA(anything),
      );
      expect(
        () => _invoke(first, 'feedHandle', [
          $String('fake'),
          $String('oops'),
          $int(6),
        ]),
        throwsA(anything),
      );
      final accepted = _invoke(first, 'feedHandle', [
        $String(handle),
        $String('x' * 5000),
        $int(2),
      ]);
      expect(accepted, 161);
      var state = _invoke(first, 'readHandle', [$String(handle)]) as Map;
      expect(state['acceptedCodeUnits'], accepted);
      expect(state['lineAdvances'], 2);
      expect(state['retainedLines'], lessThanOrEqualTo(24));
      expect(
        (_invoke(second, 'readHandle', [$String(other)])
            as Map)['acceptedCodeUnits'],
        0,
      );
      final view = _invoke(first, 'buildHandle', [$String(handle)]) as Widget;
      expect(_invoke(first, 'buildHandle', [$String(handle)]), same(view));
      await tester.pumpWidget(_host(view));
      final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(terminal.readOnly, isTrue);
      expect(terminal.autoResize, isFalse);
      expect(terminal.terminal.viewWidth, 80);
      expect(terminal.terminal.viewHeight, 6);
      _invoke(first, 'scrollHandle', [$String(handle), $double(0)]);
      expect(
        _invoke(first, 'feedHandle', [
          $String(handle),
          $String('not accepted'),
          $int(6),
        ]),
        0,
      );
      _invoke(first, 'followHandle', [$String(handle), $bool(true)]);
      expect(
        _invoke(first, 'feedHandle', [
          $String(handle),
          $String('accepted'),
          $int(6),
        ]),
        8,
      );
      _invoke(first, 'resetHandle', [$String(handle)]);
      state = _invoke(first, 'readHandle', [$String(handle)]) as Map;
      expect(state['acceptedCodeUnits'], 0);
      expect(state['lineAdvances'], 0);
      expect(state['following'], isTrue);
      await tester.pump();
      expect(_text(tester), isNot(contains('accepted')));
      expect(
        _invoke(first, 'feedHandle', [
          $String(handle),
          $String('x\x1b[999999999b'),
          $int(6),
        ]),
        -1,
      );
      expect(
        () => _invoke(first, 'readHandle', [$String(handle)]),
        throwsA(anything),
      );
      expect(
        () => _invoke(first, 'resetHandle', [$String(handle)]),
        throwsA(anything),
      );
      expect(
        (_invoke(second, 'readHandle', [$String(other)])
            as Map)['acceptedCodeUnits'],
        0,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'prepared EVC subscribes, resets and releases its exact projection',
    (tester) async {
      final generation = (await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      ))!;
      addTearDown(generation.invalidate);
      Widget presentation() => generation.createPresentation(
        library: _library,
        entrypoint: 'buildProjection',
        createBridge: () => TerminalProjectionBridge(isActive: () => true),
      );
      await tester.pumpWidget(_host(presentation()));
      await tester.pump();
      await tester.pump();
      expect(_text(tester), contains('initial\noutput'));
      expect(find.text('Notifications: 0'), findsNothing);
      expect(find.textContaining('Notifications:'), findsOneWidget);
      await tester.tap(find.text('Append'));
      await tester.pump();
      await tester.pump();
      expect(_text(tester), contains('output\nappended'));
      await tester.tap(find.text('Freeze'));
      await tester.pump();
      await tester.tap(find.text('Append'));
      await tester.pump();
      expect('appended'.allMatches(_text(tester)), hasLength(1));
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(_text(tester).trim(), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_host(presentation()));
      await tester.pump();
      expect(_text(tester), contains('initial\noutput'));
      await tester.tap(find.text('Unsupported REP'));
      await tester.pump();
      expect(find.text('Frontend unavailable.'), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final retirement in ['invalidate', 'retain', 'predicate']) {
    testWidgets('$retirement fences cached native views and later EVC feeds', (
      tester,
    ) async {
      var active = true;
      final bridge = TerminalProjectionBridge(isActive: () => active);
      addTearDown(bridge.invalidate);
      final runtime = Runtime.ofProgram(program)
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(bridge);
      final handle = _invoke(runtime, 'requestRows', [$int(6)]) as String;
      _invoke(runtime, 'feedHandle', [
        $String(handle),
        $String('retained'),
        $int(6),
      ]);
      final view = _invoke(runtime, 'buildHandle', [$String(handle)]) as Widget;
      await tester.pumpWidget(_host(view));
      switch (retirement) {
        case 'invalidate':
          bridge.invalidate();
        case 'retain':
          bridge.retainPresentation();
        case 'predicate':
          active = false;
      }
      expect(
        () => _invoke(runtime, 'feedHandle', [
          $String(handle),
          $String('late'),
          $int(6),
        ]),
        throwsA(anything),
      );
      expect(
        () => _invoke(runtime, 'resetHandle', [$String(handle)]),
        throwsA(anything),
      );
      expect(
        () => _invoke(runtime, 'buildHandle', [$String(handle)]),
        throwsA(anything),
      );
      await tester.pump();
      if (retirement == 'retain') expect(_text(tester), contains('retained'));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}

Object? _invoke(Runtime runtime, String entrypoint, List<$Value> arguments) {
  final result = runtime.executeLib(_library, entrypoint, [
    for (final value in arguments)
      if (value is $int || value is $double || value is $bool)
        value.$value
      else
        value,
  ]);
  return result is $Value ? result.$reified : result;
}

Widget _host(Widget view) => MaterialApp(
  home: Scaffold(body: SizedBox(width: 600, height: 400, child: view)),
);

String _text(WidgetTester tester) {
  final buffer = tester
      .widget<TerminalView>(find.byType(TerminalView))
      .terminal
      .buffer;
  return [
    for (var index = 0; index < buffer.height; index++)
      buffer.lines[index].getText().trimRight(),
  ].join('\n');
}
