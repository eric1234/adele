import 'dart:async';

import 'package:adele_desktop/editor/native_rich_document_editor.dart';
import 'package:adele_desktop/editor/rich_document_markdown.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
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
}) async {
  await tester.tapAt(tester.getCenter(find.text(text, findRichText: true)));
  await frames(tester);
  final state = tester
      .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
      .editorState;
  state.selection = Selection.single(
    path: [0],
    startOffset: start ?? text.length,
    endOffset: end ?? start ?? text.length,
  );
  await frames(tester);
  return state;
}

Future<void> append(WidgetTester tester, String text) async {
  final value = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '${value.text}$text',
      selection: TextSelection.collapsed(
        offset: value.text.length + text.length,
      ),
    ),
  );
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
  test('untouched snapshots preserve source including unsupported code', () {
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
