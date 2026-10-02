import 'dart:async';

import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:code_forge/code_forge.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(NativeCodeEngine.initialize);

  testWidgets(
    'scoped IME projection and snapshots do not flush the pending line',
    (tester) async {
      await _withEditor(tester, '\u{1f600}\nab', (view) async {
        await _key(tester, LogicalKeyboardKey.end, control: true);
        await tester.pump(const Duration(milliseconds: 20));
        await _key(tester, LogicalKeyboardKey.backspace);
        final controller = tester
            .widget<CodeForge>(find.byType(CodeForge))
            .controller!;
        expect(controller.bufferLineIndex, 1);
        expect(controller.rope.getText(), '\u{1f600}\nab');
        expect(
          view.inputClientForTesting!.currentTextEditingValue!.text,
          '\u{1f600}\na',
        );
        expect(view.snapshot()['text'], '\u{1f600}\na');
        expect(controller.bufferLineIndex, 1);
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.rope.getText(), '\u{1f600}\na');
      });
    },
  );

  testWidgets(
    'selection replacement beyond the ordinary IME window replaces the entire range',
    (tester) async {
      final original = 'a\u{1f600}b ' * 1300;
      await _withEditor(tester, original, (view) async {
        await _key(tester, LogicalKeyboardKey.keyA, control: true);
        await tester.pump(const Duration(milliseconds: 20));
        final advertised = TextEditingValue.fromJSON(
          Map<String, dynamic>.from(tester.testTextInput.editingState!),
        );
        expect(advertised.text, original);
        expect(advertised.selection.start, 0);
        expect(advertised.selection.end, original.length);
        await _delta(tester, advertised, 0, original.length, 'x');
        expect(view.snapshot()['text'], 'x');
        await _key(tester, LogicalKeyboardKey.keyZ, control: true);
        expect(view.snapshot()['text'], original);
      });
    },
  );

  for (final ending in ['commit', 'cancel', 'blur']) {
    testWidgets('scoped current-client composition updates then $ending', (
      tester,
    ) async {
      const original = '\u{1f600}\r\nab';
      await _withEditor(tester, original, (view) async {
        view.selectUtf16(5, 5);
        final client = view.inputClientForTesting!;
        final advertised = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        expect(advertised.text, original);
        expect(advertised.selection.extentOffset, 5);
        expect(client.currentTextEditingValue, advertised);
        final version = view.buffer.version;
        final start = advertised.selection.extentOffset;
        final first = await _delta(
          tester,
          advertised,
          start,
          start,
          'n',
          composing: TextRange(start: start, end: start + 1),
        );
        expect(view.buffer.snapshot()['text'], original);
        final second = await _delta(
          tester,
          first,
          start,
          start + 1,
          '\u4e2d',
          composing: TextRange(start: start, end: start + 1),
        );
        expect(view.inputClientForTesting, same(client));
        expect(client.currentTextEditingValue, second);
        expect(view.buffer.version, version);
        if (ending == 'commit') {
          await _delta(tester, second, -1, -1, '');
          _expectView(view, '\u{1f600}\r\na\u4e2db', 6, 6);
          await _key(tester, LogicalKeyboardKey.keyZ, control: true);
          _expectView(view, original, 5, 5);
          await _key(tester, LogicalKeyboardKey.keyY, control: true);
          _expectView(view, '\u{1f600}\r\na\u4e2db', 6, 6);
        } else if (ending == 'cancel') {
          await _delta(tester, second, start, start + 1, '');
          _expectView(view, original, 5, 5);
          expect(view.buffer.version, version);
        } else {
          FocusManager.instance.primaryFocus!.unfocus();
          await tester.pump();
          expect(client.currentTextEditingValue, isNull);
          _expectView(view, original, 5, 5);
          expect(view.buffer.version, version);
        }
      });
    });
  }

  for (final newline in ['\n', '\r\n']) {
    for (final reverse in [false, true]) {
      testWidgets(
        'Tab and Shift-Tab preserve Unicode ${newline.length}-unit lines '
        'and ${reverse ? 'reverse' : 'forward'} undo selections',
        (tester) async {
          final original =
              '\u{1f600}${newline}a\u{1f680}${newline}b${newline}tail';
          await _withEditor(tester, original, (view) async {
            final code = tester.widget<CodeForge>(find.byType(CodeForge));
            final indent = code.controller!.tabSpace;
            final indented =
                '\u{1f600}$newline${indent}a\u{1f680}$newline${indent}b${newline}tail';
            final start = original.indexOf('a');
            final end = original.indexOf('b') + 1;
            final base = reverse ? end : start;
            final extent = reverse ? start : end;
            final newStart = indented.indexOf('a');
            final newEnd = indented.indexOf('b') + 1;
            final newBase = reverse ? newEnd : newStart;
            final newExtent = reverse ? newStart : newEnd;
            view.selectUtf16(base, extent);
            await _key(tester, LogicalKeyboardKey.tab);
            _expectView(view, indented, newBase, newExtent);
            await _key(tester, LogicalKeyboardKey.keyZ, control: true);
            _expectView(view, original, base, extent);
            await _key(tester, LogicalKeyboardKey.keyY, control: true);
            _expectView(view, indented, newBase, newExtent);
            await _key(tester, LogicalKeyboardKey.tab, shift: true);
            _expectView(view, original, base, extent);
            await _key(tester, LogicalKeyboardKey.keyZ, control: true);
            _expectView(view, indented, newBase, newExtent);
            await _key(tester, LogicalKeyboardKey.keyY, control: true);
            _expectView(view, original, base, extent);
          });
        },
      );
    }

    testWidgets('collapsed Shift-Tab after supplementary text preserves '
        '${newline.length}-unit lines and clamps within removed indentation', (
      tester,
    ) async {
      final original = '\u{1f600}$newline  a\u{1f680}${newline}tail';
      await _withEditor(tester, original, (view) async {
        final caret = original.indexOf('a') - 1;
        final unindented = '\u{1f600}${newline}a\u{1f680}${newline}tail';
        final nextCaret = unindented.indexOf('a');
        view.selectUtf16(caret, caret);
        await _key(tester, LogicalKeyboardKey.tab, shift: true);
        _expectView(view, unindented, nextCaret, nextCaret);
        await _key(tester, LogicalKeyboardKey.keyZ, control: true);
        _expectView(view, original, caret, caret);
        await _key(tester, LogicalKeyboardKey.keyY, control: true);
        _expectView(view, unindented, nextCaret, nextCaret);
      });
    });
  }

  testWidgets(
    'double-click after a supplementary scalar copies and cuts a word',
    (tester) async {
      const original = '\u{1f600} abc xyz';
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
      try {
        await _withEditor(tester, original, (view) async {
          // Use the renderer's advertised caret geometry, not font-dependent pixels.
          view.selectUtf16(4, 4);
          await tester.pump();
          final caret =
              tester.testTextInput.log
                      .lastWhere(
                        (call) => call.method == 'TextInput.setCaretRect',
                      )
                      .arguments
                  as Map;
          final position =
              tester.getTopLeft(find.byType(CodeForge)) +
              Offset(
                (caret['x'] as num).toDouble() + 1,
                (caret['y'] as num).toDouble() +
                    (caret['height'] as num).toDouble() / 2,
              );
          await tester.tapAt(position);
          await tester.pump(kDoubleTapTimeout);
          await tester.tapAt(position);
          await tester.pump(kDoubleTapMinTime);
          await tester.tapAt(position);
          await tester.pump();
          _expectView(view, original, 3, 6);
          await _key(tester, LogicalKeyboardKey.keyC, control: true);
          await tester.pump();
          expect(copied, ['abc']);
          await _key(tester, LogicalKeyboardKey.keyX, control: true);
          await tester.pump();
          expect(copied, ['abc', 'abc']);
          _expectView(view, '\u{1f600}  xyz', 3, 3);
          await _key(tester, LogicalKeyboardKey.keyZ, control: true);
          _expectView(view, original, 3, 6);
        });
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      }
    },
  );
}

