import 'dart:async';

import 'package:adele_desktop/editor/native_rich_document_editor.dart';
import 'package:adele_desktop/editor/rich_document_markdown.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.linux),
  home: Scaffold(body: child),
);

Future<EditorState> select(
  WidgetTester tester,
  String text, {
  int? end,
  int? start,
  List<int> path = const [0],
}) async {
  await tester.tapAt(tester.getCenter(find.text(text, findRichText: true)));
  await frames(tester);
  final state = tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .editorState;
  state.selection = Selection.single(
    path: path,
    startOffset: start ?? text.length,
    endOffset: end ?? start ?? text.length,
  );
  await frames(tester);
  return state;
}

Future<void> append(WidgetTester tester, String text) async {
  final value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  await input(
    tester,
    TextEditingValue(
      text: '${value.text}$text',
      selection: TextSelection.collapsed(
        offset: value.text.length + text.length,
      ),
    ),
  );
}

Future<void> insertAtSelection(WidgetTester tester, String text) async {
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  final range = value.selection;
  await input(
    tester,
    TextEditingValue(
      text: value.text.replaceRange(range.start, range.end, text),
      selection: TextSelection.collapsed(offset: range.start + text.length),
    ),
  );
}

Future<void> input(WidgetTester tester, TextEditingValue value) async {
  // The mock does not retain IME updates, and AppFlowy need not echo them back.
  tester.testTextInput.editingState = value.toJSON();
  tester.testTextInput.updateEditingValue(value);
  await frames(tester);
}

