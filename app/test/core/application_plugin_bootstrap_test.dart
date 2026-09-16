import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final String rootKind in ['unconfigured', 'missing', 'empty']) {
    test('$rootKind root is ready without starting a host', () async {
      final Directory container = await Directory.systemTemp.createTemp(
        'adele-bootstrap-$rootKind-',
      );
      addTearDown(() => container.delete(recursive: true));
      final AdeleRuntime runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: rootKind),
      );
      addTearDown(runtime.close);
      final List<ApplicationPluginState> states = [];
      final subscription = runtime.plugins.changes.listen(states.add);
      addTearDown(subscription.cancel);

      await runtime.plugins.start(
        installationRoot: switch (rootKind) {
          'unconfigured' => '',
          'missing' => '${container.path}/missing',
          _ => container.path,
        },
        dartaotruntimeExecutable: '${container.path}/nonexistent-runtime',
        hostArtifactPath: '${container.path}/nonexistent-host.aot',
        startupArgumentsFile: '${container.path}/nonexistent-arguments.json',
      );

      expect(runtime.plugins.registry, same(runtime.registry));
      expect(runtime.plugins.state, ApplicationPluginState.ready);
      expect(runtime.plugins.failure, isNull);
      expect(runtime.plugins.catalog!.installations, isEmpty);
      expect(runtime.plugins.catalog!.issues, isEmpty);
      expect(runtime.plugins.backends, isEmpty);
      expect(runtime.plugins.host, isNull);
      expect(
        runtime.registry.providersFor(environmentProviderCapability),
        isEmpty,
      );
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
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
      expect(runtime.store.task(TaskId('task-$rootKind-1')), isNull);
      expect(
        runtime.store.environment(EnvironmentId('environment-$rootKind-1')),
        isNull,
      );
      expect(() => runtime.plugins.start(), throwsStateError);

      final Future<void> closing = runtime.close();
      expect(runtime.close(), same(closing));
      await closing;
      expect(runtime.close(), same(closing));
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(states, [
        ApplicationPluginState.starting,
        ApplicationPluginState.ready,
        ApplicationPluginState.closing,
        ApplicationPluginState.closed,
      ]);
      expect(
        runtime.extensions.discover(projectSelectorContributions),
        isEmpty,
      );
      expect(runtime.store.project(project.id), same(project));
    });
  }

  for (final bool invalidRoot in [true, false]) {
    test(
      '${invalidRoot ? 'non-directory root' : 'missing shared runtime'} exposes global failure with usable core',
      () async {
        final Directory container = await Directory.systemTemp.createTemp(
          'adele-bootstrap-failure-',
        );
        addTearDown(() => container.delete(recursive: true));
        final String root = '${container.path}/installations';
        if (invalidRoot) {
          await File(root).writeAsString('Not an installation directory.');
        } else {
          final Directory installation = await Directory(
            '$root/fixture',
          ).create(recursive: true);
          await File('${installation.path}/backend.aot').writeAsBytes([0]);
          await File(
            '${installation.path}/adele_plugin.installation.json',
          ).writeAsString(
            jsonEncode({
              'manifestVersion': 1,
              'metadata': {
                'id': 'dev.adele.test.fixture',
                'version': '1.0.0',
                'displayName': 'Fixture',
              },
              'components': {
                'backend': {'artifact': 'backend.aot'},
              },
            }),
          );
        }
        final AdeleRuntime runtime = AdeleRuntime();
        addTearDown(runtime.close);
        final List<ApplicationPluginState> states = [];
        final subscription = runtime.plugins.changes.listen(states.add);
        addTearDown(subscription.cancel);
        final Matcher failure = invalidRoot
            ? isA<FileSystemException>()
            : isA<ProcessException>();

        await expectLater(
          runtime.plugins.start(
            installationRoot: root,
            dartaotruntimeExecutable: '${container.path}/missing-runtime',
            hostArtifactPath: '${container.path}/missing-host.aot',
          ),
          throwsA(failure),
        );

        expect(runtime.plugins.state, ApplicationPluginState.failed);
        expect(runtime.plugins.failure, failure);
        expect(runtime.plugins.host, isNull);
        if (!invalidRoot) {
          expect(runtime.plugins.catalog!.installations, hasLength(1));
          expect(
            runtime.plugins.backends.single.state,
            InstalledBackendState.failed,
          );
          expect(runtime.plugins.backends.single.connection, isNull);
        }
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        final Project project = runtime.lifecycle.createProject(
          Uri.parse('https://example.test/after-start-failure'),
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
        expect(() => runtime.plugins.start(), throwsStateError);

        final Object originalFailure = runtime.plugins.failure!;
        final Future<void> closing = runtime.close();
        expect(runtime.close(), same(closing));
        await closing;
        expect(runtime.close(), same(closing));
        expect(runtime.plugins.failure, same(originalFailure));
        expect(states, [
          ApplicationPluginState.starting,
          ApplicationPluginState.failed,
          ApplicationPluginState.closing,
          ApplicationPluginState.closed,
        ]);
      },
    );
  }

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
      expect(plugins.host, isNull);
      expect(plugins.backends, isEmpty);
      expect(() => plugins.start(), throwsStateError);
    },
  );
}
