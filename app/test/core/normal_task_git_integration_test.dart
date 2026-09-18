@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const String _gitPluginId = 'dev.adele.plugin.git-environment';
final ProviderId _gitProviderId = ProviderId(
  'dev.adele.environment.git-worktree',
);
const String _openaiPluginId = 'dev.adele.openai';
final ProviderId _chatGptProviderId = ProviderId(
  'dev.adele.openai.chatgpt-experimental',
);

void main() {
  late Directory artifacts;
  late String dartaotruntime;
  late File hostArtifact;
  late File gitArtifact;
  late File openaiArtifact;

  setUpAll(() async {
    final Directory repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp('adele-normal-backends-');
    addTearDown(() => artifacts.delete(recursive: true));
    final String dart = _dartExecutable();
    dartaotruntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    hostArtifact = File.fromUri(artifacts.uri.resolve('host.aot'));
    gitArtifact = File.fromUri(artifacts.uri.resolve('git-environment.aot'));
    openaiArtifact = File.fromUri(artifacts.uri.resolve('openai.aot'));
    // Compile real artifacts once; startup only consumes their installed copies.
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
        stage: 'normal-bootstrap-host',
      ),
      (
        entrypoint:
            'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
        artifact: gitArtifact,
        stage: 'normal-bootstrap-git',
      ),
      (
        entrypoint:
            'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        artifact: openaiArtifact,
        stage: 'normal-bootstrap-openai',
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: target.stage,
      );
    }
  });

  late Directory container;
  late Directory installationRoot;
  late AdeleRuntime runtime;
  late File credentialFile;
  late Map<String, List<String>> startupArguments;
  late HttpServer server;
  late int requests;

  setUp(() async {
    container = await Directory.systemTemp.createTemp('adele-normal-startup-');
    addTearDown(() => container.delete(recursive: true));
    installationRoot = await Directory(
      '${container.path}/installations',
    ).create();
    credentialFile = File('${container.path}/never-created-credentials.json');
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
      expect(
        requests,
        0,
        reason: 'Bootstrap must not make OAuth or model calls.',
      );
      expect(await credentialFile.exists(), isFalse);
    });
    final String endpoint = 'http://${server.address.address}:${server.port}';
    startupArguments = {
      _openaiPluginId: [
        '--chatgpt-only',
        jsonEncode({
          'credentialFile': credentialFile.path,
          'clientId': 'adele-test-client',
          'issuer': endpoint,
          'endpoint': '$endpoint/responses',
        }),
      ],
    };
    runtime = AdeleRuntime(ids: MonotonicProductIdSource(seed: 'normal'));
    addTearDown(runtime.close);
  });

  Future<void> installBackends() async {
    await _install(installationRoot, '10-git', _gitPluginId, gitArtifact);
    await _install(
      installationRoot,
      '30-openai',
      _openaiPluginId,
      openaiArtifact,
    );
  }

  Future<void> start({bool argumentsFromFile = true}) async {
    String argumentsFile = '';
    if (argumentsFromFile) {
      argumentsFile = '${container.path}/startup-arguments.json';
      await File(argumentsFile).writeAsString(jsonEncode(startupArguments));
    }
    await runtime.plugins.start(
      installationRoot: installationRoot.path,
      dartaotruntimeExecutable: dartaotruntime,
      hostArtifactPath: hostArtifact.path,
      startupArgumentsFile: argumentsFile,
      startupArguments: argumentsFromFile ? null : startupArguments,
    );
  }

  InstalledBackendActivation backend(String id) => runtime.plugins.backends
      .singleWhere((entry) => entry.installation.metadata.id.value == id);

  void expectBothActive() {
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.failure, isNull);
    expect(runtime.plugins.registry, same(runtime.registry));
    expect(runtime.plugins.host!.isClosed, isFalse);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    for (final id in [_gitPluginId, _openaiPluginId]) {
      final InstalledBackendActivation entry = backend(id);
      expect(entry.state, InstalledBackendState.active);
      expect(entry.failure, isNull);
      expect(entry.connection!.isClosed, isFalse);
      expect(entry.connection!.pluginId, id);
      expect(
        runtime.plugins.catalog!.installations,
        contains(same(entry.installation)),
      );
      expect(
        entry.installation.backendArtifactUri!.path,
        startsWith(installationRoot.uri.path),
      );
    }
    final ProviderDescriptor git = runtime.registry
        .providersFor(environmentProviderCapability)
        .single;
    expect(git.id, _gitProviderId);
    expect(git.pluginId, _gitPluginId);
    final ProviderDescriptor openai = runtime.registry
        .providersFor(modelProviderCapability)
        .single;
    expect(openai.id, _chatGptProviderId);
    expect(openai.pluginId, _openaiPluginId);
    expect(requests, 0);
    expect(credentialFile.existsSync(), isFalse);
  }

  for (final bool dirty in [false, true]) {
    test(
      'discovered backends establish a Task and preserve ${dirty ? 'dirty' : 'clean'} nested source',
      () async {
        final Directory repository = Directory('${container.path}/repo');
        final Directory source = Directory(
          '${repository.path}/packages/source',
        );
        await Directory('${source.path}/lib').create(recursive: true);
        final File sourceFile = File('${source.path}/lib/example.dart');
        const String baselineText = 'const answer = 42;\n';
        await sourceFile.writeAsString(baselineText);
        await File(
          '${repository.path}/outside.txt',
        ).writeAsString('Outside Project scope.\n');
        await _git(repository, ['init', '--initial-branch=main']);
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Fixture baseline']);
        final String baseline = (await _git(repository, [
          'rev-parse',
          'HEAD',
        ])).trim();
        if (dirty) {
          await sourceFile.writeAsString('const answer = 43;\n');
          await _git(repository, ['add', 'packages/source/lib/example.dart']);
          await sourceFile.writeAsString('const answer = 44;\n');
          await File(
            '${source.path}/scratch.txt',
          ).writeAsString('Untracked source.\n');
        }
        final String sourceText = await sourceFile.readAsString();
        final String status = await _git(repository, [
          'status',
          '--porcelain=v1',
          '-z',
        ]);
        final String diff = await _git(repository, [
          'diff',
          '--binary',
          'HEAD',
        ]);
        final String staged = await _git(repository, [
          'diff',
          '--cached',
          '--binary',
        ]);
        expect(status.isNotEmpty, dirty);
        final Project project = runtime.lifecycle.createProject(source.uri);
        expect(runtime.store.project(project.id), same(project));
        expect(project.sourceLocation, source.uri);
        expect(runtime.store.tasksFor(project.id), isEmpty);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );

        await installBackends();
        await start();
        expectBothActive();
        expect(runtime.plugins.backends, hasLength(2));
        expect(runtime.store.tasksFor(project.id), isEmpty);
        final ProviderDescriptor descriptor = runtime.registry
            .providersFor(environmentProviderCapability)
            .single;
        final TaskCreationResult created = await runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'Normal nested Task',
        );
        expect(runtime.store.project(project.id), same(project));
        expect(runtime.store.task(created.task.id), same(created.task));
        expect(runtime.store.tasksFor(project.id).single, same(created.task));
        expect(created.task.projectId, project.id);
        expect(created.task.title, 'Normal nested Task');
        expect(
          runtime.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(
          runtime.store.primaryEnvironmentFor(created.task.id),
          same(created.environment),
        );
        expect(created.environment.taskId, created.task.id);
        expect(created.environment.role, EnvironmentRole.primary);
        expect(created.environment.providerId, descriptor.id);
        expect(created.environment.providerState, isNotEmpty);
        final EnvironmentMaterialization materialization = await runtime
            .lifecycle
            .environmentRuntime
            .materialize(created.environment.id);
        expect(materialization.environment, same(created.environment));
        expect(
          materialization,
          same(
            runtime.lifecycle.environmentRuntime.currentMaterialization(
              created.environment.id,
            ),
          ),
        );
        expect(materialization.provider, isA<GeneratedEnvironmentProvider>());
        expect(materialization.providerDescriptor, same(descriptor));
        expect(materialization.validateBinding, returnsNormally);

        // Inspect provider-owned state only to corroborate the real Git fixture.
        final Map<String, Object?> state = created.environment.providerState!;
        final Directory worktree = Directory(state['worktreePath']! as String);
        final String sourceRoot = await repository.resolveSymbolicLinks();
        final String commonDirectory = (await _git(repository, [
          'rev-parse',
          '--path-format=absolute',
          '--git-common-dir',
        ])).trim();
        expect(await worktree.exists(), isTrue);
        expect(await File('${worktree.path}/.git').exists(), isTrue);
        expect(
          worktree.path,
          isNot(startsWith('$sourceRoot${Platform.pathSeparator}')),
        );
        expect(
          await worktree.parent.parent.resolveSymbolicLinks(),
          await container.resolveSymbolicLinks(),
        );
        expect(state['environmentId'], created.environment.id.value);
        expect(state['sourcePath'], await source.resolveSymbolicLinks());
        expect(state['repositoryPath'], sourceRoot);
        expect(state['sourceRelativePath'], 'packages/source');
        expect(state['baselineCommit'], baseline);
        expect(state['commonGitDirectory'], commonDirectory);
        expect(
          (await _git(worktree, ['rev-parse', '--show-toplevel'])).trim(),
          worktree.path,
        );
        expect((await _git(worktree, ['rev-parse', 'HEAD'])).trim(), baseline);
        expect(
          (await _git(worktree, [
            'rev-parse',
            '--path-format=absolute',
            '--git-common-dir',
          ])).trim(),
          commonDirectory,
        );
        expect(
          (await _git(worktree, ['branch', '--show-current'])).trim(),
          state['branch'],
        );
        expect(
          await _git(repository, ['worktree', 'list', '--porcelain']),
          contains('worktree ${worktree.path}\n'),
        );
        expect(await _git(worktree, ['status', '--porcelain=v1']), isEmpty);
        final EnvironmentTextFile read = await materialization.provider
            .readFile(created.environment.id, 'lib/example.dart');
        expect(read.text, baselineText);
        expect(read.relativePath, 'lib/example.dart');
        expect(read.revision, isNotEmpty);
        final EnvironmentDirectoryListing listing = await materialization
            .provider
            .readDirectory(created.environment.id, '');
        expect(listing.entries.map((entry) => entry.name), ['lib']);
        await expectLater(
          materialization.provider.readFile(
            created.environment.id,
            'outside.txt',
          ),
          throwsA(
            isA<EnvironmentFailure>().having(
              (failure) => failure.code,
              'code',
              'not_found',
            ),
          ),
        );
        expect(await sourceFile.readAsString(), sourceText);
        expect(
          await _git(repository, ['status', '--porcelain=v1', '-z']),
          status,
        );
        expect(await _git(repository, ['diff', '--binary', 'HEAD']), diff);
        expect(
          await _git(repository, ['diff', '--cached', '--binary']),
          staged,
        );

        final Future<void> closing = runtime.close();
        expect(runtime.close(), same(closing));
        await closing;
        expect(runtime.close(), same(closing));
        expect(runtime.plugins.state, ApplicationPluginState.closed);
        expect(runtime.plugins.failure, isNull);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(materialization.validateBinding, throwsA(_staleProvider));
        await expectLater(
          materialization.provider.readFile(
            created.environment.id,
            'lib/example.dart',
          ),
          throwsA(isA<PluginConnectionClosed>()),
        );
        expect(runtime.store.task(created.task.id), same(created.task));
        expect(
          runtime.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(await worktree.exists(), isTrue);
        expect(
          await File(
            '${worktree.path}/packages/source/lib/example.dart',
          ).readAsString(),
          baselineText,
        );
        expect((await _git(worktree, ['rev-parse', 'HEAD'])).trim(), baseline);
        expect(
          await _git(repository, ['worktree', 'list', '--porcelain']),
          contains('worktree ${worktree.path}\n'),
        );
        expect(
          (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
          baseline,
        );
        expect(
          (await _git(repository, ['branch', '--show-current'])).trim(),
          'main',
        );
        expect(await sourceFile.readAsString(), sourceText);
        expect(
          await _git(repository, ['status', '--porcelain=v1', '-z']),
          status,
        );
        expect(await _git(repository, ['diff', '--binary', 'HEAD']), diff);
        expect(
          await _git(repository, ['diff', '--cached', '--binary']),
          staged,
        );
        if (dirty) {
          expect(
            await File('${source.path}/scratch.txt').readAsString(),
            'Untracked source.\n',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }

  test(
    'discovered Git rejects non-Git Project without Task publication',
    () async {
      final Directory source = await Directory(
        '${container.path}/not-git',
      ).create();
      await File(
        '${source.path}/source.txt',
      ).writeAsString('Not a repository.\n');
      final Project project = runtime.lifecycle.createProject(source.uri);
      await installBackends();
      await start();
      expectBothActive();
      await expectLater(
        runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'Reject non-Git source',
        ),
        throwsA(
          isA<EnvironmentFailure>().having(
            (failure) => failure.code,
            'code',
            'invalid_git_source',
          ),
        ),
      );
      expect(runtime.store.project(project.id), same(project));
      expect(runtime.store.tasksFor(project.id), isEmpty);
      expect(runtime.store.task(TaskId('task-normal-1')), isNull);
      expect(
        runtime.store.environment(EnvironmentId('environment-normal-1')),
        isNull,
      );
      expect(
        runtime.store.primaryEnvironmentFor(TaskId('task-normal-1')),
        isNull,
      );
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId('environment-normal-1'),
        ),
        isNull,
      );
      expect(
        await File('${source.path}/source.txt').readAsString(),
        'Not a repository.\n',
      );
      expect(await Directory('${source.path}/.git').exists(), isFalse);
      expectBothActive();
    },
  );

  test(
    'missing shared host artifact fails globally but leaves core usable',
    () async {
      await installBackends();
      await expectLater(
        runtime.plugins.start(
          installationRoot: installationRoot.path,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: '${container.path}/missing-host.aot',
          startupArguments: startupArguments,
        ),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(runtime.plugins.state, ApplicationPluginState.failed);
      expect(runtime.plugins.failure, isA<PluginConnectionClosed>());
      expect(runtime.plugins.catalog!.installations, hasLength(2));
      expect(
        runtime.plugins.backends.every(
          (entry) => entry.state == InstalledBackendState.failed,
        ),
        isTrue,
      );
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      final Project project = runtime.lifecycle.createProject(
        Uri.parse('https://example.test/usable'),
      );
      expect(runtime.store.project(project.id), same(project));
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        isEmpty,
      );
      await expectLater(
        runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'No fallback',
        ),
        throwsA(isA<CapabilityUnavailable>()),
      );
      expect(runtime.store.tasksFor(project.id), isEmpty);
    },
  );

  for (final document in [
    (name: 'invalid JSON', text: '{'),
    (name: 'non-object', text: '[]'),
    (name: 'non-string argv', text: '{"$_openaiPluginId":[42]}'),
  ]) {
    test(
      'startup file with ${document.name} fails before host startup',
      () async {
        await installBackends();
        final File arguments = await File(
          '${container.path}/invalid-startup.json',
        ).writeAsString(document.text);
        await expectLater(
          runtime.plugins.start(
            installationRoot: installationRoot.path,
            dartaotruntimeExecutable: dartaotruntime,
            hostArtifactPath: hostArtifact.path,
            startupArgumentsFile: arguments.path,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(runtime.plugins.state, ApplicationPluginState.failed);
        expect(runtime.plugins.failure, isA<FormatException>());
        expect(runtime.plugins.catalog!.installations, hasLength(2));
        expect(runtime.plugins.catalog!.issues, isEmpty);
        expect(runtime.plugins.host, isNull);
        for (final entry in runtime.plugins.backends) {
          expect(entry.state, InstalledBackendState.failed);
          expect(entry.failure, same(runtime.plugins.failure));
          expect(entry.connection, isNull);
        }
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        final Object failure = runtime.plugins.failure!;
        final Future<void> closing = runtime.close();
        expect(runtime.close(), same(closing));
        await closing;
        expect(runtime.plugins.state, ApplicationPluginState.closed);
        expect(runtime.plugins.failure, same(failure));
      },
    );
  }

  test(
    'activation failures before and after Git do not roll back or skip unrelated backends',
    () async {
      await installBackends();
      final File corrupt = await File(
        '${container.path}/invalid.aot',
      ).writeAsString('Not an AOT snapshot.');
      await _install(
        installationRoot,
        '00-broken',
        'dev.adele.test.broken-before',
        corrupt,
      );
      await _install(
        installationRoot,
        '20-broken',
        'dev.adele.test.broken-after',
        corrupt,
      );
      await start();
      expectBothActive();
      expect(runtime.plugins.backends.map((entry) => entry.state), [
        InstalledBackendState.failed,
        InstalledBackendState.active,
        InstalledBackendState.failed,
        InstalledBackendState.active,
      ]);
      for (final id in [
        'dev.adele.test.broken-before',
        'dev.adele.test.broken-after',
      ]) {
        expect(backend(id).failure, isNotNull);
        expect(backend(id).connection, isNull);
      }
      final Directory source = await Directory(
        '${container.path}/repo',
      ).create();
      await _git(source, ['init', '--initial-branch=main']);
      await _git(source, ['commit', '--allow-empty', '-m', 'Fixture baseline']);
      final Project project = runtime.lifecycle.createProject(source.uri);
      final TaskCreationResult created = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Independent Git survives',
      );
      expect(created.environment.providerId, _gitProviderId);
    },
  );

  test(
    'all local activation failures still leave shared bootstrap ready',
    () async {
      final File corrupt = await File(
        '${container.path}/invalid.aot',
      ).writeAsString('Not AOT.');
      await _install(
        installationRoot,
        'broken',
        'dev.adele.test.broken',
        corrupt,
      );
      await start();
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.plugins.host!.isClosed, isFalse);
      expect(
        runtime.plugins.backends.single.state,
        InstalledBackendState.failed,
      );
      expect(runtime.plugins.backends.single.failure, isNotNull);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      final Project project = runtime.lifecycle.createProject(
        Uri.parse('https://example.test/core'),
      );
      expect(runtime.store.project(project.id), same(project));
      // No successful connection remains to relay the host's failure.
      final failed = runtime.plugins.changes.firstWhere(
        (state) => state == ApplicationPluginState.failed,
      );
      expect(
        Process.killPid(runtime.plugins.host!.processId, ProcessSignal.sigkill),
        isTrue,
      );
      await failed.timeout(const Duration(seconds: 10));
      expect(runtime.plugins.failure, isA<PluginConnectionClosed>());
    },
  );

  test(
    'registration collision closes the partial plugin and preserves exact Git binding',
    () async {
      await installBackends();
      const String collisionId = 'dev.adele.test.git-collision';
      await _install(
        installationRoot,
        '20-collision',
        collisionId,
        gitArtifact,
      );
      ProviderBinding? retainedGit;
      final subscription = runtime.plugins.changes.listen((_) {
        if (retainedGit == null &&
            runtime.registry
                .providersFor(environmentProviderCapability)
                .isNotEmpty) {
          retainedGit = runtime.registry.resolve(environmentProviderCapability);
        }
      });
      addTearDown(subscription.cancel);
      await start();
      expectBothActive();
      final InstalledBackendActivation failed = backend(collisionId);
      expect(failed.state, InstalledBackendState.failed);
      expect(failed.failure, isA<DuplicateProviderRegistration>());
      expect(failed.connection, isNotNull);
      expect(failed.connection!.isClosed, isTrue);
      expect(
        await failed.connection!.terminated,
        isA<PluginConnectionClosed>(),
      );
      expect(
        () => retainedGit!.endpointAs<CapabilityEndpoint>(),
        returnsNormally,
      );
      expect(
        runtime.registry.resolve(environmentProviderCapability).provider,
        same(retainedGit!.provider),
      );
      // The failed activation must release its host identity as well as its registrations.
      final PluginBackendConnection replacement = await runtime.plugins.host!
          .startPlugin(
            pluginId: collisionId,
            artifactUri: failed.installation.backendArtifactUri!,
          );
      try {
        expect(replacement, isNot(same(failed.connection)));
        expect(replacement.isClosed, isFalse);
        expectBothActive();
      } finally {
        await replacement.close();
      }
    },
  );

  for (final bool invalidConfiguration in [false, true]) {
    test(
      'OpenAI ${invalidConfiguration ? 'invalid' : 'absent'} configuration leaves Git available',
      () async {
        await installBackends();
        startupArguments[_openaiPluginId] = [
          '--chatgpt-only',
          if (invalidConfiguration)
            jsonEncode({
              'credentialFile': credentialFile.path,
              'clientId': 'adele-test-client',
              'endpoint': 'relative',
            }),
        ];
        await start(argumentsFromFile: invalidConfiguration);
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(backend(_gitPluginId).state, InstalledBackendState.active);
        expect(
          runtime.registry.resolve(environmentProviderCapability).provider.id,
          _gitProviderId,
        );
        final InstalledBackendActivation openai = backend(_openaiPluginId);
        expect(
          openai.state,
          invalidConfiguration
              ? InstalledBackendState.failed
              : InstalledBackendState.active,
        );
        if (invalidConfiguration) {
          expect(openai.failure, isNotNull);
        } else {
          expect(openai.failure, isNull);
          expect(openai.connection!.isClosed, isFalse);
          expect(openai.connection!.capabilityExposures, isEmpty);
        }
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      },
    );
  }

  test(
    'root-only startup leaves unconfigured OpenAI empty and Git active',
    () async {
      await installBackends();
      await runtime.plugins.start(
        installationRoot: installationRoot.path,
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        startupArgumentsFile: '',
      );
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(backend(_gitPluginId).state, InstalledBackendState.active);
      expect(backend(_openaiPluginId).state, InstalledBackendState.active);
      expect(backend(_openaiPluginId).connection!.capabilityExposures, isEmpty);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        runtime.registry.resolve(environmentProviderCapability).provider.id,
        _gitProviderId,
      );
    },
  );

  test(
    'OpenAI termination preserves exact Git binding, Session and further Task creation',
    () async {
      await installBackends();
      await start();
      expectBothActive();
      final PluginBackendHost host = runtime.plugins.host!;
      final ProviderBinding git = runtime.registry.resolve(
        environmentProviderCapability,
      );
      final CapabilityEndpoint gitEndpoint = git
          .endpointAs<CapabilityEndpoint>();
      final ProviderBinding model = runtime.registry.resolve(
        modelProviderCapability,
      );
      final Directory source = await Directory(
        '${container.path}/repo',
      ).create();
      await _git(source, ['init', '--initial-branch=main']);
      await _git(source, ['commit', '--allow-empty', '-m', 'Fixture baseline']);
      final Project project = runtime.lifecycle.createProject(source.uri);
      final TaskCreationResult first = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Before OpenAI termination',
      );
      final EnvironmentMaterialization materialization = await runtime
          .lifecycle
          .environmentRuntime
          .materialize(first.environment.id);
      final Session session = runtime.lifecycle.createSession(
        taskId: first.task.id,
        strategyId: chatStrategyId,
      );
      final SessionEnvironmentAuthority authority = runtime.store
          .requireSessionAuthority(session.id);
      final Future<ApplicationPluginState> retired = runtime.plugins.changes
          .firstWhere(
            (_) =>
                backend(_openaiPluginId).state ==
                InstalledBackendState.terminated,
          )
          .timeout(const Duration(seconds: 10));
      await host.stopPlugin(_openaiPluginId);
      await retired;
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(host.isClosed, isFalse);
      expect(
        backend(_openaiPluginId).failure,
        same(await backend(_openaiPluginId).connection!.terminated),
      );
      expect(backend(_gitPluginId).state, InstalledBackendState.active);
      expect(backend(_gitPluginId).connection!.isClosed, isFalse);
      expect(git.endpointAs<CapabilityEndpoint>(), same(gitEndpoint));
      expect(
        runtime.registry.resolve(environmentProviderCapability).provider,
        same(git.provider),
      );
      expect(materialization.validateBinding, returnsNormally);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        () => model.endpointAs<CapabilityEndpoint>(),
        throwsA(_staleProvider),
      );
      expect(runtime.store.session(session.id), same(session));
      expect(
        runtime.store.requireSessionAuthority(session.id),
        same(authority),
      );
      expect(authority.environmentId, first.environment.id);
      final TaskCreationResult second = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'After OpenAI termination',
      );
      expect(second.task.id, isNot(first.task.id));
      expect(second.environment.providerId, _gitProviderId);
      expect(
        runtime.store.primaryEnvironmentFor(second.task.id),
        same(second.environment),
      );
      expect(runtime.store.tasksFor(project.id), hasLength(2));
    },
  );

  test(
    'SIGKILL of shared host invalidates all exact provider bindings',
    () async {
      await installBackends();
      await start();
      expectBothActive();
      final PluginBackendHost host = runtime.plugins.host!;
      final List<ProviderBinding> bindings = [
        runtime.registry.resolve(environmentProviderCapability),
        runtime.registry.resolve(modelProviderCapability),
      ];
      final Future<ApplicationPluginState> failed = runtime.plugins.changes
          .firstWhere((state) => state == ApplicationPluginState.failed)
          .timeout(const Duration(seconds: 10));
      expect(Process.killPid(host.processId, ProcessSignal.sigkill), isTrue);
      await failed;
      expect(runtime.plugins.state, ApplicationPluginState.failed);
      expect(runtime.plugins.failure, isA<PluginConnectionClosed>());
      expect(host.isClosed, isTrue);
      for (final entry in runtime.plugins.backends) {
        expect(entry.connection!.isClosed, isTrue);
        expect(
          await entry.connection!.terminated,
          isA<PluginConnectionClosed>(),
        );
      }
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      for (final binding in bindings) {
        expect(
          () => binding.endpointAs<CapabilityEndpoint>(),
          throwsA(_staleProvider),
        );
      }
      final Project project = runtime.lifecycle.createProject(
        Uri.parse('https://example.test/after-host-failure'),
      );
      expect(runtime.store.project(project.id), same(project));
      await expectLater(
        runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'No fallback',
        ),
        throwsA(isA<CapabilityUnavailable>()),
      );
      await runtime.close();
      expect(runtime.plugins.state, ApplicationPluginState.closed);
    },
  );

  test(
    'runtime close retires every binding before stopping connections then host',
    () async {
      await installBackends();
      await start();
      expectBothActive();
      final PluginBackendHost host = runtime.plugins.host!;
      final List<ProviderBinding> bindings = [
        runtime.registry.resolve(environmentProviderCapability),
        runtime.registry.resolve(modelProviderCapability),
      ];
      expect(runtime.store.project(ProjectId('project-normal-1')), isNull);
      expect(runtime.store.task(TaskId('task-normal-1')), isNull);
      expect(
        runtime.store.environment(EnvironmentId('environment-normal-1')),
        isNull,
      );
      expect(runtime.store.session(SessionId('session-normal-1')), isNull);
      final stockChat = runtime.lifecycle.strategyResolver.resolve(
        chatStrategyId,
      );
      final List<String> stopped = [];
      final List<Future<void>> observations = [
        for (final entry in runtime.plugins.backends)
          entry.connection!.terminated.then((_) {
            stopped.add(entry.connection!.pluginId);
            expect(host.isClosed, isFalse);
            expect(stockChat.validateBinding, returnsNormally);
            for (final binding in bindings) {
              expect(
                () => binding.endpointAs<CapabilityEndpoint>(),
                throwsA(_staleProvider),
              );
            }
            expect(
              runtime.registry.providersFor(environmentProviderCapability),
              isEmpty,
            );
            expect(
              runtime.registry.providersFor(modelProviderCapability),
              isEmpty,
            );
          }),
      ];
      final Future<void> closing = runtime.close();
      expect(runtime.close(), same(closing));
      await closing;
      await Future.wait(observations);
      expect(runtime.close(), same(closing));
      expect(stopped, [_openaiPluginId, _gitPluginId]);
      expect(host.isClosed, isTrue);
      expect(
        runtime.plugins.backends.every(
          (entry) => entry.state == InstalledBackendState.closed,
        ),
        isTrue,
      );
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(runtime.plugins.failure, isNull);
      expect(stockChat.validateBinding, throwsA(isA<StaleExtensionBinding>()));
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        isEmpty,
      );
    },
  );

  test(
    'close during startup drains acquired backends and skips remaining installations',
    () async {
      await installBackends();
      const String skippedId = 'dev.adele.test.skipped';
      await _install(installationRoot, '99-skipped', skippedId, gitArtifact);
      final Completer<void> closeStarted = Completer<void>();
      late Future<void> shutdown;
      final List<ApplicationPluginState> states = [];
      final subscription = runtime.plugins.changes.listen((state) {
        states.add(state);
        if (!closeStarted.isCompleted &&
            runtime.plugins.backends.any(
              (entry) => entry.state == InstalledBackendState.active,
            )) {
          expect(state, ApplicationPluginState.starting);
          expect(runtime.plugins.host!.isClosed, isFalse);
          shutdown = runtime.close();
          closeStarted.complete();
        }
      });
      addTearDown(subscription.cancel);
      final Future<void> starting = start();
      await closeStarted.future.timeout(const Duration(seconds: 10));
      await starting;
      await shutdown;
      expect(runtime.close(), same(shutdown));
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.plugins.host!.isClosed, isTrue);
      expect(backend(_gitPluginId).connection!.isClosed, isTrue);
      for (final entry in runtime.plugins.backends) {
        expect(entry.connection == null || entry.connection!.isClosed, isTrue);
      }
      expect(backend(skippedId).connection, isNull);
      expect(backend(skippedId).state, InstalledBackendState.closed);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(states, isNot(contains(ApplicationPluginState.ready)));
      expect(states, isNot(contains(ApplicationPluginState.failed)));
      expect(states.last, ApplicationPluginState.closed);
    },
  );
}

final Matcher _staleProvider = isA<ProviderUnavailable>().having(
  (error) => error.stale,
  'stale',
  isTrue,
);

Future<void> _install(
  Directory root,
  String name,
  String id,
  File artifact,
) async {
  final Directory directory = await Directory('${root.path}/$name').create();
  await artifact.copy('${directory.path}/backend.aot');
  await File('${directory.path}/adele_plugin.installation.json').writeAsString(
    jsonEncode({
      'manifestVersion': 1,
      'metadata': {'id': id, 'version': '1.0.0', 'displayName': name},
      'components': {
        'backend': {'artifact': 'backend.aot'},
      },
    }),
  );
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final ProcessResult result = await Process.run('git', [
    '-c',
    'user.name=ADELE Test',
    '-c',
    'user.email=adele-test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    ...arguments,
  ], workingDirectory: directory.path);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString();
}

String _dartExecutable() {
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final File executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final File executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
