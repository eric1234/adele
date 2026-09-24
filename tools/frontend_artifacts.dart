import 'dart:io';

// Keep the launcher import graph SDK-only so test-plan works before bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';

Future<Map<String, File>> prepareDesktopFrontendArtifacts({
  required Directory repositoryRoot,
  required String flutterExecutable,
  required Directory installationRoot,
}) async {
  final Directory root = repositoryRoot.absolute;
  final Directory app = Directory.fromUri(root.uri.resolve('app/'));
  final artifacts = <String, File>{};
  for (final frontend in const [
    (
      name: 'chat',
      directory: 'chat-strategy',
      pluginId: 'dev.adele.plugin.chat-strategy',
    ),
    (
      name: 'filesystem',
      directory: 'filesystem-tools',
      pluginId: 'dev.adele.plugin.filesystem-tools',
    ),
    (
      name: 'command',
      directory: 'command-tools',
      pluginId: 'dev.adele.plugin.command-tools',
    ),
    (name: 'openai', directory: 'openai', pluginId: 'dev.adele.openai'),
    (
      name: 'local-directory-project',
      directory: 'local-directory-project',
      pluginId: 'dev.adele.plugin.local-directory-project',
    ),
  ]) {
    final File artifact = File.fromUri(
      installationRoot.absolute.uri.resolve(
        '${frontend.directory}/frontend.evc',
      ),
    );
    await artifact.parent.create(recursive: true);
    final String stage = '${frontend.name}-frontend-compilation';
    final bool chat = frontend.name == 'chat';
    final bool openai = frontend.name == 'openai';
    final bool localDirectoryProject =
        frontend.name == 'local-directory-project';
    final List<String> arguments = <String>[
      'test',
      '--no-pub',
      '--concurrency',
      '1',
      chat
          ? 'tool/compile_chat_frontend.dart'
          : openai
          ? 'tool/compile_openai_activity_frontend.dart'
          : localDirectoryProject
          ? 'tool/compile_local_directory_project_frontend.dart'
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
          if (localDirectoryProject)
            'ADELE_LOCAL_DIRECTORY_PROJECT_FRONTEND_OUTPUT': artifact.path,
          if (!chat && !openai && !localDirectoryProject) ...{
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
    artifacts[frontend.pluginId] = artifact;
  }
  return artifacts;
}
