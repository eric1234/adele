import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';

import 'backend_test_sdk.dart';
import 'git_worktree_fixture.dart';

export 'git_worktree_fixture.dart' show git, gitPluginId, gitProviderId;

const _projectPluginId = 'dev.adele.plugin.local-directory-project';
final localDirectoryProviderId = ProviderId(
  'dev.adele.project.local-directory',
);

/// Suite-local artifacts for real Local Directory Project and Git Task lifecycles.
final class PreparedDurableGit {
  PreparedDurableGit(this.repository);

  final Directory repository;
  late final Directory _installations;
  late final File _hostArtifact;
  late final String _dartaotruntime;

  Future<void> prepare() async {
    final artifacts = await Directory.systemTemp.createTemp(
      'adele-durable-git-backends-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    _installations = await Directory('${artifacts.path}/installed').create();
    _hostArtifact = File('${artifacts.path}/host.aot');
    final sdk = backendTestSdk();
    _dartaotruntime = sdk.aotRuntime;
    // Compile once, but start a fresh shared host and both backends per runtime.
    await compileAotSnapshot(
      dartExecutable: sdk.dart,
      workingDirectory: repository,
      entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      artifact: _hostArtifact,
      stage: 'durable-git-host',
    );
    for (final entry in const {
      gitPluginId: 'plugins/git/packages/backend/bin/git_backend.dart',
      _projectPluginId:
          'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
    }.entries) {
      final installed = await Directory(
        '${_installations.path}/${entry.key}',
      ).create();
      await compileAotSnapshot(
        dartExecutable: sdk.dart,
        workingDirectory: repository,
        entrypoint: entry.value,
        artifact: File('${installed.path}/backend.aot'),
        stage: 'durable-git-${entry.key}',
      );
      await File(
        '${installed.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': entry.key,
            'version': '1.0.0',
            'displayName': entry.key,
          },
          'components': {
            'backend': {'artifact': 'backend.aot'},
          },
        }),
      );
    }
  }

  Future<AdeleRuntime> start(ProductIdSource ids) async {
    final runtime = AdeleRuntime(ids: ids);
    addTearDown(runtime.close);
    await startBackends(runtime.plugins);
    return runtime;
  }

  Future<void> startBackends(ApplicationPluginBootstrap plugins) async {
    await plugins.start(
      installationRoot: _installations.path,
      dartaotruntimeExecutable: _dartaotruntime,
      hostArtifactPath: _hostArtifact.path,
      startupArguments: const {},
    );
    expect(plugins.state, ApplicationPluginState.ready);
    expect(plugins.failure, isNull);
    expect(plugins.catalog!.issues, isEmpty);
    expect(plugins.backends, hasLength(2));
    for (final backend in plugins.backends) {
      expect(backend.state, InstalledBackendState.active);
      expect(backend.failure, isNull);
      expect(backend.connection!.isClosed, isFalse);
    }
    final git = plugins.registry
        .providersFor(environmentProviderCapability)
        .single;
    expect(git.id, gitProviderId);
    expect(git.pluginId, gitPluginId);
    final project = plugins.registry
        .providersFor(projectProviderCapability)
        .single;
    expect(project.id, localDirectoryProviderId);
    expect(project.pluginId, _projectPluginId);
  }
}

Map<String, Object?> gitAnchor(
  ProjectDatabase database,
  EnvironmentId environment,
) => database
    .queryPluginRows(
      'SELECT * FROM adele_git_task_anchors WHERE environment_id=:environment',
      {':environment': environment.value},
    )
    .single
    .values;

OrchestrationStrategyId registerGitTestStrategy(ExtensionRegistry extensions) {
  final id = OrchestrationStrategyId('dev.adele.test.git-lifecycle');
  final registration = extensions.register(
    point: orchestrationStrategyContributions,
    id: ExtensionId(id.value),
    value: OrchestrationStrategyContribution(
      strategyId: id,
      materialize: (_) => throw StateError('No Run is started.'),
    ),
  );
  addTearDown(registration.close);
  return id;
}

Future<T> invokeChangeSet<T>(
  AdeleRuntime runtime,
  Session session,
  Future<T> Function(ChangeSetSourceServiceClient) invoke, {
  ApplicationPluginBootstrap? backends,
}) async {
  final plugins = backends ?? runtime.plugins;
  final selection = await CapturedEnvironmentCapabilities(
    environmentRuntime: runtime.lifecycle.environmentRuntime,
    backends: plugins,
    session: session,
  ).resolve(changeSetSourceCapability);
  return invokeEnvironmentCapabilityWithBufferedProcess(
    selection: selection,
    backends: plugins,
    serviceId: changeSetSourceServiceId,
    invoke: (channel) => invoke(ChangeSetSourceServiceClient(channel)),
  );
}

Future<Directory> createGitRepository(String prefix) async {
  final source = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => source.delete(recursive: true));
  await File(
    '${source.path}/seed.txt',
  ).writeAsString('Original source commit.\n');
  await git(source, ['init', '--initial-branch=main', '--object-format=sha1']);
  await git(source, ['add', 'seed.txt']);
  await git(source, ['commit', '-m', 'Original source commit']);
  return source;
}

final class NoAllocationIds implements ProductIdSource {
  int calls = 0;

  Never _allocate() {
    calls++;
    throw StateError(
      'Reopening durable work must not allocate any product ID.',
    );
  }

  @override
  ProjectId nextProjectId() => _allocate();

  @override
  TaskId nextTaskId() => _allocate();

  @override
  EnvironmentId nextEnvironmentId() => _allocate();

  @override
  SessionId nextSessionId() => _allocate();
}
