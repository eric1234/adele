import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/plugins/stock_backend_plugins.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unconfigured stock bootstrap leaves core usable without a provider',
    () async {
      final AdeleRuntime runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'unconfigured'),
      );
      addTearDown(runtime.close);
      final List<ApplicationPluginState> states = [];
      final subscription = runtime.plugins.changes.listen(states.add);
      addTearDown(subscription.cancel);

      await bootstrapStockBackendPlugins(
        runtime.plugins,
        dartaotruntimeExecutable: '',
        hostArtifactPath: '',
        gitEnvironmentArtifactPath: '',
      );

      expect(runtime.plugins.registry, same(runtime.registry));
      expect(runtime.plugins.state, ApplicationPluginState.unconfigured);
      expect(runtime.plugins.failure, isNull);
      expect(states, isEmpty);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      final Project project = runtime.lifecycle.createProject(
        Uri.parse('https://example.test/project'),
      );
      expect(runtime.store.project(project.id), same(project));
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        hasLength(1),
      );
      await expectLater(
        runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'Unavailable',
        ),
        throwsA(isA<CapabilityUnavailable>()),
      );
      expect(runtime.store.tasksFor(project.id), isEmpty);
      expect(runtime.store.task(TaskId('task-unconfigured-1')), isNull);
      expect(
        runtime.store.environment(EnvironmentId('environment-unconfigured-1')),
        isNull,
      );

      final Future<void> closing = runtime.close();
      expect(runtime.close(), same(closing));
      await closing;
      expect(runtime.close(), same(closing));
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(states, [
        ApplicationPluginState.closing,
        ApplicationPluginState.closed,
      ]);
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        isEmpty,
      );
      expect(runtime.store.project(project.id), same(project));
    },
  );

  test('missing executable exposes failure without disabling core', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-bootstrap-missing-executable-',
    );
    addTearDown(() => container.delete(recursive: true));
    final AdeleRuntime runtime = AdeleRuntime();
    addTearDown(runtime.close);
    final List<ApplicationPluginState> states = [];
    final subscription = runtime.plugins.changes.listen(states.add);
    addTearDown(subscription.cancel);
    int activationCalls = 0;

    await expectLater(
      runtime.plugins.start(
        dartaotruntimeExecutable: '${container.path}/missing-runtime',
        hostArtifactPath: '${container.path}/missing-host.aot',
        activate: [
          (_, _) async {
            activationCalls++;
            throw StateError('Activation must not run without a host.');
          },
        ],
      ),
      throwsA(isA<ProcessException>()),
    );

    expect(activationCalls, 0);
    expect(runtime.plugins.state, ApplicationPluginState.failed);
    expect(runtime.plugins.failure, isA<ProcessException>());
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    final Project project = runtime.lifecycle.createProject(
      Uri.parse('https://example.test/after-start-failure'),
    );
    expect(runtime.store.project(project.id), same(project));
    expect(
      runtime.extensions.discover(projectSelectorContributions),
      hasLength(1),
    );
    await expectLater(
      runtime.lifecycle.createTask(projectId: project.id, title: 'No fallback'),
      throwsA(isA<CapabilityUnavailable>()),
    );
    expect(runtime.store.tasksFor(project.id), isEmpty);
    expect(
      () => runtime.plugins.start(
        dartaotruntimeExecutable: '',
        hostArtifactPath: '',
        activate: [],
      ),
      throwsStateError,
    );

    final Object failure = runtime.plugins.failure!;
    final Future<void> closing = runtime.close();
    expect(runtime.close(), same(closing));
    await closing;
    expect(runtime.close(), same(closing));
    expect(runtime.plugins.failure, same(failure));
    expect(states, [
      ApplicationPluginState.starting,
      ApplicationPluginState.failed,
      ApplicationPluginState.closing,
      ApplicationPluginState.closed,
    ]);
  });

  test(
    'closing an unused bootstrap is terminal and shares completion',
    () async {
      final ApplicationPluginBootstrap plugins = ApplicationPluginBootstrap(
        CapabilityRegistry(),
      );
      final Future<void> closing = plugins.close();
      expect(plugins.close(), same(closing));
      await closing;
      expect(plugins.close(), same(closing));
      expect(plugins.state, ApplicationPluginState.closed);
      expect(plugins.failure, isNull);
      expect(
        () => plugins.start(
          dartaotruntimeExecutable: '',
          hostArtifactPath: '',
          activate: [],
        ),
        throwsStateError,
      );
    },
  );
}
