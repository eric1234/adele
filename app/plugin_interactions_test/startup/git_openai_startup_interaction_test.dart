@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../test/support/git_worktree_fixture.dart';
import '../../test/support/prepared_normal_task_git.dart';

void main() {
  final suite = PreparedNormalTaskGit(Directory.current.parent);
  setUpAll(suite.prepare);

  late NormalTaskGitCase fixture;
  late AdeleRuntime runtime;
  setUp(() async {
    fixture = await suite.createCase();
    runtime = fixture.runtime;
  });

  for (final bool invalidConfiguration in [false, true]) {
    test(
      'OpenAI ${invalidConfiguration ? 'invalid' : 'absent'} configuration leaves Git available',
      () async {
        await fixture.installBackends();
        fixture.startupArguments[openaiPluginId] = [
          '--chatgpt-only',
          if (invalidConfiguration)
            jsonEncode({
              'credentialFile': fixture.credentialFile.path,
              'clientId': 'adele-test-client',
              'endpoint': 'relative',
            }),
        ];
        await fixture.start(argumentsFromFile: invalidConfiguration);
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(
          fixture.backend(gitPluginId).state,
          InstalledBackendState.active,
        );
        expect(
          runtime.registry.resolve(environmentProviderCapability).provider.id,
          gitProviderId,
        );
        final InstalledBackendActivation openai = fixture.backend(
          openaiPluginId,
        );
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
      await fixture.installBackends();
      await runtime.plugins.start(
        installationRoot: fixture.installationRoot.path,
        dartaotruntimeExecutable: suite.sdk.aotRuntime,
        hostArtifactPath: suite.hostArtifact.path,
        startupArgumentsFile: '',
      );
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(fixture.backend(gitPluginId).state, InstalledBackendState.active);
      expect(
        fixture.backend(openaiPluginId).state,
        InstalledBackendState.active,
      );
      expect(
        fixture.backend(openaiPluginId).connection!.capabilityExposures,
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        runtime.registry.resolve(environmentProviderCapability).provider.id,
        gitProviderId,
      );
    },
  );

  test(
    'OpenAI termination preserves exact Git binding, Session and further Task creation',
    () async {
      await fixture.installBackends();
      await fixture.start();
      fixture.expectBothActive();
      final PluginBackendHost host = runtime.plugins.host!;
      final ProviderBinding gitBinding = runtime.registry.resolve(
        environmentProviderCapability,
      );
      final CapabilityEndpoint gitEndpoint = gitBinding
          .endpointAs<CapabilityEndpoint>();
      final ProviderBinding model = runtime.registry.resolve(
        modelProviderCapability,
      );
      final Directory source = await Directory(
        '${fixture.container.path}/repo',
      ).create();
      await git(source, ['init', '--initial-branch=main']);
      await git(source, ['commit', '--allow-empty', '-m', 'Fixture baseline']);
      final Project project = runtime.lifecycle.createProject(source.uri);
      final TaskCreationResult first = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Before OpenAI termination',
      );
      final database = runtime.lifecycle.existingDatabaseForProject(project)!;
      final retainedAnchor = database
          .queryPluginRows('SELECT * FROM adele_git_task_anchors', {})
          .single
          .values;
      expect(
        retainedAnchor['baseline_commit'],
        (await git(source, ['rev-parse', 'HEAD'])).trim(),
      );
      expect(database.loadProductGraph().sessions, isEmpty);
      final EnvironmentMaterialization materialization = await runtime
          .lifecycle
          .environmentRuntime
          .materialize(first.environment.id);
      final strategyId = OrchestrationStrategyId('dev.adele.test.lifecycle');
      addTearDown(
        runtime.extensions
            .register(
              point: orchestrationStrategyContributions,
              id: ExtensionId('dev.adele.test.lifecycle.strategy'),
              value: OrchestrationStrategyContribution(
                strategyId: strategyId,
                materialize: (_) => throw StateError('No Run is started here.'),
              ),
            )
            .close,
      );
      final Session session = runtime.lifecycle.createSession(
        taskId: first.task.id,
        strategyId: strategyId,
      );
      expect(
        runtime.lifecycle.databaseForSession(
          session.id,
          accessMode: ProjectStorageAccessMode.durableOrTemporary,
        ),
        same(database),
      );
      final worktree = Directory(
        gitWorktreeFixturePath(project, first.environment),
      );
      await git(worktree, ['commit', '--allow-empty', '-m', 'Task progress']);
      await git(source, ['commit', '--allow-empty', '-m', 'Source progress']);
      final laterSession = runtime.lifecycle.createSession(
        taskId: first.task.id,
        strategyId: strategyId,
      );
      expect(
        runtime.lifecycle.databaseForSession(
          laterSession.id,
          accessMode: ProjectStorageAccessMode.durableOrTemporary,
        ),
        same(database),
      );
      expect(
        database
            .queryPluginRows(
              '''SELECT g.* FROM adele_product_session_environment_authority a
          JOIN adele_git_task_anchors g ON g.environment_id=a.environment_id
          WHERE a.session_id=:session''',
              {':session': laterSession.id.value},
            )
            .single
            .values,
        retainedAnchor,
      );
      final SessionEnvironmentAuthority authority = runtime.store
          .requireSessionAuthority(session.id);
      final Future<ApplicationPluginState> retired = runtime.plugins.changes
          .firstWhere(
            (_) =>
                fixture.backend(openaiPluginId).state ==
                InstalledBackendState.terminated,
          )
          .timeout(const Duration(seconds: 10));
      await host.stopPlugin(openaiPluginId);
      await retired;
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(host.isClosed, isFalse);
      expect(
        fixture.backend(openaiPluginId).failure,
        same(await fixture.backend(openaiPluginId).connection!.terminated),
      );
      expect(fixture.backend(gitPluginId).state, InstalledBackendState.active);
      expect(fixture.backend(gitPluginId).connection!.isClosed, isFalse);
      expect(gitBinding.endpointAs<CapabilityEndpoint>(), same(gitEndpoint));
      expect(
        runtime.registry.resolve(environmentProviderCapability).provider,
        same(gitBinding.provider),
      );
      expect(materialization.validateBinding, returnsNormally);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      expect(
        () => model.endpointAs<CapabilityEndpoint>(),
        throwsA(staleProvider),
      );
      expect(runtime.store.session(session.id), same(session));
      expect(runtime.store.sessionsForTask(first.task.id), [
        same(session),
        same(laterSession),
      ]);
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
      expect(second.environment.providerId, gitProviderId);
      expect(
        runtime.store.primaryEnvironmentFor(second.task.id),
        same(second.environment),
      );
      expect(runtime.store.tasksFor(project.id), hasLength(2));
      expect(runtime.store.sessionsForTask(second.task.id), isEmpty);
    },
  );
}
