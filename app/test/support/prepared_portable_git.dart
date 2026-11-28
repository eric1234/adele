import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/environment_capability_access_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_backend/git_backend.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/stock_frontend_descriptors.dart';
import '../../tool/diff_viewer_frontend_compiler.dart';
import 'portable_git_review_repository.dart';
import 'prepared_environment_capability_installation.dart';

const portableGitWait = Duration(seconds: 15);
const changeSetService = 'diff.changeSetSource';
const portableApprovalProvider = 'test.callable.approval';
const _library = 'package:portable_git_consumer/main.dart';
final changeSetCapability = CapabilityKey(
  id: CapabilityId('adele.diff.change-set-source'),
  majorVersion: 1,
);

/// Suite-owned repositories and compiled artifacts; mounts never share a live installation.
final class PreparedPortableGit {
  PreparedPortableGit({required this.stock, required this.repositoryRoot});

  final bool stock;
  final Directory repositoryRoot;
  late final Directory temporary;
  final roots = <String, String>{};
  late final String selectedBaseline;
  late final String primaryBaseline;
  late final String committedRoot;
  late final File _hostArtifact;
  late final File _environmentArtifact;
  late final File _callableArtifact;
  late final File _frontendArtifact;
  late final String _aotRuntime;
  int _sequence = 0;
  int nextSequence() => _sequence++;

  Future<void> prepare() async {
    // Keep temporary Dart entrypoints under the app so AOT compilation finds
    // the resolved workspace package configuration.
    final parent = await Directory(
      '${repositoryRoot.path}/app/.dart_tool',
    ).create(recursive: true);
    temporary = await parent.createTemp('prepared-portable-git-');
    await _prepareRepositories();
    await _compileArtifacts();
  }

