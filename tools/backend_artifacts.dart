import 'dart:convert';
import 'dart:io';

// Keep the launcher import graph SDK-only so test-plan works before bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';
import 'frontend_artifacts.dart';
import 'stock_frontend_descriptors.dart';

Future<List<String>> prepareDesktopPluginDefines({
  required Directory repositoryRoot,
  required String flutterExecutable,
  Map<String, String>? environment,
}) async {
  final startupArguments = _stockStartupArguments(
    environment ?? Platform.environment,
  );
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
    repositoryRoot.absolute.uri.resolve('.dart_tool/adele/desktop-plugins/'),
  );
  await parent.create(recursive: true);
  // Retain each invocation: an earlier app or built bundle may still use it.
  final Directory output = await parent.createTemp('build-');
  final File host = File.fromUri(output.uri.resolve('host.aot'));
  final Directory installations = Directory.fromUri(
    output.uri.resolve('installations/'),
  );
  final File git = File.fromUri(
    installations.uri.resolve('git-environment/backend.aot'),
  );
  final File openai = File.fromUri(
    installations.uri.resolve('openai/backend.aot'),
  );
  final File agentsMd = File.fromUri(
    installations.uri.resolve('agents-md/backend.aot'),
  );
  final File searchTools = File.fromUri(
    installations.uri.resolve('search-tools/backend.aot'),
  );
  final File filesystemTools = File.fromUri(
    installations.uri.resolve('filesystem-tools/backend.aot'),
  );
  final File commandTools = File.fromUri(
    installations.uri.resolve('command-tools/backend.aot'),
  );
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
        (
          entrypoint:
              'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
          artifact: openai,
          stage: 'openai-compilation',
        ),
        (
          entrypoint:
              'plugins/agents_md/packages/backend/bin/agents_md_backend.dart',
          artifact: agentsMd,
          stage: 'agents-md-compilation',
        ),
        (
          entrypoint:
              'plugins/search_tools/packages/backend/bin/search_tools_backend.dart',
          artifact: searchTools,
          stage: 'search-tools-compilation',
        ),
        (
          entrypoint:
              'plugins/filesystem_tools/packages/backend/bin/filesystem_tools_backend.dart',
          artifact: filesystemTools,
          stage: 'filesystem-tools-compilation',
        ),
        (
          entrypoint:
              'plugins/command_tools/packages/backend/bin/command_tools_backend.dart',
          artifact: commandTools,
          stage: 'command-tools-compilation',
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
  final frontends = await prepareDesktopFrontendArtifacts(
    repositoryRoot: repositoryRoot,
    flutterExecutable: flutterExecutable,
    installationRoot: installations,
  );
  // Publish each installation once, only after all components are prepared.
  for (final plugin in [
    (
      backend: git,
      id: 'dev.adele.plugin.git-environment',
      displayName: 'Git Worktree Environment',
    ),
    (backend: openai, id: 'dev.adele.openai', displayName: 'OpenAI'),
    (
      backend: agentsMd,
      id: 'dev.adele.plugin.agents-md',
      displayName: 'AGENTS.md',
    ),
    (
      backend: searchTools,
      id: 'dev.adele.plugin.search-tools',
      displayName: 'Search Tools',
    ),
    (backend: null, id: 'dev.adele.plugin.chat-strategy', displayName: 'Chat'),
    (
      backend: filesystemTools,
      id: 'dev.adele.plugin.filesystem-tools',
      displayName: 'Filesystem Tools',
    ),
    (
      backend: commandTools,
      id: 'dev.adele.plugin.command-tools',
      displayName: 'Command Tools',
    ),
  ]) {
    final frontend = frontends[plugin.id];
    final directory = (plugin.backend ?? frontend!).parent;
    await File.fromUri(
      directory.uri.resolve('adele_plugin.installation.json'),
    ).writeAsString(
      jsonEncode(<String, Object?>{
        'manifestVersion': 1,
        'metadata': <String, Object?>{
          'id': plugin.id,
          'version': '0.1.0',
          'displayName': plugin.displayName,
        },
        'components': <String, Object?>{
          if (plugin.backend != null)
            'backend': <String, Object?>{'artifact': 'backend.aot'},
          if (frontend != null)
            'frontend': <String, Object?>{
              'artifact': 'frontend.evc',
              'presentations': stockFrontendDescriptors[plugin.id]!,
            },
        },
      }),
    );
  }
  final File argumentsFile = File.fromUri(
    output.uri.resolve('startup-arguments.json'),
  );
  await argumentsFile.writeAsString(jsonEncode(startupArguments));
  return <String>[
    '--dart-define=ADELE_DARTAOTRUNTIME_EXECUTABLE=${runtime.path}',
    '--dart-define=ADELE_BACKEND_HOST_ARTIFACT=${host.path}',
    '--dart-define=ADELE_PLUGIN_INSTALLATION_ROOT=${installations.path}',
    '--dart-define=ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE=${argumentsFile.path}',
  ];
}

// Temporary until general plugin configuration exists. Forward public references
// only; the backend owns validation and credential loading, not the launcher.
Map<String, List<String>> _stockStartupArguments(
  Map<String, String> environment,
) {
  String? configured(String suffix) {
    final value = environment['ADELE_OPENAI_CHATGPT_$suffix'];
    return value == null || value.trim().isEmpty ? null : value;
  }

  final credentialFile = configured('CREDENTIAL_FILE');
  final clientId = configured('CLIENT_ID');
  return <String, List<String>>{
    'dev.adele.openai': <String>[
      '--chatgpt-only',
      if (credentialFile != null)
        jsonEncode(<String, Object?>{
          'credentialFile': credentialFile,
          if (clientId != null)
            'clientId': clientId
          else
            'experimentalCodexClient': true,
          if (configured('INSTANCE_ID') case final String instanceId)
            'instanceId': instanceId,
          if (configured('OAUTH_ISSUER') case final String issuer)
            'issuer': issuer,
          if (configured('REDIRECT_URI') case final String redirectUri)
            'redirectUri': redirectUri,
          if (configured('ENDPOINT') case final String endpoint)
            'endpoint': endpoint,
        }),
    ],
  };
}
