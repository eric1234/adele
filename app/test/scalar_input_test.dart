import 'package:adele_desktop/ui/settings/scalar_input.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('nonblank and length constraints do not imply a single line', (
    tester,
  ) async {
    Object? draft;
    const key = ValueKey('notes');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScalarInput(
            inputKey: key,
            type: StringSettingType.constrained(nonBlank: true, maxLength: 64),
            label: 'Notes',
            value: '',
            enabled: true,
            onChanged: (value) => draft = value,
          ),
        ),
      ),
    );
    final input = find.byKey(key);
    final field = tester.widget<TextField>(input);
    expect(field.keyboardType, TextInputType.multiline);
    expect(field.minLines, 2);
    expect(field.maxLines, isNull);
    await tester.enterText(input, ' first\nsecond ');
    expect(draft, ' first\nsecond ');
  });

  for (final (constraint, type) in [
    (
      'no ASCII controls',
      StringSettingType.constrained(rejectAsciiControls: true),
    ),
    (
      'public ID',
      StringSettingType.constrained(format: StringSettingFormat.adelePublicId),
    ),
  ]) {
    testWidgets(
      '$constraint: one row, exact paste over selection, Done',
      (tester) async {
        final text = TextEditingController(text: 'org.old.id');
        addTearDown(text.dispose);
        String? draft;
        const key = ValueKey('input');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 160,
                child: ScalarInput(
                  inputKey: key,
                  type: type,
                  label: 'Value',
                  value: text.text,
                  text: text,
                  enabled: true,
                  onChanged: (value) => draft = value as String,
                ),
              ),
            ),
          ),
        );
        final input = find.byKey(key);
        final field = tester.widget<TextField>(input);
        expect(field.keyboardType, TextInputType.text);
        expect(field.textInputAction, TextInputAction.done);
        final editable = find.byType(EditableText);
        final rowHeight = tester.getSize(editable).height;
        await tester.tap(input);
        await tester.pump();
        text.selection = const TextSelection(baseOffset: 7, extentOffset: 4);
        var clipboardReads = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              clipboardReads++;
              return {'text': 'a\nb'};
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
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(clipboardReads, 1);
        expect(draft, 'org.a\nb.id'); // Never repair the paste into org.ab.id.
        expect(text.text, draft);
        expect(text.selection, const TextSelection.collapsed(offset: 7));
        expect(field.focusNode!.hasFocus, isTrue);

        final long = 'org.${'x' * 160}.id';
        await tester.enterText(input, long);
        await tester.pumpAndSettle();
        expect(text.text, long);
        expect(draft, long);
        expect(tester.getSize(editable).height, rowHeight);
        final scroll = Scrollable.of(
          tester.element(input),
          axis: Axis.horizontal,
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        expect(scroll.position.pixels, greaterThan(0)); // Caret stays in view.
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(field.focusNode!.hasFocus, isFalse);
        expect(text.text, long);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }
}
