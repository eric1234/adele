import 'dart:io';

// Keep the launcher import graph SDK-only so test-plan works before bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';

Future<List<String>> prepareDesktopFrontendDefines({
  required Directory repositoryRoot,
  required String flutterExecutable,
}) async {
  final Directory root = repositoryRoot.absolute;
  final Directory app = Directory.fromUri(root.uri.resolve('app/'));
  final Directory parent = Directory.fromUri(
    root.uri.resolve('.dart_tool/adele/desktop-frontends/'),
  );
  await parent.create(recursive: true);
  // Retain each invocation: an earlier app or built bundle may still use it.
  final Directory output = await parent.createTemp('build-');
  final File artifact = File.fromUri(output.uri.resolve('chat.evc'));
  const String stage = 'chat-frontend-compilation';
  const List<String> arguments = <String>[
    'test',
    '--no-pub',
    '--concurrency',
    '1',
    'tool/compile_chat_frontend.dart',
  ];
  stdout.writeln('==> $stage');
  final ProcessResult result;
  try {
    result = await Process.run(
      flutterExecutable,
      arguments,
      workingDirectory: app.path,
      environment: <String, String>{
        'ADELE_REPOSITORY_ROOT': root.path,
        'ADELE_CHAT_FRONTEND_OUTPUT': artifact.path,
      },
    );
  } on ProcessException catch (error) {
    throw PluginBuildFailure('$stage could not start: $error');
  }
  final PluginBuildDiagnostic diagnostic = PluginBuildDiagnostic(
    stage: stage,
    command: <String>[flutterExecutable, ...arguments],
    workingDirectory: app.path,
    exitCode: result.exitCode,
    stdoutText: result.stdout.toString(),
    stderrText: result.stderr.toString(),
  );
  stdout.write(diagnostic.stdoutText);
  stderr.write(diagnostic.stderrText);
  if (result.exitCode != 0) {
    throw PluginBuildFailure(
      '$stage failed with exit code ${result.exitCode}.',
      diagnostic: diagnostic,
    );
  }
  if (!await artifact.exists() || await artifact.length() == 0) {
    throw PluginBuildFailure(
      '$stage produced no non-empty artifact: ${artifact.path}',
      diagnostic: diagnostic,
    );
  }
  return <String>[
    '--dart-define=ADELE_CHAT_FRONTEND_ARTIFACT=${artifact.path}',
  ];
}
