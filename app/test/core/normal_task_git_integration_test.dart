@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../support/git_worktree_fixture.dart';
import '../support/prepared_normal_task_git.dart';

void main() {
  final suite = PreparedNormalTaskGit(Directory.current.parent);
  setUpAll(suite.prepare);

  late NormalTaskGitCase fixture;
  late AdeleRuntime runtime;
  setUp(() async {
    fixture = await suite.createCase();
    runtime = fixture.runtime;
  });

  test(
    'missing shared host artifact fails globally but leaves core usable',
    () async {
      await fixture.installBackends();
      await expectLater(
        runtime.plugins.start(
          installationRoot: fixture.installationRoot.path,
          dartaotruntimeExecutable: suite.sdk.aotRuntime,
          hostArtifactPath: '${fixture.container.path}/missing-host.aot',
          startupArguments: fixture.startupArguments,
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
    (name: 'non-string argv', text: '{"$openaiPluginId":[42]}'),
  ]) {
    test(
      'startup file with ${document.name} fails before host startup',
      () async {
        await fixture.installBackends();
        final File arguments = await File(
          '${fixture.container.path}/invalid-startup.json',
        ).writeAsString(document.text);
        await expectLater(
          runtime.plugins.start(
            installationRoot: fixture.installationRoot.path,
            dartaotruntimeExecutable: suite.sdk.aotRuntime,
            hostArtifactPath: suite.hostArtifact.path,
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
      await fixture.installBackends();
      final File corrupt = await File(
        '${fixture.container.path}/invalid.aot',
      ).writeAsString('Not an AOT snapshot.');
      await fixture.install(
        '00-broken',
        'dev.adele.test.broken-before',
        corrupt,
      );
      await fixture.install(
        '20-broken',
        'dev.adele.test.broken-after',
        corrupt,
      );
      await fixture.start();
      fixture.expectBothActive();
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
        expect(fixture.backend(id).failure, isNotNull);
        expect(fixture.backend(id).connection, isNull);
      }
      final Directory source = await Directory(
        '${fixture.container.path}/repo',
      ).create();
      await git(source, ['init', '--initial-branch=main']);
      await git(source, ['commit', '--allow-empty', '-m', 'Fixture baseline']);
      final Project project = runtime.lifecycle.createProject(source.uri);
      final TaskCreationResult created = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Independent Git survives',
      );
      expect(created.environment.providerId, gitProviderId);
    },
  );

  test(
    'all local activation failures still leave shared bootstrap ready',
    () async {
      final File corrupt = await File(
        '${fixture.container.path}/invalid.aot',
      ).writeAsString('Not AOT.');
      await fixture.install('broken', 'dev.adele.test.broken', corrupt);
      await fixture.start();
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
      await fixture.installBackends();
      const String collisionId = 'dev.adele.test.git-collision';
      await fixture.install('20-collision', collisionId, suite.gitArtifact);
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
      await fixture.start();
      fixture.expectBothActive();
      final InstalledBackendActivation failed = fixture.backend(collisionId);
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
        fixture.expectBothActive();
      } finally {
        await replacement.close();
      }
    },
  );

  test(
    'SIGKILL of shared host invalidates all exact provider bindings',
    () async {
      await fixture.installBackends();
      await fixture.start();
      fixture.expectBothActive();
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
          throwsA(staleProvider),
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
      await fixture.installBackends();
      await fixture.start();
      fixture.expectBothActive();
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
      expect(
        runtime.extensions.discover(orchestrationStrategyContributions),
        isEmpty,
      );
      final List<String> stopped = [];
      final List<Future<void>> observations = [
        for (final entry in runtime.plugins.backends)
          entry.connection!.terminated.then((_) {
            stopped.add(entry.connection!.pluginId);
            expect(host.isClosed, isFalse);
            for (final binding in bindings) {
              expect(
                () => binding.endpointAs<CapabilityEndpoint>(),
                throwsA(staleProvider),
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
      expect(stopped, [openaiPluginId, gitPluginId]);
      expect(host.isClosed, isTrue);
      expect(
        runtime.plugins.backends.every(
          (entry) => entry.state == InstalledBackendState.closed,
        ),
        isTrue,
      );
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(runtime.plugins.failure, isNull);
      expect(
        runtime.extensions.discover(orchestrationStrategyContributions),
        isEmpty,
      );
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        isEmpty,
      );
    },
  );

  test(
    'close during startup drains acquired backends and skips remaining installations',
    () async {
      await fixture.installBackends();
      const String skippedId = 'dev.adele.test.skipped';
      await fixture.install('99-skipped', skippedId, suite.gitArtifact);
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
      final Future<void> starting = fixture.start();
      await closeStarted.future.timeout(const Duration(seconds: 10));
      await starting;
      await shutdown;
      expect(runtime.close(), same(shutdown));
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.plugins.host!.isClosed, isTrue);
      expect(fixture.backend(gitPluginId).connection!.isClosed, isTrue);
      for (final entry in runtime.plugins.backends) {
        expect(entry.connection == null || entry.connection!.isClosed, isTrue);
      }
      expect(fixture.backend(skippedId).connection, isNull);
      expect(fixture.backend(skippedId).state, InstalledBackendState.closed);
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
