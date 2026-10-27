import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

// Keep the launcher import graph SDK-only so test-plan works before bootstrap.
// ignore: avoid_relative_lib_imports
import '../packages/plugin_builder/lib/plugin_builder.dart';
import 'build_timing.dart';
import 'contract_artifacts.dart';
import 'desktop_artifact_cache.dart';
import 'desktop_build_inputs.dart';
import 'desktop_tool_artifacts.dart';
import 'frontend_artifacts.dart';
import 'git_pty_artifact.dart';
import 'stock_frontend_descriptors.dart';

const _stockSchemaSources = {
  'dev.adele.source-editor': {
    'settings': 'plugins/source_editor/settings.schema.json',
  },
  'dev.adele.openai': {'records': 'plugins/openai/records.schema.json'},
};

Future<Map<String, Object>> desktopPreparationToolStats(Directory root) =>
    buildInputStats([
      for (final path in [
        'tools/adele.dart',
        'tools/backend_artifacts.dart',
        'tools/frontend_artifacts.dart',
        'tools/git_pty_artifact.dart',
        'tools/desktop_artifact_cache.dart',
        'tools/desktop_build_inputs.dart',
        'tools/desktop_tool_artifacts.dart',
        'tools/contract_artifacts.dart',
        'tools/build_timing.dart',
        'tools/stock_frontend_descriptors.dart',
        'packages/plugin_builder/lib/src/development_plugin_builder.dart',
      ])
        File.fromUri(root.absolute.uri.resolve(path)).path,
    ]);

Future<List<String>> prepareDesktopPluginDefines({
  required Directory repositoryRoot,
  required String flutterExecutable,
  Map<String, String>? environment,
  Map<String, Object>? initialToolStats,
  bool incrementalContracts = false,
}) => timeBuildStage(
  'desktop-preparation',
  () => withDesktopArtifactCache(
    repositoryRoot,
    (cache) => _prepareDesktopPlugins(
      repositoryRoot: repositoryRoot,
      flutterExecutable: flutterExecutable,
      environment: environment,
      cache: cache,
      initialToolStats: initialToolStats,
      incrementalContracts: incrementalContracts,
    ),
  ),
);

