import 'dart:io';
import 'dart:typed_data';

import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';

Future<void> main(List<String> arguments) async {
  final File artifact = File(arguments.single);
  final Program program = Compiler().compile(<String, Map<String, String>>{
    'probe': <String, String>{
      'main.dart': 'String marker() => \'pure-dart-evc\';',
    },
  });
  await artifact.parent.create(recursive: true);
  await artifact.writeAsBytes(program.write());
  final Uint8List bytes = await artifact.readAsBytes();
  final Runtime runtime = Runtime(bytes.buffer.asByteData());
  final Object? result = runtime.executeLib(
    'package:probe/main.dart',
    'marker',
  );
  final Object? reified = result is $Value ? result.$reified : result;
  stdout.writeln('artifactBytes=${await artifact.length()} result=$reified');
}
