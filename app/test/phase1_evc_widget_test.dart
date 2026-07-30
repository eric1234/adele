import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late final Compiler compiler;

  setUpAll(() {
    compiler = Compiler()..addPlugin(flutterEvalPlugin);
  });

  testWidgets('persists, reloads, and renders an interpreted widget', (
    WidgetTester tester,
  ) async {
    final Program program = compiler.compile(<String, Map<String, String>>{
      'example': <String, String>{
        'main.dart': '''
import 'package:flutter/widgets.dart';

class MyApp extends StatelessWidget {
  MyApp();

  @override
  Widget build(BuildContext context) {
    return Text('Interpreted Phase 1');
  }
}
''',
      },
    });
    final Directory directory = Directory.systemTemp.createTempSync(
      'adele-phase1-evc-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File artifact = File('${directory.path}/frontend.evc');
    artifact.writeAsBytesSync(program.write());

    final Uint8List bytes = artifact.readAsBytesSync();
    final Runtime runtime = Runtime(bytes.buffer.asByteData())
      ..addPlugin(flutterEvalPlugin);
    final Object? result = runtime.executeLib(
      'package:example/main.dart',
      'MyApp.',
    );
    expect(result, isA<Widget>());
    await tester.pumpWidget(MaterialApp(home: result! as Widget));
    expect(find.text('Interpreted Phase 1'), findsOneWidget);
    expect(artifact.lengthSync(), greaterThan(0));
  });
}
