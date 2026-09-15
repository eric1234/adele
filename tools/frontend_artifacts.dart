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
  final List<String> defines = <String>[];
  for (final frontend in const [
    (name: 'chat', define: 'ADELE_CHAT_FRONTEND_ARTIFACT'),
    (name: 'filesystem', define: 'ADELE_FILESYSTEM_TOOLS_FRONTEND_ARTIFACT'),
    (name: 'command', define: 'ADELE_COMMAND_TOOLS_FRONTEND_ARTIFACT'),
    (name: 'openai', define: 'ADELE_OPENAI_ACTIVITY_FRONTEND_ARTIFACT'),
  ]) {
    final File artifact = File.fromUri(
      output.uri.resolve('${frontend.name}.evc'),
    );
    final String stage = '${frontend.name}-frontend-compilation';
    final bool chat = frontend.name == 'chat';
    final bool openai = frontend.name == 'openai';
    final List<String> arguments = <String>[
      'test',
      '--no-pub',
      '--concurrency',
      '1',
      chat
          ? 'tool/compile_chat_frontend.dart'
          : openai
          ? 'tool/compile_openai_activity_frontend.dart'
          : 'tool/compile_tool_inspection_frontends.dart',
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
          if (chat) 'ADELE_CHAT_FRONTEND_OUTPUT': artifact.path,
          if (openai) 'ADELE_OPENAI_ACTIVITY_FRONTEND_OUTPUT': artifact.path,
          if (!chat && !openai) ...{
            'ADELE_TOOL_INSPECTION_FRONTEND': frontend.name,
            'ADELE_TOOL_INSPECTION_FRONTEND_OUTPUT': artifact.path,
          },
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
    defines.add('--dart-define=${frontend.define}=${artifact.path}');
  }
  return defines;
}