  Future<void> _prepareRepositories() async {
    for (final id in ['additional', 'primary']) {
      final repository = await Directory(
        '${temporary.absolute.path}/$id',
      ).create();
      roots[id] = await repository.resolveSymbolicLinks();
      await runGit(repository, [
        'init',
        '--initial-branch=${id == 'additional' ? selectedBranch : 'main'}',
      ]);
      final files = id == 'additional'
          ? {
              'file with spaces.txt': 'old selected\n',
              'deleted.txt': 'deleted selected\n',
              'staged-only.txt': 'old staged\n',
              'staged deleted.txt': 'deleted staged\n',
              'partial.txt': 'head partial\n',
              'cancel.txt': 'head cancellation\n',
              'conflicted.txt': 'base conflict\n',
              'committed-only.txt': 'baseline committed\n',
              'committed deleted.txt': 'baseline deleted\n',
              'three-layer.txt': 'baseline layer\n',
            }
          : {'primary-only.txt': 'old primary\n'};
      for (final entry in files.entries) {
        await File(
          '${repository.path}/${entry.key}',
        ).writeAsString(entry.value);
      }
      await runGit(repository, ['add', '--all']);
      await runGit(repository, [
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-m',
        'baseline',
      ]);
      if (id == 'additional') {
        // Retain the exact baseline before subsequent commits. Trusted setup
        // provisions it; no invocation derives it from current HEAD.
        selectedBaseline = await runGit(repository, ['rev-parse', 'HEAD']);
        for (final side in ['conflict-side', selectedBranch]) {
          await runGit(repository, [
            'checkout',
            if (side == 'conflict-side') '-b',
            side,
          ]);
          await File(
            '${repository.path}/conflicted.txt',
          ).writeAsString('$side conflict\n');
          if (side == selectedBranch) {
            for (final entry in {
              'committed-only.txt': 'head committed\n',
              'committed added.txt': 'head added\n',
              'three-layer.txt': 'head layer\n',
            }.entries) {
              await File(
                '${repository.path}/${entry.key}',
              ).writeAsString(entry.value);
            }
            await File('${repository.path}/committed deleted.txt').delete();
            await runGit(repository, ['add', '--all']);
          }
          await runGit(repository, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-am',
            side,
          ]);
        }
        await runGit(repository, [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          'merge',
          '--no-commit',
          'conflict-side',
        ], exitCode: 1);
        for (final entry in {
          'staged-only.txt': 'new staged\n',
          'added\nstaged.txt': 'added staged\n',
          'partial.txt': 'index partial\n',
          'cancel.txt': 'index cancellation\n',
          'three-layer.txt': 'index layer\n',
        }.entries) {
          await File(
            '${repository.path}/${entry.key}',
          ).writeAsString(entry.value);
          await runGit(repository, ['add', '--', entry.key]);
        }
        await runGit(repository, ['rm', '--', 'staged deleted.txt']);
        await File(
          '${repository.path}/partial.txt',
        ).writeAsString('work partial\n');
        await File(
          '${repository.path}/cancel.txt',
        ).writeAsString('head cancellation\n');
        await File(
          '${repository.path}/three-layer.txt',
        ).writeAsString('baseline layer\n');
        await File(
          '${repository.path}/file with spaces.txt',
        ).writeAsString('new selected\n');
        await File('${repository.path}/deleted.txt').delete();
        await File(
          '${repository.path}/line\nname.txt',
        ).writeAsString('added selected\n');
      } else {
        primaryBaseline = await runGit(repository, ['rev-parse', 'HEAD']);
        await File(
          '${repository.path}/primary-only.txt',
        ).writeAsString('new primary\n');
      }
    }
    expect(selectedBaseline, isNot(primaryBaseline));
    expect(
      await runGit(Directory(roots['additional']!), ['rev-parse', 'HEAD']),
      isNot(selectedBaseline),
    );
    if (!stock) {
      // Clone committed history only, leaving the layered/conflicted fixture intact.
      await runGit(temporary, [
        'clone',
        '--no-hardlinks',
        '--single-branch',
        '--branch',
        selectedBranch,
        roots['additional']!,
        'committed-only',
      ]);
      committedRoot = await Directory(
        '${temporary.path}/committed-only',
      ).resolveSymbolicLinks();
    }
  }

  Future<void> _compileArtifacts() async {
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    final sdk = File(dart).parent.parent.path;
    _aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    for (final name in [
      'prepared_environment_capability_support',
      'portable_git_environment',
      if (!stock) 'portable_git_callable',
    ]) {
      await File('${temporary.path}/$name.dart').writeAsString(
        await File(
          '${repositoryRoot.path}/app/test/fixtures/$name.dart.txt',
        ).readAsString(),
      );
    }
    _hostArtifact = File('${temporary.path}/host.aot');
    _environmentArtifact = File('${temporary.path}/environment.aot');
    _callableArtifact = File('${temporary.path}/callable.aot');
    _frontendArtifact = File('${temporary.path}/frontend.evc');
    if (stock) {
      await _compileStockFrontend(repositoryRoot, sdk, _frontendArtifact.path);
    } else {
      await _compileFrontend(repositoryRoot, sdk, _frontendArtifact);
    }
    for (final target in [
      (
        'packages/plugin_backend_host/bin/adele_backend_host.dart',
        _hostArtifact,
      ),
      (
        '${temporary.absolute.path}/portable_git_environment.dart',
        _environmentArtifact,
      ),
      (
        stock
            ? 'plugins/git/packages/backend/bin/git_backend.dart'
            : '${temporary.absolute.path}/portable_git_callable.dart',
        _callableArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repositoryRoot,
        entrypoint: target.$1,
        artifact: target.$2.absolute,
        stage: 'prepared-portable-git',
      );
    }
  }

  Future<void> close() => temporary.delete(recursive: true);

  Future<PreparedEnvironmentCapabilityInstallation> mount(
    WidgetTester tester, {
    bool processGrant = true,
    bool providerPermission = true,
    bool providerPresent = true,
    bool approvalGrant = false,
    bool approvalProviderPermission = true,
    bool approvalProviderPresent = false,
    bool noBufferedFacet = false,
    bool unavailable = false,
    bool concurrent = false,
    bool present = true,
    CapabilityRegistry? registry,
    ProductLifecycleCoordinator? lifecycle,
    String? additionalRoot,
    String? primaryRoot,
    bool withTaskAnchor = true,
    String? baselineCommit,
    String expectedBranchRef = selectedBranchRef,
  }) async {
    if (stock) expect(lifecycle, isNotNull);
    final selectedRoots = {
      ...roots,
      'additional': ?additionalRoot,
      'primary': ?primaryRoot,
    };
    final callablePlugin = lifecycle == null ? callablePluginId : gitPluginId;
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = PreparedEnvironmentCapabilityInstallation(
      files: temporary,
      independent: true,
      capabilities: registry,
      lifecycle: lifecycle,
      callablePlugin: callablePlugin,
      environments: [
        for (final id in ['additional', 'primary'])
          Environment(
            id: EnvironmentId(id),
            taskId: TaskId('task'),
            role: id == 'additional'
                ? EnvironmentRole.additional
                : EnvironmentRole.primary,
            providerId: ProviderId(
              'test.environment.${id == 'additional' ? 'a' : 'b'}',
            ),
            providerState: {'root': selectedRoots[id]},
          ),
      ],
    );
    addTearDown(fixture.close);
    await tester.runAsync(() async {
      final root = await Directory(
        '${temporary.path}/case-${nextSequence()}',
      ).create();
      for (final (id, artifact) in [
        (environmentPluginId, _environmentArtifact),
        (callablePlugin, _callableArtifact),
      ]) {
        final installation = await Directory('${root.path}/$id').create();
        await artifact.copy('${installation.path}/backend.aot');
        await _manifest(installation, id, {
          'backend': {'artifact': 'backend.aot'},
        });
      }
      final consumer = await Directory('${root.path}/consumer').create();
      await _frontendArtifact.copy('${consumer.path}/frontend.evc');
      await _manifest(
        consumer,
        stock ? 'dev.adele.diff-viewer' : 'test.portable.git.consumer',
        {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': stock
                ? stockFrontendDescriptors['dev.adele.diff-viewer']!
                : [
                    {
                      'role': 'mainContent',
                      'extensionId': 'test.portable.git.pane',
                      'order': 100,
                      'library': _library,
                      'initialize': 'initialize',
                      'entrypoint': 'buildPane',
                      'capabilities': [
                        {'id': changeSetCapability.id.value, 'majorVersion': 1},
                        if (approvalProviderPresent)
                          {
                            'id': reviewApprovalCapability.id.value,
                            'majorVersion': 1,
                          },
                      ],
                      if (processGrant || approvalGrant)
                        'environmentBufferedProcessCapabilities': [
                          if (processGrant)
                            {
                              'id': changeSetCapability.id.value,
                              'majorVersion': 1,
                            },
                          if (approvalGrant)
                            {
                              'id': reviewApprovalCapability.id.value,
                              'majorVersion': 1,
                            },
                        ],
                    },
                  ],
          },
        },
      );
      await fixture.backends.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: _aotRuntime,
        hostArtifactPath: _hostArtifact.path,
        startupArguments: {
          environmentPluginId: [
            jsonEncode({
              'roots': selectedRoots,
              'noBufferedFacet': noBufferedFacet,
              'unavailable': unavailable,
              'exposures': [
                for (final id in ['a', 'b'])
                  AdeleCapabilityExposure(
                    providerId: 'test.environment.$id',
                    capabilityId: environmentProviderCapability.id.value,
                    capabilityMajorVersion:
                        environmentProviderCapability.majorVersion,
                    serviceId: environmentProviderServiceId,
                    displayName: id,
                    configurationContext: id,
                  ).toMap(),
              ],
            }),
          ],
          if (!stock)
            callablePlugin: [
              jsonEncode({
                'persisted': lifecycle != null,
                if (lifecycle == null && withTaskAnchor)
                  'taskAnchor': {
                    'baselineCommit': baselineCommit ?? selectedBaseline,
                    'expectedBranchRef': expectedBranchRef,
                  },
                'exposures': [
                  if (providerPresent)
                    AdeleCapabilityExposure(
                      providerId: lifecycle == null
                          ? 'test.callable.a'
                          : gitChangeSetSourceProviderId,
                      capabilityId: changeSetCapability.id.value,
                      capabilityMajorVersion: 1,
                      serviceId: changeSetService,
                      displayName: 'Independent portable Git',
                      configurationContext: 'callable-shared',
                      environmentBound: true,
                      environmentHostServices: [
                        if (providerPermission)
                          AdeleEnvironmentHostService.bufferedProcess,
                      ],
                    ).toMap(),
                  if (approvalProviderPresent)
                    AdeleCapabilityExposure(
                      providerId: portableApprovalProvider,
                      capabilityId: reviewApprovalCapability.id.value,
                      capabilityMajorVersion: 1,
                      serviceId: reviewApprovalHandlerServiceId,
                      displayName: 'Independent portable Git approval',
                      configurationContext: 'callable-shared',
                      environmentBound: true,
                      environmentHostServices: [
                        if (approvalProviderPermission)
                          AdeleEnvironmentHostService.bufferedProcess,
                      ],
                    ).toMap(),
                ],
              }),
            ],
        },
      );
      expect(fixture.backends.state, ApplicationPluginState.ready);
      expect(fixture.backends.failure, isNull);
      expect(fixture.backends.catalog!.issues, isEmpty);
      expect(fixture.backends.catalog!.installations, hasLength(3));
      expect(fixture.backends.backends, hasLength(2));
      for (final backend in fixture.backends.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
        expect(backend.installation.frontend, isNull);
      }
      await fixture.frontends.start(fixture.backends.catalog!);
      final frontend = fixture.frontends.generations.single;
      expect(
        frontend.state,
        InstalledFrontendState.active,
        reason: '${frontend.failure}',
      );
      expect(frontend.installation.backendArtifactUri, isNull);
    });
    if (present) {
      await tester.pumpWidget(fixture.widget(concurrent: concurrent));
      await tester.pumpAndSettle();
      if (!stock) expect(find.text('idle'), findsNWidgets(concurrent ? 2 : 1));
    }
    return fixture;
  }

  Future<Map<String, String>> reviewRepositories(
    WidgetTester tester, {
    bool wholeFile = false,
    bool wholeLayer = false,
    String? newFileContent,
    String? deletedFileContent,
  }) async => (await tester.runAsync(() async {
    final result = <String, String>{};
    final name = 'review-${nextSequence()}';
    for (final id in ['additional', 'primary']) {
      final root = await Directory('${temporary.path}/$name-$id').create();
      await runGit(root, [
        'init',
        '--object-format=sha1',
        '--initial-branch=main',
      ]);
      await File('${root.path}/review.txt').writeAsString(
        wholeFile || wholeLayer ? fileReviewContent(id) : reviewContent(id),
      );
      await File('${root.path}/untouched.txt').writeAsString('$id sentinel\n');
      if (wholeLayer) {
        await File(
          '${root.path}/$deletedFileReviewPath',
        ).writeAsString('$id deleted layer\n');
      }
      if (deletedFileContent != null) {
        final deleted = File('${root.path}/$deletedFileReviewPath');
        await deleted.writeAsString(deletedFileContent);
        if (deletedFileContent.isNotEmpty) {
          final chmod = await Process.run('/bin/chmod', ['755', deleted.path]);
          expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
        }
      }
      if (wholeFile || wholeLayer) {
        await File(
          '${root.path}/z-other.txt',
        ).writeAsString('$id other baseline\n');
      }
      await runGit(root, ['add', '--all']);
      await runGit(root, [
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-m',
        'approval baseline',
      ]);
      if (wholeFile || wholeLayer) {
        await File(
          '${root.path}/review.txt',
        ).writeAsString(fileReviewContent(id, staged: true));
        await File(
          '${root.path}/untouched.txt',
        ).writeAsString('$id staged sentinel\n');
        await runGit(root, ['add', '--', 'review.txt', 'untouched.txt']);
        await File(
          '${root.path}/z-other.txt',
        ).writeAsString('$id other working\n');
      }
      if (deletedFileContent != null) {
        await File(
          '${root.path}/untouched.txt',
        ).writeAsString('$id unrelated staged deletion sentinel\n');
        await runGit(root, ['add', '--', 'untouched.txt']);
        final deleted = File('${root.path}/$deletedFileReviewPath');
        if (id == 'primary') {
          await deleted.writeAsString('Primary staged deletion sentinel\n');
          await runGit(root, ['add', '--', deletedFileReviewPath]);
          await deleted.writeAsString('Primary working deletion sentinel\n');
        } else {
          await deleted.delete();
        }
      } else if (newFileContent != null) {
        await File(
          '${root.path}/untouched.txt',
        ).writeAsString('$id unrelated staged sentinel\n');
        await runGit(root, ['add', '--', 'untouched.txt']);
        final added = File('${root.path}/$newFileReviewPath');
        if (id == 'primary') {
          await added.writeAsString('Primary staged new file\n');
          await runGit(root, ['add', '--', newFileReviewPath]);
          await added.writeAsString('Primary working new file\n');
        } else {
          await added.writeAsString(newFileContent);
        }
      } else {
        await File('${root.path}/review.txt').writeAsString(
          wholeFile || wholeLayer
              ? fileReviewContent(id, staged: true, changed: true)
              : reviewContent(id, first: true, second: true),
        );
      }
      if (wholeLayer) {
        await File('${root.path}/$deletedFileReviewPath').delete();
        await File(
          '${root.path}/$newFileReviewPath',
        ).writeAsString('$id added layer\n');
      }
      result[id] = await root.resolveSymbolicLinks();
    }
    return result;
  }))!;

  Future<
    ({
      Directory backing,
      ProductLifecycleCoordinator lifecycle,
      CapabilityRegistry registry,
    })
  >
  openDurable(
    WidgetTester tester, {
    Directory? backing,
    String? additionalRoot,
    String? primaryRoot,
    Map<String, GitTaskComparisonAnchor> initialAnchors = const {},
  }) async => (await tester.runAsync(() async {
    final source =
        backing ??
        await Directory(
          '${temporary.absolute.path}/project-${nextSequence()}',
        ).create();
    if (backing == null) {
      _seedProject(source, {
        ...roots,
        'additional': ?additionalRoot,
        'primary': ?primaryRoot,
      });
    }
    final registry = CapabilityRegistry();
    final providerId = ProviderId('test.portable.project');
    final registration = registry.register(
      provider: ProviderDescriptor(
        id: providerId,
        capability: projectProviderCapability,
        pluginId: 'test.portable.project',
        displayName: 'Durable fixture Project',
        serviceId: projectProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: _ProjectChannel(),
        serviceId: projectProviderServiceId,
        isAvailable: () => true,
      ),
    );
    addTearDown(registration.close);
    final extensions = ExtensionRegistry();
    final lifecycle = ProductLifecycleCoordinator.generated(
      store: InMemoryProductStore(),
      registry: registry,
      extensions: extensions,
      ids: _FixtureSessionIds(),
    );
    addTearDown(lifecycle.close);
    final project = await lifecycle.openProject(
      sourceLocation: source.uri,
      provider: lifecycle.resolveProjectProvider(providerId),
    );
    expect(project.id, ProjectId('project'));
    if (backing == null) {
      final database = lifecycle.databaseForEnvironment(
        EnvironmentId('primary'),
      )!;
      expect(database.loadProductGraph().sessions, isEmpty);
      // Trusted fixture provisioning, before either Sessions or AOT invocation
      // grants exist. Production snapshots only read the retained Git state.
      final anchors = GitTaskAnchorStore(
        ProjectStorageHost(
          lifecycle: lifecycle,
          owner: PluginId(gitPluginId),
          validateAccess: () {},
        ),
      );
      for (final entry in initialAnchors.entries) {
        await anchors.enrollForEnvironment(
          environmentId: entry.key,
          anchor: entry.value,
        );
      }
      expect(database.loadProductGraph().sessions, isEmpty);
      final strategy = OrchestrationStrategyId('test.uninstalled-strategy');
      final strategyRegistration = extensions.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('test.fixture.strategy'),
        value: OrchestrationStrategyContribution(
          strategyId: strategy,
          materialize: (_) => fail('Fixture must not materialize a strategy.'),
        ),
      );
      try {
        for (final environment in ['additional', 'primary', 'additional']) {
          lifecycle.createSession(
            taskId: TaskId('task'),
            strategyId: strategy,
            environmentId: EnvironmentId(environment),
          );
        }
      } finally {
        strategyRegistration.close();
      }
    } else {
      expect(
        initialAnchors,
        isEmpty,
        reason: 'Reopen never reenrolls anchors.',
      );
    }
    for (final id in ['additional', 'primary']) {
      expect(
        lifecycle.environmentRuntime.currentMaterialization(EnvironmentId(id)),
        isNull,
      );
    }
    return (backing: source, lifecycle: lifecycle, registry: registry);
  }))!;
}

