import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:flutter_eval/flutter_eval.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: phase1_eval_probe <output.evc>');
    exitCode = 64;
    return;
  }
  _stage('compiler-start');
  final Compiler compiler = Compiler()..addPlugin(flutterEvalPlugin);
  _stage('flutter-plugin-added');
  const String source = '''
import 'package:flutter/widgets.dart';
Widget buildWorkspaceDemo() => Text('Interpreted Phase 1');
''';
  final Program program = compiler.compile(<String, Map<String, String>>{
    'probe': <String, String>{'main.dart': source},
  });
  _stage('compiled');
  final File artifact = File(arguments[0]);
  await artifact.parent.create(recursive: true);
  await artifact.writeAsBytes(program.write());
  _stage('written:${await artifact.length()}');
  final Uint8List bytes = await artifact.readAsBytes();
  final Runtime runtime = Runtime(bytes.buffer.asByteData());
  runtime.addPlugin(flutterEvalPlugin);
  _stage('runtime-ready');
  final Object? result = runtime.executeLib(
    'package:probe/main.dart',
    'buildWorkspaceDemo',
  );
  final Object? reified = result is $Value ? result.$reified : result;
  _stage('executed:${reified.runtimeType}:$reified');
}

void _stage(String value) {
  stdout.writeln('${DateTime.now().toIso8601String()} $value');
}
