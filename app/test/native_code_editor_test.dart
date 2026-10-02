import 'dart:async';

import 'package:adele_desktop/editor/native_code_editor.dart';
import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(NativeCodeEditor.initializeLibrary);

  testWidgets(
    'ordinary editing, notifications and undo retain external ownership',
    (tester) async {
      final editor = NativeCodeEditor(text: 'abc');
      await tester.runAsync(editor.initialize);
      await _mount(tester, editor);
      editor.requestFocus();
      await tester.pump();
      var changes = 0;
      editor.addListener(() => changes++);
      await _key(tester, LogicalKeyboardKey.home, control: true);
      await _key(tester, LogicalKeyboardKey.delete);
      await _key(tester, LogicalKeyboardKey.delete);
      expect(editor.snapshot()['text'], 'c');
      expect(changes, greaterThan(0));
      final snapshot = editor.snapshot();
      await _key(tester, LogicalKeyboardKey.keyZ, control: true);
      expect(editor.snapshot()['text'], 'abc');
      expect(snapshot['text'], 'c');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(editor.isDisposed, false);
      expect(editor.snapshot()['text'], 'abc');
      await _mount(tester, editor);
      editor.requestFocus();
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.keyY, control: true);
      expect(editor.snapshot()['text'], 'c');
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
      editor.dispose();
      expect(editor.snapshot, throwsStateError);
    },
  );

  testWidgets(
    'focus and admitted clipboard work stay with their original editor',
    (tester) async {
      final a = NativeCodeEditor(text: 'a');
      final b = NativeCodeEditor(text: 'b', readOnly: true);
      await tester.runAsync(() async {
        await a.initialize();
        await b.initialize();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: a.buildView()),
                Expanded(child: b.buildView()),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      a.requestFocus();
      await tester.pump();
      final held = Completer<Map<String, String>>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return held.future;
          return null;
        },
      );
      final original = tester
          .widget<CodeForge>(find.byType(CodeForge).first)
          .controller!;
      original.pressDocumentEndKey();
      final paste = original.paste();
      b.requestFocus();
      await tester.pump();
      held.complete({'text': 'x'});
      await paste;
      expect(a.snapshot()['text'], 'ax');
      expect(b.snapshot()['text'], 'b');
      for (final key in [
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.backspace,
      ]) {
        await _key(tester, key);
      }
      expect(b.snapshot()['text'], 'b');
      await tester.pumpWidget(const SizedBox.shrink());
      a.dispose();
      b.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );

  testWidgets('close retires reads and releases the displayed component', (
    tester,
  ) async {
    final editor = NativeCodeEditor(text: 'closed');
    await tester.runAsync(editor.initialize);
    await _mount(tester, editor);
    editor.dispose();
    expect(editor.readState, throwsStateError);
    expect(editor.buildView, throwsStateError);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byType(CodeForge), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained small fixes cover pending text and scalar undo', (
    tester,
  ) async {
    final editor = NativeCodeEditor(text: '\u{1f600}\nab');
    await tester.runAsync(editor.initialize);
    await _mount(tester, editor);
    editor.requestFocus();
    await tester.pump();
    await _key(tester, LogicalKeyboardKey.end, control: true);
    await _key(tester, LogicalKeyboardKey.backspace);
    expect(editor.snapshot()['text'], '\u{1f600}\na');
    await _key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(editor.snapshot()['text'], '\u{1f600}\nab');
    await tester.pumpWidget(const SizedBox.shrink());
    editor.dispose();
  });
  testWidgets('ordinary supplementary paste and undo preserve the neighbor', (
    tester,
  ) async {
    final editor = NativeCodeEditor(text: 'ab');
    await tester.runAsync(editor.initialize);
    await _mount(tester, editor);
    editor.requestFocus();
    await tester.pump();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': '\u{1f600}'};
        return null;
      },
    );
    await _key(tester, LogicalKeyboardKey.keyV, control: true);
    await tester.pump();
    expect(editor.snapshot()['text'], '\u{1f600}ab');
    await _key(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(editor.snapshot()['text'], 'ab');
    await tester.pumpWidget(const SizedBox.shrink());
    editor.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}

Future<void> _mount(WidgetTester tester, NativeCodeEditor editor) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: editor.buildView())),
  );
  await tester.pump();
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
