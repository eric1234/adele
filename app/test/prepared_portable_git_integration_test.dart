@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
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
import 'package:crypto/crypto.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_backend/git_backend.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/stock_frontend_descriptors.dart';
import '../tool/diff_viewer_frontend_compiler.dart';
import 'prepared_environment_capability_integration_test.dart'
    show PreparedEnvironmentCapabilityInstallation;

const _bound = Duration(seconds: 15);
const _environmentPlugin = 'test.environment.only';
const _callablePlugin = 'test.capability.only';
const _service = 'diff.changeSetSource';
const _approvalProvider = 'test.callable.approval';
const _selectedBranch = 'selected-task';
const _selectedBranchRef = 'refs/heads/$_selectedBranch';
const _library = 'package:portable_git_consumer/main.dart';
final _capability = CapabilityKey(
  id: CapabilityId('adele.diff.change-set-source'),
  majorVersion: 1,
);

void main() {
  late Directory temporary;
  late Map<String, String> roots;
  late String selectedBaseline;
  late String primaryBaseline;
  late String committedRoot;
  late File hostArtifact;
  late File environmentArtifact;
  late File callableArtifact;
  late File frontendArtifact;
  late File stockGitArtifact;
  late File stockDiffArtifact;
  late String aotRuntime;
  var sequence = 0;

  setUpAll(() async {
    final parent = await Directory('.dart_tool').create(recursive: true);
    temporary = await parent.createTemp('prepared-portable-git-');
    roots = {};
    for (final id in ['additional', 'primary']) {
      final repository = await Directory(
        '${temporary.absolute.path}/$id',
      ).create();
      roots[id] = await repository.resolveSymbolicLinks();
      await _git(repository, [
        'init',
        '--initial-branch=${id == 'additional' ? _selectedBranch : 'main'}',
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
      await _git(repository, ['add', '--all']);
      await _git(repository, [
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
        selectedBaseline = await _git(repository, ['rev-parse', 'HEAD']);
        for (final side in ['conflict-side', _selectedBranch]) {
          await _git(repository, [
            'checkout',
            if (side == 'conflict-side') '-b',
            side,
          ]);
          await File(
            '${repository.path}/conflicted.txt',
          ).writeAsString('$side conflict\n');
          if (side == _selectedBranch) {
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
            await _git(repository, ['add', '--all']);
          }
          await _git(repository, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-am',
            side,
          ]);
        }
        await _git(repository, [
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
          await _git(repository, ['add', '--', entry.key]);
        }
        await _git(repository, ['rm', '--', 'staged deleted.txt']);
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
        primaryBaseline = await _git(repository, ['rev-parse', 'HEAD']);
        await File(
          '${repository.path}/primary-only.txt',
        ).writeAsString('new primary\n');
      }
    }
    expect(selectedBaseline, isNot(primaryBaseline));
    expect(
      await _git(Directory(roots['additional']!), ['rev-parse', 'HEAD']),
      isNot(selectedBaseline),
    );
    // Clone committed history only, leaving the layered/conflicted fixture intact.
    await _git(temporary, [
      'clone',
      '--no-hardlinks',
      '--single-branch',
      '--branch',
      _selectedBranch,
      roots['additional']!,
      'committed-only',
    ]);
    committedRoot = await Directory(
      '${temporary.path}/committed-only',
    ).resolveSymbolicLinks();
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    final sdk = File(dart).parent.parent.path;
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    for (final name in [
      'prepared_environment_capability_support',
      'portable_git_environment',
      'portable_git_callable',
    ]) {
      await File('${temporary.path}/$name.dart').writeAsString(
        await File('test/fixtures/$name.dart.txt').readAsString(),
      );
    }
    hostArtifact = File('${temporary.path}/host.aot');
    environmentArtifact = File('${temporary.path}/environment.aot');
    callableArtifact = File('${temporary.path}/callable.aot');
    frontendArtifact = File('${temporary.path}/frontend.evc');
    stockGitArtifact = File('${temporary.path}/stock-git.aot');
    stockDiffArtifact = File('${temporary.path}/stock-diff.evc');
    await _compileFrontend(sdk, frontendArtifact);
    await _compileStockFrontend(sdk, stockDiffArtifact.path);
    for (final target in [
      (
        'packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact,
      ),
      (
        '${temporary.absolute.path}/portable_git_environment.dart',
        environmentArtifact,
      ),
      (
        '${temporary.absolute.path}/portable_git_callable.dart',
        callableArtifact,
      ),
      ('plugins/git/packages/backend/bin/git_backend.dart', stockGitArtifact),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.$1,
        artifact: target.$2.absolute,
        stage: 'prepared-portable-git',
      );
    }
  });
  tearDownAll(() => temporary.delete(recursive: true));

  late PreparedEnvironmentCapabilityInstallation fixture;
  Future<void> mount(
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
    String expectedBranchRef = _selectedBranchRef,
    bool stock = false,
  }) async {
    if (stock) expect(lifecycle, isNotNull);
    final selectedRoots = {
      ...roots,
      'additional': ?additionalRoot,
      'primary': ?primaryRoot,
    };
    final callablePlugin = lifecycle == null ? _callablePlugin : gitPluginId;
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    fixture = PreparedEnvironmentCapabilityInstallation(
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
        '${temporary.path}/case-${sequence++}',
      ).create();
      for (final (id, artifact) in [
        (_environmentPlugin, environmentArtifact),
        (callablePlugin, stock ? stockGitArtifact : callableArtifact),
      ]) {
        final installation = await Directory('${root.path}/$id').create();
        await artifact.copy('${installation.path}/backend.aot');
        await _manifest(installation, id, {
          'backend': {'artifact': 'backend.aot'},
        });
      }
      final consumer = await Directory('${root.path}/consumer').create();
      await (stock ? stockDiffArtifact : frontendArtifact).copy(
        '${consumer.path}/frontend.evc',
      );
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
                        {'id': _capability.id.value, 'majorVersion': 1},
                        if (approvalProviderPresent)
                          {
                            'id': reviewApprovalCapability.id.value,
                            'majorVersion': 1,
                          },
                      ],
                      if (processGrant || approvalGrant)
                        'environmentBufferedProcessCapabilities': [
                          if (processGrant)
                            {'id': _capability.id.value, 'majorVersion': 1},
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
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          _environmentPlugin: [
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
                      capabilityId: _capability.id.value,
                      capabilityMajorVersion: 1,
                      serviceId: _service,
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
                      providerId: _approvalProvider,
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
  }

  Future<Map<String, String>> reviewRepositories(
    WidgetTester tester,
  ) async => (await tester.runAsync(() async {
    final result = <String, String>{};
    final name = 'review-${sequence++}';
    for (final id in ['additional', 'primary']) {
      final root = await Directory('${temporary.path}/$name-$id').create();
      await _git(root, [
        'init',
        '--object-format=sha1',
        '--initial-branch=main',
      ]);
      await File('${root.path}/review.txt').writeAsString(_reviewContent(id));
      await File('${root.path}/untouched.txt').writeAsString('$id sentinel\n');
      await _git(root, ['add', '--all']);
      await _git(root, [
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-m',
        'approval baseline',
      ]);
      await File(
        '${root.path}/review.txt',
      ).writeAsString(_reviewContent(id, first: true, second: true));
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
    Map<String, GitTaskComparisonAnchor> initialAnchors = const {},
  }) async => (await tester.runAsync(() async {
    final source =
        backing ??
        await Directory(
          '${temporary.absolute.path}/project-${sequence++}',
        ).create();
    if (backing == null) {
      _seedProject(source, {...roots, 'additional': ?additionalRoot});
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

  test(
    'independent A and semantic B/C preserve implementation boundaries',
    () async {
      final a = await File(
        'test/fixtures/portable_git_environment.dart.txt',
      ).readAsString();
      final b = await File(
        'test/fixtures/portable_git_callable.dart.txt',
      ).readAsString();
      final c = await File(
        'test/fixtures/portable_git_frontend.dart.txt',
      ).readAsString();
      final stock = await File(
        '../plugins/diff_viewer/packages/frontend/lib/main.dart',
      ).readAsString();
      expect(a, contains('Process.start('));
      expect(a, isNot(contains('git_backend')));
      expect(a, isNot(contains('diff_viewer_contract')));
      expect(b, contains('GitPortableUnstagedSnapshotService('));
      expect(
        b,
        contains('GitPortableReviewApprovalService(processes: processes)'),
      );
      expect(b, contains('ReviewApprovalHandlerServiceDispatcher('));
      expect(b, contains("state.checkpoint('after:\$method')"));
      expect(b, contains('processes: processes,'));
      expect(b, contains('taskAnchor: taskAnchor,'));
      expect(b, contains("state.options['taskAnchor']"));
      expect(b, contains('GitPersistedChangeSetSourceService('));
      expect(b, contains('ProjectStorageServiceClient('));
      expect(b, contains('state.hostRequests.bindInfrastructure('));
      expect(b, isNot(contains('.enrollForEnvironment(')));
      expect(
        b.indexOf('GitTaskComparisonAnchor('),
        lessThan(b.indexOf('createDispatcher:')),
      );
      expect(b, contains('return await snapshots.snapshotUncommitted();'));
      expect(b, contains('return await snapshots.snapshotTaskChanges();'));
      expect(b, contains('AuthorizedEnvironmentBufferedProcessServiceClient('));
      for (final source in [b, c]) {
        expect(source, isNot(contains("import 'dart:io'")));
        expect(source, isNot(contains('Process.start')));
        expect(source, isNot(contains('package:adele_desktop')));
        expect(source, isNot(contains('package:plugin_runtime')));
        expect(source, isNot(contains('GitWorktree')));
      }
      expect(c, contains('ChangeSetSourceServiceClient('));
      expect(c, contains('ReviewApprovalHandlerServiceClient('));
      expect(c, contains('ReviewHunkSelection('));
      expect(c, contains('file.reviewRevision'));
      expect(
        c,
        contains('final UncommittedChangeSetSnapshot value = result[1];'),
      );
      expect(c, contains('renderFiles(value.staged.files)'));
      expect(c, contains('renderFiles(value.unstaged.files)'));
      expect(c, contains('renderFiles(value.conflicts)'));
      expect(c, contains('final TaskChangeSetSnapshot value = result[1];'));
      expect(c, contains('renderFiles(value.committed.files)'));
      expect(c, contains('renderFiles(value.uncommitted.staged.files)'));
      expect(c, contains('renderFiles(value.uncommitted.unstaged.files)'));
      expect(c, contains('renderFiles(value.uncommitted.conflicts)'));
      expect(c, isNot(contains('baselineCommit')));
      expect(c, isNot(contains('expectedBranchRef')));
      expect(c, isNot(contains('taskAnchor')));
      expect(c, isNot(contains('package:adele_environment')));
      expect(c, isNot(contains('package:adele_project_storage')));
      expect(c, isNot(contains('capturedIdentity')));
      expect(c, isNot(contains('EnvironmentBufferedProcessRequest')));
      expect(c, isNot(contains('runBufferedProcess')));
      expect(c, isNot(contains('package:git_backend')));
      expect(stock, isNot(contains('reviewApprovalCapability')));
      expect(stock, isNot(contains('ReviewApprovalHandlerServiceClient')));
      expect(
        stock,
        contains('resolveEnvironmentBufferedProcessCapabilityProvider('),
      );
      expect(stock, contains('ChangeSetSourceServiceClient('));
      for (final forbidden in [
        "import 'dart:io'",
        'package:adele_environment',
        'package:adele_project_storage',
        'package:git_backend',
        'EnvironmentBufferedProcessRequest',
        'runBufferedProcess',
        'capturedIdentity',
        'baselineCommit',
      ]) {
        expect(stock, isNot(contains(forbidden)));
      }
    },
  );

  testWidgets(
    'G6a independent approval stages one hunk and unapproves without crossing same-path repositories',
    (tester) async {
      final repositories = await reviewRepositories(tester);
      final before = (await tester.runAsync(
        () => _reviewStates(repositories),
      ))!;
      await mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
        concurrent: true,
      );
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      final selected = (await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(reviewApprovalCapability),
      ))!;
      expect(selected.environment.id, EnvironmentId('additional'));
      expect(selected.environment.role, EnvironmentRole.additional);
      expect(selected.binding.provider.id.value, _approvalProvider);
      expect(fixture.callableOwner.associationFor(selected.binding), isNull);
      for (final pane in ['a', 'b']) {
        _press(tester, 'Select approval', pane: pane);
        await _text(tester, 'approval-selected', pane: pane);
        // A client without a snapshot selection must remain non-actionable.
        _press(tester, 'Approve', pane: pane);
        _press(tester, 'Unapprove', pane: pane);
        await _text(tester, 'approval:idle', pane: pane);
        await _select(tester, pane: pane);
        _press(tester, 'Uncommitted', pane: pane);
        final snapshot = await _snapshot(tester, pane: pane);
        expect(snapshot, contains('review.txt|modified|text'));
        expect(snapshot.split('\n@@'), hasLength(3));
        expect(
          snapshot,
          contains(
            'addition:${pane == 'a' ? 'additional' : 'primary'} first change:false',
          ),
        );
      }
      expect(
        await tester.runAsync(
          () => _calls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ),
        isEmpty,
      );
      expect(await tester.runAsync(() => _reviewStates(repositories)), before);
      _press(tester, 'Approve');
      await _text(tester, 'approval:success');
      final approved = (await tester.runAsync(
        () => _reviewStates(repositories),
      ))!;
      _expectReviewIndex(
        approved,
        before,
        'additional',
        _reviewContent('additional', first: true),
      );
      final calls = (await tester.runAsync(
        () => _calls(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], reviewApprovalHandlerServiceApproveHunkId);
      final selection = (calls.single['payload'] as Map)['selection'] as Map;
      expect(calls.single['payload'], {'selection': selection});
      expect(selection, {
        'relativePath': 'review.txt',
        'hunkIndex': 0,
        'expectedRevision': isA<String>().having(
          (value) => value.isNotEmpty,
          'not empty',
          isTrue,
        ),
      });
      await tester.runAsync(
        () => _denied(fixture, calls.single['hostInvocationContext'] as String),
      );
      // The EVC retains the exact old DTO; duplicate submission must not replay.
      _press(tester, 'Approve');
      await _text(tester, 'approval:unavailable');
      expect(
        await tester.runAsync(() => _reviewStates(repositories)),
        approved,
      );
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['stale_selection']);

      _press(tester, 'Uncommitted');
      final partial = await _snapshot(tester);
      final staged = partial.split('\nstaged')[1].split('\nunstaged')[0];
      final unstaged = partial.split('\nunstaged')[1].split('\nconflicts')[0];
      expect(staged.split('\n@@'), hasLength(2));
      expect(unstaged.split('\n@@'), hasLength(2));
      expect(staged, contains('addition:additional first change:false'));
      expect(staged, isNot(contains('second change')));
      expect(unstaged, contains('addition:additional second change:false'));
      expect(unstaged, isNot(contains('first change')));
      _press(tester, 'Unapprove');
      await _text(tester, 'approval:success');
      expect(await tester.runAsync(() => _reviewStates(repositories)), before);
      _press(tester, 'Unapprove');
      await _text(tester, 'approval:unavailable');
      expect(await tester.runAsync(() => _reviewStates(repositories)), before);
      final duplicate =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(duplicate['failures'], ['stale_selection', 'stale_selection']);
      final allCalls = (await tester.runAsync(
        () => _calls(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      expect(allCalls.map((call) => call['method']), [
        reviewApprovalHandlerServiceApproveHunkId,
        reviewApprovalHandlerServiceApproveHunkId,
        reviewApprovalHandlerServiceUnapproveHunkId,
        reviewApprovalHandlerServiceUnapproveHunkId,
      ]);
      expect(
        allCalls.map((call) => call['hostInvocationContext']).toSet(),
        hasLength(4),
      );
      expect(
        ((allCalls.last['payload'] as Map)['selection']
            as Map)['expectedRevision'],
        isNot(selection['expectedRevision']),
      );
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(_reviewWrites(evidence), hasLength(2));
      for (final write in _reviewWrites(evidence)) {
        expect(write['environmentId'], 'additional');
        expect(write['cwd'], repositories['additional']);
        expect(write['exitCode'], 0);
      }
      expect(evidence['reads'], isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final denial in [
    'frontend declaration',
    'provider permission',
    'absent provider',
  ]) {
    testWidgets(
      'G6a $denial denies approval independently of snapshot access',
      (tester) async {
        final repositories = await reviewRepositories(tester);
        final before = (await tester.runAsync(
          () => _reviewStates(repositories),
        ))!;
        await mount(
          tester,
          additionalRoot: repositories['additional'],
          primaryRoot: repositories['primary'],
          approvalGrant: denial != 'frontend declaration',
          approvalProviderPermission: denial != 'provider permission',
          approvalProviderPresent: denial != 'absent provider',
        );
        _press(tester, 'Select approval');
        await _text(tester, 'approval-selection:unavailable');
        expect(
          await tester.runAsync(
            () => _calls(fixture, serviceId: reviewApprovalHandlerServiceId),
          ),
          isEmpty,
        );
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await _select(tester);
        _press(tester, 'Uncommitted');
        expect(
          await _snapshot(tester),
          contains('addition:additional first change:false'),
        );
        _press(tester, 'Approve');
        await _text(tester, 'approval:idle');
        expect(
          await tester.runAsync(
            () => _calls(fixture, serviceId: reviewApprovalHandlerServiceId),
          ),
          isEmpty,
        );
        expect(
          await tester.runAsync(() => _reviewStates(repositories)),
          before,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'G6a stale EVC selection rejects a working-tree edit without index or unrelated writes',
    (tester) async {
      final repositories = await reviewRepositories(tester);
      await mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
      );
      await _select(tester);
      _press(tester, 'Uncommitted');
      await _snapshot(tester);
      _press(tester, 'Select approval');
      await _text(tester, 'approval-selected');
      final before = (await tester.runAsync(() async {
        await File('${repositories['additional']}/review.txt').writeAsString(
          '${_reviewContent('additional', first: true, second: true)}external edit\n',
        );
        return _reviewStates(repositories);
      }))!;
      _press(tester, 'Approve');
      await _text(tester, 'approval:unavailable');
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['stale_selection']);
      expect(
        _reviewWrites((await tester.runAsync(fixture.snapshot))!),
        isEmpty,
      );
      expect(await tester.runAsync(() => _reviewStates(repositories)), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'G6a malformed approval transport cannot inject selectors or bypass native selection bounds',
    (tester) async {
      final repositories = await reviewRepositories(tester);
      final before = (await tester.runAsync(
        () => _reviewStates(repositories),
      ))!;
      await mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalProviderPresent: true,
        present: false,
      );
      // Trusted test-side injection uses the existing host admission helper.
      // C never receives a raw request channel or authority selectors.
      await tester.runAsync(() async {
        final selected = await CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(reviewApprovalCapability);
        final valid = <String, Object?>{
          'relativePath': 'review.txt',
          'hunkIndex': 0,
          'expectedRevision': 'opaque-test-revision',
        };
        final payloads = <Map<String, Object?>>[
          {},
          {'selection': null},
          {
            'selection': {'relativePath': 'review.txt', 'hunkIndex': 0},
          },
          for (final path in [
            '',
            '/review.txt',
            '../review.txt',
            'a/../review.txt',
            'a\u0000b',
            'x' * 4097,
          ])
            {
              'selection': {...valid, 'relativePath': path},
            },
          for (final index in <Object>[-1, 8192, '0', 0.5])
            {
              'selection': {...valid, 'hunkIndex': index},
            },
          for (final revision in <Object?>[
            null,
            '',
            'bad\nrevision',
            'x' * 257,
          ])
            {
              'selection': {...valid, 'expectedRevision': revision},
            },
          for (final field in [
            'environmentId',
            'sessionId',
            'repository',
            'providerId',
            'rawPatch',
            'hostInvocationContext',
          ]) ...[
            {'selection': valid, field: 'primary'},
            {
              'selection': {...valid, field: 'primary'},
            },
          ],
        ];
        for (final method in [
          reviewApprovalHandlerServiceApproveHunkId,
          reviewApprovalHandlerServiceUnapproveHunkId,
        ]) {
          for (final payload in payloads) {
            await expectLater(
              invokeEnvironmentCapabilityWithBufferedProcess(
                selection: selected,
                backends: fixture.backends,
                serviceId: reviewApprovalHandlerServiceId,
                invoke: (channel) => channel.request(method, payload),
              ),
              throwsA(
                isA<AdeleRemoteFailure>().having(
                  (error) => error.code,
                  'code',
                  'invalid_request',
                ),
              ),
            );
          }
        }
        final calls = await _calls(
          fixture,
          serviceId: reviewApprovalHandlerServiceId,
        );
        expect(calls, hasLength(payloads.length * 2));
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(calls.length),
        );
        for (final call in calls) {
          await _denied(fixture, call['hostInvocationContext'] as String);
        }
        final probe = await fixture.control('snapshot') as Map;
        expect(
          probe['failures'],
          isEmpty,
          reason: 'Malformed DTOs never enter the implementation.',
        );
        expect((await fixture.snapshot())['processes'], isEmpty);
        expect(await _reviewStates(repositories), before);
      });
    },
  );

  for (final side in ['environment', 'callable']) {
    for (final termination in [false, true]) {
      testWidgets(
        'G6a $side ${termination ? 'backend' : 'provider'} retirement after effect suppresses success without replay or rollback',
        (tester) async {
          final repositories = await reviewRepositories(tester);
          final before = (await tester.runAsync(
            () => _reviewStates(repositories),
          ))!;
          await mount(
            tester,
            additionalRoot: repositories['additional'],
            primaryRoot: repositories['primary'],
            approvalGrant: true,
            approvalProviderPresent: true,
          );
          await _select(tester);
          _press(tester, 'Uncommitted');
          await _snapshot(tester);
          _press(tester, 'Select approval');
          await _text(tester, 'approval-selected');
          await tester.runAsync(
            () => fixture.control('hold', {'key': 'after:approve'}),
          );
          _press(tester, 'Approve');
          await tester.runAsync(() => fixture.wait(tester, 'after:approve'));
          final token = (await tester.runAsync(
            () => _token(fixture, serviceId: reviewApprovalHandlerServiceId),
          ))!;
          final stale = _callback(tester, 'Approve');
          final effected = (await tester.runAsync(
            () => _reviewStates(repositories),
          ))!;
          _expectReviewIndex(
            effected,
            before,
            'additional',
            _reviewContent('additional', first: true),
          );
          final evidence = (await tester.runAsync(fixture.snapshot))!;
          expect(_reviewWrites(evidence), hasLength(1));
          expect(_reviewWrites(evidence).single['exitCode'], 0);
          await _text(tester, 'approval:pending');
          final target = side == 'environment'
              ? fixture.environmentConnection
              : fixture.connection;
          final survivor = side == 'environment'
              ? fixture.connection
              : fixture.environmentConnection;
          if (termination) {
            await tester.runAsync(() async {
              await expectLater(
                fixture.controlOn(target, 'terminate'),
                throwsA(isA<PluginRemoteFailure>()),
              );
              await target.terminated.timeout(_bound);
            });
            expect(target.isClosed, isTrue);
            expect(survivor.isClosed, isFalse);
            expect(fixture.backends.host!.isClosed, isFalse);
          } else {
            final binding = fixture.capabilities.resolve(
              side == 'environment'
                  ? environmentProviderCapability
                  : reviewApprovalCapability,
              providerId: ProviderId(
                side == 'environment'
                    ? 'test.environment.a'
                    : _approvalProvider,
              ),
            );
            await tester.runAsync(
              () =>
                  (side == 'environment'
                          ? fixture.environmentOwner
                          : fixture.callableOwner)
                      .retireProvider(binding),
            );
            expect(
              () => binding.requestChannel,
              throwsA(isA<ProviderUnavailable>()),
            );
            fixture.environmentOwner.validate();
            fixture.callableOwner.validate();
          }
          // Retirement revokes authority immediately, but does not cancel B's
          // admitted unary operation. Publication is checked after settlement.
          await tester.runAsync(() async {
            expect(
              await fixture.controlOn(survivor, 'attackBuffered', {
                'token': token,
                'method':
                    authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
                'arguments': <String, Object?>{},
              }),
              {'ok': false},
            );
            if (!termination || side == 'environment') {
              await _denied(fixture, token);
              expect(
                await fixture.control('retainedBufferedIdentity', {
                  'key': 'approval',
                }),
                {'ok': false},
              );
              expect(await _reviewStates(repositories), effected);
              await fixture.control('release', {'key': 'after:approve'});
              await fixture.wait(tester, 'settled:approve');
            }
          });
          await _text(tester, 'approval:unavailable');
          stale();
          await _text(tester, 'approval:unavailable');
          await tester.runAsync(() async {
            if (!termination || side == 'environment') {
              expect(
                await _calls(
                  fixture,
                  serviceId: reviewApprovalHandlerServiceId,
                ),
                hasLength(1),
              );
            }
            if (!termination || side == 'callable') {
              final after =
                  await fixture.controlOn(
                        fixture.environmentConnection,
                        'snapshot',
                      )
                      as Map<Object?, Object?>;
              expect(after['processes'], evidence['processes']);
            }
            expect(await _reviewStates(repositories), effected);
          });
          expect(find.text('approval:success'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'G6a same-ID replacement requires fresh approval access and never replays an effected old request',
    (tester) async {
      final repositories = await reviewRepositories(tester);
      final before = (await tester.runAsync(
        () => _reviewStates(repositories),
      ))!;
      await mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
      );
      await _select(tester);
      _press(tester, 'Uncommitted');
      await _snapshot(tester);
      _press(tester, 'Select approval');
      await _text(tester, 'approval-selected');
      final old = fixture;
      final oldApproval = old.capabilities.resolve(
        reviewApprovalCapability,
        providerId: ProviderId(_approvalProvider),
      );
      final oldEnvironment = old.capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.a'),
      );
      final stale = _callback(tester, 'Approve');
      await tester.runAsync(
        () => old.control('hold', {'key': 'after:approve'}),
      );
      _press(tester, 'Approve');
      await tester.runAsync(() => old.wait(tester, 'after:approve'));
      final token = (await tester.runAsync(
        () => _token(old, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      final effected = (await tester.runAsync(
        () => _reviewStates(repositories),
      ))!;
      _expectReviewIndex(
        effected,
        before,
        'additional',
        _reviewContent('additional', first: true),
      );
      expect(
        _reviewWrites((await tester.runAsync(old.snapshot))!),
        hasLength(1),
      );
      await tester.runAsync(old.backends.close);
      await _text(tester, 'approval:unavailable');
      await mount(
        tester,
        additionalRoot: repositories['additional'],
        primaryRoot: repositories['primary'],
        approvalGrant: true,
        approvalProviderPresent: true,
        registry: old.capabilities,
        present: false,
      );
      expect(fixture.connection, isNot(same(old.connection)));
      expect(
        fixture.environmentConnection,
        isNot(same(old.environmentConnection)),
      );
      expect(
        fixture.capabilities
            .resolve(
              reviewApprovalCapability,
              providerId: ProviderId(_approvalProvider),
            )
            .isSameRegistration(oldApproval),
        isFalse,
      );
      expect(
        fixture.capabilities
            .resolve(
              environmentProviderCapability,
              providerId: ProviderId('test.environment.a'),
            )
            .isSameRegistration(oldEnvironment),
        isFalse,
      );
      stale();
      await _text(tester, 'approval:unavailable');
      await tester.runAsync(() => _denied(fixture, token));
      expect(
        await tester.runAsync(
          () => _calls(fixture, serviceId: reviewApprovalHandlerServiceId),
        ),
        isEmpty,
      );
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      expect(
        await tester.runAsync(() => _reviewStates(repositories)),
        effected,
      );
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await _select(tester);
      _press(tester, 'Uncommitted');
      await _snapshot(tester);
      _press(tester, 'Select approval');
      await _text(tester, 'approval-selected');
      _press(tester, 'Unapprove');
      await _text(tester, 'approval:success');
      expect(await tester.runAsync(() => _reviewStates(repositories)), before);
      final calls = (await tester.runAsync(
        () => _calls(fixture, serviceId: reviewApprovalHandlerServiceId),
      ))!;
      expect(calls, hasLength(1));
      expect(
        calls.single['method'],
        reviewApprovalHandlerServiceUnapproveHunkId,
      );
      expect(calls.single['hostInvocationContext'], isNot(token));
      expect(
        _reviewWrites((await tester.runAsync(fixture.snapshot))!),
        hasLength(1),
      );
      await tester.runAsync(
        () => _denied(fixture, calls.single['hostInvocationContext'] as String),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'persisted Task anchors select exact nonprimary and primary Environments and shared Sessions',
    (tester) async {
      final durable = await openDurable(
        tester,
        initialAnchors: {
          'additional': GitTaskComparisonAnchor(
            baselineCommit: selectedBaseline,
            expectedBranchRef: _selectedBranchRef,
          ),
          'primary': GitTaskComparisonAnchor(
            baselineCommit: primaryBaseline,
            expectedBranchRef: 'refs/heads/main',
          ),
        },
      );
      await mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        present: false,
      );
      expect(fixture.connection.pluginId, gitPluginId);
      expect(fixture.connection, isNot(same(fixture.environmentConnection)));
      final database = durable.lifecycle.databaseForSession(
        fixture.sessionA.id,
      )!;
      expect(
        database
            .queryPluginRows(
              'SELECT owner_id, version FROM adele_schema_versions WHERE owner_id=:owner',
              {':owner': gitPluginId},
            )
            .map((row) => row.values),
        [
          {'owner_id': gitPluginId, 'version': 1},
        ],
      );
      final retained = _anchorRows(durable.lifecycle);
      expect(retained, [
        {
          'environment_id': 'additional',
          'baseline_commit': selectedBaseline,
          'expected_branch_ref': _selectedBranchRef,
        },
        {
          'environment_id': 'primary',
          'baseline_commit': primaryBaseline,
          'expected_branch_ref': 'refs/heads/main',
        },
      ]);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(fixture.widget(concurrent: true));
      await tester.pumpAndSettle();
      for (final pane in ['a', 'b']) {
        await _select(tester, pane: pane);
        _press(tester, 'Task', pane: pane);
        final snapshot = await _snapshot(tester, pane: pane);
        if (pane == 'a') {
          _expectAdditional(snapshot, scope: 'Task');
        } else {
          expect(
            snapshot,
            startsWith('snapshot\ncommitted\nstaged\nunstaged\n'),
          );
          expect(snapshot, contains('primary-only.txt|modified|text'));
          expect(snapshot, contains('deletion:old primary:false'));
          expect(snapshot, contains('addition:new primary:false'));
          expect(snapshot, isNot(contains('committed-only.txt')));
        }
      }
      final selected = (await tester.runAsync(
        () => CapturedEnvironmentCapabilities(
          environmentRuntime: fixture.environmentRuntime,
          backends: fixture.backends,
          session: fixture.sessionA,
        ).resolve(_capability),
      ))!;
      expect(selected.environment.id, EnvironmentId('additional'));
      expect(selected.environment.role, EnvironmentRole.additional);
      expect(selected.binding.provider.id.value, gitChangeSetSourceProviderId);
      expect(fixture.callableOwner.associationFor(selected.binding), isNull);
      fixture.callableOwner.validateProviderOwnership(selected.binding);
      fixture.environmentOwner.validateProviderOwnership(
        selected.materialization.binding,
      );

      final sibling = durable.lifecycle.store.session(
        SessionId('shared-session'),
      )!;
      expect(sibling, isNot(same(fixture.sessionA)));
      expect(
        durable.lifecycle.store
            .requireSessionAuthority(sibling.id)
            .environmentId,
        EnvironmentId('additional'),
      );
      fixture.frontends.unbind(fixture.sessionA);
      fixture.frontends.unbind(fixture.sessionB);
      await tester.pumpWidget(fixture.widget(session: sibling));
      await tester.pumpAndSettle();
      await _select(tester);
      _press(tester, 'Task');
      _expectAdditional(await _snapshot(tester), scope: 'Task');
      expect(_anchorRows(durable.lifecycle), retained);
      final calls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(calls, hasLength(3));
      expect(
        calls.map((call) => call['hostInvocationContext']).toSet(),
        hasLength(3),
      );
      for (final call in calls) {
        expect(call['method'], _method('Task'));
        expect(call['payload'], isEmpty);
        await tester.runAsync(
          () => _denied(fixture, call['hostInvocationContext'] as String),
        );
      }
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      final processes = (evidence['processes'] as List)
          .cast<Map<Object?, Object?>>();
      expect(processes.map((process) => process['environmentId']).toSet(), {
        'additional',
        'primary',
      });
      for (final process in processes) {
        expect(process['cwd'], roots[process['environmentId']]);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'persisted missing anchor never borrows primary and leaves Unstaged and Uncommitted usable',
    (tester) async {
      final durable = await openDurable(
        tester,
        initialAnchors: {
          'primary': GitTaskComparisonAnchor(
            baselineCommit: primaryBaseline,
            expectedBranchRef: 'refs/heads/main',
          ),
        },
      );
      await mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        present: false,
      );
      final retained = _anchorRows(durable.lifecycle);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      for (final label in ['Wrong service', 'Missing provider']) {
        _press(tester, label);
        await _text(tester, 'selection:unavailable');
      }
      expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
      await _select(tester);
      _press(tester, 'Task');
      await _text(tester, 'snapshot:unavailable');
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], ['baseline_unavailable']);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      for (final scope in ['Unstaged', 'Uncommitted']) {
        _press(tester, scope);
        _expectAdditional(await _snapshot(tester), scope: scope);
      }
      expect(_anchorRows(durable.lifecycle), retained);
      final processes =
          ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
              .cast<Map<Object?, Object?>>();
      expect(processes, isNotEmpty);
      expect(
        processes.every((process) => process['environmentId'] == 'additional'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'persisted Task replacement and durable reopen retain old baseline after HEAD changes without reenrollment',
    (tester) async {
      final repository = (await tester.runAsync(() async {
        final name = 'persisted-reopen-${sequence++}';
        await _git(temporary, ['clone', '--no-hardlinks', committedRoot, name]);
        return Directory('${temporary.path}/$name').resolveSymbolicLinks();
      }))!;
      final durable = await openDurable(
        tester,
        additionalRoot: repository,
        initialAnchors: {
          'additional': GitTaskComparisonAnchor(
            baselineCommit: selectedBaseline,
            expectedBranchRef: _selectedBranchRef,
          ),
        },
      );
      await mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        additionalRoot: repository,
        present: false,
      );
      final identity = AuthorizedEnvironmentIdentity(
        sessionId: 'nonprimary-session',
        environmentId: 'additional',
      );
      final anchors = _anchorStore(durable.lifecycle, fixture);
      final retained = _anchorRows(durable.lifecycle);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await _select(tester);
      final old = fixture;
      final oldBinding = old.capabilities.resolve(
        _capability,
        providerId: ProviderId(gitChangeSetSourceProviderId),
      );
      final stale = _callback(tester, 'Task');
      await tester.runAsync(
        () => old.control('hold', {'key': 'process:completed'}),
      );
      _press(tester, 'Task');
      await tester.runAsync(() => old.wait(tester, 'process:completed'));
      final token = (await tester.runAsync(() => _token(old)))!;
      await tester.runAsync(() async {
        await _denied(
          old,
          token,
          service: projectStorageServiceId,
          method: projectStorageServiceQueryForSessionId,
          arguments: {
            'sessionId': identity.sessionId,
            'sql': 'SELECT 1',
            'parameters': <String, Object?>{},
            'accessMode': 'durable',
          },
        );
        expect(
          await old.controlOn(old.environmentConnection, 'attackBuffered', {
            'token': token,
          }),
          {'ok': false},
        );
        await old.backends.close();
        await expectLater(anchors.read(identity), throwsA(isA<Exception>()));
      });
      await _text(tester, 'snapshot:unavailable');
      await mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        additionalRoot: repository,
        present: false,
      );
      expect(fixture.connection, isNot(same(old.connection)));
      expect(
        fixture.capabilities
            .resolve(
              _capability,
              providerId: ProviderId(gitChangeSetSourceProviderId),
            )
            .isSameRegistration(oldBinding),
        isFalse,
      );
      stale();
      await _text(tester, 'snapshot:unavailable');
      await tester.runAsync(() => _denied(fixture, token));
      expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await _select(tester);
      _press(tester, 'Task');
      _expectCommitted(await _snapshot(tester));
      expect(_anchorRows(durable.lifecycle), retained);
      final oldSession = fixture.sessionA;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await fixture.close();
        await old.close();
        await durable.lifecycle.close();
        final root = Directory(repository);
        await File(
          '$repository/after-enrollment.txt',
        ).writeAsString('committed after enrollment\n');
        await _git(root, ['add', '--all']);
        await _git(root, [
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          'commit',
          '-m',
          'after enrollment',
        ]);
        expect(
          await _git(root, ['rev-parse', 'HEAD']),
          isNot(selectedBaseline),
        );
      });
      final reopened = await openDurable(tester, backing: durable.backing);
      expect(_anchorRows(reopened.lifecycle), retained);
      await mount(
        tester,
        registry: reopened.registry,
        lifecycle: reopened.lifecycle,
        additionalRoot: repository,
      );
      expect(fixture.sessionA, isNot(same(oldSession)));
      expect(fixture.sessionA.id, oldSession.id);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await _select(tester);
      _press(tester, 'Uncommitted');
      await _text(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      _press(tester, 'Task');
      final snapshot = await _snapshot(tester);
      _expectCommitted(snapshot);
      expect(snapshot, contains('after-enrollment.txt|added|text'));
      expect(snapshot, contains('addition:committed after enrollment:false'));
      expect(snapshot, endsWith('\nstaged\nunstaged\nconflicts'));
      expect(_anchorRows(reopened.lifecycle), retained);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'persisted temporary volatile Project retains its anchor across AOT replacement without reenrollment',
    (tester) async {
      // Reuse the harness's canonical volatile graph, without opening a Project
      // provider or starting this seed installation's backend/frontend owners.
      final seed = PreparedEnvironmentCapabilityInstallation(
        files: temporary,
        independent: true,
        sourceLocation: Uri.parse('test:/volatile-portable-git'),
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
              providerState: {'root': roots[id]},
            ),
        ],
      );
      addTearDown(seed.close);
      final lifecycle = ProductLifecycleCoordinator.generated(
        store: seed.environmentRuntime.store,
        registry: seed.capabilities,
        extensions: seed.extensions,
      );
      addTearDown(lifecycle.close);
      expect(lifecycle.databaseForSession(seed.sessionA.id), isNull);
      await mount(
        tester,
        registry: seed.capabilities,
        lifecycle: lifecycle,
        present: false,
      );
      final identity = AuthorizedEnvironmentIdentity(
        sessionId: fixture.sessionA.id.value,
        environmentId: 'additional',
      );
      final anchors = _anchorStore(lifecycle, fixture);
      await tester.runAsync(
        () => anchors.enrollForEnvironment(
          environmentId: identity.environmentId,
          anchor: GitTaskComparisonAnchor(
            baselineCommit: selectedBaseline,
            expectedBranchRef: _selectedBranchRef,
          ),
        ),
      );
      final database = lifecycle.databaseForSession(
        fixture.sessionA.id,
        accessMode: ProjectStorageAccessMode.durableOrTemporary,
      )!;
      final backing = File(database.path);
      expect(backing.existsSync(), isTrue);
      expect(database.path, isNot(startsWith(temporary.absolute.path)));
      expect(lifecycle.databaseForSession(fixture.sessionA.id), isNull);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await _select(tester);
      _press(tester, 'Task');
      _expectAdditional(await _snapshot(tester), scope: 'Task');

      final old = fixture;
      final oldBinding = old.capabilities.resolve(
        _capability,
        providerId: ProviderId(gitChangeSetSourceProviderId),
      );
      final token = (await tester.runAsync(() => _token(old)))!;
      final stale = _callback(tester, 'Task');
      await tester.runAsync(() async {
        await old.backends.close();
        await expectLater(anchors.read(identity), throwsA(isA<Exception>()));
      });
      await mount(
        tester,
        registry: seed.capabilities,
        lifecycle: lifecycle,
        present: false,
      );
      expect(fixture.connection, isNot(same(old.connection)));
      expect(
        fixture.capabilities
            .resolve(
              _capability,
              providerId: ProviderId(gitChangeSetSourceProviderId),
            )
            .isSameRegistration(oldBinding),
        isFalse,
      );
      stale();
      await _text(tester, 'snapshot:unavailable');
      await tester.runAsync(() => _denied(fixture, token));
      expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      expect(
        lifecycle.databaseForSession(
          fixture.sessionA.id,
          accessMode: ProjectStorageAccessMode.durableOrTemporary,
        ),
        same(database),
      );
      expect(backing.existsSync(), isTrue);
      final retained = (await tester.runAsync(
        () => _anchorStore(lifecycle, fixture).read(identity),
      ))!;
      expect(retained.baselineCommit, selectedBaseline);
      expect(retained.expectedBranchRef, _selectedBranchRef);
      expect(lifecycle.databaseForSession(fixture.sessionA.id), isNull);
      await tester.pumpWidget(fixture.widget());
      await tester.pumpAndSettle();
      await _select(tester);
      _press(tester, 'Task');
      _expectAdditional(await _snapshot(tester), scope: 'Task');
      final calls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], _method('Task'));
      expect(calls.single['payload'], isEmpty);
      expect(calls.single['hostInvocationContext'], isNot(token));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await fixture.close();
        await old.close();
        await lifecycle.close();
      });
      expect(backing.parent.existsSync(), isFalse);
    },
  );

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    testWidgets(
      'real independent AOT repositories produce typed nonprimary EVC $scope changes',
      (tester) async {
        await mount(tester, concurrent: true);
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        final selected = (await tester.runAsync(
          () => CapturedEnvironmentCapabilities(
            environmentRuntime: fixture.environmentRuntime,
            backends: fixture.backends,
            session: fixture.sessionA,
          ).resolve(_capability),
        ))!;
        expect(selected.environment.id.value, 'additional');
        expect(selected.environment.role, EnvironmentRole.additional);
        expect(
          selected.materialization.binding.provider.id.value,
          'test.environment.a',
        );
        expect(selected.binding.provider.id.value, 'test.callable.a');
        expect(fixture.callableOwner.associationFor(selected.binding), isNull);
        fixture.environmentOwner.validateProviderOwnership(
          selected.materialization.binding,
        );
        fixture.callableOwner.validateProviderOwnership(selected.binding);
        expect(
          () => fixture.environmentOwner.validateProviderOwnership(
            selected.binding,
          ),
          throwsStateError,
        );
        await _select(tester);
        await _select(tester, pane: 'b');
        final elapsed = Stopwatch()..start();
        _press(tester, scope);
        final additional = await _snapshot(tester);
        elapsed.stop();
        _expectAdditional(additional, scope: scope);
        final selectedCalls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(selectedCalls, hasLength(1));
        expect(selectedCalls.single['method'], _method(scope));
        expect(selectedCalls.single['payload'], isEmpty);
        final selectedEvidence = (await tester.runAsync(fixture.snapshot))!;
        final selectedProcesses = (selectedEvidence['processes'] as List)
            .cast<Map<Object?, Object?>>();
        expect(selectedProcesses, isNotEmpty);
        expect(
          selectedProcesses.every(
            (process) => process['environmentId'] == 'additional',
          ),
          isTrue,
        );
        debugPrint(
          'Prepared portable $scope layered fixture: '
          '${selectedProcesses.length} process requests, '
          '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
        );
        _press(tester, scope, pane: 'b');
        if (scope == 'Task') {
          // The single fixed B anchor belongs to the selected repository, not
          // this unrelated primary. No inference, substitution, or clean result.
          await _text(tester, 'snapshot:unavailable', pane: 'b');
          expect(
            _pane('b', find.textContaining('primary-only.txt|')),
            findsNothing,
          );
          final probe =
              (await tester.runAsync(() => fixture.control('snapshot')))!
                  as Map;
          expect(probe['failures'], ['baseline_unavailable']);
        } else {
          final primary = await _snapshot(tester, pane: 'b');
          expect(
            primary,
            contains('primary-only.txt|modified|text\n@@1,1:1,1'),
          );
          expect(primary, contains('deletion:old primary:false'));
          expect(primary, contains('addition:new primary:false'));
          expect(primary, isNot(contains('selected')));
          expect(primary, isNot(contains('partial.txt')));
          expect(primary, isNot(contains('conflicted.txt')));
          if (scope == 'Uncommitted') {
            expect(
              primary,
              startsWith('snapshot\nstaged\nunstaged\nprimary-only.txt|'),
            );
            expect(primary, endsWith('\nconflicts'));
          }
        }
        final evidence = (await tester.runAsync(fixture.snapshot))!;
        expect(evidence['reads'], isEmpty);
        final processes = (evidence['processes'] as List)
            .cast<Map<Object?, Object?>>();
        expect(processes, isNotEmpty);
        final primaryProcesses = processes.skip(selectedProcesses.length);
        expect(primaryProcesses, isNotEmpty);
        expect(
          primaryProcesses.every(
            (process) => process['environmentId'] == 'primary',
          ),
          isTrue,
        );
        for (final process in processes) {
          expect(process['cwd'], roots[process['environmentId']]);
          expect(process['exitCode'], isA<int>());
          expect(
            process['providerId'],
            process['environmentId'] == 'additional'
                ? 'test.environment.a'
                : 'test.environment.b',
          );
        }
        final calls = await tester.runAsync(() => _calls(fixture));
        expect(calls, hasLength(2));
        expect(
          calls!.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(2),
        );
        for (final call in calls) {
          expect(call['method'], _method(scope));
          expect(call['payload'], isEmpty);
          await tester.runAsync(
            () => _denied(fixture, call['hostInvocationContext'] as String),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final count in [100, 160, 500, 900]) {
    testWidgets(
      'clean nonprimary prepared snapshots batch $count files across backends',
      (tester) async {
        final repository = (await tester.runAsync(() async {
          final root = await Directory(
            '${temporary.path}/scaling-$count',
          ).create();
          await _git(root, ['init', '--initial-branch=main']);
          await Directory('${root.path}/tracked').create();
          for (var i = 0; i < count; i++) {
            await File(
              '${root.path}/tracked/file $i.txt',
            ).writeAsString('clean selected $i\n');
          }
          await _git(root, ['add', '--all']);
          await _git(root, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-m',
            'baseline',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
        final baseline = (await tester.runAsync(
          () => _git(Directory(repository), ['rev-parse', 'HEAD']),
        ))!;
        await mount(
          tester,
          additionalRoot: repository,
          baselineCommit: baseline,
          expectedBranchRef: 'refs/heads/main',
        );
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        await _select(tester);
        var previousProcessCount = 0;
        var semanticCallCount = 0;
        var comparisonTaskMilliseconds = 0;
        var comparisonTaskProcesses = 0;
        for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
          final elapsed = Stopwatch()..start();
          _press(tester, scope);
          await _text(tester, switch (scope) {
            'Unstaged' => 'snapshot',
            'Task' => 'snapshot\ncommitted\nstaged\nunstaged\nconflicts',
            _ => 'snapshot\nstaged\nunstaged\nconflicts',
          });
          elapsed.stop();
          final evidence = (await tester.runAsync(fixture.snapshot))!;
          expect(evidence['reads'], isEmpty);
          final processes = (evidence['processes'] as List)
              .cast<Map<Object?, Object?>>();
          final requests = (evidence['requests'] as List)
              .cast<Map<Object?, Object?>>()
              .where(
                (request) =>
                    request['method'] ==
                    environmentProviderServiceRunBufferedProcessId,
              );
          expect(requests, hasLength(processes.length));
          final processCount = processes.length - previousProcessCount;
          if (scope == 'Task') {
            comparisonTaskMilliseconds = elapsed.elapsedMilliseconds;
            comparisonTaskProcesses = processCount;
          }
          final batches = (count + 127) ~/ 128;
          if (scope == 'Unstaged') {
            expect(processCount, 21 + 4 * batches);
          } else if (scope == 'Uncommitted') {
            expect(processCount, 27 + 4 * batches);
          } else {
            // Fixed anchor/tree validation plus the same working-file batches.
            // No subprocess per clean tracked object is permitted.
            expect(processCount, lessThanOrEqualTo(40 + 4 * batches));
          }
          debugPrint(
            'Prepared portable $scope $count clean files: '
            '$processCount process requests, '
            '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
          );
          for (final process in processes) {
            expect(process['environmentId'], 'additional');
            expect(process['providerId'], 'test.environment.a');
            expect(process['cwd'], repository);
            expect(process['exitCode'], 0);
          }
          final calls = (await tester.runAsync(() => _calls(fixture)))!;
          expect(calls, hasLength(++semanticCallCount));
          expect(calls.last['method'], _method(scope));
          expect(calls.last['payload'], isEmpty);
          expect(
            calls.map((call) => call['hostInvocationContext']).toSet(),
            hasLength(semanticCallCount),
          );
          await tester.runAsync(
            () =>
                _denied(fixture, calls.last['hostInvocationContext'] as String),
          );
          previousProcessCount = processes.length;
        }
        if (count >= 500) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(fixture.close);
          final durable = await openDurable(
            tester,
            additionalRoot: repository,
            initialAnchors: {
              'additional': GitTaskComparisonAnchor(
                baselineCommit: baseline,
                expectedBranchRef: 'refs/heads/main',
              ),
            },
          );
          await mount(
            tester,
            registry: durable.registry,
            lifecycle: durable.lifecycle,
            additionalRoot: repository,
            present: false,
          );
          final anchors = _anchorStore(durable.lifecycle, fixture);
          final identity = AuthorizedEnvironmentIdentity(
            sessionId: fixture.sessionA.id.value,
            environmentId: 'additional',
          );
          final lookup = Stopwatch();
          await tester.runAsync(() async {
            lookup.start();
            expect((await anchors.read(identity)).baselineCommit, baseline);
            lookup.stop();
          });
          await tester.pumpWidget(fixture.widget());
          await tester.pumpAndSettle();
          await _select(tester);
          final elapsed = Stopwatch()..start();
          _press(tester, 'Task');
          await _text(
            tester,
            'snapshot\ncommitted\nstaged\nunstaged\nconflicts',
          );
          elapsed.stop();
          final evidence = (await tester.runAsync(fixture.snapshot))!;
          final processes = evidence['processes'] as List;
          expect(processes, hasLength(comparisonTaskProcesses));
          expect(evidence['reads'], isEmpty);
          debugPrint(
            'Prepared persisted Task $count clean files: '
            '${processes.length} process requests (comparison unchanged), '
            '${lookup.elapsedMicroseconds} us native ProjectStorageHost anchor lookup, '
            '${elapsed.elapsedMilliseconds} ms full AOT/EVC snapshot, '
            '${elapsed.elapsedMilliseconds - comparisonTaskMilliseconds} ms '
            'versus comparison-only (diagnostic only; includes transport and scheduling).',
          );
          final calls = (await tester.runAsync(() => _calls(fixture)))!;
          expect(calls, hasLength(1));
          expect(calls.single['method'], _method('Task'));
          expect(calls.single['payload'], isEmpty);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final count in [100, 500, 900]) {
    testWidgets(
      'actual stock Git and Diff use independent Environment AOT for $count clean files and layered changes',
      (tester) async {
        final repository = (await tester.runAsync(() async {
          final root = await Directory(
            '${temporary.path}/stock-$count',
          ).create();
          await _git(root, ['init', '--initial-branch=main']);
          await Directory('${root.path}/tracked').create();
          for (var i = 0; i < count; i++) {
            await File(
              '${root.path}/tracked/file $i.txt',
            ).writeAsString('baseline $i\n');
          }
          await _git(root, ['add', '--all']);
          await _git(root, [
            '-c',
            'user.name=Fixture',
            '-c',
            'user.email=fixture@example.invalid',
            'commit',
            '-m',
            'stock route baseline',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
        final baseline = (await tester.runAsync(
          () => _git(Directory(repository), ['rev-parse', 'HEAD']),
        ))!;
        final durable = await openDurable(
          tester,
          additionalRoot: repository,
          initialAnchors: {
            'additional': GitTaskComparisonAnchor(
              baselineCommit: baseline,
              expectedBranchRef: 'refs/heads/main',
            ),
            'primary': GitTaskComparisonAnchor(
              baselineCommit: primaryBaseline,
              expectedBranchRef: 'refs/heads/main',
            ),
          },
        );
        await mount(
          tester,
          registry: durable.registry,
          lifecycle: durable.lifecycle,
          additionalRoot: repository,
          stock: true,
          present: false,
        );
        final retained = _anchorRows(durable.lifecycle);
        expect(fixture.connection.pluginId, gitPluginId);
        expect(fixture.connection, isNot(same(fixture.environmentConnection)));
        expect(
          fixture.capabilities.providersFor(environmentProviderCapability),
          hasLength(3),
        );
        final binding = fixture.capabilities.resolve(_capability);
        expect(binding.provider.id.value, gitChangeSetSourceProviderId);
        expect(fixture.callableOwner.associationFor(binding), isNull);
        expect(fixture.callableOwner.isEnvironmentBound(binding), isTrue);
        expect(
          fixture.callableOwner.allowsEnvironmentHostService(
            binding,
            AdeleEnvironmentHostService.bufferedProcess,
          ),
          isTrue,
        );
        expect(
          fixture.callableOwner.allowsEnvironmentHostService(
            binding,
            AdeleEnvironmentHostService.read,
          ),
          isFalse,
        );
        var previousCount = 0;
        final batches = (count + 127) ~/ 128;
        for (final (scope, clean, expected) in [
          ('Unstaged changes', 'No unstaged changes', 21 + 4 * batches),
          ('Uncommitted changes', 'No uncommitted changes', 27 + 4 * batches),
          ('Task / Branch', 'No task changes', 36 + 4 * batches),
        ]) {
          final elapsed = Stopwatch()..start();
          if (previousCount == 0) {
            await tester.pumpWidget(fixture.widget());
          } else {
            _press(tester, scope);
          }
          await _stockVisible(tester, clean);
          elapsed.stop();
          final evidence = (await tester.runAsync(
            () => _stockEvidence(fixture),
          ))!;
          final processes = (evidence['processes'] as List)
              .cast<Map<Object?, Object?>>();
          final requests = processes.length - previousCount;
          expect(requests, expected);
          for (final process in processes) {
            expect(process['environmentId'], 'additional');
            expect(process['providerId'], 'test.environment.a');
            expect(process['cwd'], repository);
            expect(process['exitCode'], 0);
          }
          debugPrint(
            'Actual stock $scope $count clean files: $requests process requests, '
            '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
          );
          previousCount = processes.length;
        }
        final selected = (await tester.runAsync(
          () => CapturedEnvironmentCapabilities(
            environmentRuntime: fixture.environmentRuntime,
            backends: fixture.backends,
            session: fixture.sessionA,
          ).resolve(_capability),
        ))!;
        expect(selected.environment.id, EnvironmentId('additional'));
        expect(selected.environment.role, EnvironmentRole.additional);
        expect(
          selected.materialization.binding.provider.id.value,
          'test.environment.a',
        );
        expect(
          fixture.environmentRuntime.currentMaterialization(
            EnvironmentId('primary'),
          ),
          isNull,
        );
        expect(
          fixture.environmentRuntime.store
              .environment(EnvironmentId('additional'))!
              .providerState,
          {'root': repository},
        );

        for (final committed in [false, true]) {
          await tester.runAsync(() async {
            final file = File('$repository/tracked/file 0.txt');
            if (committed) {
              await file.writeAsString('committed layer\n');
              await _git(Directory(repository), ['add', '--all']);
              await _git(Directory(repository), [
                '-c',
                'user.name=Fixture',
                '-c',
                'user.email=fixture@example.invalid',
                'commit',
                '-m',
                'after retained anchor',
              ]);
            }
            await file.writeAsString('staged layer\n');
            await _git(Directory(repository), ['add', '--all']);
            await file.writeAsString('working layer\n');
          });
          int? firstCount;
          for (var refresh = 0; refresh < 2; refresh++) {
            final elapsed = Stopwatch()..start();
            _press(
              tester,
              refresh == 1
                  ? 'Refresh'
                  : committed
                  ? 'Task / Branch'
                  : 'Uncommitted changes',
            );
            await _stockVisible(tester, '+working layer');
            elapsed.stop();
            expect(
              find.text('tracked/file 0.txt  [modified]'),
              findsNWidgets(committed ? 3 : 2),
            );
            expect(find.textContaining('+staged layer'), findsOneWidget);
            expect(find.textContaining('-staged layer'), findsOneWidget);
            expect(find.textContaining('-baseline 0'), findsOneWidget);
            if (committed) {
              expect(find.textContaining('+committed layer'), findsOneWidget);
              expect(find.textContaining('-committed layer'), findsOneWidget);
            }
            final evidence = (await tester.runAsync(
              () => _stockEvidence(fixture),
            ))!;
            final total = (evidence['processes'] as List).length;
            final requests = total - previousCount;
            if (firstCount != null) expect(requests, firstCount);
            firstCount = requests;
            // Fixed rendered-file work, not a subprocess for every clean file.
            expect(requests, (committed ? 66 : 42) + 4 * batches);
            debugPrint(
              'Actual stock ${committed ? 'committed+staged+unstaged' : 'staged+unstaged'} '
              '$count files refresh $refresh: $requests process requests, '
              '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
            );
            previousCount = total;
            expect(_anchorRows(durable.lifecycle), retained);
          }
        }
        if (count == 100) {
          final oldSession = fixture.sessionA;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await fixture.close();
            await durable.lifecycle.close();
          });
          final reopened = await openDurable(tester, backing: durable.backing);
          expect(_anchorRows(reopened.lifecycle), retained);
          await mount(
            tester,
            registry: reopened.registry,
            lifecycle: reopened.lifecycle,
            additionalRoot: repository,
            stock: true,
          );
          expect(fixture.sessionA, isNot(same(oldSession)));
          await _stockVisible(tester, '+working layer');
          _press(tester, 'Task / Branch');
          await _stockVisible(tester, '+committed layer');
          expect(find.textContaining('-baseline 0'), findsOneWidget);
          fixture.frontends.unbind(fixture.sessionA);
          await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
          await _stockVisible(tester, '+new primary');
          _press(tester, 'Task / Branch');
          await _stockVisible(tester, 'No committed changes');
          expect(find.textContaining('tracked/file 0.txt'), findsNothing);
          expect(_anchorRows(reopened.lifecycle), retained);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'actual stock layers retain conflicts and unsupported files without Source authority',
    (tester) async {
      final link = Link('${roots['additional']}/unsupported-link.txt');
      await tester.runAsync(() => link.create('file with spaces.txt'));
      addTearDown(() async {
        if (await link.exists()) await link.delete();
      });
      final durable = await openDurable(
        tester,
        initialAnchors: {
          'additional': GitTaskComparisonAnchor(
            baselineCommit: selectedBaseline,
            expectedBranchRef: _selectedBranchRef,
          ),
        },
      );
      await mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        stock: true,
      );
      await _stockVisible(tester, '+new selected');
      final retained = _anchorRows(durable.lifecycle);
      for (final scope in [
        'Unstaged changes',
        'Uncommitted changes',
        'Task / Branch',
      ]) {
        if (scope != 'Unstaged changes') {
          _press(tester, scope);
          await _stockVisible(tester, '+new staged');
          expect(find.text('Conflicts'), findsOneWidget);
        }
        expect(find.text('conflicted.txt  [conflicted]'), findsOneWidget);
        expect(find.text('conflicted'), findsOneWidget);
        expect(
          find.text('unsupported-link.txt  [unsupported]'),
          findsOneWidget,
        );
        expect(find.text('unsupported'), findsOneWidget);
        expect(
          find.textContaining('Symbolic links and special working files'),
          findsOneWidget,
        );
        expect(find.textContaining('<<<<<<<'), findsNothing);
        expect(find.text('Open in Source'), findsNothing);
        expect(find.text('Source is unavailable.'), findsWidgets);
        if (scope == 'Task / Branch') {
          // An unmerged path keeps its independent committed change, not an
          // invented staged/unstaged text patch from the conflict workfile.
          expect(find.text('conflicted.txt  [modified]'), findsOneWidget);
          expect(find.textContaining('-base conflict'), findsOneWidget);
          expect(
            find.textContaining('+$_selectedBranch conflict'),
            findsOneWidget,
          );
        }
        expect(_anchorRows(durable.lifecycle), retained);
      }
      final evidence = (await tester.runAsync(() => _stockEvidence(fixture)))!;
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'actual stock Task without a selected anchor does not borrow primary or disable other scopes',
    (tester) async {
      final durable = await openDurable(
        tester,
        initialAnchors: {
          'primary': GitTaskComparisonAnchor(
            baselineCommit: primaryBaseline,
            expectedBranchRef: 'refs/heads/main',
          ),
        },
      );
      await mount(
        tester,
        registry: durable.registry,
        lifecycle: durable.lifecycle,
        stock: true,
      );
      await _stockVisible(tester, '+new selected');
      final retained = _anchorRows(durable.lifecycle);
      final before =
          ((await tester.runAsync(() => _stockEvidence(fixture)))!['processes']
                  as List)
              .length;
      _press(tester, 'Task / Branch');
      await _stockVisible(tester, 'Unable to load');
      expect(find.textContaining('No task changes'), findsNothing);
      expect(
        ((await tester.runAsync(() => _stockEvidence(fixture)))!['processes']
            as List),
        hasLength(before),
      );
      _press(tester, 'Uncommitted changes');
      await _stockVisible(tester, '+new staged');
      expect(find.textContaining('+new selected'), findsOneWidget);
      expect(_anchorRows(durable.lifecycle), retained);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final denial in [
    'frontend declaration',
    'provider permission',
    'absent provider',
  ]) {
    testWidgets('$denial prevents portable Git admission without fallback', (
      tester,
    ) async {
      await mount(
        tester,
        processGrant: denial != 'frontend declaration',
        providerPermission: denial != 'provider permission',
        providerPresent: denial != 'absent provider',
      );
      _press(tester, 'Select');
      await _text(tester, 'selection:unavailable');
      expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
      expect((await tester.runAsync(fixture.snapshot))!['processes'], isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    testWidgets(
      '$scope wrong service and explicit missing provider do not select the available provider',
      (tester) async {
        await mount(tester);
        for (final label in ['Wrong service', 'Missing provider']) {
          _press(tester, label);
          await _text(tester, 'selection:unavailable');
        }
        expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await _select(tester);
        _press(tester, scope);
        _expectAdditional(await _snapshot(tester), scope: scope);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final noFacet in [true, false]) {
      testWidgets(
        '$scope ${noFacet ? 'absent process facet' : 'explicit unavailable Environment'} never falls back to primary',
        (tester) async {
          await mount(
            tester,
            noBufferedFacet: noFacet,
            unavailable: !noFacet,
            concurrent: true,
          );
          await _select(tester);
          _press(tester, scope);
          await _text(tester, 'snapshot:unavailable');
          expect(
            (await tester.runAsync(fixture.snapshot))!['processes'],
            isEmpty,
          );
          await _select(tester, pane: 'b');
          _press(tester, scope, pane: 'b');
          if (scope == 'Task') {
            await _text(tester, 'snapshot:unavailable', pane: 'b');
          } else {
            expect(
              await _snapshot(tester, pane: 'b'),
              contains('primary-only.txt|modified|text'),
            );
          }
          final processes =
              ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                  .cast<Map<Object?, Object?>>();
          expect(processes, isNotEmpty);
          expect(
            processes.every((process) => process['environmentId'] == 'primary'),
            isTrue,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'Task retains committed-only nonprimary changes after Uncommitted is clean',
    (tester) async {
      await mount(tester, additionalRoot: committedRoot);
      await _select(tester);
      _press(tester, 'Uncommitted');
      await _text(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      var previousProcessCount =
          ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
              .length;
      for (var refresh = 0; refresh < 2; refresh++) {
        final elapsed = Stopwatch()..start();
        _press(tester, 'Task');
        final snapshot = await _snapshot(tester);
        elapsed.stop();
        final processCount =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .length;
        debugPrint(
          'Prepared portable Task committed-only: '
          '${processCount - previousProcessCount} process requests, '
          '${elapsed.elapsedMilliseconds} ms (diagnostic only).',
        );
        previousProcessCount = processCount;
        _expectCommitted(snapshot);
        expect(snapshot, endsWith('\nstaged\nunstaged\nconflicts'));
        expect(snapshot, isNot(contains('primary-only.txt')));
        final calls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(calls, hasLength(2 + refresh));
        expect(calls.first['method'], _method('Uncommitted'));
        for (final call in calls.skip(1)) {
          expect(call['method'], _method('Task'));
          expect(call['payload'], isEmpty);
        }
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(calls.length),
        );
        await tester.runAsync(
          () => _denied(fixture, calls.last['hostInvocationContext'] as String),
        );
      }
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], committedRoot);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (invalid, code) in [
    ('missing anchor', 'baseline_unavailable'),
    ('empty baseline', 'invalid_baseline'),
    ('invalid baseline', 'invalid_baseline'),
    ('unavailable baseline', 'baseline_unavailable'),
    ('invalid branch', 'invalid_branch'),
    ('wrong branch', 'unexpected_branch'),
    ('detached HEAD', 'detached_head'),
  ]) {
    testWidgets('Task $invalid fails without inferring or replacing its anchor', (
      tester,
    ) async {
      var repository = committedRoot;
      if (invalid == 'wrong branch' || invalid == 'detached HEAD') {
        repository = (await tester.runAsync(() async {
          final name = 'invalid-anchor-${sequence++}';
          await _git(temporary, [
            'clone',
            '--no-hardlinks',
            committedRoot,
            name,
          ]);
          final root = Directory('${temporary.path}/$name');
          await _git(root, [
            'checkout',
            if (invalid == 'wrong branch') ...[
              '-b',
              'unexpected-task',
            ] else
              '--detach',
          ]);
          return root.resolveSymbolicLinks();
        }))!;
      }
      await mount(
        tester,
        additionalRoot: repository,
        withTaskAnchor: invalid != 'missing anchor',
        baselineCommit: switch (invalid) {
          'empty baseline' => '',
          'invalid baseline' => 'HEAD',
          // A real but unrelated primary commit must not cause primary fallback.
          'unavailable baseline' => primaryBaseline,
          _ => selectedBaseline,
        },
        expectedBranchRef: invalid == 'invalid branch'
            ? 'HEAD'
            : _selectedBranchRef,
      );
      await _select(tester);
      _press(tester, 'Task');
      await _text(tester, 'snapshot:unavailable');
      final calls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], _method('Task'));
      expect(calls.single['payload'], isEmpty);
      final probe =
          (await tester.runAsync(() => fixture.control('snapshot')))! as Map;
      expect(probe['failures'], [code]);
      await tester.runAsync(
        () => _denied(fixture, calls.single['hostInvocationContext'] as String),
      );
      final failedEvidence = (await tester.runAsync(fixture.snapshot))!;
      if (invalid == 'missing anchor') {
        expect(failedEvidence['processes'], isEmpty);
      }
      // Optional Task metadata must not disable either existing scope, including
      // on the detached checkout. These calls still inspect the selected root.
      _press(tester, 'Unstaged');
      await _text(tester, 'snapshot');
      _press(tester, 'Uncommitted');
      await _text(tester, 'snapshot\nstaged\nunstaged\nconflicts');
      final allCalls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(allCalls.map((call) => call['method']), [
        _method('Task'),
        _method('Unstaged'),
        _method('Uncommitted'),
      ]);
      expect(
        allCalls.every((call) => (call['payload'] as Map).isEmpty),
        isTrue,
      );
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      for (final process
          in (evidence['processes'] as List).cast<Map<Object?, Object?>>()) {
        expect(process['environmentId'], 'additional');
        expect(process['providerId'], 'test.environment.a');
        expect(process['cwd'], repository);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'pending Task grants no extra services or foreign activation authority',
    (tester) async {
      await mount(tester);
      await _select(tester);
      await tester.runAsync(
        () => fixture.control('hold', {'key': 'process:completed'}),
      );
      _press(tester, 'Task');
      await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
      final token = (await tester.runAsync(() => _token(fixture)))!;
      await tester.runAsync(() async {
        expect(
          await fixture.controlOn(
            fixture.environmentConnection,
            'attackBuffered',
            {'token': token},
          ),
          {'ok': false},
        );
        for (final (service, method, arguments) in [
          (
            authorizedEnvironmentReadServiceId,
            authorizedEnvironmentReadServiceReadFileId,
            <String, Object?>{'relativePath': 'committed-only.txt'},
          ),
          (
            authorizedEnvironmentMutationServiceId,
            'authorizedEnvironmentMutation.writeFile',
            <String, Object?>{},
          ),
          (
            authorizedEnvironmentProcessServiceId,
            'authorizedEnvironmentProcess.run',
            <String, Object?>{},
          ),
          ('projectStorage', 'projectStorage.query', <String, Object?>{}),
          ('unlisted', 'unlisted.call', <String, Object?>{}),
        ]) {
          await _denied(
            fixture,
            token,
            service: service,
            method: method,
            arguments: arguments,
          );
        }
        await fixture.control('release', {'key': 'process:completed'});
      });
      _expectAdditional(await _snapshot(tester), scope: 'Task');
      final calls = (await tester.runAsync(() => _calls(fixture)))!;
      expect(calls, hasLength(1));
      expect(calls.single['method'], _method('Task'));
      expect(calls.single['payload'], isEmpty);
      await tester.runAsync(() => _denied(fixture, token));
      final evidence = (await tester.runAsync(fixture.snapshot))!;
      expect(evidence['reads'], isEmpty);
      expect(
        (evidence['processes'] as List).cast<Map<Object?, Object?>>().every(
          (process) => process['environmentId'] == 'additional',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    for (final side in ['environment', 'callable']) {
      testWidgets(
        '$scope exact $side retirement fences outstanding real process result',
        (tester) async {
          await mount(tester, concurrent: true);
          await _select(tester);
          await _select(tester, pane: 'b');
          final environment = fixture.capabilities.resolve(
            environmentProviderCapability,
            providerId: ProviderId('test.environment.a'),
          );
          final callable = fixture.capabilities.resolve(
            _capability,
            providerId: ProviderId('test.callable.a'),
          );
          final target = side == 'environment' ? environment : callable;
          final owner = side == 'environment'
              ? fixture.environmentOwner
              : fixture.callableOwner;
          await tester.runAsync(
            () => fixture.control('hold', {'key': 'process:completed'}),
          );
          _press(tester, scope);
          await tester.runAsync(
            () => fixture.wait(tester, 'process:completed'),
          );
          final token = (await tester.runAsync(() => _token(fixture)))!;
          final stale = _callback(tester, scope);
          await tester.runAsync(() => owner.retireProvider(target));
          await _text(tester, 'snapshot:unavailable');
          expect(
            () => target.requestChannel,
            throwsA(isA<ProviderUnavailable>()),
          );
          fixture.environmentOwner.validate();
          fixture.callableOwner.validate();
          expect(fixture.connection.isClosed, isFalse);
          expect(fixture.environmentConnection.isClosed, isFalse);
          await tester.runAsync(() => _denied(fixture, token));
          stale();
          _press(tester, 'Select');
          await _text(tester, 'selection:unavailable');
          await tester.runAsync(() async {
            await fixture.control('release', {'key': 'process:completed'});
            await fixture.wait(tester, 'settled:${scope.toLowerCase()}');
          });
          _press(tester, scope, pane: 'b');
          if (side == 'environment' && scope != 'Task') {
            expect(
              await _snapshot(tester, pane: 'b'),
              contains('primary-only.txt|modified|text'),
            );
          } else {
            await _text(tester, 'snapshot:unavailable', pane: 'b');
          }
          expect(
            _pane('a', find.textContaining('file with spaces.txt|')),
            findsNothing,
          );
          final processes =
              ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                  .cast<Map<Object?, Object?>>();
          expect(
            processes.where(
              (process) => process['environmentId'] == 'additional',
            ),
            hasLength(1),
          );
          final calls = (await tester.runAsync(() => _calls(fixture)))!;
          expect(calls, hasLength(side == 'environment' ? 2 : 1));
          expect(
            calls.every((call) => call['method'] == _method(scope)),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '$scope departure suppresses outstanding snapshot without moving its authority',
      (tester) async {
        await mount(tester);
        await _select(tester);
        await tester.runAsync(
          () => fixture.control('hold', {'key': 'process:completed'}),
        );
        _press(tester, scope);
        await tester.runAsync(() => fixture.wait(tester, 'process:completed'));
        final token = (await tester.runAsync(() => _token(fixture)))!;
        final stale = _callback(tester, scope);
        fixture.frontends.unbind(fixture.sessionA);
        await tester.pumpWidget(fixture.widget(session: fixture.sessionB));
        await tester.pumpAndSettle();
        stale();
        await tester.runAsync(() async {
          await _denied(fixture, token);
          await fixture.control('release', {'key': 'process:completed'});
          await fixture.wait(tester, 'settled:${scope.toLowerCase()}');
        });
        expect(await tester.runAsync(() => _calls(fixture)), hasLength(1));
        expect(find.textContaining('file with spaces.txt|'), findsNothing);
        await _select(tester);
        _press(tester, scope);
        if (scope == 'Task') {
          await _text(tester, 'snapshot:unavailable');
        } else {
          expect(
            await _snapshot(tester),
            contains('primary-only.txt|modified|text'),
          );
        }
        final processes =
            ((await tester.runAsync(fixture.snapshot))!['processes'] as List)
                .cast<Map<Object?, Object?>>();
        expect(
          processes.where(
            (process) => process['environmentId'] == 'additional',
          ),
          hasLength(1),
        );
        expect(
          processes
              .skip(1)
              .every((process) => process['environmentId'] == 'primary'),
          isTrue,
        );
        final calls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(calls, hasLength(2));
        expect(
          calls.map((call) => call['hostInvocationContext']).toSet(),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$scope same-ID replacement never revives a retained generated client or token',
      (tester) async {
        await mount(tester);
        await _select(tester);
        final old = fixture;
        final oldBinding = old.capabilities.resolve(
          _capability,
          providerId: ProviderId('test.callable.a'),
        );
        final oldEnvironment = old.capabilities.resolve(
          environmentProviderCapability,
          providerId: ProviderId('test.environment.a'),
        );
        final stale = _callback(tester, scope);
        await tester.runAsync(
          () => old.control('hold', {'key': 'process:completed'}),
        );
        _press(tester, scope);
        await tester.runAsync(() => old.wait(tester, 'process:completed'));
        final token = (await tester.runAsync(() => _token(old)))!;
        await tester.runAsync(old.backends.close);
        await _text(tester, 'snapshot:unavailable');
        await mount(tester, present: false, registry: old.capabilities);
        expect(fixture.connection, isNot(same(old.connection)));
        expect(
          fixture.capabilities
              .resolve(_capability, providerId: ProviderId('test.callable.a'))
              .isSameRegistration(oldBinding),
          isFalse,
        );
        expect(
          fixture.capabilities
              .resolve(
                environmentProviderCapability,
                providerId: ProviderId('test.environment.a'),
              )
              .isSameRegistration(oldEnvironment),
          isFalse,
        );
        stale();
        await _text(tester, 'snapshot:unavailable');
        await tester.runAsync(() => _denied(fixture, token));
        expect(await tester.runAsync(() => _calls(fixture)), isEmpty);
        expect(
          (await tester.runAsync(fixture.snapshot))!['processes'],
          isEmpty,
        );
        await tester.pumpWidget(fixture.widget());
        await tester.pumpAndSettle();
        await _select(tester);
        _press(tester, scope);
        _expectAdditional(await _snapshot(tester), scope: scope);
        final calls = (await tester.runAsync(() => _calls(fixture)))!;
        expect(calls, hasLength(1));
        expect(calls.single['method'], _method(scope));
        expect(calls.single['payload'], isEmpty);
        await tester.runAsync(
          () =>
              _denied(fixture, calls.single['hostInvocationContext'] as String),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
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

GitTaskAnchorStore _anchorStore(
  ProductLifecycleCoordinator lifecycle,
  PreparedEnvironmentCapabilityInstallation fixture,
) {
  final connection = fixture.connection;
  expect(connection.pluginId, gitPluginId);
  return GitTaskAnchorStore(
    ProjectStorageHost(
      lifecycle: lifecycle,
      owner: PluginId(connection.pluginId),
      validateAccess: connection.validateInfrastructureContext,
    ),
  );
}

List<Map<String, Object?>> _anchorRows(ProductLifecycleCoordinator lifecycle) =>
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

Future<void> _compileFrontend(String sdk, File artifact) async {
  final root = Directory.current.parent.path;
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
                'test/fixtures/portable_git_frontend.dart.txt',
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

Future<void> _compileStockFrontend(String sdk, String output) => Isolate.run(
  // The pinned compiler retains TypeRefs by library ID across Compiler instances.
  // Keep the independently prepared probe and stock EVC type universes separate.
  () => compileDiffViewerFrontend(
    repositoryRoot: Directory.current.parent,
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

Future<String> _git(
  Directory root,
  List<String> arguments, {
  int exitCode = 0,
}) async {
  final result = await Process.run(
    '/usr/bin/git',
    arguments,
    workingDirectory: root.path,
  );
  expect(
    result.exitCode,
    exitCode,
    reason: '${result.stdout}\n${result.stderr}',
  );
  return (result.stdout as String).trim();
}

String _reviewContent(String id, {bool first = false, bool second = false}) =>
    '${List.generate(30, (index) {
      if (index == 3 && first) return '$id first change';
      if (index == 24 && second) return '$id second change';
      return '$id line $index';
    }).join('\n')}\n';

String _reviewBlobOid(String content) {
  final bytes = utf8.encode(content);
  return sha1.convert([
    ...utf8.encode('blob ${bytes.length}\u0000'),
    ...bytes,
  ]).toString();
}

Future<Map<String, Map<String, Object>>> _reviewStates(
  Map<String, String> roots,
) async {
  final result = <String, Map<String, Object>>{};
  for (final entry in roots.entries) {
    final root = Directory(entry.value);
    final hashes = <String, String>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final path = entity.path.substring(root.path.length + 1);
      if (path == '.git' || path.startsWith('.git/')) continue;
      expect(entity, isA<File>(), reason: 'Unexpected worktree entry: $path');
      hashes[path] = sha256
          .convert(await File(entity.path).readAsBytes())
          .toString();
    }
    result[entry.key] = {
      'head': await _git(root, ['rev-parse', 'HEAD']),
      'branch': await _git(root, ['symbolic-ref', 'HEAD']),
      'index': await _git(root, ['ls-files', '--stage', '-z']),
      'workingHashes': hashes,
    };
  }
  return result;
}

void _expectReviewIndex(
  Map<String, Map<String, Object>> actual,
  Map<String, Map<String, Object>> before,
  String environment,
  String expectedContent,
) {
  final oldOid = _reviewBlobOid(_reviewContent(environment));
  final newOid = _reviewBlobOid(expectedContent);
  expect(newOid, isNot(oldOid));
  expect(
    before[environment]!['index'],
    contains('$oldOid 0\treview.txt\u0000'),
  );
  expect(actual, {
    ...before,
    environment: {
      ...before[environment]!,
      'index': (before[environment]!['index']! as String).replaceFirst(
        '$oldOid 0\treview.txt\u0000',
        '$newOid 0\treview.txt\u0000',
      ),
    },
  });
}

List<Map<Object?, Object?>> _reviewWrites(Map<Object?, Object?> evidence) =>
    (evidence['processes'] as List).cast<Map<Object?, Object?>>().where((
      process,
    ) {
      final arguments = process['arguments'] as List;
      return arguments.contains('apply') &&
          arguments.contains('--cached') &&
          !arguments.contains('--check');
    }).toList();

String _method(String scope) =>
    '$_service.snapshot${scope == 'Task' ? 'TaskChanges' : scope}';

Future<List<Map<Object?, Object?>>> _calls(
  PreparedEnvironmentCapabilityInstallation fixture, {
  String serviceId = _service,
}) async {
  final snapshot = (await fixture.control('snapshot'))! as Map;
  return (snapshot['requests'] as List)
      .cast<Map<Object?, Object?>>()
      .where((call) => call['serviceId'] == serviceId)
      .toList();
}

Future<Map<Object?, Object?>> _stockEvidence(
  PreparedEnvironmentCapabilityInstallation fixture,
) async {
  // Stock Git exposes no probe. Observe only the independent process owner.
  final evidence =
      (await fixture.controlOn(fixture.environmentConnection, 'snapshot'))!
          as Map<Object?, Object?>;
  expect(evidence['reads'], isEmpty);
  final requests = (evidence['requests'] as List)
      .cast<Map<Object?, Object?>>()
      .where(
        (request) =>
            request['method'] == environmentProviderServiceRunBufferedProcessId,
      );
  expect(requests, hasLength((evidence['processes'] as List).length));
  return evidence;
}

Future<void> _stockVisible(WidgetTester tester, String text) =>
    _waitFor(tester, _pane('a', find.textContaining(text)));

Future<String> _token(
  PreparedEnvironmentCapabilityInstallation fixture, {
  String serviceId = _service,
}) async =>
    (await _calls(fixture, serviceId: serviceId)).last['hostInvocationContext']
        as String;

Future<void> _denied(
  PreparedEnvironmentCapabilityInstallation fixture,
  String token, {
  String? service,
  String? method,
  Map<String, Object?>? arguments,
}) async {
  expect(
    await fixture.control('attackBuffered', {
      'token': token,
      'service': ?service,
      // Identity must fail at host authority, not A's executable allowlist.
      'method':
          method ??
          authorizedEnvironmentBufferedProcessServiceCapturedIdentityId,
      'arguments': arguments ?? <String, Object?>{},
    }),
    {'ok': false},
  );
}

Finder _pane(String pane, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(pane)), matching: matching);

VoidCallback _callback(
  WidgetTester tester,
  String label, {
  String pane = 'a',
}) => tester
    .widget<TextButton>(_pane(pane, find.widgetWithText(TextButton, label)))
    .onPressed!;

void _press(WidgetTester tester, String label, {String pane = 'a'}) =>
    _callback(tester, label, pane: pane)();

Future<void> _text(
  WidgetTester tester,
  String text, {
  String pane = 'a',
}) async => _waitFor(tester, _pane(pane, find.text(text)));

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  await tester.pump();
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(_bound);
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>(() {});
      await tester.pump();
    }
  });
  expect(
    finder,
    findsOneWidget,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .join(' | '),
  );
}

Future<void> _select(WidgetTester tester, {String pane = 'a'}) async {
  _press(tester, 'Select', pane: pane);
  await _text(tester, 'selected', pane: pane);
}

Future<String> _snapshot(WidgetTester tester, {String pane = 'a'}) async {
  final finder = _pane(
    pane,
    find.byWidgetPredicate(
      (widget) =>
          widget is Text && (widget.data?.startsWith('snapshot\n') ?? false),
    ),
  );
  await _waitFor(tester, finder);
  return tester.widget<Text>(finder).data!;
}

void _expectAdditional(String snapshot, {String scope = 'Unstaged'}) {
  final unstaged = scope == 'Unstaged'
      ? snapshot
      : snapshot.split('\nunstaged\n')[1].split('\nconflicts\n')[0];
  expect(unstaged, contains('file with spaces.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:old selected:false'));
  expect(unstaged, contains('addition:new selected:false'));
  expect(unstaged, contains('deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(unstaged, contains('deletion:deleted selected:false'));
  expect(unstaged, contains('line\nname.txt|added|text\n@@0,0:1,1'));
  expect(unstaged, contains('addition:added selected:false'));
  expect(snapshot, isNot(contains('primary')));
  if (scope == 'Unstaged') {
    expect(snapshot, isNot(contains('staged-only.txt')));
    return;
  }
  final staged = snapshot.split('\nstaged\n')[1].split('\nunstaged\n')[0];
  final conflicts = snapshot.split('\nconflicts\n')[1];
  expect(staged, contains('staged-only.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:old staged:false'));
  expect(staged, contains('addition:new staged:false'));
  expect(staged, contains('added\nstaged.txt|added|text\n@@0,0:1,1'));
  expect(staged, contains('addition:added staged:false'));
  expect(staged, contains('staged deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(staged, contains('deletion:deleted staged:false'));
  expect(staged, contains('partial.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:head partial:false'));
  expect(staged, contains('addition:index partial:false'));
  expect(unstaged, contains('partial.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:index partial:false'));
  expect(unstaged, contains('addition:work partial:false'));
  expect(staged, contains('cancel.txt|modified|text\n@@1,1:1,1'));
  expect(staged, contains('deletion:head cancellation:false'));
  expect(staged, contains('addition:index cancellation:false'));
  expect(unstaged, contains('cancel.txt|modified|text\n@@1,1:1,1'));
  expect(unstaged, contains('deletion:index cancellation:false'));
  expect(unstaged, contains('addition:head cancellation:false'));
  expect(staged, isNot(contains('file with spaces.txt')));
  expect(unstaged, isNot(contains('staged-only.txt')));
  expect(unstaged, isNot(contains('staged deleted.txt')));
  expect(unstaged, isNot(contains('added\nstaged.txt')));
  expect(staged, isNot(contains('conflicted.txt')));
  expect(unstaged, isNot(contains('conflicted.txt')));
  expect(conflicts, 'conflicted.txt|conflicted|conflicted');
  if (scope == 'Task') {
    _expectCommitted(snapshot);
    expect(staged, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
    expect(staged, contains('deletion:head layer:false'));
    expect(staged, contains('addition:index layer:false'));
    expect(unstaged, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
    expect(unstaged, contains('deletion:index layer:false'));
    expect(unstaged, contains('addition:baseline layer:false'));
  }
}

void _expectCommitted(String snapshot) {
  expect(snapshot, startsWith('snapshot\ncommitted\n'));
  final committed = snapshot.split('\ncommitted\n')[1].split('\nstaged')[0];
  expect(committed, contains('committed-only.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:baseline committed:false'));
  expect(committed, contains('addition:head committed:false'));
  expect(committed, contains('committed added.txt|added|text\n@@0,0:1,1'));
  expect(committed, contains('addition:head added:false'));
  expect(committed, contains('committed deleted.txt|deleted|text\n@@1,1:0,0'));
  expect(committed, contains('deletion:baseline deleted:false'));
  expect(committed, contains('three-layer.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:baseline layer:false'));
  expect(committed, contains('addition:head layer:false'));
  // A currently unmerged path retains its independent committed change too.
  expect(committed, contains('conflicted.txt|modified|text\n@@1,1:1,1'));
  expect(committed, contains('deletion:base conflict:false'));
  expect(committed, contains('addition:$_selectedBranch conflict:false'));
  expect(committed, isNot(contains('index layer')));
  expect(committed, isNot(contains('staged-only.txt')));
  expect(committed, isNot(contains('file with spaces.txt')));
}
