import 'dart:async';

import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:code_forge/code_forge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(NativeCodeEngine.initialize);

  test(
    'admission rejects malformed text and unsupported hints without allocation',
    () {
      expect(() => NativeCodeBuffer(text: '\ud800'), throwsArgumentError);
      expect(() => NativeCodeBuffer(text: '\udfff'), throwsArgumentError);
      expect(
        () => NativeCodeBuffer(text: 'x', language: '/tmp/file.dart'),
        throwsArgumentError,
      );
      expect(
        () => NativeCodeBuffer(text: 'x' * (NativeCodeBuffer.maxScalars + 1)),
        throwsRangeError,
      );
    },
  );

  test(
    'UTF-16 ranges reject invalid endpoints and snapshots remain immutable',
    () async {
      final buffer = NativeCodeBuffer(text: 'a\u{1f600}\r\n\te\u0301\u4e2d');
      await buffer.initialize();
      final before = buffer.snapshot();
      final version = buffer.version;
      for (final range in [(2, 2), (1, 2), (2, 3)]) {
        expect(
          () => buffer.replaceRangeUtf16(range.$1, range.$2, 'x'),
          throwsArgumentError,
        );
      }
      for (final range in [(-1, 0), (3, 1), (0, 999)]) {
        expect(
          () => buffer.replaceRangeUtf16(range.$1, range.$2, 'x'),
          throwsRangeError,
        );
      }
      expect(buffer.version, version);
      buffer.replaceRangeUtf16(1, 3, '\u{1f680}');
      expect(buffer.snapshot()['text'], 'a\u{1f680}\r\n\te\u0301\u4e2d');
      expect(before['text'], 'a\u{1f600}\r\n\te\u0301\u4e2d');
      expect(() => before['text'] = 'changed', throwsUnsupportedError);
      buffer.dispose();
      buffer.dispose();
      expect(buffer.snapshot, throwsStateError);
      expect(buffer.initialize, throwsStateError);
    },
  );

  testWidgets(
    'changes coalesce, navigation exports no snapshots, pending text is coherent',
    (tester) async {
      final buffer = NativeCodeBuffer(text: '\u{1f600}\nab');
      final view = NativeCodeView(buffer: buffer);
      final access = view.createAccess(isActive: () => true);
      await _mount(tester, access);
      await _focus(tester, view);
      var notifications = 0;
      final detach = access.observeChanges(() => notifications++);
      final version = buffer.version;
      final exports = buffer.snapshotReads;
      await _key(tester, LogicalKeyboardKey.end, control: true);
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(buffer.version, version);
      expect(notifications, 0);
      expect(buffer.snapshotReads, exports);
      final controller = tester
          .widget<CodeForge>(find.byType(CodeForge))
          .controller!;
      controller.backspace();
      controller.backspace();
      final immediate = access.snapshot();
      expect(immediate['text'], '\u{1f600}\n');
      expect(immediate['version'], buffer.version);
      await tester.pump();
      expect(notifications, 1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(buffer.snapshot()['text'], immediate['text']);
      detach();
      access.revoke();
      expect(buffer.observerCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      buffer.dispose();
    },
  );

  testWidgets(
    'the first visible pointer click focuses and positions the caret',
    (tester) async {
      final buffer = NativeCodeBuffer(text: 'abcdef');
      final view = NativeCodeView(buffer: buffer);
      final access = view.createAccess(isActive: () => true);
      await _mount(tester, access);
      expect(view.readState()['focused'], false);
      await tester.tapAt(
        tester.getTopLeft(find.byType(CodeForge)) + const Offset(300, 12),
      );
      await tester.pump();
      expect(view.readState()['focused'], true);
      expect(view.snapshot()['selectionBase'], 6);
      buffer.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      // Flutter's double-tap minimum-time tracker outlives its disposed widget.
      await tester.pump(kDoubleTapMinTime);
    },
  );

  testWidgets(
    'complete unmount retains text/history/selection/scroll before first visible frame',
    (tester) async {
      final text = List.generate(160, (i) => 'line $i ${'x' * 180}\n').join();
      final buffer = NativeCodeBuffer(text: text);
      final view = NativeCodeView(buffer: buffer);
      final old = view.createAccess(isActive: () => true);
      await _mount(tester, old);
      await _focus(tester, view);
      view.selectUtf16(0, 4);
      await _key(tester, LogicalKeyboardKey.delete);
      final edited = buffer.snapshot()['text'];
      view.selectUtf16(700, 709);
      view.scrollTo(horizontal: 120, vertical: 600);
      await tester.pump();
      final position = view.snapshot();
      final offsets = view.readState();
      old.revoke();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(find.byType(CodeForge), findsNothing);
      expect(view.readState()['verticalOffset'], offsets['verticalOffset']);
      expect(buffer.snapshot()['text'], edited);
      expect(old.readState, throwsStateError);
      final fresh = view.createAccess(isActive: () => true);
      await _mount(tester, fresh);
      expect(view.snapshot()['selectionBase'], position['selectionBase']);
      expect(view.snapshot()['selectionExtent'], position['selectionExtent']);
      expect(view.readState()['verticalOffset'], offsets['verticalOffset']);
      expect(view.readState()['horizontalOffset'], offsets['horizontalOffset']);
      await _focus(tester, view);
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(buffer.snapshot()['text'], text);
      await _key(tester, LogicalKeyboardKey.keyY, control: true);
      expect(buffer.snapshot()['text'], edited);
      fresh.revoke();
      await tester.pumpWidget(const SizedBox.shrink());
      buffer.dispose();
    },
  );

  testWidgets('independent buffers and read-only mutation routes', (
    tester,
  ) async {
    final a = NativeCodeBuffer(text: 'editable');
    final b = NativeCodeBuffer(text: 'a\u{1f600}b');
    final av = NativeCodeView(buffer: a);
    final bv = NativeCodeView(buffer: b, readOnly: true);
    final aa = av.createAccess(isActive: () => true);
    final ba = bv.createAccess(isActive: () => true);
    await tester.runAsync(() async {
      await a.initialize();
      await b.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: aa.buildView()),
              Expanded(child: ba.buildView()),
            ],
          ),
        ),
      ),
    );
    await _frames(tester);
    await _focus(tester, bv);
    bv.selectUtf16(1, 3);
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'blocked'};
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await _key(tester, LogicalKeyboardKey.keyC, control: true);
    await tester.pump();
    expect(clipboard, ['\u{1f600}']);
    for (final key in [
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.enter,
    ]) {
      await _key(tester, key);
    }
    for (final key in [
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.keyY,
    ]) {
      await _key(tester, key, control: true);
    }
    expect(b.snapshot()['text'], 'a\u{1f600}b');
    await _focus(tester, av);
    av.selectUtf16(0, 1);
    await _key(tester, LogicalKeyboardKey.delete);
    expect(a.snapshot()['text'], 'ditable');
    expect(b.snapshot()['text'], 'a\u{1f600}b');
    a.dispose();
    await tester.pump();
    expect(ba.readState()['readOnly'], true);
    await _focus(tester, bv);
    b.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('competing attachment fails without stealing the first buffer', (
    tester,
  ) async {
    final buffer = NativeCodeBuffer(text: 'abc');
    final a = NativeCodeView(buffer: buffer);
    final b = NativeCodeView(buffer: buffer);
    final aa = a.createAccess(isActive: () => true);
    var unavailable = 0;
    final ba = b.createAccess(
      isActive: () => true,
      onUnavailable: () => unavailable++,
    );
    await tester.runAsync(buffer.initialize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: aa.buildView()),
              Expanded(child: ba.buildView()),
            ],
          ),
        ),
      ),
    );
    await _frames(tester);
    expect(unavailable, 1);
    expect(find.textContaining('only one mounted'), findsOneWidget);
    await _focus(tester, a);
    a.selectUtf16(0, 1);
    await _key(tester, LogicalKeyboardKey.delete);
    expect(buffer.snapshot()['text'], 'bc');
    buffer.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('A-B-A focus cannot revive held paste or the old input client', (
    tester,
  ) async {
    final buffer = NativeCodeBuffer(text: 'ab');
    final view = NativeCodeView(buffer: buffer);
    final access = view.createAccess(isActive: () => true);
    await _mount(tester, access);
    await _focus(tester, view);
    final client = view.inputClientForTesting!;
    final controller = tester
        .widget<CodeForge>(find.byType(CodeForge))
        .controller!;
    final clipboard = Completer<Map<String, String>?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? clipboard.future : null,
    );
    final paste = controller.paste();
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    await _focus(tester, view);
    expect(identical(client, view.inputClientForTesting), false);
    clipboard.complete({'text': 'late'});
    await paste;
    client.updateEditingValue(
      const TextEditingValue(
        text: 'stale',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    expect(client.currentTextEditingValue, isNull);
    expect(buffer.snapshot()['text'], 'ab');
    access.revoke();
    await tester.pumpWidget(const SizedBox.shrink());
    buffer.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets(
    'revocation fences native work before reentrant teardown listeners',
    (tester) async {
      final buffer = NativeCodeBuffer(text: 'abc');
      final view = NativeCodeView(buffer: buffer);
      final access = view.createAccess(isActive: () => true);
      await _mount(tester, access);
      await _focus(tester, view);
      final code = tester.widget<CodeForge>(find.byType(CodeForge));
      code.focusNode!.addListener(() {
        code.controller!.replaceRange(0, 1, 'bad');
        code.focusNode!.requestFocus();
      });
      access.revoke();
      await tester.pump();
      expect(buffer.snapshot()['text'], 'abc');
      expect(view.requestFocus(), false);
      await tester.pumpWidget(const SizedBox.shrink());
      buffer.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'context copy works but old menu callbacks cannot act after refocus',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final buffer = NativeCodeBuffer(text: 'copy me');
      final view = NativeCodeView(buffer: buffer, readOnly: true);
      final access = view.createAccess(isActive: () => true);
      await _mount(tester, access);
      await _focus(tester, view);
      view.selectUtf16(0, 4);
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
      Future<VoidCallback> menu() async {
        await tester.tapAt(
          tester.getTopLeft(find.byType(CodeForge)) + const Offset(100, 20),
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        final item = find.ancestor(
          of: find.text('Copy'),
          matching: find.byType(InkWell),
        );
        return tester.widget<InkWell>(item).onTap!;
      }

      final first = await menu();
      first();
      await tester.pump();
      expect(copied, ['copy']);
      final stale = await menu();
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      await _focus(tester, view);
      await menu();
      stale();
      await tester.pump();
      expect(copied, ['copy']);
      expect(find.text('Copy'), findsOneWidget);
      buffer.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'window departure cancels clipboard and preserves view state with bounded work',
    (tester) async {
      final buffer = NativeCodeBuffer(
        text: List.generate(100, (i) => 'line $i\n').join(),
      );
      final view = NativeCodeView(buffer: buffer);
      final access = view.createAccess(isActive: () => true);
      await _mount(tester, access);
      await _focus(tester, view);
      view.selectUtf16(0, 1);
      view.scrollTo(horizontal: 0, vertical: 600);
      final before = buffer.snapshot();
      final held = Completer<Map<String, String>?>();
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            reads++;
            return held.future;
          }
          return null;
        },
      );
      final controller = tester
          .widget<CodeForge>(find.byType(CodeForge))
          .controller!;
      final first = controller.paste();
      for (var i = 0; i < 20; i++) {
        await controller.paste();
      }
      expect(reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(view.requestFocus(), false);
      expect(view.readState()['verticalOffset'], 600);
      held.complete({'text': 'not admitted'});
      await first;
      expect(buffer.snapshot(), before);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _focus(tester, view);
      buffer.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );

  testWidgets('reentrant liveness cannot revive a disposed owner', (
    tester,
  ) async {
    final buffer = NativeCodeBuffer(text: 'owned');
    final view = NativeCodeView(buffer: buffer);
    var retireInsideCheck = false;
    final access = view.createAccess(
      isActive: () {
        if (retireInsideCheck) buffer.dispose();
        return true;
      },
    );
    await _mount(tester, access);
    retireInsideCheck = true;
    expect(access.readState, throwsStateError);
    expect(access.snapshot, throwsStateError);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(buffer.isDisposed, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owner cleanup completes exactly once even when an unavailable listener throws',
    (tester) async {
      final buffer = NativeCodeBuffer(text: 'retained');
      final view = NativeCodeView(buffer: buffer);
      var calls = 0;
      final access = view.createAccess(
        isActive: () => true,
        onUnavailable: () {
          calls++;
          throw StateError('listener failure');
        },
      );
      await _mount(tester, access);
      final code = tester.widget<CodeForge>(find.byType(CodeForge));
      final rope = code.controller!.rope;
      expect(buffer.dispose, throwsStateError);
      expect(buffer.isDisposed, true);
      expect(code.controller!.isDisposed, true);
      expect(
        () => rope.length,
        throwsA(
          predicate<Object>(
            (error) =>
                error.runtimeType.toString() == 'DroppableDisposedException',
          ),
        ),
      );
      expect(buffer.observerCount, 0);
      buffer.dispose();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late initialization and snapshot never revive disposed ownership',
    (tester) async {
      final initialize = Completer<void>();
      final buffer = NativeCodeBuffer(
        text: 'pending',
        initializeNative: () => initialize.future,
      );
      final view = NativeCodeView(buffer: buffer);
      final access = view.createAccess(isActive: () => true);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(width: 400, height: 200, child: access.buildView()),
        ),
      );
      expect(access.snapshot, throwsStateError);
      final rejection = expectLater(buffer.initialize(), throwsStateError);
      access.revoke();
      buffer.dispose();
      initialize.complete();
      await tester.pump();
      await rejection;
      expect(find.byType(CodeForge), findsNothing);
      expect(buffer.isInitialized, false);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'trusted replace resets history only while detached; resizing does not edit',
    (tester) async {
      final buffer = NativeCodeBuffer(text: 'abc');
      await tester.runAsync(buffer.initialize);
      buffer.replaceRangeUtf16(0, 1, 'X');
      buffer.replaceText('new\r\ntext');
      final view = NativeCodeView(buffer: buffer);
      final access = view.createAccess(isActive: () => true);
      await _mount(tester, access);
      final version = buffer.version;
      expect(() => buffer.replaceText('blocked'), throwsStateError);
      await _focus(tester, view);
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(buffer.snapshot()['text'], 'new\r\ntext');
      await tester.binding.setSurfaceSize(const Size(420, 320));
      await tester.pump();
      expect(buffer.version, version);
      expect(buffer.snapshot()['text'], 'new\r\ntext');
      access.revoke();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      buffer.dispose();
    },
  );

  testWidgets(
    'representative long-line and multiline work remains native and coalesced',
    (tester) async {
      final text =
          '${'a' * 32768}\n${List.generate(2048, (i) => 'row $i\t\u4e2d\u6587 e\u0301 \u{1f600}\r\n').join()}';
      final buffer = NativeCodeBuffer(text: text);
      final view = NativeCodeView(buffer: buffer);
      final access = view.createAccess(isActive: () => true);
      await _mount(tester, access);
      await _focus(tester, view);
      final code = tester.widget<CodeForge>(find.byType(CodeForge));
      var notifications = 0;
      final detach = buffer.observeChanges(() => notifications++);
      final exports = buffer.snapshotReads;
      for (var i = 0; i < 50; i++) {
        code.controller!.delete();
      }
      expect(buffer.snapshotReads, exports);
      await tester.pump();
      expect(notifications, 1);
      expect(buffer.snapshot()['text'], text.substring(50));
      final history = code.undoController!.undoStackSize;
      for (var i = 0; i < history; i++) {
        await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      }
      expect(buffer.snapshot()['text'], text);
      detach();
      buffer.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(buffer.observerCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _mount(WidgetTester tester, NativeCodeAccess access) async {
  await tester.runAsync(access.view.buffer.initialize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 620, height: 320, child: access.buildView()),
      ),
    ),
  );
  await _frames(tester);
  expect(
    access.readState()['ready'],
    true,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .join('\n'),
  );
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> _focus(WidgetTester tester, NativeCodeView view) async {
  expect(view.requestFocus(), true);
  await tester.pump();
  expect(view.readState()['focused'], true);
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}
