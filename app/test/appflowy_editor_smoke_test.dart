import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('patched AppFlowy mounts, edits through native input, and disposes', (
    tester,
  ) async {
    await AppFlowyEditorLocalizations.load(const Locale('en'));
    final editor = EditorState(
      document: Document(
        root: pageNode(children: [paragraphNode(text: 'Hello')]),
      ),
    );
    final focus = FocusNode();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          locale: const Locale('en'),
          localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
          home: Scaffold(
            body: AppFlowyEditor(editorState: editor, focusNode: focus),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(find.text('Hello', findRichText: true), findsOneWidget);

      // The selection overlay, rather than the paragraph, receives pointer input.
      await tester.tapAt(
        tester.getCenter(find.text('Hello', findRichText: true)),
      );
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      editor.selection = Selection.collapsed(Position(path: [0], offset: 5));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isTrue);

      // Use Flutter's real text-input client route, not an editor transaction.
      // Preserve any upstream IME sentinel in the supplied editing value.
      final input = TextEditingValue.fromJSON(
        tester.testTextInput.editingState!,
      );
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${input.text}!',
          selection: TextSelection.collapsed(offset: input.text.length + 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        editor.document.root.children.single.delta!.toPlainText(),
        'Hello!',
      );
      expect(find.text('Hello!', findRichText: true), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(
        editor.document.root.children.single.delta!.toPlainText(),
        'Hello',
      );
      expect(find.text('Hello', findRichText: true), findsOneWidget);
    } finally {
      // AppFlowy closes its input client on focus loss, before widget teardown.
      focus.unfocus();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
      focus.dispose();
      await tester.pump();
    }
    expect(editor.isDisposed, isTrue);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(tester.takeException(), isNull);
  });
}