Future<List<String>> _prepareDesktopPlugins({
  required Directory repositoryRoot,
  required String flutterExecutable,
  required Map<String, String>? environment,
  required DesktopArtifactCache cache,
  required Map<String, Object>? initialToolStats,
  required bool incrementalContracts,
}) async {
  final toolStats =
      initialToolStats ?? await desktopPreparationToolStats(repositoryRoot);
  final startupArguments = _stockStartupArguments(
    environment ?? Platform.environment,
  );
  final sdkTimer = Stopwatch()..start();
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
  reportBuildTiming('flutter-sdk-inspection', sdkTimer);

  final enginePlatform = Abi.current() == Abi.linuxArm64
      ? 'linux-arm64'
      : 'linux-x64';
  final sdkFiles = [
    dart.path,
    runtime.path,
    await File(flutterExecutable).resolveSymbolicLinks(),
    for (final path in [
      'bin/cache/dart-sdk/bin/dartvm',
      'bin/cache/dart-sdk/bin/snapshots/dartdev_aot.dart.snapshot',
      'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot',
      'bin/cache/dart-sdk/bin/utils/gen_snapshot',
      'bin/cache/dart-sdk/lib/_internal/vm_platform_strong.dill',
      'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill',
      'bin/cache/dart-sdk/lib/_internal/vm_platform.dill',
      'bin/cache/flutter_tools.snapshot',
      'bin/cache/artifacts/engine/$enginePlatform/frontend_server_aot.dart.snapshot',
      'bin/cache/artifacts/engine/$enginePlatform/flutter_tester',
      'bin/cache/artifacts/engine/$enginePlatform/icudtl.dat',
      'bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill',
    ])
      File.fromUri(flutterRoot.uri.resolve(path)).path,
  ];
  final tools = await timeBuildStage(
    'build-tool-preparation',
    () => DesktopToolArtifacts.prepare(
      repositoryRoot: repositoryRoot,
      cache: cache,
      dartExecutable: dart.path,
      runtimeExecutable: runtime.path,
      sdkFiles: sdkFiles,
      sdkVersion: version,
    ),
  );
  await timeBuildStage(
    'contract-generation',
    () => runContractCodegen(
      repositoryRoot: repositoryRoot,
      dartExecutable: runtime.path,
      snapshot: tools.generator,
      options: [if (incrementalContracts) '--incremental'],
    ),
  );
  final inputs = await timeBuildStage('dependency-discovery', () async {
    await tools.validateArtifacts();
    return discoverDesktopBuildInputs(
      repositoryRoot: repositoryRoot,
      dartExecutable: runtime.path,
      snapshot: tools.discovery,
    );
  });
  final tooling =
      <String>[
            'tools/desktop_artifact_cache.dart',
            'tools/frontend_artifacts.dart',
            'tools/git_pty_artifact.dart',
            'tools/backend_artifacts.dart',
            'tools/stock_frontend_descriptors.dart',
            'packages/plugin_builder/lib/src/development_plugin_builder.dart',
            for (final schemas in _stockSchemaSources.values) ...schemas.values,
          ]
          .map(
            (path) =>
                File.fromUri(repositoryRoot.absolute.uri.resolve(path)).path,
          )
          .toList();
  for (final schemas in _stockSchemaSources.values) {
    for (final schema in schemas.entries) {
      final file = File.fromUri(
        repositoryRoot.absolute.uri.resolve(schema.value),
      );
      if (!await file.exists() || await file.length() == 0) {
        throw PluginBuildFailure(
          'Stock ${schema.key} schema is missing or empty: ${file.path}',
        );
      }
    }
  }
  final allPaths = {
    ...inputs.values.expand((paths) => paths),
    ...sdkFiles,
    ...tooling,
  };
  final hashingTimer = Stopwatch()..start();
  final initialStats = await buildInputStats(allPaths);
  final initialHashes = await hashBuildFiles(allPaths);
  reportBuildTiming('build-input-fingerprinting', hashingTimer);
  final sdkIdentity = {
    'version': version,
    'executables': {for (final path in sdkFiles) path: initialHashes[path]},
  };
  Future<String> identity(
    String stage,
    Object options,
    List<String> implementation,
  ) {
    final paths = inputs[stage];
    if (paths == null || paths.isEmpty) {
      throw PluginBuildFailure('No build inputs established for $stage.');
    }
    return digestJson({
      'cacheVersion': 1,
      'sdk': sdkIdentity,
      'platform': '${Platform.operatingSystem}/${Abi.current()}',
      'options': options,
      'inputs': {for (final path in paths) path: initialHashes[path]},
      'implementation': {
        for (final path in [
          'tools/desktop_artifact_cache.dart',
          ...implementation,
        ])
          path:
              initialHashes[File.fromUri(
                repositoryRoot.absolute.uri.resolve(path),
              ).path],
      },
    });
  }

  final Directory output = await cache.stage();
  final File host = File.fromUri(output.uri.resolve('host.aot'));
  final Directory installations = Directory.fromUri(
    output.uri.resolve('installations/'),
  );
  final File git = File.fromUri(installations.uri.resolve('git/backend.aot'));
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
  final File chat = File.fromUri(
    installations.uri.resolve('chat-strategy/backend.aot'),
  );
  final File localDirectoryProject = File.fromUri(
    installations.uri.resolve('local-directory-project/backend.aot'),
  );
  final File sessionEvaluator = File.fromUri(
    installations.uri.resolve('session-evaluator/backend.aot'),
  );
  final File diffViewer = File.fromUri(
    installations.uri.resolve('diff-viewer/backend.aot'),
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
          entrypoint: 'plugins/git/packages/backend/bin/git_backend.dart',
          artifact: git,
          stage: 'git-compilation',
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
        (
          entrypoint:
              'plugins/chat_strategy/packages/backend/bin/chat_strategy_backend.dart',
          artifact: chat,
          stage: 'chat-strategy-compilation',
        ),
        (
          entrypoint:
              'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
          artifact: localDirectoryProject,
          stage: 'local-directory-project-compilation',
        ),
        (
          entrypoint:
              'plugins/session_evaluator/packages/backend/bin/session_evaluator_backend.dart',
          artifact: sessionEvaluator,
          stage: 'session-evaluator-compilation',
        ),
        (
          entrypoint:
              'plugins/diff_viewer/packages/backend/bin/diff_viewer_backend.dart',
          artifact: diffViewer,
          stage: 'diff-viewer-compilation',
        ),
      ]) {
    final prepared = await cache.component(
      name: target.stage,
      identity: await identity(
        target.stage,
        ['compile', 'aot-snapshot', target.entrypoint, '-o', '<artifact>'],
        ['packages/plugin_builder/lib/src/development_plugin_builder.dart'],
      ),
      filename: 'backend.aot',
      build: (artifact) => compileAotSnapshot(
        dartExecutable: dart.path,
        workingDirectory: repositoryRoot,
        entrypoint: target.entrypoint,
        artifact: artifact,
        stage: target.stage,
        onDiagnostic: (PluginBuildDiagnostic diagnostic) {
          stdout.write(diagnostic.stdoutText);
          stderr.write(diagnostic.stderrText);
        },
      ).then((_) {}),
    );
    await target.artifact.parent.create(recursive: true);
    await prepared.copy(target.artifact.path);
  }
  Map<String, Object>? nativeIdentity;
  Map<String, Object>? nativeStats;
  if (Platform.isLinux && Abi.current() == Abi.linuxX64) {
    final ptyHelper = File.fromUri(git.parent.uri.resolve('pty-helper'));
    nativeIdentity = await timeBuildStage(
      'git-pty-toolchain-inspection',
      () => gitPtyBuildIdentity(repositoryRoot),
    );
    final nativeFiles = nativeIdentity!['inputFiles'] as List<String>;
    nativeStats = await buildInputStats([
      ...nativeFiles,
      for (final path in nativeFiles) File(path).parent.path,
    ]);
    final prepared = await cache.component(
      name: 'git-pty-helper-compilation',
      identity: await digestJson(nativeIdentity),
      filename: 'pty-helper',
      build: (artifact) =>
          prepareGitPtyHelper(repositoryRoot: repositoryRoot, output: artifact),
    );
    await prepared.copy(ptyHelper.path);
  }
  final frontends = await prepareDesktopFrontendArtifacts(
    repositoryRoot: repositoryRoot,
    flutterExecutable: flutterExecutable,
    installationRoot: installations,
    cache: cache,
    identity: (stage, options) =>
        identity(stage, options, ['tools/frontend_artifacts.dart']),
  );
  final assemblyTimer = Stopwatch()..start();
  // Publish each installation once, only after all components are prepared.
  for (final plugin in <({File? backend, String id, String displayName})>[
    (backend: diffViewer, id: 'dev.adele.diff-viewer', displayName: 'Diff'),
    (backend: null, id: 'dev.adele.source-editor', displayName: 'Source'),
    (backend: null, id: 'dev.adele.plugin.terminal', displayName: 'Terminal'),
    (
      backend: null,
      id: 'dev.adele.plugin.task-browser',
      displayName: 'Task Browser',
    ),
    (backend: git, id: 'dev.adele.plugin.git', displayName: 'Git'),
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
    (backend: chat, id: 'dev.adele.plugin.chat-strategy', displayName: 'Chat'),
    (
      backend: localDirectoryProject,
      id: 'dev.adele.plugin.local-directory-project',
      displayName: 'Local Directory Project',
    ),
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
    (
      backend: sessionEvaluator,
      id: 'dev.adele.plugin.session-evaluator',
      displayName: 'Session Evaluator',
    ),
  ]) {
    final frontend = frontends[plugin.id];
    final directory = (plugin.backend ?? frontend!).parent;
    await publishStockPluginInstallation(
      repositoryRoot: repositoryRoot,
      installationDirectory: directory,
      pluginId: plugin.id,
      displayName: plugin.displayName,
      backend: plugin.backend != null,
      frontend: frontend != null,
    );
  }
  // Re-discover as well as rehash: a new import or a new dynamically loaded file
  // must not be published under the graph observed before compilation.
  assemblyTimer.stop();
  await timeBuildStage('build-input-revalidation', () async {
    // Discovery executes the sealed AOT, not its live source. Check executable
    // artifacts before use; the full tool-input fence below spans discovery too.
    await timeBuildStage('revalidation-tools-before', tools.validateArtifacts);
    final finalInputs = await timeBuildStage(
      'revalidation-discovery',
      () => discoverDesktopBuildInputs(
        repositoryRoot: repositoryRoot,
        dartExecutable: runtime.path,
        snapshot: tools.discovery,
      ),
    );
    if (await timeBuildStage(
          'revalidation-metadata',
          () async =>
              jsonEncode(toolStats) !=
                  jsonEncode(
                    await desktopPreparationToolStats(repositoryRoot),
                  ) ||
              jsonEncode(inputs) != jsonEncode(finalInputs) ||
              jsonEncode(initialStats) !=
                  jsonEncode(await buildInputStats(allPaths)),
        ) ||
        await timeBuildStage(
          'revalidation-content',
          () async =>
              jsonEncode(initialHashes) !=
              jsonEncode(await hashBuildFiles(allPaths)),
        ) ||
        await timeBuildStage(
          'revalidation-native',
          () async =>
              nativeIdentity != null &&
              (jsonEncode(nativeStats) !=
                      jsonEncode(
                        await buildInputStats([
                          ...nativeIdentity['inputFiles'] as List<String>,
                          for (final path
                              in nativeIdentity['inputFiles'] as List<String>)
                            File(path).parent.path,
                        ]),
                      ) ||
                  jsonEncode(nativeIdentity) !=
                      jsonEncode(await gitPtyBuildIdentity(repositoryRoot))),
        )) {
      throw const PluginBuildFailure(
        'Build inputs changed during desktop preparation. Retry.',
      );
    }
    await timeBuildStage('revalidation-tools-after', tools.validate);
  });
  assemblyTimer.start();
  await tools.cache.publishComponents();
  await cache.publishComponents();
  final published = await cache.publishSnapshot(output);
  final publishedHost = File.fromUri(published.uri.resolve('host.aot'));
  final publishedInstallations = Directory.fromUri(
    published.uri.resolve('installations/'),
  );
  if (nativeIdentity != null) {
    startupArguments['dev.adele.plugin.git'] = [
      '--pty-helper=${File.fromUri(publishedInstallations.uri.resolve('git/pty-helper')).path}',
    ];
  }
  final argumentsFile = await cache.startupArguments(startupArguments);
  reportBuildTiming('installation-assembly', assemblyTimer);
  return <String>[
    '--dart-define=ADELE_DARTAOTRUNTIME_EXECUTABLE=${runtime.path}',
    '--dart-define=ADELE_BACKEND_HOST_ARTIFACT=${publishedHost.path}',
    '--dart-define=ADELE_PLUGIN_INSTALLATION_ROOT=${publishedInstallations.path}',
    '--dart-define=ADELE_PLUGIN_STARTUP_ARGUMENTS_FILE=${argumentsFile.path}',
  ];
}