void _seedProject(Directory source, Map<String, String> roots) {
  final database = ProjectDatabase.open(
    ProjectBacking(sourceLocation: source.uri, databaseRelativePath: 'data.db'),
  );
  try {
    final project = database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('project'),
    );
    final task = Task(
      id: TaskId('task'),
      projectId: project.id,
      title: 'Portable Git',
    );
    database.insertTaskWithPrimaryEnvironment(
      task,
      Environment(
        id: EnvironmentId('primary'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('test.environment.b'),
        providerState: {'root': roots['primary']},
      ),
    );
    // No public additional-Environment creation API exists. Seed only the core
    // graph here; Git anchors are enrolled later through the production store.
    database.executePluginTransaction([
      RelationalStatement(
        sql: '''INSERT INTO adele_product_environments
          (id, task_id, role, provider_id, provider_state_json)
          VALUES ('additional', :task, 'additional', :provider, :state)''',
        parameters: {
          ':task': task.id.value,
          ':provider': 'test.environment.a',
          ':state': jsonEncode({'root': roots['additional']}),
        },
        expectedRows: 1,
      ),
    ]);
  } finally {
    database.close();
  }
}

final class _FixtureSessionIds implements ProductIdSource {
  var _nextSession = 0;

  @override
  SessionId nextSessionId() => SessionId(
    const [
      'nonprimary-session',
      'primary-session',
      'shared-session',
    ][_nextSession++],
  );

