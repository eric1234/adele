import 'dart:async';
import 'dart:io';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    final directory =
        Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'];
    if (directory == null ||
        !File('$directory/libcode_forge.so').existsSync()) {
      throw StateError('A prepared real CodeForge native library is required');
    }
    await RustLib.init();
  });

  for (final backward in [false, true]) {
    testWidgets('grouped supplementary ${backward ? 'backspace' : 'delete'}', (
      tester,
    ) async {
      final editor = _Editor('a\u{1f600}\u{1f642}z');
      try {
        editor.controller.selection = TextSelection.collapsed(
          offset: backward ? 3 : 1,
        );
        backward ? editor.controller.backspace() : editor.controller.delete();
        backward ? editor.controller.backspace() : editor.controller.delete();
        expect(editor.controller.text, 'az');
        expect(editor.controller.length, 2);
        _roundTrip(editor, 'a\u{1f600}\u{1f642}z', 'az');
      } finally {
        await editor.close(tester);
      }
    });
  }

  testWidgets('default grouped insertion and replacement use scalar spans', (
    tester,
  ) async {
    final editor = _Editor('ab');
    try {
      editor.controller.replaceRange(0, 0, '\u{1f600}');
      editor.controller.replaceRange(1, 1, '\u{1f642}');
      _roundTrip(editor, 'ab', '\u{1f600}\u{1f642}ab');
      editor.undo.clear();
      editor.controller.replaceRange(0, 2, 'X\u{1f680}');
      _roundTrip(editor, '\u{1f600}\u{1f642}ab', 'X\u{1f680}ab');
      final first = InsertOperation(
        offset: 0,
        text: '\u{1f600}',
        selectionBefore: const TextSelection.collapsed(offset: 0),
        selectionAfter: const TextSelection.collapsed(offset: 1),
        timestamp: DateTime(2026),
      );
      final second = InsertOperation(
        offset: 1,
        text: '\u{1f642}',
        selectionBefore: const TextSelection.collapsed(offset: 1),
        selectionAfter: const TextSelection.collapsed(offset: 2),
        timestamp: DateTime(2026),
      );
      expect(first.canMergeWith(second), isTrue);
      expect(
        (first.mergeWith(second) as InsertOperation).text,
        '\u{1f600}\u{1f642}',
      );
    } finally {
      await editor.close(tester);
    }
  });

  testWidgets('pending snapshot length lines and version stay coherent', (
    tester,
  ) async {
    final editor = _Editor('\u{1f600}\nab\u{1f642}\nz');
    try {
      final initialVersion = editor.controller.contentVersion;
      editor.controller.selection = const TextSelection.collapsed(offset: 5);
      expect(editor.controller.contentVersion, initialVersion);
      editor.controller.backspace();
      final version = editor.controller.contentVersion;
      expect(version, greaterThan(initialVersion));
      expect(editor.controller.text, '\u{1f600}\nab\nz');
      expect(editor.controller.length, 6);
      expect(editor.controller.getLineStartOffset(2), 5);
      expect(editor.controller.getLineAtOffset(5), 2);
      await tester.pump(const Duration(milliseconds: 120));
      expect(editor.controller.rope.getText(), editor.controller.text);
      expect(editor.controller.contentVersion, version);
      editor.undo.undo();
      expect(editor.controller.contentVersion, greaterThan(version));
    } finally {
      await editor.close(tester);
    }
  });

  for (final newline in ['\n', '\r\n']) {
    for (final backward in [false, true]) {
      testWidgets('join ${newline.length} units backward=$backward', (
        tester,
      ) async {
        final initial = '\u{1f600}${newline}b\r\nc';
        final editor = _Editor(initial);
        try {
          editor.controller.selection = TextSelection.collapsed(
            offset: backward ? 1 + newline.length : 1,
          );
          backward ? editor.controller.backspace() : editor.controller.delete();
          expect(editor.controller.text, '\u{1f600}b\r\nc');
          _roundTrip(editor, initial, '\u{1f600}b\r\nc');
        } finally {
          await editor.close(tester);
        }
      });
    }
  }

  testWidgets('copy cut and paste select complete supplementary scalars', (
    tester,
  ) async {
    final editor = _Editor('a\u{1f600}b');
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      },
    );
    try {
      editor.controller.selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 2,
      );
      editor.controller.copy();
      await tester.pump();
      expect(clipboard, '\u{1f600}');
      editor.controller.cut();
      expect(editor.controller.text, 'ab');
      await editor.controller.paste();
      expect(editor.controller.text, 'a\u{1f600}b');
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await editor.close(tester);
    }
  });

  testWidgets(
    'revoked activation rejects late paste and owner bypass is scoped',
    (tester) async {
      final editor = _Editor('ab');
      var allowed = true;
      var token = Object();
      editor.controller.interactionAllowed = () => allowed;
      editor.controller.interactionToken = () => token;
      final pending = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) => pending.future,
      );
      try {
        final paste = editor.controller.paste();
        token = Object();
        pending.complete({'text': 'late'});
        await paste;
        expect(editor.controller.text, 'ab');
        allowed = false;
        editor.controller.replaceRange(0, 0, 'denied');
        editor.controller.selection = const TextSelection.collapsed(offset: 0);
        expect(editor.controller.selection.extentOffset, 2);
        editor.controller.withOwnerMutation(
          () => editor.controller.replaceRange(0, 0, 'owner'),
        );
        expect(editor.controller.text, 'ownerab');
        expect(editor.undo.undo(), isFalse);
        expect(editor.controller.withOwnerMutation(editor.undo.undo), isTrue);
        expect(editor.controller.text, 'ab');
        editor.controller.dispose();
        expect(editor.controller.isDisposed, isTrue);
        expect(editor.controller.rope.isDisposed, isTrue);
        editor.controller.replaceRange(0, 0, 'dead');
        expect(
          () => editor.controller.withOwnerMutation(() {}),
          throwsStateError,
        );
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        await editor.close(tester);
      }
    },
  );

  testWidgets(
    'unfocused mount never attaches IME and external focus detaches cleanly',
    (tester) async {
      final editor = _Editor('ab');
      try {
        await editor.mount(tester, autofocus: false);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        editor.focus.requestFocus();
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);
        editor.focus.unfocus();
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        editor.focus.requestFocus();
        editor.horizontal.notifyListeners();
        editor.vertical.notifyListeners();
        expect(tester.takeException(), isNull);
        editor.controller.replaceRange(0, 0, 'retained');
        expect(editor.undo.undo(), isTrue);
        expect(editor.controller.text, 'ab');
      } finally {
        await editor.close(tester);
      }
    },
  );

  for (final ending in ['commit', 'cancel', 'blur']) {
    testWidgets('advertised CRLF supplementary composition $ending', (
      tester,
    ) async {
      final editor = _Editor('\u{1f600}\r\nab');
      try {
        await editor.mount(tester);
        editor.controller.selection = const TextSelection.collapsed(offset: 4);
        await tester.pump();
        final before = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        expect(before.text, '\u{1f600}\r\nab');
        final start = before.selection.extentOffset;
        final composing = before.copyWith(
          text: before.text.replaceRange(start, start, '\u4e2d'),
          selection: TextSelection.collapsed(offset: start + 1),
          composing: TextRange(start: start, end: start + 1),
        );
        tester.testTextInput.updateEditingValue(composing);
        await tester.pump();
        expect(editor.controller.isComposingActive, isTrue);
        expect(editor.controller.text, '\u{1f600}\r\nab');
        if (ending == 'commit') {
          tester.testTextInput.updateEditingValue(
            composing.copyWith(composing: TextRange.empty),
          );
        } else if (ending == 'cancel') {
          tester.testTextInput.updateEditingValue(
            before.copyWith(composing: TextRange.empty),
          );
        } else {
          editor.focus.unfocus();
        }
        await tester.pump();
        expect(editor.controller.isComposingActive, isFalse);
        expect(
          editor.controller.text,
          ending == 'commit' ? '\u{1f600}\r\na\u4e2db' : '\u{1f600}\r\nab',
        );
        if (ending == 'commit') {
          _roundTrip(editor, '\u{1f600}\r\nab', '\u{1f600}\r\na\u4e2db');
        }
      } finally {
        await editor.close(tester);
      }
    });
  }

  testWidgets('advertised newline input inserts LF preserving untouched CRLF', (
    tester,
  ) async {
    final editor = _Editor('\u{1f600}\r\nab');
    try {
      await editor.mount(tester);
      editor.controller.selection = const TextSelection.collapsed(offset: 4);
      final value = TextEditingValue.fromJSON(
        tester.testTextInput.editingState!,
      );
      final offset = value.selection.extentOffset;
      tester.testTextInput.updateEditingValue(
        value.copyWith(
          text: value.text.replaceRange(offset, offset, '\n'),
          selection: TextSelection.collapsed(offset: offset + 1),
        ),
      );
      await tester.pump();
      expect(editor.controller.text, '\u{1f600}\r\na\nb');
      _roundTrip(editor, '\u{1f600}\r\nab', '\u{1f600}\r\na\nb');
    } finally {
      await editor.close(tester);
    }
  });

  testWidgets(
    'current-client deltas insert replace delete supplementary scalars',
    (tester) async {
      final editor = _Editor('\u{1f600}\r\nab');
      try {
        await editor.mount(tester);
        editor.controller.selection = const TextSelection.collapsed(offset: 4);
        final before = _advertised(tester);
        final offset = before.selection.extentOffset;
        // The platform retains its applied value; a controller need not echo
        // an accepted delta back before the next key arrives.
        final inserted = await _delta(
          tester,
          before,
          offset,
          offset,
          '\u{1f642}',
        );
        expect(editor.controller.text, '\u{1f600}\r\na\u{1f642}b');
        expect(editor.controller.selection.extentOffset, 5);
        final replaced = await _delta(
          tester,
          inserted,
          offset,
          offset + 2,
          '\u{1f680}',
        );
        expect(editor.controller.text, '\u{1f600}\r\na\u{1f680}b');
        expect(editor.controller.selection.extentOffset, 5);
        await _delta(tester, replaced, offset, offset + 2, '');
        expect(editor.controller.text, '\u{1f600}\r\nab');
        expect(editor.controller.selection.extentOffset, 4);
        _roundTrip(editor, '\u{1f600}\r\nab', '\u{1f600}\r\nab');
        editor.undo.clear();
        final ascii = _advertised(tester);
        await _delta(tester, ascii, offset, offset + 1, '\u{1f642}');
        expect(editor.controller.selection.extentOffset, 5);
        expect(editor.controller.text, '\u{1f600}\r\na\u{1f642}');
        _roundTrip(editor, '\u{1f600}\r\nab', '\u{1f600}\r\na\u{1f642}');
      } finally {
        await editor.close(tester);
      }
    },
  );

  testWidgets('composition deltas commit current advertised CRLF window', (
    tester,
  ) async {
    final editor = _Editor('\u{1f600}\r\nab');
    try {
      await editor.mount(tester);
      editor.controller.selection = const TextSelection.collapsed(offset: 4);
      final before = _advertised(tester);
      final offset = before.selection.extentOffset;
      final composing = await _delta(
        tester,
        before,
        offset,
        offset,
        '\u{1f642}',
        composing: TextRange(start: offset, end: offset + 2),
      );
      expect(editor.controller.text, '\u{1f600}\r\nab');
      expect(editor.controller.imeComposition!.anchor, 4);
      await _delta(tester, composing, offset, offset + 2, '\u4e2d');
      expect(editor.controller.text, '\u{1f600}\r\na\u4e2db');
      expect(editor.controller.selection.extentOffset, 5);
      _roundTrip(editor, '\u{1f600}\r\nab', '\u{1f600}\r\na\u4e2db');
    } finally {
      await editor.close(tester);
    }
  });

  testWidgets(
    'text replacement cancels old buffer and releases old native rope',
    (tester) async {
      final editor = _Editor('abc');
      try {
        final oldRope = editor.controller.rope;
        editor.controller.backspace();
        editor.controller.text = '\u{1f600}XYZ';
        await tester.pump(const Duration(milliseconds: 120));
        expect(oldRope.isDisposed, isTrue);
        expect(editor.controller.text, '\u{1f600}XYZ');
        expect(editor.controller.rope.getText(), '\u{1f600}XYZ');
        expect(editor.controller.selection.extentOffset, 4);
        expect(editor.undo.canUndo, isFalse);
      } finally {
        await editor.close(tester);
      }
    },
  );

  testWidgets('scalar bound rejects owner and input without truncating', (
    tester,
  ) async {
    final editor = _Editor('ab');
    try {
      editor.controller.maxLength = 3;
      editor.controller.replaceRange(2, 2, '\u{1f600}');
      expect(editor.controller.length, 3);
      final version = editor.controller.contentVersion;
      expect(() => editor.controller.replaceRange(3, 3, 'X'), throwsRangeError);
      expect(editor.controller.contentVersion, version);
      await editor.mount(tester);
      final value = _advertised(tester);
      // Exercise the input sink directly so rejection is observable before dispatch.
      expect(
        () => (editor.controller as TextInputClient).updateEditingValue(
          value.copyWith(text: '${value.text}X'),
        ),
        throwsRangeError,
      );
      editor.controller.backspace();
      expect(editor.controller.text, 'ab');
      final bracketValue = _advertised(tester);
      expect(
        () => (editor.controller as DeltaTextInputClient)
            .updateEditingValueWithDeltas([
              TextEditingDeltaInsertion(
                oldText: bracketValue.text,
                textInserted: '(',
                insertionOffset: 2,
                selection: const TextSelection.collapsed(offset: 3),
                composing: TextRange.empty,
              ),
            ]),
        throwsRangeError,
      );
      editor.controller.selection = const TextSelection.collapsed(offset: 0);
      expect(_advertised(tester).selection.extentOffset, 0);
    } finally {
      await editor.close(tester);
    }
  });

  testWidgets('disposing owner while mounted blocks input and later layout', (
    tester,
  ) async {
    final editor = _Editor('abc');
    try {
      await editor.mount(tester);
      editor.controller.dispose();
      editor.controller.delete();
      editor.controller.selectAll();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
      expect(tester.testTextInput.hasAnyClients, isFalse);
    } finally {
      await editor.close(tester);
    }
  });

  for (final gap in [20, 120]) {
    testWidgets('ASCII delete grouping with ${gap}ms buffer interval', (
      tester,
    ) async {
      final editor = _Editor('abc');
      try {
        await editor.mount(tester);
        editor.controller.pressDocumentHomeKey();
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pump(Duration(milliseconds: gap));
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        expect(editor.controller.text, 'c');
        _roundTrip(editor, 'abc', 'c');
      } finally {
        await editor.close(tester);
      }
    });
  }

  testWidgets('pending buffered deletion followed by CRLF boundary join', (
    tester,
  ) async {
    final editor = _Editor('a\u{1f600}\r\nb');
    try {
      editor.controller.selection = const TextSelection.collapsed(offset: 1);
      editor.controller.delete();
      editor.controller.delete();
      expect(editor.controller.text, 'ab');
      _roundTrip(editor, 'a\u{1f600}\r\nb', 'ab');
    } finally {
      await editor.close(tester);
    }
  });

  testWidgets('cached key and drag callbacks reject a retired activation', (
    tester,
  ) async {
    final editor = _Editor('abcdef');
    var token = Object();
    editor.controller.interactionToken = () => token;
    try {
      await editor.mount(tester);
      final focusWidget = tester
          .widgetList<Focus>(find.byType(Focus))
          .singleWhere((widget) => identical(widget.focusNode, editor.focus));
      final oldKey = focusWidget.onKeyEvent!;
      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(CodeForge)) + const Offset(60, 10),
      );
      final selection = editor.controller.selection;
      token = Object();
      final result = oldKey(
        editor.focus,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.delete,
          logicalKey: LogicalKeyboardKey.delete,
          timeStamp: Duration.zero,
        ),
      );
      expect(result, KeyEventResult.ignored);
      await gesture.moveBy(const Offset(50, 0));
      await gesture.up();
      expect(editor.controller.selection, selection);
      expect(editor.controller.text, 'abcdef');
    } finally {
      await editor.close(tester);
    }
  });
}