Future<void> control(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  test('untouched snapshots preserve supported and unsupported source', () {
    for (final source in [
      '',
      ' \t\n\n',
      'paragraph\r\n\r\nsecond\r\n',
      '# Title\n\n**bold** and *italic*\n',
      'before  \nafter\n',
      '```dart\n  final x = 1;  \n  print(x);\n```\n',
      '````text\nembedded ``` backticks\n\ntrailing  \n````\n',
      '~~~python\n\tprint("hello")  \n~~~\n',
      '    indented\n    code  \n',
      '```dart\r\ncode  \r\n```\r\n',
      '![alt](image.png)\n',
      '|a|b|\n|-|-|\n|x|y|\n',
      'text\u00a0\n\nother block\n',
      '# \u00a0text\u2003\n',
    ]) {
      final owner = NativeRichDocumentEditor(markdown: source);
      expect(owner.snapshot()['markdown'], source);
      expect(owner.revision, 0);
      owner.dispose();
    }
  });

  testWidgets(
    'supported imported structure survives a document edit and snapshot',
    (tester) async {
      for (final source in [
        'one\n\ntwo\n',
        '# Title\n\nparagraph',
        '**bold** and *italic* and `code`',
        '- first\n- second\n  - nested',
        '3. first\n4. second\n   - nested',
        '> quoted **text**',
        '[link](https://example.invalid/a?x=1&y=2)',
        'other block\n\ntext&nbsp;\n\n# &nbsp;text&emsp;',
        '\u4e2d\u6587 \ud83d\ude42 e\u0301\r\n\r\nnext\r\n',
      ]) {
        final owner = NativeRichDocumentEditor(markdown: source);
        await tester.pumpWidget(host(owner.buildView()));
        await frames(tester);
        final state = tester
            .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
            .editorState;
        expect(owner.snapshot()['markdown'], source);
        final first = state.document.root.children.first;
        await state.apply(
          state.transaction..insertText(first, first.delta!.length, '!'),
          withUpdateSelection: false,
        );
        final exported = RichDocumentMarkdown.decode(
          owner.snapshot()['markdown']! as String,
        );
        expect(exported.toJson(), state.document.toJson());
        exported.dispose();
        owner.dispose();
        await frames(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('metrics callback cannot outlive selected widget teardown', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(markdown: 'Resize');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    await select(tester, 'Resize');
    tester.binding.handleMetricsChanged();
    await tester.pumpWidget(const SizedBox.shrink());
    owner.dispose();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('blankness uses model text rather than Markdown scaffolding', () {
    for (final source in [
      '',
      ' \t\n',
      '# ',
      '- ',
      '1. ',
      '> ',
      '```dart\n\n```',
      '```\n \t\n```',
      '# \n\n- \n\n```\n\n```',
    ]) {
      final owner = NativeRichDocumentEditor(markdown: source);
      expect(owner.unsupportedReason, isNull, reason: source);
      expect(owner.snapshot()['isBlank'], isTrue, reason: source);
      expect(owner.snapshot()['markdown'], source);
      owner.dispose();
    }
    for (final source in [
      '# title',
      '- parent\n  - child',
      '```\nx\n```',
      '![unsupported](image.png)',
    ]) {
      final owner = NativeRichDocumentEditor(markdown: source);
      expect(owner.snapshot()['isBlank'], isFalse, reason: source);
      expect(owner.snapshot()['markdown'], source);
      owner.dispose();
    }
  });

  testWidgets(
    'editing gate closes focused input and retains document and undo',
    (tester) async {
      final owner = NativeRichDocumentEditor(markdown: 'Keep');
      await tester.pumpWidget(
        host(SizedBox(height: 140, child: owner.buildView())),
      );
      await frames(tester);
      final state = await select(tester, 'Keep');
      final undo = state.undoManager;
      await append(tester, '!');
      final snapshot = owner.snapshot();
      final client = tester.testTextInput.log.lastWhere(
        (call) => call.method == 'TextInput.setClient',
      );
      owner.setEditingEnabled(false);
      expect(state.editable, isFalse);
      expect(owner.editingEnabled, isFalse);
      expect(owner.readOnly, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.textInput.name,
        SystemChannels.textInput.codec.encodeMethodCall(
          MethodCall('TextInputClient.updateEditingState', [
            (client.arguments as List).first,
            const TextEditingValue(text: 'stale').toJSON(),
          ]),
        ),
        (_) {},
      );
      // The old command list exists until rebuild: it must not pop undo history.
      final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
      editor.commandShortcutEvents
          .firstWhere((event) => event.key == 'undo')
          .handler(state);
      await frames(tester);
      await select(tester, 'Keep!', start: 0, end: 4);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await control(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, 'Keep');
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(owner.snapshot()['markdown'], snapshot['markdown']);
      expect(owner.revision, snapshot['revision']);
      owner.setEditingEnabled(true);
      await frames(tester);
      expect(await select(tester, 'Keep!'), same(state));
      expect(state.undoManager, same(undo));
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(owner.snapshot()['markdown'], 'Keep');
      await control(tester, LogicalKeyboardKey.keyY);
      expect(owner.snapshot()['markdown'], 'Keep!');
      owner.dispose();
      expect(() => owner.setEditingEnabled(true), throwsStateError);
      expect(owner.editingEnabled, isFalse);
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final code in [false, true]) {
    testWidgets('safe snapshots reject composing replacements (code: $code)', (
      tester,
    ) async {
      final owner = NativeRichDocumentEditor(
        markdown: code ? '```dart\nab\n```' : 'ab',
      );
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, 'ab', start: 0, end: 1);
      var value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
      final composing = TextEditingValue(
        text: value.text.replaceRange(
          value.selection.start,
          value.selection.end,
          'x',
        ),
        selection: TextSelection.collapsed(offset: value.selection.start + 1),
        composing: TextRange(
          start: value.selection.start,
          end: value.selection.start + 1,
        ),
      );
      tester.testTextInput.editingState = composing.toJSON();
      tester.testTextInput.updateEditingValue(composing);
      expect(owner.snapshot()['error'], 'composition_pending');
      await frames(tester);
      expect(state.document.root.children.single.delta!.toPlainText(), 'xb');
      expect(owner.snapshot()['markdown'], isNull);
      expect(owner.snapshot()['isBlank'], isNull);
      expect(owner.snapshot()['error'], 'composition_pending');
      final revision = owner.revision;
      var notices = 0;
      owner.addListener(() => notices++);
      value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
      await input(tester, value.copyWith(composing: TextRange.empty));
      expect(owner.snapshot()['markdown'], code ? '```dart\nxb\n```' : 'xb');
      expect(owner.snapshot()['isBlank'], isFalse);
      expect(owner.revision, revision);
      expect(notices, greaterThan(0));
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(state.document.root.children.single.delta!.toPlainText(), 'ab');
      owner.dispose();
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disable and blur do not silently finalize native composition', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(markdown: 'a');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, 'a');
    var value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    await input(
      tester,
      TextEditingValue(
        text: '${value.text}x',
        selection: TextSelection.collapsed(offset: value.text.length + 1),
        composing: TextRange(
          start: value.text.length,
          end: value.text.length + 1,
        ),
      ),
    );
    expect(owner.snapshot()['error'], 'composition_pending');
    tester
        .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
        .focusNode!
        .unfocus();
    await frames(tester);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(owner.snapshot()['error'], 'composition_pending');
    await tester.pumpWidget(host(const SizedBox.shrink()));
    await frames(tester);
    expect(owner.snapshot()['error'], 'composition_pending');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    expect(await select(tester, 'ax'), same(state));
    expect(owner.snapshot()['error'], 'composition_pending');
    owner.setEditingEnabled(false);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    await frames(tester);
    expect(owner.snapshot()['error'], 'composition_pending');
    expect(state.document.root.children.single.delta!.toPlainText(), 'ax');
    owner.setEditingEnabled(true);
    await frames(tester);
    await select(tester, 'ax');
    expect(owner.snapshot()['error'], 'composition_pending');
    value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    await input(
      tester,
      value.copyWith(composing: const TextRange(start: 2, end: 3)),
    );
    await input(tester, value.copyWith(composing: TextRange.empty));
    expect(owner.snapshot()['markdown'], 'ax');
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'input, formatting, copy, cut, paste and undo use native routes',
    (tester) async {
      final owner = NativeRichDocumentEditor(markdown: 'Hello');
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, 'Hello');
      var notices = 0;
      owner.addListener(() => notices++);
      expect(owner.snapshot()['markdown'], 'Hello');
      expect(owner.revision, 0);

      await Clipboard.setData(const ClipboardData(text: ''));
      await control(tester, LogicalKeyboardKey.keyV);
      expect(owner.snapshot()['markdown'], 'Hello');
      expect(owner.revision, 0);

      await control(tester, LogicalKeyboardKey.keyX);
      expect(state.document.root.children, hasLength(1));
      expect(owner.snapshot()['markdown'], 'Hello');

      await append(tester, '!');
      expect(owner.snapshot()['markdown'], contains('Hello!'));
      expect(notices, greaterThan(0));

      final beforeSelection = owner.revision;
      final beforeSelectionNotices = notices;
      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 5,
      );
      await frames(tester);
      expect(owner.revision, beforeSelection);
      expect(notices, beforeSelectionNotices);
      await control(tester, LogicalKeyboardKey.keyB);
      expect(owner.snapshot()['markdown'], contains('**Hello**'));

      await control(tester, LogicalKeyboardKey.keyC);
      expect(AppFlowyClipboard.lastText, 'Hello');
      expect(clipboard, 'Hello');
      await control(tester, LogicalKeyboardKey.keyX);
      expect(state.document.root.children.first.delta!.toPlainText(), '!');
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(state.document.root.children.first.delta!.toPlainText(), 'Hello!');

      state.selection = Selection.collapsed(Position(path: [0], offset: 6));
      await frames(tester);
      await Clipboard.setData(const ClipboardData(text: ' literal * [x]'));
      await control(tester, LogicalKeyboardKey.keyV);
      expect(
        state.document.root.children.first.delta!.toPlainText(),
        contains(' literal * [x]'),
      );
      expect(owner.snapshot()['markdown'], contains(r'\*'));

      final selectionService = state.service.selectionService;
      owner.dispose();
      selectionService.updateSelection(
        Selection.collapsed(Position(path: [0], offset: 1)),
      );
      expect(state.selection, isNull);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await frames(tester);
      expect(state.isDisposed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rebuild and complete native unmount retain document and undo', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(markdown: 'Keep');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, 'Keep');
    await append(tester, '!');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    expect(
      tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState,
      same(state),
    );

    await tester.pumpWidget(host(const SizedBox.shrink()));
    await frames(tester);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(state.isDisposed, isFalse);
    expect(owner.snapshot()['markdown'], contains('Keep!'));

    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    expect(await select(tester, 'Keep!'), same(state));
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(owner.snapshot()['markdown'], contains('Keep'));
    expect(state.document.root.children.first.delta!.toPlainText(), 'Keep');
    await control(tester, LogicalKeyboardKey.keyY);
    expect(state.document.root.children.first.delta!.toPlainText(), 'Keep!');
    await tester.pumpWidget(const SizedBox.shrink());
    owner.dispose();
    expect(state.isDisposed, isTrue);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-frame keyed replacement waits for old native detach', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(markdown: 'Keyed');
    await tester.pumpWidget(
      host(KeyedSubtree(key: const ValueKey('a'), child: owner.buildView())),
    );
    await frames(tester);
    final state = await select(tester, 'Keyed');
    await append(tester, '!');
    await tester.pumpWidget(
      host(KeyedSubtree(key: const ValueKey('b'), child: owner.buildView())),
    );
    await frames(tester);
    expect(await select(tester, 'Keyed!'), same(state));
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(state.document.root.children.single.delta!.toPlainText(), 'Keyed');
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'read-only permits selection but not text or formatting mutation',
    (tester) async {
      final owner = NativeRichDocumentEditor(
        markdown: '**Read** only',
        readOnly: true,
      );
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, 'Read only', start: 0, end: 4);
      owner.setEditingEnabled(false);
      owner.setEditingEnabled(true);
      expect(owner.editingEnabled, isFalse);
      await control(tester, LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await frames(tester);
      if (tester.testTextInput.hasAnyClients) await append(tester, 'denied');
      expect(owner.snapshot()['markdown'], '**Read** only');
      expect(owner.revision, 0);
      expect(state.editable, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await control(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, 'Read');
      owner.dispose();
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('independent owners do not share document state', (tester) async {
    final first = NativeRichDocumentEditor(markdown: 'First');
    final second = NativeRichDocumentEditor(markdown: 'Second');
    await tester.pumpWidget(host(first.buildView()));
    await frames(tester);
    final firstState = await select(tester, 'First');
    await append(tester, '!');
    await tester.pumpWidget(host(second.buildView()));
    await frames(tester);
    final secondState = await select(tester, 'Second');
    expect(secondState, isNot(same(firstState)));
    expect(first.snapshot()['markdown'], contains('First!'));
    expect(second.snapshot()['markdown'], 'Second');
    await append(tester, '?');
    expect(first.snapshot()['markdown'], contains('First!'));
    expect(second.snapshot()['markdown'], contains('Second?'));
    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();
    second.dispose();
    expect(firstState.isDisposed, isTrue);
    expect(secondState.isDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiline paste and undo retain nested list children', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(markdown: '- parent\n  - child\n');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, 'parent');
    final child = state.document.root.children.single.children.single;
    await Clipboard.setData(const ClipboardData(text: ' first\nsecond  \n'));
    await control(tester, LogicalKeyboardKey.keyV);
    expect(
      state.document.root.children.single.delta!.toPlainText(),
      'parent first\nsecond  \n',
    );
    expect(state.document.root.children.single.children.single, same(child));
    expect(owner.snapshot()['markdown'], contains('child'));
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(state.document.root.children.single.delta!.toPlainText(), 'parent');
    expect(
      state.document.root.children.single.children.single.delta!.toPlainText(),
      'child',
    );
    state.selection = Selection.collapsed(Position(path: [0], offset: 0));
    await frames(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await frames(tester);
    expect(
      state.document.root.children.single.type,
      BulletedListBlockKeys.type,
    );
    expect(owner.snapshot()['markdown'], contains('child'));
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'code typing and formatting shortcuts retain literal plain text',
    (tester) async {
      final owner = NativeRichDocumentEditor(markdown: '```dart\nseed\n```');
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, 'seed');
      final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
      expect(owner.unsupportedReason, isNull);
      expect(
        editor.blockComponentBuilders[RichDocumentMarkdown.codeBlockType],
        isA<ParagraphBlockComponentBuilder>(),
      );
      final builder =
          editor.blockComponentBuilders[RichDocumentMarkdown.codeBlockType]!;
      expect(
        builder.configuration
            .textStyle(state.document.root.children.single)
            .fontFamily,
        'monospace',
      );

      for (final literal in [
        '- item',
        '# title',
        '* item',
        '**bold**',
        '*italic*',
        '`inline`',
        '```dart',
      ]) {
        final code = state.document.root.children.single;
        state.selection = Selection.single(
          path: [0],
          startOffset: 0,
          endOffset: code.delta!.length,
        );
        await frames(tester);
        // Whole-string insertion bypasses AppFlowy's character transformations.
        for (final character in literal.split('')) {
          await insertAtSelection(tester, character);
        }
        expect(code.type, RichDocumentMarkdown.codeBlockType);
        expect(code.attributes['language'], 'dart');
        expect(code.children, isEmpty);
        expect(code.delta!.toJson(), (Delta()..insert(literal)).toJson());
        expect(state.document.root.children, hasLength(1));

        state.selection = Selection.single(
          path: [0],
          startOffset: 0,
          endOffset: literal.length,
        );
        await frames(tester);
        final revision = owner.revision;
        for (final key in [
          LogicalKeyboardKey.keyB,
          LogicalKeyboardKey.keyI,
          LogicalKeyboardKey.keyE,
        ]) {
          await control(tester, key);
        }
        expect(owner.revision, revision);
        expect(code.delta!.toJson(), (Delta()..insert(literal)).toJson());
      }
      state.selection = Selection.collapsed(Position(path: [0], offset: 7));
      await frames(tester);
      await control(tester, LogicalKeyboardKey.keyB);
      await insertAtSelection(tester, '!');
      expect(
        state.document.root.children.single.delta!.toJson(),
        (Delta()..insert('```dart!')).toJson(),
      );
      expect(owner.snapshot()['markdown'], '````dart\n```dart!\n````');
      owner.dispose();
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'code newline, paste replacement, copy and cut use native routes',
    (tester) async {
      final owner = NativeRichDocumentEditor(
        markdown: '```dart\nalpha\nomega\n```',
      );
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, 'alpha\nomega', start: 5);
      final code = state.document.root.children.single;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await frames(tester);
      expect(code.delta!.toPlainText(), 'alpha\n\nomega');
      await insertAtSelection(tester, '\n');
      expect(code.delta!.toPlainText(), 'alpha\n\n\nomega');
      expect(state.document.root.children, hasLength(1));

      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 8,
      );
      await frames(tester);
      await Clipboard.setData(const ClipboardData(text: '  *x*\r\n\t`y`\r\n'));
      await control(tester, LogicalKeyboardKey.keyV);
      const pasted = '  *x*\n\t`y`\nomega';
      expect(code.delta!.toJson(), (Delta()..insert(pasted)).toJson());
      expect(code.attributes['language'], 'dart');
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(code.delta!.toPlainText(), 'alpha\n\n\nomega');
      await control(tester, LogicalKeyboardKey.keyY);
      expect(code.delta!.toPlainText(), pasted);

      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 11,
      );
      await frames(tester);
      final revision = owner.revision;
      await control(tester, LogicalKeyboardKey.keyC);
      expect(clipboard, '  *x*\n\t`y`\n');
      expect(owner.revision, revision);
      await control(tester, LogicalKeyboardKey.keyX);
      expect(clipboard, '  *x*\n\t`y`\n');
      expect(code.delta!.toPlainText(), 'omega');
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(code.delta!.toPlainText(), pasted);
      await control(tester, LogicalKeyboardKey.keyY);
      expect(code.delta!.toPlainText(), 'omega');
      expect(owner.snapshot()['markdown'], '```dart\nomega\n```');
      owner.dispose();
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('typed fence creates code, Tab is literal and Alt Enter exits', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(markdown: 'replace');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, 'replace', start: 0, end: 7);
    for (final character in '```dart'.split('')) {
      await insertAtSelection(tester, character);
    }
    expect(state.document.root.children.single.type, ParagraphBlockKeys.type);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await frames(tester);
    expect(
      state.document.root.children.single.type,
      RichDocumentMarkdown.codeBlockType,
    );
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(state.document.root.children.single.type, ParagraphBlockKeys.type);
    expect(state.document.root.children.single.delta!.toPlainText(), '```dart');
    await control(tester, LogicalKeyboardKey.keyY);
    final code = state.document.root.children.single;
    expect(code.type, RichDocumentMarkdown.codeBlockType);
    expect(code.attributes['language'], 'dart');
    expect(code.delta!.toPlainText(), '');
    expect(owner.snapshot()['markdown'], '```dart\n\n```');
    final revision = owner.revision;
    await control(tester, LogicalKeyboardKey.enter);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await frames(tester);
    expect(owner.revision, revision);
    await insertAtSelection(tester, 'ab');
    state.selection = Selection.single(path: [0], startOffset: 1, endOffset: 2);
    await frames(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await frames(tester);
    expect(code.delta!.toPlainText(), 'a\t');

    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 1);
    await frames(tester);
    final beforeExit = code.toJson();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await frames(tester);
    expect(code.toJson(), beforeExit);
    expect(state.document.root.children, hasLength(2));
    expect(state.document.root.children.last.type, ParagraphBlockKeys.type);
    expect(state.selection, Selection.collapsed(Position(path: [1])));
    await insertAtSelection(tester, 'after');
    expect(state.document.root.children.last.delta!.toPlainText(), 'after');
    await control(tester, LogicalKeyboardKey.keyZ);
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(state.document.root.children, hasLength(1));
    expect(state.document.root.children.single.toJson(), beforeExit);
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final readOnly in [false, true]) {
    testWidgets(
      'code mouse caret and Shift arrow selection, readOnly=$readOnly',
      (tester) async {
        const text = 'abcd\nefgh';
        const source = '```text\n$text\n```';
        final owner = NativeRichDocumentEditor(
          markdown: source,
          readOnly: readOnly,
        );
        await tester.pumpWidget(host(owner.buildView()));
        await frames(tester);
        final state = tester
            .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
            .editorState;
        final rendered = tester.renderObject<RenderParagraph>(
          find.text(text, findRichText: true),
        );
        final caret = rendered.getOffsetForCaret(
          const TextPosition(offset: 2),
          Rect.zero,
        );
        await tester.tapAt(
          rendered.localToGlobal(caret + const Offset(1, 5)),
          kind: PointerDeviceKind.mouse,
        );
        await frames(tester);
        expect(
          state.selection,
          Selection.collapsed(Position(path: [0], offset: 2)),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await frames(tester);
        expect(
          state.selection,
          Selection.single(path: [0], startOffset: 3, endOffset: 1),
        );
        await control(tester, LogicalKeyboardKey.keyC);
        expect(clipboard, 'bc');
        expect(owner.snapshot()['markdown'], source);
        expect(owner.revision, 0);
        expect(tester.testTextInput.hasAnyClients, !readOnly);
        if (readOnly) {
          await control(tester, LogicalKeyboardKey.keyX);
          await control(tester, LogicalKeyboardKey.keyV);
          await control(tester, LogicalKeyboardKey.keyB);
          await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await frames(tester);
          expect(owner.snapshot()['markdown'], source);
          expect(owner.revision, 0);
          expect(tester.testTextInput.hasAnyClients, isFalse);
        } else {
          await insertAtSelection(tester, '!');
          expect(
            state.document.root.children.single.delta!.toPlainText(),
            'a!d\nefgh',
          );
        }
        owner.dispose();
        await frames(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'multiple code edits and list paste undo preserve mixed structure',
    (tester) async {
      const source =
          '# Title\n\n- parent\n  - child\n\n'
          '```dart\nfirst\n```\n\n## Middle\n\n'
          '~~~python\nsecond\n~~~\n\nAfter';
      final owner = NativeRichDocumentEditor(markdown: source);
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, 'first', path: [2]);
      final original = state.document.toJson();
      final blocks = state.document.root.children;
      final child = blocks[1].children.single;
      final childJson = child.toJson();
      await insertAtSelection(tester, '!');
      await select(tester, 'second', path: [4], start: 0, end: 6);
      await insertAtSelection(tester, 'two');
      expect(blocks[2].delta!.toPlainText(), 'first!');
      expect(blocks[2].attributes['language'], 'dart');
      expect(blocks[4].delta!.toPlainText(), 'two');
      expect(blocks[4].attributes['language'], 'python');
      await select(tester, 'parent', path: [1]);
      await Clipboard.setData(const ClipboardData(text: ' first\nsecond  \n'));
      await control(tester, LogicalKeyboardKey.keyV);
      expect(blocks[1].delta!.toPlainText(), 'parent first\nsecond  \n');
      expect(blocks[1].children.single, same(child));
      expect(child.toJson(), childJson);
      final exported = RichDocumentMarkdown.decode(
        owner.snapshot()['markdown']! as String,
      );
      expect(exported.toJson(), state.document.toJson());
      exported.dispose();
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(blocks[1].delta!.toPlainText(), 'parent');
      expect(blocks[1].children.single.toJson(), childJson);
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(blocks[4].delta!.toPlainText(), 'second');
      expect(blocks[2].delta!.toPlainText(), 'first!');
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(state.document.toJson(), original);
      owner.dispose();
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('code IME commits and replacements remain literal', (
    tester,
  ) async {
    const source = '~~~dart\n`x`\n~~~';
    final owner = NativeRichDocumentEditor(markdown: source);
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, '`x`');
    final code = state.document.root.children.single;
    var value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    await input(
      tester,
      value.copyWith(composing: const TextRange(start: 1, end: 4)),
    );
    value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    expect(value.composing, const TextRange(start: 1, end: 4));
    await input(tester, value.copyWith(composing: TextRange.empty));
    expect(code.delta!.toJson(), (Delta()..insert('`x`')).toJson());
    expect(owner.snapshot()['markdown'], source);
    expect(owner.revision, 0);
    value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    expect(value.composing, TextRange.empty);
    // Commit can arrive before a frame. Rejection plus post-frame repair would
    // restore the cached old value and make this commit look like a no-op.
    tester.testTextInput.updateEditingValue(
      value.copyWith(composing: const TextRange(start: 1, end: 4)),
    );
    await tester.idle();
    tester.testTextInput.updateEditingValue(value);
    await tester.idle();
    await frames(tester);
    expect(code.delta!.toJson(), (Delta()..insert('`x`')).toJson());
    expect(owner.revision, 0);
    expect(
      TextEditingValue.fromJSON(tester.testTextInput.editingState!).composing,
      TextRange.empty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await frames(tester);
    expect(code.delta!.toPlainText(), '`x`\n');
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(code.delta!.toPlainText(), '`x`');
    value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    await input(
      tester,
      value.copyWith(selection: const TextSelection.collapsed(offset: 2)),
    );
    expect(
      state.selection,
      Selection.collapsed(Position(path: [0], offset: 1)),
    );
    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 3);
    await frames(tester);
    await insertAtSelection(tester, 'abx');
    value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    await input(
      tester,
      value.copyWith(composing: const TextRange(start: 3, end: 4)),
    );
    value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    // A composition replacement's range is not the collapsed editor selection.
    await input(
      tester,
      TextEditingValue(
        text: value.text.replaceRange(3, 4, '\n'),
        selection: const TextSelection.collapsed(offset: 4),
      ),
    );
    expect(code.delta!.toPlainText(), 'ab\n');
    await insertAtSelection(tester, ' \n');
    expect(code.delta!.toPlainText(), 'ab\n \n');
    expect(owner.snapshot()['markdown'], '```dart\nab\n \n\n```');

    // Retirement during a non-text update must not reopen its input client.
    state.selectionNotifier.addListener(() {
      if (!owner.isDisposed) owner.dispose();
    });
    value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
    await input(
      tester,
      value.copyWith(selection: const TextSelection.collapsed(offset: 2)),
    );
    expect(state.isDisposed, isTrue);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('word deletion near code never uses a neighboring offset', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(
      markdown: 'Before\n\n```dart\n  code  \n```\n\nAfter',
    );
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, '  code  ', path: [1], start: 2);
    final original = state.document.toJson();
    final code = state.document.root.children[1];
    await control(tester, LogicalKeyboardKey.backspace);
    expect(code.delta!.toPlainText(), 'code  ');
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(state.document.toJson(), original);
    state.selection = Selection.collapsed(Position(path: [1], offset: 6));
    await frames(tester);
    await control(tester, LogicalKeyboardKey.delete);
    expect(code.delta!.toPlainText(), '  code');
    await control(tester, LogicalKeyboardKey.keyZ);
    expect(state.document.toJson(), original);
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('cross-block code selections copy but reject destructive input', (
    tester,
  ) async {
    const source = 'Before\n\n```dart\nalpha\nbeta\n```\n\nAfter';
    final owner = NativeRichDocumentEditor(markdown: source);
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, 'Before');
    final original = state.document.toJson();
    final ranges = [
      (
        Selection(
          start: Position(path: [0], offset: 2),
          end: Position(path: [1], offset: 5),
        ),
        'fore\nalpha',
      ),
      (
        Selection(
          start: Position(path: [1], offset: 2),
          end: Position(path: [2], offset: 3),
        ),
        'pha\nbeta\nAft',
      ),
      (
        Selection(
          start: Position(path: [0], offset: 2),
          end: Position(path: [2], offset: 3),
        ),
        'fore\nalpha\nbeta\nAft',
      ),
    ];
    for (final (range, copied) in ranges) {
      for (final selection in [range, range.reversed]) {
        state.selection = selection;
        await frames(tester);
        final value = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        await input(
          tester,
          value.copyWith(composing: const TextRange(start: 1, end: 2)),
        );
        expect(state.selection, selection);
        await control(tester, LogicalKeyboardKey.keyC);
        expect(clipboard, copied);
        await Clipboard.setData(const ClipboardData(text: 'replacement'));
        for (final key in [
          LogicalKeyboardKey.backspace,
          LogicalKeyboardKey.delete,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.tab,
        ]) {
          await tester.sendKeyEvent(key);
          await frames(tester);
          expect(state.document.toJson(), original, reason: '$selection $key');
        }
        for (final key in [
          LogicalKeyboardKey.backspace,
          LogicalKeyboardKey.delete,
          LogicalKeyboardKey.keyX,
          LogicalKeyboardKey.keyV,
        ]) {
          await control(tester, key);
          expect(
            state.document.toJson(),
            original,
            reason: '$selection Ctrl+$key',
          );
        }
        expect(clipboard, 'replacement');
        // Exercise all three IME deltas independently of keyboard commands.
        await insertAtSelection(tester, 'denied');
        expect(state.document.toJson(), original);
        await insertAtSelection(tester, '');
        expect(state.document.toJson(), original);
        await append(tester, '!');
        expect(state.document.toJson(), original);
        expect(state.selection, selection);
        expect(owner.revision, 0);
        expect(owner.snapshot()['markdown'], source);
      }
    }
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'boundary deletion preserves code language and neighboring heading',
    (tester) async {
      const source = 'Before\n\n```dart\nalpha\nbeta\n```\n\n## After';
      final owner = NativeRichDocumentEditor(markdown: source);
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, 'Before');
      final original = state.document.toJson();
      for (final (path, offset, key) in [
        ([0], 6, LogicalKeyboardKey.delete),
        ([1], 0, LogicalKeyboardKey.backspace),
        ([1], 10, LogicalKeyboardKey.delete),
        ([2], 0, LogicalKeyboardKey.backspace),
      ]) {
        state.selection = Selection.collapsed(
          Position(path: path, offset: offset),
        );
        await frames(tester);
        await tester.sendKeyEvent(key);
        await frames(tester);
        expect(state.document.toJson(), original, reason: '$path $key');
        await control(tester, key);
        expect(state.document.toJson(), original, reason: '$path Ctrl+$key');
        expect(owner.revision, 0);
      }
      final code = state.document.root.children[1];
      for (final (offset, key) in [
        (5, LogicalKeyboardKey.delete),
        (6, LogicalKeyboardKey.backspace),
      ]) {
        state.selection = Selection.collapsed(
          Position(path: [1], offset: offset),
        );
        await frames(tester);
        await tester.sendKeyEvent(key);
        await frames(tester);
        expect(code.delta!.toPlainText(), 'alphabeta');
        expect(code.type, RichDocumentMarkdown.codeBlockType);
        expect(code.attributes['language'], 'dart');
        await control(tester, LogicalKeyboardKey.keyZ);
        expect(state.document.toJson(), original);
      }
      owner.dispose();
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'code remount retains exact CRLF until editing, then retains undo',
    (tester) async {
      const source = '~~~dart\r\n  value  \r\n\tline\r\n~~~\r\n';
      const text = '  value  \n\tline';
      final owner = NativeRichDocumentEditor(markdown: source);
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      final state = await select(tester, text);
      expect(owner.snapshot()['markdown'], source);
      expect(owner.revision, 0);
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await frames(tester);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(state.isDisposed, isFalse);
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      expect(await select(tester, text), same(state));
      expect(owner.snapshot()['markdown'], source);
      expect(owner.revision, 0);
      await insertAtSelection(tester, '!');
      expect(owner.snapshot()['markdown'], '```dart\n$text!\n```');
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await frames(tester);
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      expect(await select(tester, '$text!'), same(state));
      await control(tester, LogicalKeyboardKey.keyZ);
      expect(owner.snapshot()['markdown'], '```dart\n$text\n```');
      await control(tester, LogicalKeyboardKey.keyY);
      expect(owner.snapshot()['markdown'], '```dart\n$text!\n```');
      owner.dispose();
      await frames(tester);
      expect(state.isDisposed, isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final cut in [false, true]) {
    testWidgets(
      'pending code ${cut ? 'cut' : 'paste'} cannot mutate stale input',
      (tester) async {
        for (final invalidation in [
          'selection',
          'revision',
          'unmount',
          'focus',
          'retirement',
        ]) {
          final pending = Completer<Object?>();
          var requests = 0;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                if (call.method ==
                    (cut ? 'Clipboard.setData' : 'Clipboard.getData')) {
                  requests++;
                  return pending.future;
                }
                return null;
              });
          final owner = NativeRichDocumentEditor(
            markdown: '```dart\nkeep\n```',
          );
          await tester.pumpWidget(host(owner.buildView()));
          await frames(tester);
          final state = await select(tester, 'keep', start: 0, end: 2);
          final selection = state.selection;
          await control(
            tester,
            cut ? LogicalKeyboardKey.keyX : LogicalKeyboardKey.keyV,
          );
          expect(requests, 1, reason: invalidation);
          switch (invalidation) {
            case 'selection':
              state.selection = Selection.collapsed(
                Position(path: [0], offset: 4),
              );
              await frames(tester);
            case 'revision':
              await insertAtSelection(tester, 'OK');
              // Restore the captured selection so revision alone must fence it.
              state.selection = selection;
              await frames(tester);
            case 'unmount':
              await tester.pumpWidget(host(const SizedBox.shrink()));
              await frames(tester);
              expect(tester.testTextInput.hasAnyClients, isFalse);
              await tester.pumpWidget(host(owner.buildView()));
              await frames(tester);
              expect(
                await select(tester, 'keep', start: 0, end: 2),
                same(state),
              );
            case 'focus':
              tester
                  .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
                  .focusNode!
                  .unfocus();
              await frames(tester);
            case 'retirement':
              owner.dispose();
              await frames(tester);
          }
          final revision = owner.revision;
          pending.complete(cut ? null : {'text': 'stale paste'});
          await frames(tester);
          expect(owner.revision, revision, reason: invalidation);
          if (invalidation == 'retirement') {
            expect(state.isDisposed, isTrue);
            expect(tester.testTextInput.hasAnyClients, isFalse);
          } else {
            expect(
              state.document.root.children.single.delta!.toPlainText(),
              invalidation == 'revision' ? 'OKep' : 'keep',
              reason: invalidation,
            );
            expect(
              state.document.root.children.single.attributes['language'],
              'dart',
            );
            owner.dispose();
            await frames(tester);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('competing mount fails without replacing the first attachment', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(markdown: 'Single');
    await tester.pumpWidget(
      host(
        Row(
          children: [
            Expanded(child: owner.buildView()),
            Expanded(child: owner.buildView()),
          ],
        ),
      ),
    );
    await frames(tester);
    expect(tester.takeException(), isStateError);
    expect(find.byType(AppFlowyEditor), findsOneWidget);
    await select(tester, 'Single');
    await append(tester, '!');
    expect(owner.snapshot()['markdown'], contains('Single!'));
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unsupported Markdown remains explicit, intact and non-editable',
    (tester) async {
      const markdown =
          'Before\n\n![alt](https://example.invalid/image.png)\n\nAfter\n';
      final owner = NativeRichDocumentEditor(markdown: markdown);
      expect(owner.unsupportedReason, isNotNull);
      expect(owner.readOnly, isTrue);
      owner.setEditingEnabled(true);
      expect(owner.editingEnabled, isFalse);
      expect(owner.snapshot()['markdown'], markdown);
      await tester.pumpWidget(host(owner.buildView()));
      await frames(tester);
      expect(find.byType(AppFlowyEditor), findsNothing);
      expect(find.textContaining('Read-only Markdown:'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      owner.dispose();
      await frames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('disposal fences a pending clipboard completion', (tester) async {
    final clipboard = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') return clipboard.future;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final owner = NativeRichDocumentEditor(markdown: 'Original');
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final state = await select(tester, 'Original');
    await control(tester, LogicalKeyboardKey.keyV);
    owner.dispose();
    clipboard.complete({'text': 'stale paste'});
    await frames(tester);
    expect(state.isDisposed, isTrue);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(owner.buildView, throwsStateError);
    expect(owner.snapshot, throwsStateError);
    owner.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('links stay inert and unsupported actions are not installed', (
    tester,
  ) async {
    final owner = NativeRichDocumentEditor(
      markdown: '[label](https://example.invalid)',
    );
    await tester.pumpWidget(host(owner.buildView()));
    await frames(tester);
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(
      editor.blockComponentBuilders.keys,
      isNot(contains(ImageBlockKeys.type)),
    );
    expect(
      editor.blockComponentBuilders.keys,
      isNot(contains(TableBlockKeys.type)),
    );
    expect(editor.characterShortcutEvents, isNot(contains(slashCommand)));
    expect(editor.commandShortcutEvents, isNot(contains(openLinksCommand)));
    expect(editor.commandShortcutEvents, isNot(contains(showLinkMenuCommand)));
    expect(
      editor.commandShortcutEvents,
      isNot(contains(toggleUnderlineCommand)),
    );
    expect(editor.contextMenuBuilder, isNull);
    expect(editor.contentInsertionConfiguration, isNull);
    final before = const TextSpan(text: 'label');
    final decorated = editor.editorStyle.textSpanDecorator!(
      tester.element(find.byType(AppFlowyEditor)),
      editor.editorState.document.root.children.first,
      0,
      TextInsert(
        'label',
        attributes: {AppFlowyRichTextKeys.href: 'https://example.invalid'},
      ),
      before,
      before,
    );
    expect((decorated as TextSpan).recognizer, isNull);
    owner.dispose();
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