  @override
  ProjectId nextProjectId() => fail('Project must already exist.');

  @override
  TaskId nextTaskId() => fail('Task must already exist.');

  @override
  EnvironmentId nextEnvironmentId() => fail('Environment must already exist.');
}

List<Map<String, Object?>> anchorRows(ProductLifecycleCoordinator lifecycle) =>
    lifecycle
        .databaseForSession(SessionId('nonprimary-session'))!
        .queryPluginRows(
          'SELECT environment_id, baseline_commit, expected_branch_ref '
          'FROM adele_git_task_anchors ORDER BY environment_id',
          const {},
        )
        .map((row) => row.values)
        .toList();

final class _ProjectChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, projectProviderServicePrepareSourceId);
    return {
      'sourceLocation': payload['sourceLocation'],
      'databaseRelativePath': 'data.db',
    };
  }
}

Future<void> _compileFrontend(
  Directory repositoryRoot,
  String sdk,
  File artifact,
) async {
  final root = repositoryRoot.path;
  final generated = await ContractGenerator(sdkPath: sdk).generateEvalClient(
    File(
      '$root/plugins/diff_viewer/packages/contract/lib/diff_viewer_contract.dart',
    ),
  );
  final program =
      (Compiler()
            ..addPlugin(flutterEvalPlugin)
            ..addPlugin(const MainContentDeclarations())
            ..addPlugin(const EnvironmentCapabilityAccessDeclarations())
            ..entrypoints.addAll([
              _library,
              'package:diff_viewer_contract/diff_viewer_contract.dart',
              'package:adele_contract/adele_contract.dart',
            ]))
          .compile({
            'portable_git_consumer': {
              'main.dart': await File(
                '$root/app/test/fixtures/portable_git_frontend.dart.txt',
              ).readAsString(),
            },
            'diff_viewer_contract': {'diff_viewer_contract.dart': generated},
            'adele_contract': {
              'adele_contract.dart': evalContractSupportSource,
            },
            'adele_ui': {
              for (final library in [
                'environment_capability_bridge',
                'main_content_bridge',
              ])
                '$library.dart': await File(
                  '$root/packages/ui/lib/$library.dart',
                ).readAsString(),
            },
          });
  await artifact.writeAsBytes(program.write());
}