TextEditingValue _advertised(WidgetTester tester) =>
    TextEditingValue.fromJSON(tester.testTextInput.editingState!);

Future<TextEditingValue> _delta(
  WidgetTester tester,
  TextEditingValue old,
  int start,
  int end,
  String text, {
  TextRange composing = TextRange.empty,
}) async {
  final next = old.copyWith(
    text: old.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
    composing: composing,
  );
  final reply = Completer<void>();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        tester.testTextInput.setClientArgs == null
            ? throw StateError('No current client')
            : tester.testTextInput.log
                  .lastWhere((call) => call.method == 'TextInput.setClient')
                  .arguments[0],
        {
          'deltas': [
            {
              'oldText': old.text,
              'deltaText': text,
              'deltaStart': start,
              'deltaEnd': end,
              'selectionBase': next.selection.baseOffset,
              'selectionExtent': next.selection.extentOffset,
              'composingBase': composing.start,
              'composingExtent': composing.end,
            },
          ],
        },
      ]),
    ),
    (data) {
      try {
        if (data == null) throw StateError('Missing input reply');
        SystemChannels.textInput.codec.decodeEnvelope(data);
        reply.complete();
      } catch (error, stack) {
        reply.completeError(error, stack);
      }
    },
  );
  await reply.future;
  await tester.pump();
  return next;
}

void _roundTrip(_Editor editor, String original, String edited) {
  final count = editor.undo.undoStackSize;
  expect(count, greaterThan(0));
  for (var i = 0; i < count; i++) {
    expect(editor.undo.undo(), isTrue);
  }
  expect(editor.controller.text, original);
  for (var i = 0; i < count; i++) {
    expect(editor.undo.redo(), isTrue);
  }
  expect(editor.controller.text, edited);
}

class _Editor {
  _Editor(String text) {
    controller.text = text;
    controller.setUndoController(undo);
  }
  final controller = CodeForgeController();
  final undo = UndoRedoController();
  final focus = FocusNode();
  final horizontal = ScrollController();
  final vertical = ScrollController();

  Future<void> mount(WidgetTester tester, {bool autofocus = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeForge(
            controller: controller,
            undoController: undo,
            focusNode: focus,
            horizontalScrollController: horizontal,
            verticalScrollController: vertical,
            autoFocus: autofocus,
            enableFolding: false,
            enableLocalSuggestions: false,
            enableKeyboardSuggestions: false,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 150));
    controller.dispose();
    undo.dispose();
    focus.dispose();
    horizontal.dispose();
    vertical.dispose();
  }
}
