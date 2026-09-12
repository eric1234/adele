import 'dart:convert';
import 'dart:io';

// Keep the launcher import graph SDK-only so test-plan works before bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';

Future<List<String>> prepareDesktopBackendDefines({
  required Directory repositoryRoot,
  required String flutterExecutable,
}) async {
  final ProcessResult machine = await Process.run(
    flutterExecutable,
    const <String>['--version', '--machine'],
    workingDirectory: repositoryRoot.path,
  );
  if (machine.exitCode != 0) {
    throw PluginBuildFailure(
      'Unable to inspect Flutter SDK: ${machine.stderr}',
    );
  }
  final Object? version = jsonDecode(machine.stdout.toString());
  if (version is! Map<String, dynamic> ||
      version['flutterRoot'] is! String ||
      (version['flutterRoot'] as String).isEmpty) {
    throw const PluginBuildFailure('Flutter SDK root was not reported.');
  }
  final Directory flutterRoot = Directory(version['flutterRoot'] as String);
  if (!flutterRoot.uri.isAbsolute) {
    throw const PluginBuildFailure('Flutter SDK root must be absolute.');
  }
  final Directory sdkBin = Directory.fromUri(
    flutterRoot.uri.resolve('bin/cache/dart-sdk/bin/'),
  );
  final File dart = File.fromUri(sdkBin.uri.resolve('dart'));
  final File runtime = File.fromUri(sdkBin.uri.resolve('dartaotruntime'));
  for (final File executable in <File>[dart, runtime]) {
    if (!await executable.exists()) {
      throw PluginBuildFailure(
        'Required SDK executable is missing: ${executable.path}',
      );
    }
  }

  final Directory parent = Directory.fromUri(
    repositoryRoot.absolute.uri.resolve('.dart_tool/adele/desktop-backends/'),
  );
  await parent.create(recursive: true);
  // Retain each invocation: an earlier app or built bundle may still use it.
  final Directory output = await parent.createTemp('build-');
  final File host = File.fromUri(output.uri.resolve('host.aot'));
  final File git = File.fromUri(output.uri.resolve('git-environment.aot'));
  for (final ({String entrypoint, File artifact, String stage}) target
      in <({String entrypoint, File artifact, String stage})>[
        (
          entrypoint:
              'packages/plugin_backend_host/bin/adele_backend_host.dart',
          artifact: host,
          stage: 'backend-host-compilation',
        ),
        (
          entrypoint:
              'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
          artifact: git,
          stage: 'git-environment-compilation',
        ),
      ]) {
    stdout.writeln('==> ${target.stage}');
    await compileAotSnapshot(
      dartExecutable: dart.path,
      workingDirectory: repositoryRoot,
      entrypoint: target.entrypoint,
      artifact: target.artifact,
      stage: target.stage,
      onDiagnostic: (PluginBuildDiagnostic diagnostic) {
        stdout.write(diagnostic.stdoutText);
        stderr.write(diagnostic.stderrText);
      },
    );
  }
  return <String>[
    '--dart-define=ADELE_DARTAOTRUNTIME_EXECUTABLE=${runtime.path}',
    '--dart-define=ADELE_BACKEND_HOST_ARTIFACT=${host.path}',
    '--dart-define=ADELE_GIT_ENVIRONMENT_ARTIFACT=${git.path}',
  ];
}
