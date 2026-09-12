@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/plugins/stock_backend_plugins.dart';
import 'package:adele_desktop/plugins/stock_git_environment.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  late Directory artifacts;
  late String dartaotruntime;
  late File hostArtifact;
  late File gitArtifact;

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
    // Build each real backend artifact once for every scenario in this suite.
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

  for (final bool dirty in [false, true]) {
    test(
      'normal bootstrap establishes a nested Task and preserves ${dirty ? 'dirty' : 'clean'} source',
      () async {
        final Directory container = await Directory.systemTemp.createTemp(
          'adele-normal-task-',
        );
        addTearDown(() => container.delete(recursive: true));
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
        final AdeleRuntime runtime = AdeleRuntime();
        addTearDown(runtime.close);
        final Project project = runtime.lifecycle.createProject(source.uri);
        expect(runtime.store.project(project.id), same(project));
        expect(project.sourceLocation, source.uri);
        expect(runtime.store.tasksFor(project.id), isEmpty);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );

        await bootstrapStockBackendPlugins(
          runtime.plugins,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          gitEnvironmentArtifactPath: gitArtifact.path,
        );

        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(runtime.plugins.registry, same(runtime.registry));
        final ProviderDescriptor descriptor = runtime.registry
            .providersFor(environmentProviderCapability)
            .single;
        expect(descriptor.id, stockGitEnvironmentProviderId);
        expect(descriptor.pluginId, stockGitEnvironmentPluginId);
        expect(runtime.store.tasksFor(project.id), isEmpty);
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

        // Inspect stock-owned state only here to corroborate the real Git fixture.
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
    'stock provider rejects non-Git Project without Task publication',
    () async {
      final Directory source = await Directory.systemTemp.createTemp(
        'adele-not-git-',
      );
      addTearDown(() => source.delete(recursive: true));
      await File(
        '${source.path}/source.txt',
      ).writeAsString('Not a repository.\n');
      final AdeleRuntime runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'non-git'),
      );
      addTearDown(runtime.close);
      final Project project = runtime.lifecycle.createProject(source.uri);
      expect(runtime.store.project(project.id), same(project));
      await bootstrapStockBackendPlugins(
        runtime.plugins,
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        gitEnvironmentArtifactPath: gitArtifact.path,
      );
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
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.store.project(project.id), same(project));
      expect(runtime.store.tasksFor(project.id), isEmpty);
      expect(runtime.store.task(TaskId('task-non-git-1')), isNull);
      expect(
        runtime.store.environment(EnvironmentId('environment-non-git-1')),
        isNull,
      );
      expect(
        runtime.store.primaryEnvironmentFor(TaskId('task-non-git-1')),
        isNull,
      );
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId('environment-non-git-1'),
        ),
        isNull,
      );
      expect(
        await File('${source.path}/source.txt').readAsString(),
        'Not a repository.\n',
      );
      expect(await Directory('${source.path}/.git').exists(), isFalse);
      expect(
        runtime.registry.providersFor(environmentProviderCapability).single.id,
        stockGitEnvironmentProviderId,
      );
    },
  );

  test(
    'missing host artifact leaves visible failure and usable core',
    () async {
      final AdeleRuntime runtime = AdeleRuntime();
      addTearDown(runtime.close);
      final List<ApplicationPluginState> states = [];
      final subscription = runtime.plugins.changes.listen(states.add);
      addTearDown(subscription.cancel);
      await expectLater(
        bootstrapStockBackendPlugins(
          runtime.plugins,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: '${artifacts.path}/missing-host.aot',
          gitEnvironmentArtifactPath: gitArtifact.path,
        ),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(runtime.plugins.state, ApplicationPluginState.failed);
      expect(runtime.plugins.failure, isA<PluginConnectionClosed>());
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      final Project project = runtime.lifecycle.createProject(
        Uri.parse('https://example.test/core-still-usable'),
      );
      expect(runtime.store.project(project.id), same(project));
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        hasLength(1),
      );
      await expectLater(
        runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'No fallback',
        ),
        throwsA(isA<CapabilityUnavailable>()),
      );
      expect(runtime.store.tasksFor(project.id), isEmpty);
      await runtime.close();
      expect(states, [
        ApplicationPluginState.starting,
        ApplicationPluginState.failed,
        ApplicationPluginState.closing,
        ApplicationPluginState.closed,
      ]);
    },
  );

  test(
    'runtime close retires capability and closes owned connection and host',
    () async {
      final AdeleRuntime runtime = AdeleRuntime();
      addTearDown(runtime.close);
      late PluginBackendHost host;
      late PluginCapabilityActivation activation;
      final List<ApplicationPluginState> states = [];
      final subscription = runtime.plugins.changes.listen(states.add);
      addTearDown(subscription.cancel);
      await runtime.plugins.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        activate: [
          (ownedHost, registry) async {
            host = ownedHost;
            expect(registry, same(runtime.registry));
            return activation = await activateStockGitEnvironment(
              host: host,
              registry: registry,
              artifactUri: gitArtifact.uri,
            );
          },
        ],
      );
      final ProviderBinding binding = runtime.registry.resolve(
        environmentProviderCapability,
      );
      expect(host.isClosed, isFalse);
      expect(activation.connection.isClosed, isFalse);
      final Future<void> closing = runtime.close();
      expect(runtime.close(), same(closing));
      await closing;
      expect(runtime.close(), same(closing));
      expect(host.isClosed, isTrue);
      expect(activation.connection.isClosed, isTrue);
      expect(
        await activation.connection.terminated,
        isA<PluginConnectionClosed>(),
      );
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(
        () => binding.endpointAs<CapabilityEndpoint>(),
        throwsA(_staleProvider),
      );
      expect(runtime.plugins.failure, isNull);
      expect(states, [
        ApplicationPluginState.starting,
        ApplicationPluginState.ready,
        ApplicationPluginState.closing,
        ApplicationPluginState.closed,
      ]);
    },
  );

  test(
    'later activation failure rolls back a successful activation and host',
    () async {
      final AdeleRuntime runtime = AdeleRuntime();
      addTearDown(runtime.close);
      late PluginBackendHost host;
      late PluginCapabilityActivation activation;
      late ProviderBinding binding;
      final StateError failure = StateError('Second activation failed.');
      int skippedCalls = 0;
      await expectLater(
        runtime.plugins.start(
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          activate: [
            (ownedHost, registry) async {
              host = ownedHost;
              activation = await activateStockGitEnvironment(
                host: host,
                registry: registry,
                artifactUri: gitArtifact.uri,
              );
              binding = registry.resolve(environmentProviderCapability);
              return activation;
            },
            (ownedHost, registry) async {
              expect(ownedHost, same(host));
              expect(activation.connection.isClosed, isFalse);
              expect(
                registry.providersFor(environmentProviderCapability),
                hasLength(1),
              );
              throw failure;
            },
            (_, _) async {
              skippedCalls++;
              throw StateError('Unreachable activation');
            },
          ],
        ),
        throwsA(same(failure)),
      );
      expect(skippedCalls, 0);
      expect(runtime.plugins.state, ApplicationPluginState.failed);
      expect(runtime.plugins.failure, same(failure));
      expect(host.isClosed, isTrue);
      expect(activation.connection.isClosed, isTrue);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(
        () => binding.endpointAs<CapabilityEndpoint>(),
        throwsA(_staleProvider),
      );
      await runtime.close();
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(runtime.plugins.failure, same(failure));
    },
  );

  test(
    'stock registration failure closes its connection before host rollback',
    () async {
      final AdeleRuntime runtime = AdeleRuntime();
      addTearDown(runtime.close);
      final CapabilityRegistration existing = runtime.registry.register(
        provider: ProviderDescriptor(
          id: stockGitEnvironmentProviderId,
          capability: environmentProviderCapability,
          pluginId: 'dev.adele.plugin.existing-test',
          displayName: 'Existing provider',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: const _AvailableEndpoint(),
      );
      addTearDown(existing.close);
      final ProviderBinding binding = runtime.registry.resolve(
        environmentProviderCapability,
      );
      late PluginBackendHost host;
      bool connectionWasReleased = false;
      await expectLater(
        runtime.plugins.start(
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          activate: [
            (ownedHost, registry) async {
              host = ownedHost;
              try {
                return await activateStockGitEnvironment(
                  host: host,
                  registry: registry,
                  artifactUri: gitArtifact.uri,
                );
              } on DuplicateProviderRegistration {
                // Starting the same plugin on this still-open host proves the failed
                // stock activator released its otherwise inaccessible connection.
                expect(host.isClosed, isFalse);
                final PluginBackendConnection replacement = await host
                    .startPlugin(
                      pluginId: stockGitEnvironmentPluginId,
                      artifactUri: gitArtifact.uri,
                    );
                connectionWasReleased = true;
                await replacement.close();
                rethrow;
              }
            },
          ],
        ),
        throwsA(isA<DuplicateProviderRegistration>()),
      );
      expect(connectionWasReleased, isTrue);
      expect(runtime.plugins.state, ApplicationPluginState.failed);
      expect(runtime.plugins.failure, isA<DuplicateProviderRegistration>());
      expect(host.isClosed, isTrue);
      expect(existing.isClosed, isFalse);
      expect(() => binding.endpointAs<CapabilityEndpoint>(), returnsNormally);
      await runtime.close();
      expect(existing.isClosed, isFalse);
    },
  );

  test(
    'close waits for an in-flight activation and skips remaining startup',
    () async {
      final AdeleRuntime runtime = AdeleRuntime();
      addTearDown(runtime.close);
      final Completer<void> activated = Completer<void>();
      final Completer<void> release = Completer<void>();
      // Release before teardown closes the runtime, even if an assertion fails.
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      late PluginBackendHost host;
      late PluginCapabilityActivation activation;
      int skippedCalls = 0;
      final List<ApplicationPluginState> states = [];
      final subscription = runtime.plugins.changes.listen(states.add);
      addTearDown(subscription.cancel);
      final Future<void> starting = runtime.plugins.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        activate: [
          (ownedHost, registry) async {
            host = ownedHost;
            activation = await activateStockGitEnvironment(
              host: host,
              registry: registry,
              artifactUri: gitArtifact.uri,
            );
            activated.complete();
            await release.future;
            return activation;
          },
          (_, _) async {
            skippedCalls++;
            throw StateError('Must not start while closing.');
          },
        ],
      );
      await activated.future.timeout(const Duration(seconds: 10));
      expect(runtime.plugins.state, ApplicationPluginState.starting);
      final Future<void> closing = runtime.close();
      expect(runtime.close(), same(closing));
      expect(runtime.plugins.state, ApplicationPluginState.closing);
      expect(host.isClosed, isFalse);
      expect(activation.connection.isClosed, isFalse);
      bool closed = false;
      unawaited(
        closing.then((_) {
          closed = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      release.complete();
      await starting;
      await closing;
      expect(runtime.close(), same(closing));
      expect(skippedCalls, 0);
      expect(host.isClosed, isTrue);
      expect(activation.connection.isClosed, isTrue);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.plugins.failure, isNull);
      expect(states, [
        ApplicationPluginState.starting,
        ApplicationPluginState.closing,
        ApplicationPluginState.closed,
      ]);
    },
  );

  test('termination during a later activation cannot publish ready', () async {
    final AdeleRuntime runtime = AdeleRuntime();
    addTearDown(runtime.close);
    late PluginBackendHost host;
    final List<PluginCapabilityActivation> activations = [];
    final List<ProviderBinding> bindings = [];
    final List<ApplicationPluginState> states = [];
    final subscription = runtime.plugins.changes.listen(states.add);
    addTearDown(subscription.cancel);
    await expectLater(
      runtime.plugins.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        activate: [
          (ownedHost, registry) async {
            host = ownedHost;
            final PluginCapabilityActivation activation =
                await activateStockGitEnvironment(
                  host: host,
                  registry: registry,
                  artifactUri: gitArtifact.uri,
                );
            activations.add(activation);
            bindings.add(registry.resolve(environmentProviderCapability));
            return activation;
          },
          (ownedHost, registry) async {
            expect(runtime.plugins.state, ApplicationPluginState.starting);
            await ownedHost.stopPlugin(stockGitEnvironmentPluginId);
            expect(activations.single.connection.isClosed, isTrue);
            final PluginCapabilityActivation replacement =
                await activateStockGitEnvironment(
                  host: ownedHost,
                  registry: registry,
                  artifactUri: gitArtifact.uri,
                );
            activations.add(replacement);
            bindings.add(registry.resolve(environmentProviderCapability));
            return replacement;
          },
        ],
      ),
      throwsStateError,
    );
    expect(activations, hasLength(2));
    expect(runtime.plugins.state, ApplicationPluginState.failed);
    expect(runtime.plugins.failure, isA<StateError>());
    expect(host.isClosed, isTrue);
    expect(
      activations.every((activation) => activation.connection.isClosed),
      isTrue,
    );
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    for (final ProviderBinding binding in bindings) {
      expect(
        () => binding.endpointAs<CapabilityEndpoint>(),
        throwsA(_staleProvider),
      );
    }
    await runtime.close();
    expect(states, [
      ApplicationPluginState.starting,
      ApplicationPluginState.failed,
      ApplicationPluginState.closing,
      ApplicationPluginState.closed,
    ]);
  });

  test(
    'out-of-band plugin termination fails startup owner and retires provider',
    () async {
      final AdeleRuntime runtime = AdeleRuntime();
      addTearDown(runtime.close);
      late PluginBackendHost host;
      late PluginCapabilityActivation activation;
      await runtime.plugins.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        activate: [
          (ownedHost, registry) async {
            host = ownedHost;
            return activation = await activateStockGitEnvironment(
              host: host,
              registry: registry,
              artifactUri: gitArtifact.uri,
            );
          },
        ],
      );
      final ProviderBinding binding = runtime.registry.resolve(
        environmentProviderCapability,
      );
      final Future<ApplicationPluginState> failed = runtime.plugins.changes
          .firstWhere((state) => state == ApplicationPluginState.failed)
          .timeout(const Duration(seconds: 10));
      await host.stopPlugin(stockGitEnvironmentPluginId);
      await failed;
      expect(runtime.plugins.state, ApplicationPluginState.failed);
      expect(
        runtime.plugins.failure,
        same(await activation.connection.terminated),
      );
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(
        () => binding.endpointAs<CapabilityEndpoint>(),
        throwsA(_staleProvider),
      );
      final Future<void> closing = runtime.close();
      expect(runtime.close(), same(closing));
      await closing;
      expect(host.isClosed, isTrue);
      expect(activation.connection.isClosed, isTrue);
      expect(runtime.plugins.state, ApplicationPluginState.closed);
    },
  );
}

final Matcher _staleProvider = isA<ProviderUnavailable>().having(
  (error) => error.stale,
  'stale',
  isTrue,
);

final class _AvailableEndpoint implements CapabilityEndpoint {
  const _AvailableEndpoint();

  @override
  String get serviceId => environmentProviderServiceId;

  @override
  bool get isAvailable => true;
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
