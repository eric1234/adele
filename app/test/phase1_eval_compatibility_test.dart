import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('constructs the direct eval compiler and Flutter plugin', () {
    final Compiler compiler = Compiler();
    compiler.addPlugin(flutterEvalPlugin);
  });
}
