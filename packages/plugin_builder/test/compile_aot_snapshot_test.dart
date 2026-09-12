import 'dart:io';

import 'package:plugin_builder/plugin_builder.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File artifact;

  setUp(() {
    root = Directory.systemTemp.createTempSync('adele aot compiler ');
    artifact = File('${root.path}/new output/backend.aot');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('compiles one snapshot with exact argv, cwd and diagnostics', () async {
    final File compiler = _compiler(root, '''
printf '%s\n' "\$PWD"
printf 'compiler warning' >&2
printf 'snapshot' > "\$5"
''');
    PluginBuildDiagnostic? observed;
    bool callbackCompleted = false;
    final PluginBuildDiagnostic result = await compileAotSnapshot(
      dartExecutable: compiler.path,
      workingDirectory: root,
      entrypoint: 'source with spaces.dart',
      artifact: artifact,
      stage: 'test-compilation',
      onDiagnostic: (PluginBuildDiagnostic diagnostic) async {
        observed = diagnostic;
        await Future<void>.delayed(Duration.zero);
        callbackCompleted = true;
      },
    );

    expect(artifact.readAsStringSync(), 'snapshot');
    expect(result.stage, 'test-compilation');
    expect(result.command, <String>[
      compiler.path,
      'compile',
      'aot-snapshot',
      'source with spaces.dart',
      '-o',
      artifact.absolute.path,
    ]);
    expect(result.workingDirectory, root.path);
    expect(result.exitCode, 0);
    expect(result.stdoutText.trim(), root.path);
    expect(result.stderrText, 'compiler warning');
    expect(observed, same(result));
    expect(callbackCompleted, isTrue);
  });

  test('delivers diagnostics before throwing a compiler failure', () async {
    final File compiler = _compiler(root, '''
printf 'compiler output'
printf 'compiler failure' >&2
exit 7
''');
    PluginBuildDiagnostic? observed;
    await expectLater(
      compileAotSnapshot(
        dartExecutable: compiler.path,
        workingDirectory: root,
        entrypoint: 'backend.dart',
        artifact: artifact,
        stage: 'test-compilation',
        onDiagnostic: (PluginBuildDiagnostic diagnostic) {
          observed = diagnostic;
        },
      ),
      throwsA(
        isA<PluginBuildFailure>()
            .having(
              (PluginBuildFailure failure) => failure.diagnostic,
              'diagnostic',
              predicate<PluginBuildDiagnostic>(
                (PluginBuildDiagnostic value) => identical(value, observed),
              ),
            )
            .having(
              (PluginBuildFailure failure) => failure.diagnostic?.exitCode,
              'exit code',
              7,
            ),
      ),
    );
    expect(observed?.stdoutText, 'compiler output');
    expect(observed?.stderrText, 'compiler failure');
    expect(artifact.existsSync(), isFalse);
  });

  test('rejects compiler success without an output artifact', () async {
    final File compiler = _compiler(root, 'exit 0');
    await expectLater(
      compileAotSnapshot(
        dartExecutable: compiler.path,
        workingDirectory: root,
        entrypoint: 'backend.dart',
        artifact: artifact,
        stage: 'test-compilation',
      ),
      throwsA(
        isA<PluginBuildFailure>()
            .having(
              (PluginBuildFailure failure) => failure.message,
              'message',
              contains('produced no artifact'),
            )
            .having(
              (PluginBuildFailure failure) => failure.diagnostic?.exitCode,
              'exit code',
              0,
            ),
      ),
    );
  });

  test(
    'reports process-start failure through the build failure type',
    () async {
      await expectLater(
        compileAotSnapshot(
          dartExecutable: '${root.path}/missing-dart',
          workingDirectory: root,
          entrypoint: 'backend.dart',
          artifact: artifact,
          stage: 'test-compilation',
        ),
        throwsA(
          isA<PluginBuildFailure>().having(
            (PluginBuildFailure failure) => failure.message,
            'message',
            contains('test-compilation could not start'),
          ),
        ),
      );
    },
  );
}

File _compiler(Directory root, String body) {
  final File file = File('${root.path}/fake dart');
  file.writeAsStringSync('#!/bin/sh\n$body\n');
  Process.runSync('chmod', <String>['+x', file.path]);
  return file;
}