Future<void> _withEditor(
  WidgetTester tester,
  String text,
  Future<void> Function(NativeCodeView view) exercise,
) async {
  final buffer = NativeCodeBuffer(text: text);
  final view = NativeCodeView(buffer: buffer);
  final access = view.createAccess(isActive: () => true);
  try {
    await tester.runAsync(buffer.initialize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 620, height: 320, child: access.buildView()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(view.readState()['ready'], true);
    expect(view.requestFocus(), true);
    await tester.pump();
    expect(view.readState()['focused'], true);
    expect(tester.testTextInput.hasAnyClients, true);
    await exercise(view);
  } finally {
    access.revoke();
    await tester.pumpWidget(const SizedBox.shrink());
    buffer.dispose();
    await tester.pump(kDoubleTapTimeout);
  }
  expect(tester.takeException(), isNull);
}

void _expectView(NativeCodeView view, String text, int base, int extent) {
  final snapshot = view.snapshot();
  expect(snapshot['text'], text);
  expect(snapshot['selectionBase'], base);
  expect(snapshot['selectionExtent'], extent);
  expect(snapshot['selectionUnit'], 'utf16');
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool shift = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  try {
    await tester.sendKeyEvent(key);
  } finally {
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
}

Future<TextEditingValue> _delta(
  WidgetTester tester,
  TextEditingValue old,
  int start,
  int end,
  String replacement, {
  TextRange composing = TextRange.empty,
}) async {
  expect(tester.testTextInput.hasAnyClients, true);
  expect(tester.testTextInput.setClientArgs!['enableDeltaModel'], true);
  final attach = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
  );
  final client = (attach.arguments as List)[0] as int;
  final next = start < 0
      ? old.copyWith(composing: composing)
      : old.copyWith(
          text: old.text.replaceRange(start, end, replacement),
          selection: TextSelection.collapsed(
            offset: start + replacement.length,
          ),
          composing: composing,
        );
  final reply = Completer<void>();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        client,
        {
          'deltas': [
            {
              'oldText': old.text,
              'deltaStart': start,
              'deltaEnd': end,
              'deltaText': replacement,
              'selectionBase': next.selection.baseOffset,
              'selectionExtent': next.selection.extentOffset,
              'composingBase': next.composing.start,
              'composingExtent': next.composing.end,
            },
          ],
        },
      ]),
    ),
    (data) {
      try {
        if (data == null) throw StateError('Missing platform input reply.');
        SystemChannels.textInput.codec.decodeEnvelope(data);
        reply.complete();
      } on Object catch (error, stack) {
        reply.completeError(error, stack);
      }
    },
  );
  await reply.future;
  await tester.pump();
  return next;
}