Future<void> _compileStockFrontend(
  Directory repositoryRoot,
  String sdk,
  String output,
) => Isolate.run(
  // The pinned compiler retains TypeRefs by library ID across Compiler instances.
  // Keep the independently prepared probe and stock EVC type universes separate.
  () => compileDiffViewerFrontend(
    repositoryRoot: repositoryRoot,
    sdkPath: sdk,
    artifact: File(output),
  ),
);

Future<void> _manifest(
  Directory root,
  String id,
  Map<String, Object?> components,
) => File('${root.path}/adele_plugin.installation.json').writeAsString(
  jsonEncode({
    'manifestVersion': 1,
    'metadata': {'id': id, 'version': '1', 'displayName': id},
    'components': components,
  }),
);

Finder inPane(String pane, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(pane)), matching: matching);

VoidCallback paneCallback(
  WidgetTester tester,
  String label, {
  String pane = 'a',
}) => tester
    .widget<TextButton>(inPane(pane, find.widgetWithText(TextButton, label)))
    .onPressed!;

void pressPaneButton(WidgetTester tester, String label, {String pane = 'a'}) =>
    paneCallback(tester, label, pane: pane)();

Future<void> waitForFinder(
  WidgetTester tester,
  Finder finder, {
  int count = 1,
}) async {
  await tester.pump();
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(portableGitWait);
    while (finder.evaluate().length != count &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(
    finder,
    findsNWidgets(count),
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .join(' | '),
  );
}
