import 'dart:io';

import 'package:adele_desktop/frontend/prepared_frontend.dart';
import 'package:adele_desktop/frontend/presentation_dialog_bridge.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:modal_probe/main.dart';

void main() {
  late File artifact;
  setUpAll(() async {
    final temp = await Directory.systemTemp.createTemp('prepared-modal-');
    addTearDown(() => temp.delete(recursive: true));
    final compiler = Compiler()
      ..addPlugin(flutterEvalPlugin)
      ..addPlugin(const PresentationDialogDeclarations())
      ..entrypoints.add(_library);
    final program = compiler.compile({
      'modal_probe': {'main.dart': _source},
      'adele_ui': {
        'presentation_dialog.dart': await File(
          '../packages/ui/lib/presentation_dialog.dart',
        ).readAsString(),
      },
    });
    artifact = await File(
      '${temp.path}/modal.evc',
    ).writeAsBytes(program.write());
  });

  testWidgets(
    'stale callbacks cannot dismiss another dialog; unmount removes only the owned route',
    (tester) async {
      final frontend = await tester.runAsync(
        () => PreparedFrontend.load(artifact),
      );
      final showEditor = ValueNotifier(true);
      addTearDown(showEditor.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showEditor,
              builder: (_, visible, _) => visible
                  ? frontend!.createPresentation(
                      library: _library,
                      entrypoint: 'editor',
                      createBridge: PresentationDialogBridge.new,
                    )
                  : const Text('Editor removed'),
            ),
          ),
        ),
      );
      final open = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Open'))
          .onPressed!;
      open();
      await tester.pumpAndSettle();
      final chips = find.widgetWithText(ChoiceChip, 'Dismiss');
      final oldDismiss = tester.widget<ChoiceChip>(chips).onSelected!;
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(chips, findsNothing);
      open();
      await tester.pumpAndSettle();
      oldDismiss(true);
      await tester.pumpAndSettle();
      expect(chips, findsOneWidget);
      await tester.tap(chips);
      await tester.pumpAndSettle();
      expect(chips, findsNothing);

      open();
      await tester.pumpAndSettle();
      final ownedChild = tester.element(chips);
      final nativeDialog = showDialog<void>(
        context: ownedChild,
        builder: (_) => const AlertDialog(title: Text('Unrelated')),
      );
      await tester.pumpAndSettle();
      showEditor.value = false;
      await tester.pumpAndSettle();
      expect(ownedChild.mounted, isFalse);
      expect(find.text('Unrelated'), findsOneWidget);
      open(); // Retained callback from the unmounted editor.
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await nativeDialog;
      expect(chips, findsNothing);
      expect(find.text('Editor removed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

const _source = '''
import 'package:flutter/material.dart';
import 'package:adele_ui/presentation_dialog.dart';

Widget editor() => Editor();
class Editor extends StatelessWidget {
  Widget build(BuildContext context) => TextButton(
    onPressed: () { showPresentationDialog(context, Contents()); },
    child: Text('Open'),
  );
}
class Contents extends StatelessWidget {
  Widget build(BuildContext context) => ChoiceChip(
    label: Text('Dismiss'),
    selected: false,
    onSelected: (bool selected) {
      if (selected && isPresentationDialogCurrent(context)) {
        dismissPresentationDialog(context);
      }
    },
  );
}
''';
