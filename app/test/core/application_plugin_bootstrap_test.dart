import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  test(
    'exact installation, strategy origins and channels never retarget',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'adele-exact-bootstrap-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final root = await Directory('${directory.path}/installations').create();
      final installationDirectory = await Directory(
        '${root.path}/plugin',
      ).create();
      final artifact = await File(
        '${installationDirectory.path}/backend.aot',
      ).writeAsString('fixture');
      const pluginId = 'dev.adele.test.exact-backend';
      await File(
        '${installationDirectory.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': pluginId,
            'version': 'test',
            'displayName': 'Exact Backend',
          },
          'components': {
            'backend': {'artifact': 'backend.aot'},
          },
        }),
      );
      final script = await File(
        '${directory.path}/host.dart',
      ).writeAsString(_exactHostScript);
      final extensions = ExtensionRegistry();
      final capabilities = CapabilityRegistry();
      final bootstrap = ApplicationPluginBootstrap(capabilities, extensions);
      addTearDown(bootstrap.close);
      final exposures = <Map<String, Object?>>[
        for (final name in ['a', 'b'])
          {
            'extensionPointId': orchestrationStrategyContributions.value,
            'extensionId': 'dev.adele.test.strategy.$name',
            'serviceId': remoteOrchestrationServiceId,
            'configurationContext': 'configured-$name',
            'metadata': {
              'strategyId': 'dev.adele.strategy.$name',
              'routeId': name,
            },
          },
      ];
      final startup = [
        jsonEncode({'extensionExposures': exposures}),
      ];
      final before = (await PreparedPluginCatalog.discover(
        root.path,
      )).installations.single;
      expect(bootstrap.backendForInstallation(before), isNull);
      final started = bootstrap.start(
        installationRoot: root.path,
        dartaotruntimeExecutable:
            '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
        hostArtifactPath: script.path,
        startupArguments: {pluginId: startup},
      );
      expect(bootstrap.backendForInstallation(before), isNull);
      await started;
      final installation = bootstrap.catalog!.installations.single;
      final backend = bootstrap.backendForInstallation(installation)!;
      expect(bootstrap.backendForInstallation(before), isNull);
      expect(
        bootstrap.backendForInstallation(
          PreparedPluginInstallation(
            metadata: installation.metadata,
            installationDirectory: installation.installationDirectory,
            backendArtifactUri: installation.backendArtifactUri,
          ),
        ),
        isNull,
      );
      final bindings = extensions.discover(orchestrationStrategyContributions);
      final strategyA = bindings.first;
      final originA = backend.strategyOrigin(strategyA)!;
      final originB = backend.strategyOrigin(bindings.last)!;
      expect(originA.connection, same(originB.connection));
      expect(
        backend.strategyOrigin(
          extensions.discover(orchestrationStrategyContributions).first,
        ),
        same(originA),
      );
      PreparedSessionPresentation presentation(
        OrchestrationStrategyId id,
        PreparedStrategyAffinity affinity,
      ) => PreparedSessionPresentation(
        extensionId: ExtensionId('dev.adele.test.presentation'),
        strategyId: id,
        displayName: 'Example',
        library: 'package:example/session.dart',
        entrypoint: 'buildSession',
        backendServices: ['history'],
        strategyAffinity: affinity,
      );
      var live = true;
      final channel = backend.openChannel(
        presentation: presentation(
          strategyA.value.strategyId,
          PreparedStrategyAffinity.owningBackend,
        ),
        strategyBinding: strategyA,
        validatePresentation: () {
          if (!live) throw StateError('View retired.');
        },
      );
      expect(await channel.request('history', 'echo', {}), {
        'configurationContext': 'configured-a',
        'serviceId': 'history',
      });
      final channelB = backend.openChannel(
        presentation: presentation(
          bindings.last.value.strategyId,
          PreparedStrategyAffinity.owningBackend,
        ),
        strategyBinding: bindings.last,
        validatePresentation: () {},
      );
      expect(await channelB.request('history', 'echo', {}), {
        'configurationContext': 'configured-b',
        'serviceId': 'history',
      });
      final foreign = ExtensionRegistry();
      foreign.register(
        point: orchestrationStrategyContributions,
        id: strategyA.id,
        value: strategyA.value,
      );
      final foreignBinding = foreign
          .discover(orchestrationStrategyContributions)
          .single;
      expect(backend.strategyOrigin(foreignBinding), isNull);
      expect(
        () => backend.openChannel(
          presentation: presentation(
            strategyA.value.strategyId,
            PreparedStrategyAffinity.owningBackend,
          ),
          strategyBinding: foreignBinding,
          validatePresentation: () {},
        ),
        throwsStateError,
      );
      expect(
        () => backend.openChannel(
          presentation: presentation(
            bindings.last.value.strategyId,
            PreparedStrategyAffinity.owningBackend,
          ),
          strategyBinding: strategyA,
          validatePresentation: () {},
        ),
        throwsArgumentError,
      );
      final independent = backend.openChannel(
        presentation: presentation(
          strategyA.value.strategyId,
          PreparedStrategyAffinity.independent,
        ),
        strategyBinding: foreignBinding,
        validatePresentation: () {},
      );
      expect(await independent.request('history', 'echo', {}), {
        'configurationContext': 'default',
        'serviceId': 'history',
      });
      live = false;
      await expectLater(
        channel.request('history', 'echo', {}),
        throwsStateError,
      );
      live = true;
      await backend.connection!.close();
      expect(bootstrap.backendForInstallation(installation), isNull);
      final replacement = await bootstrap.host!.startPlugin(
        pluginId: pluginId,
        artifactUri: artifact.uri,
        arguments: startup,
      );
      final activation = await PluginBackendActivation.registerAdvertised(
        connection: replacement,
        capabilities: capabilities,
        extensions: extensions,
        adapters: createRemoteExtensionAdapters(),
      );
      addTearDown(activation.close);
      final replacementBinding = extensions
          .discover(orchestrationStrategyContributions)
          .first;
      expect(
        activation.extensionOrigin(replacementBinding)!.connection,
        same(replacement),
      );
      expect(originA.validate, throwsA(isA<StaleExtensionBinding>()));
      await expectLater(
        channel.request('history', 'echo', {}),
        throwsStateError,
      );
      await expectLater(
        independent.request('history', 'echo', {}),
        throwsStateError,
      );
      expect(bootstrap.backendForInstallation(installation), isNull);
      await activation.close();
      final closing = bootstrap.close();
      expect(bootstrap.backendForInstallation(installation), isNull);
      await closing;
    },
  );

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
      expect(runtime.plugins.extensions, same(runtime.extensions));
      expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
      expect(runtime.extensions.discover(modelToolContributions), isEmpty);
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
        isEmpty,
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
        bool snapshotPublishedBeforeBackendFailure = false;
        final discoverySubscription = runtime.plugins.changes.listen((state) {
          if (runtime.plugins.catalog != null &&
              state == ApplicationPluginState.starting &&
              runtime.plugins.failure == null) {
            snapshotPublishedBeforeBackendFailure = true;
          }
        });
        addTearDown(discoverySubscription.cancel);
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
          expect(snapshotPublishedBeforeBackendFailure, isTrue);
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
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
        expect(runtime.extensions.discover(modelToolContributions), isEmpty);
        final Project project = runtime.lifecycle.createProject(
          Uri.parse('https://example.test/after-start-failure'),
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
        expect(() => runtime.plugins.start(), throwsStateError);

        final Object originalFailure = runtime.plugins.failure!;
        final Future<void> closing = runtime.close();
        expect(runtime.close(), same(closing));
        await closing;
        expect(runtime.close(), same(closing));
        expect(runtime.plugins.failure, same(originalFailure));
        expect(states, [
          ApplicationPluginState.starting,
          if (!invalidRoot) ApplicationPluginState.starting,
          ApplicationPluginState.failed,
          ApplicationPluginState.closing,
          ApplicationPluginState.closed,
        ]);
      },
    );
  }

  test(
    'frontend-only discovery needs no backend infrastructure or rescan',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'adele-frontend-only-',
      );
      addTearDown(() => root.delete(recursive: true));
      final installation = await Directory('${root.path}/frontend').create();
      await File('${installation.path}/frontend.evc').writeAsBytes([1, 2, 3]);
      final manifest = File(
        '${installation.path}/adele_plugin.installation.json',
      );
      await manifest.writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': 'dev.adele.test.frontend',
            'version': '1',
            'displayName': 'Frontend',
          },
          'components': {
            'frontend': {
              'artifact': 'frontend.evc',
              'presentations': <Object?>[],
            },
          },
        }),
      );
      final plugins = ApplicationPluginBootstrap(
        CapabilityRegistry(),
        ExtensionRegistry(),
      );
      addTearDown(plugins.close);
      await plugins.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: '${root.path}/missing-runtime',
        hostArtifactPath: '${root.path}/missing-host.aot',
        startupArgumentsFile: '${root.path}/missing-argv.json',
      );
      final catalog = plugins.catalog!;
      expect(catalog.installations.single.frontend, isNotNull);
      expect(catalog.installations.single.backendArtifactUri, isNull);
      expect(plugins.backends, isEmpty);
      expect(plugins.host, isNull);
      expect(plugins.state, ApplicationPluginState.ready);
      await manifest.delete();
      expect(plugins.catalog, same(catalog));
      expect(plugins.catalog!.installations.single.frontend, isNotNull);
    },
  );

  test(
    'closing an unused bootstrap is terminal and shares completion',
    () async {
      final ApplicationPluginBootstrap plugins = ApplicationPluginBootstrap(
        CapabilityRegistry(),
        ExtensionRegistry(),
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

// Only transport framing/readiness are faked; activation and routing are real.
const _exactHostScript = r'''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
void send(Map<String, Object?> message) {
  final bytes = utf8.encode(jsonEncode({'protocolVersion': 1, ...message}));
  final length = ByteData(4)..setUint32(0, bytes.length);
  stdout.add([...length.buffer.asUint8List(), ...bytes]);
}
void main() {
  send({'kind': 'hostHello'});
  var buffer = <int>[];
  stdin.listen((bytes) {
    buffer.addAll(bytes);
    while (buffer.length >= 4) {
      final length = ByteData.sublistView(Uint8List.fromList(buffer), 0, 4).getUint32(0);
      if (buffer.length < length + 4) break;
      final message = jsonDecode(utf8.decode(buffer.sublist(4, 4 + length))) as Map<String, dynamic>;
      buffer = buffer.sublist(4 + length);
      final route = {'requestId': message['requestId'], 'pluginId': message['pluginId'], 'generation': message['generation']};
      switch (message['kind']) {
        case 'startPlugin':
          send({'kind': 'pluginReady', ...route, ...jsonDecode(message['arguments'][0]) as Map<String, dynamic>});
        case 'stopPlugin':
          send({'kind': 'pluginStopped', ...route});
        case 'request':
          send({'kind': 'response', ...route, 'ok': true, 'payload': {'configurationContext': message['configurationContext'], 'serviceId': message['serviceId']}});
        case 'shutdownHost':
          send({'kind': 'hostStopped', 'requestId': message['requestId']});
          exit(0);
      }
    }
  });
}
''';
