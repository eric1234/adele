import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late final Compiler compiler;

  setUpAll(() {
    compiler = Compiler()..addPlugin(flutterEvalPlugin);
  });

  test('matches upstream in-memory widget execution', () {
    final Program program = compiler.compile(_source);
    final Runtime runtime = Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin);
    final Object? result = runtime.executeLib(
      'package:example/main.dart',
      'MyApp.',
    );
    expect(result, isA<StatelessWidget>());
  });

  test('serializes and reloads widget bytecode in memory', () {
    final Program program = compiler.compile(_source);
    final Runtime runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(flutterEvalPlugin);
    final Object? result = runtime.executeLib(
      'package:example/main.dart',
      'MyApp.',
    );
    expect(result, isA<StatelessWidget>());
  });

  testWidgets('mounts the upstream-equivalent interpreted widget', (
    WidgetTester tester,
  ) async {
    final Program program = compiler.compile(_source);
    final Runtime runtime = Runtime.ofProgram(program)
      ..addPlugin(flutterEvalPlugin);
    final Object? result = runtime.executeLib(
      'package:example/main.dart',
      'MyApp.',
    );
    await tester.pumpWidget(MaterialApp(home: result! as Widget));
    expect(find.text('Interpreted Phase 1'), findsOneWidget);
  });

  testWidgets('mounts an interpreted widget reloaded from EVC bytes', (
    WidgetTester tester,
  ) async {
    final Program program = compiler.compile(_source);
    final Runtime runtime = Runtime(program.write().buffer.asByteData())
      ..addPlugin(flutterEvalPlugin);
    final Object? result = runtime.executeLib(
      'package:example/main.dart',
      'MyApp.',
    );
    await tester.pumpWidget(MaterialApp(home: result! as Widget));
    expect(find.text('Interpreted Phase 1'), findsOneWidget);
  });
}

const Map<String, Map<String, String>> _source = <String, Map<String, String>>{
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
};
