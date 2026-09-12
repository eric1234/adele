import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('self-hosting CLI remains importable without a Flutter engine', () async {
    // The shared runtime must remain plain-Dart even with a native stock picker.
    // Help compiles that import graph without credentials, providers, or a Run.
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'app/bin/adele_self_host.dart', '--help'],
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      result.stdout,
      contains('Usage: dart run app/bin/adele_self_host.dart'),
    );
    expect(result.stdout, isNot(contains('Run evidence:')));
  });
}