/// Publishes stock metadata and authored assets after component preparation.
/// Runtime discovery remains the sole declarative-schema parser.
Future<void> publishStockPluginInstallation({
  required Directory repositoryRoot,
  required Directory installationDirectory,
  required String pluginId,
  required String displayName,
  bool backend = false,
  bool frontend = false,
}) async {
  final schemaSources =
      _stockSchemaSources[pluginId] ?? const <String, String>{};
  await installationDirectory.create(recursive: true);
  for (final schema in schemaSources.entries) {
    final source = File.fromUri(
      repositoryRoot.absolute.uri.resolve(schema.value),
    );
    try {
      final bytes = await source.readAsBytes();
      if (bytes.isEmpty) {
        throw PluginBuildFailure(
          'Stock ${schema.key} schema is empty: ${source.path}',
        );
      }
      await File.fromUri(
        installationDirectory.uri.resolve('${schema.key}.schema.json'),
      ).writeAsBytes(bytes);
    } on FileSystemException catch (error) {
      throw PluginBuildFailure(
        'Unable to prepare stock ${schema.key} schema: $error',
      );
    }
  }
  await File.fromUri(
    installationDirectory.uri.resolve('adele_plugin.installation.json'),
  ).writeAsString(
    jsonEncode(<String, Object?>{
      'manifestVersion': 1,
      'metadata': <String, Object?>{
        'id': pluginId,
        'version': '0.1.0',
        'displayName': displayName,
      },
      for (final schema in schemaSources.keys)
        '${schema}Schema': '$schema.schema.json',
      'components': <String, Object?>{
        if (backend) 'backend': <String, Object?>{'artifact': 'backend.aot'},
        if (frontend)
          'frontend': <String, Object?>{
            'artifact': 'frontend.evc',
            'presentations': stockFrontendDescriptors[pluginId] ?? [],
            'extensions': ?stockFrontendExtensionDescriptors[pluginId],
          },
      },
    }),
  );
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
