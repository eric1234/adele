@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

import '../support/project_provider.dart';

const _plugin = 'test.associated.backend';
const _bound = Duration(seconds: 10);

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File probeArtifact;
  late String aotRuntime;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-associated-');
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    probeArtifact = File('${artifacts.path}/probe.aot');
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint: 'app/test/core/fixtures/associated_capability_probe.dart',
        artifact: probeArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'associated-capability-integration',
      );
    }
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  late PluginBackendHost host;
  late CapabilityRegistry capabilities;
  late ExtensionRegistry extensions;
  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: hostArtifact.path,
    );
    addTearDown(host.close);
    capabilities = CapabilityRegistry();
    extensions = ExtensionRegistry();
  });

  Future<PluginBackendActivation> start({
    String pluginId = _plugin,
    List<AdeleCapabilityExposure>? exposures,
    Map<String, Object?> options = const {},
    ProductLifecycleCoordinator? lifecycle,
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: probeArtifact.uri,
      arguments: [
        jsonEncode({
          ...options,
          'exposures': (exposures ?? _exposures())
              .map((e) => e.toMap())
              .toList(),
        }),
      ],
      createInfrastructureServices: lifecycle == null
          ? null
          : (connection) {
              final services = projectStorageServices(lifecycle, connection);
              for (final dispatcher in services.values) {
                addTearDown(dispatcher.close);
              }
              return services;
            },
    );
    addTearDown(connection.close);
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: capabilities,
      extensions: extensions,
      adapters: RemoteExtensionAdapterRegistry([]),
    );
    addTearDown(activation.close);
    return activation;
  }

  ProductLifecycleCoordinator createLifecycle({
    required PluginBackendActivation Function() activation,
    AdeleRequestChannel Function(AdeleRequestChannel)? wrapChannel,
    void Function()? onCapture,
    void Function()? onValidate,
  }) {
    final lifecycle = ProductLifecycleCoordinator(
      store: InMemoryProductStore(),
      registry: capabilities,
      extensions: extensions,
      ids: MonotonicProductIdSource(),
      providerForBinding: (binding) => GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(
          wrapChannel?.call(binding.requestChannel) ?? binding.requestChannel,
        ),
      ),
      captureEstablishmentOwner: (binding) {
        onCapture?.call();
        final captured = activation();
        return EnvironmentEstablishmentOwner(
          pluginId: PluginId(captured.connection.pluginId),
          validate: () {
            onValidate?.call();
            captured.validate();
            if (!captured.ownsProvider(binding)) {
              throw StateError(
                'The captured backend does not own this binding.',
              );
            }
          },
        );
      },
    );
    addTearDown(lifecycle.close);
    return lifecycle;
  }

  Future<Project> openProject(ProductLifecycleCoordinator lifecycle) async {
    final root = await Directory(artifacts.path).createTemp('initial-state-');
    final provider = TestProjectProvider(capabilities);
    addTearDown(provider.close);
    return lifecycle.openProject(
      sourceLocation: root.uri,
      provider: lifecycle.resolveProjectProvider(provider.providerId),
    );
  }

  test(
    'normal runtime derives initial SQL owner from installed AOT backend',
    () async {
      final root = await Directory(
        artifacts.path,
      ).createTemp('initial-runtime-');
      final installation = await Directory('${root.path}/probe').create();
      await probeArtifact.copy('${installation.path}/backend.aot');
      await File(
        '${installation.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': _plugin,
            'displayName': 'Initial state probe',
            'version': '0.1.0',
            'description': 'Generic establishment fixture',
          },
          'components': {
            'backend': {'artifact': 'backend.aot'},
          },
        }),
      );
      final runtime = AdeleRuntime();
      addTearDown(runtime.close);
      await runtime.plugins.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          _plugin: [
            jsonEncode({
              'exposures': _exposures().map((e) => e.toMap()).toList(),
              'initialState': true,
            }),
          ],
        },
      );
      final project = runtime.lifecycle.createProject(
        Uri.parse('test:/runtime'),
      );
      final created = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'normal-runtime',
        providerId: ProviderId('test.environment.a'),
      );
      final binding = runtime.lifecycle.environmentRuntime
          .currentMaterialization(created.environment.id)!
          .binding;
      final backend = runtime.plugins.backendForProvider(binding)!;
      backend.validateProviderOwnership(binding);
      final connection = backend.connection!;
      final response = await connection
          .channelFor(connection.defaultConfigurationContext, 'probe')
          .request('queryEnvironment', {
            'environmentId': created.environment.id.value,
            'sql':
                'SELECT r.value, v.owner_id FROM fixture_initial_records r '
                'JOIN adele_schema_versions v ON v.owner_id = :owner',
            'parameters': {':owner': connection.pluginId},
          });
      expect((response! as Map)['rows'], [
        {'value': 'normal-runtime', 'owner_id': _plugin},
      ]);
      expect(runtime.store.sessionsForTask(created.task.id), isEmpty);
    },
  );

  for (final durable in [true, false]) {
    test(
      'AOT initial state publishes ${durable ? 'durable' : 'temporary'} rows before Sessions and survives backend replacement',
      () async {
        late PluginBackendActivation activation;
        var captures = 0;
        var validations = 0;
        final lifecycle = createLifecycle(
          activation: () => activation,
          onCapture: () => captures++,
          onValidate: () => validations++,
        );
        final project = durable
            ? await openProject(lifecycle)
            : lifecycle.createProject(
                Uri.parse('test:/temporary-initial-state'),
              );
        activation = await start(
          lifecycle: lifecycle,
          options: {'initialState': true, 'holdEstablish': true},
        );
        final creating = lifecycle.createTask(
          projectId: project.id,
          title: 'initial-value',
          providerId: ProviderId('test.environment.a'),
        );
        final snapshot = await _probe(activation, 'establishing');
        final provisional =
            (snapshot['establishments'] as List<Object?>).single!
                as Map<Object?, Object?>;
        expect(captures, 1);
        expect(validations, greaterThanOrEqualTo(1));
        _expectUnpublished(lifecycle, project, provisional);
        await _probe(activation, 'release');
        final created = await creating.timeout(_bound);
        expect(captures, 1);
        expect(validations, greaterThanOrEqualTo(2));
        expect(lifecycle.store.task(created.task.id), same(created.task));
        expect(
          lifecycle.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(created.environment.providerState, {
          'provider': 'test.environment.a',
        });
        expect(lifecycle.store.sessionsForTask(created.task.id), isEmpty);
        expect(
          lifecycle.databaseForEnvironment(created.environment.id) != null,
          durable,
        );
        final database = lifecycle.databaseForEnvironment(
          created.environment.id,
          accessMode: ProjectStorageAccessMode.durableOrTemporary,
        )!;
        final rows = [
          {
            'environment_id': created.environment.id.value,
            'task_id': created.task.id.value,
            'project_id': project.id.value,
            'value': 'initial-value',
          },
        ];
        expect(await _initialRows(activation, created.environment.id), rows);
        expect(
          await _query(
            activation,
            created.environment.id,
            "SELECT owner_id, version FROM adele_schema_versions WHERE owner_id LIKE 'test.%'",
          ),
          [
            {'owner_id': activation.connection.pluginId, 'version': 1},
          ],
        );
        expect(
          activation.connection.pluginId,
          isNot(created.environment.providerId.value),
        );
        expect(
          await _query(
            activation,
            created.environment.id,
            'SELECT COUNT(*) AS count FROM adele_product_sessions',
          ),
          [
            {'count': 0},
          ],
        );
        final observed = await _probe(activation, 'snapshot');
        expect(observed['reverseRequests'], isNotEmpty);
        expect(
          observed['reverseRequests'],
          everyElement({
            'serviceId': projectStorageServiceId,
            'method': projectStorageServiceQueryForEnvironmentId,
            'hostContextKind': 'infrastructure',
          }),
        );
        final oldBinding = lifecycle.environmentRuntime
            .currentMaterialization(created.environment.id)!
            .binding;
        await activation.close();
        activation = await start(
          lifecycle: lifecycle,
          options: {'initialState': true},
        );
        expect(await _initialRows(activation, created.environment.id), rows);
        expect(
          lifecycle.databaseForEnvironment(
            created.environment.id,
            accessMode: ProjectStorageAccessMode.durableOrTemporary,
          ),
          same(database),
        );
        // Restore returns only provider state, even when establishment is configured
        // to require rows. A replacement must not replay an initialization insert.
        final restored = await lifecycle.environmentRuntime
            .materialize(created.environment.id)
            .timeout(_bound);
        expect(restored.binding.isSameRegistration(oldBinding), isFalse);
        expect(await _initialRows(activation, created.environment.id), rows);
        expect(
          (await _probe(activation, 'snapshot'))['establishments'],
          isEmpty,
        );
        expect(captures, 1);

        if (durable) {
          await activation.close();
          await lifecycle.close();
          final reopened = createLifecycle(activation: () => activation);
          final projectAgain = await reopened.openProject(
            sourceLocation: project.sourceLocation,
            provider: reopened.resolveProjectProvider(testProjectProviderId),
          );
          expect(projectAgain.id, project.id);
          expect(
            reopened.store.tasksFor(project.id).single.id,
            created.task.id,
          );
          activation = await start(lifecycle: reopened);
          expect(await _initialRows(activation, created.environment.id), rows);
          expect(
            (await _probe(activation, 'snapshot'))['establishments'],
            isEmpty,
          );
        }
      },
    );
  }

  for (final fault in ['malformed', 'forgedOwner', 'invalidSql', 'wrongRows']) {
    test('AOT $fault initial plan leaves no partial graph or SQL rows', () async {
      late PluginBackendActivation activation;
      final lifecycle = createLifecycle(activation: () => activation);
      final project = await openProject(lifecycle);
      activation = await start(
        lifecycle: lifecycle,
        options: {
          'initialState': true,
          'faultProviderId': 'test.environment.b',
          'fault': fault,
        },
      );
      final baseline = await lifecycle.createTask(
        projectId: project.id,
        title: 'baseline',
        providerId: ProviderId('test.environment.a'),
      );
      final before = await _initialRows(activation, baseline.environment.id);
      await expectLater(
        lifecycle
            .createTask(
              projectId: project.id,
              title: 'must-not-publish',
              providerId: ProviderId('test.environment.b'),
            )
            .timeout(_bound),
        throwsA(
          fault == 'malformed' || fault == 'forgedOwner'
              ? isA<AdeleProtocolException>()
              : fault == 'invalidSql'
              ? isA<ArgumentError>()
              : isA<StateError>(),
        ),
      );
      final snapshot = await _probe(activation, 'snapshot');
      final failed =
          (snapshot['establishments'] as List<Object?>).last!
              as Map<Object?, Object?>;
      _expectUnpublished(lifecycle, project, failed, existingTasks: 1);
      expect(await _initialRows(activation, baseline.environment.id), before);
      expect(
        await _query(
          activation,
          baseline.environment.id,
          'SELECT (SELECT COUNT(*) FROM adele_product_tasks) AS tasks, '
          '(SELECT COUNT(*) FROM adele_product_environments) AS environments, '
          '(SELECT COUNT(*) FROM fixture_initial_records) AS records',
        ),
        [
          {'tasks': 1, 'environments': 1, 'records': 1},
        ],
      );
      expect(
        await _query(
          activation,
          baseline.environment.id,
          "SELECT owner_id FROM adele_schema_versions WHERE owner_id LIKE 'test.%'",
        ),
        [
          {'owner_id': _plugin},
        ],
      );
    });
  }

  test(
    'descriptor identity cannot authorize an unowned AOT provider binding',
    () async {
      late PluginBackendActivation activation;
      final lifecycle = createLifecycle(activation: () => activation);
      final project = await openProject(lifecycle);
      activation = await start(
        lifecycle: lifecycle,
        options: {'initialState': true},
      );
      final baseline = await lifecycle.createTask(
        projectId: project.id,
        title: 'baseline',
        providerId: ProviderId('test.environment.a'),
      );
      final real = capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.b'),
      );
      final channel = real.requestChannel;
      await activation.retireProvider(real);
      final forged = capabilities.register(
        provider: ProviderDescriptor(
          id: real.provider.id,
          capability: environmentProviderCapability,
          pluginId: activation.connection.pluginId,
          displayName: 'Forged same-owner descriptor',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(forged.close);
      await expectLater(
        lifecycle.createTask(
          projectId: project.id,
          title: 'forged',
          providerId: real.provider.id,
        ),
        throwsStateError,
      );
      expect(
        (await _probe(activation, 'snapshot'))['establishments'],
        hasLength(1),
      );
      expect(
        await _initialRows(activation, baseline.environment.id),
        hasLength(1),
      );
      expect(lifecycle.store.tasksFor(project.id), [baseline.task]);
    },
  );

  for (final afterResponse in [false, true]) {
    test(
      'AOT retirement ${afterResponse ? 'after real response' : 'during establishment'} cannot revive an old plan on same-ID replacement',
      () async {
        late PluginBackendActivation activation;
        late _EstablishmentGate gate;
        var captures = 0;
        var gateNext = afterResponse;
        final lifecycle = createLifecycle(
          activation: () => activation,
          onCapture: () => captures++,
          wrapChannel: (channel) {
            if (!gateNext) return channel;
            gateNext = false;
            return gate = _EstablishmentGate(channel);
          },
        );
        final project = await openProject(lifecycle);
        activation = await start(
          lifecycle: lifecycle,
          options: {'initialState': true, 'holdEstablish': !afterResponse},
        );
        final creating = lifecycle.createTask(
          projectId: project.id,
          title: 'retired-plan',
          providerId: ProviderId('test.environment.a'),
        );
        final failed = expectLater(
          creating.timeout(_bound),
          throwsA(
            anyOf(isA<ProviderUnavailable>(), isA<PluginConnectionClosed>()),
          ),
        );
        final snapshot = await _probe(activation, 'establishing');
        final provisional =
            (snapshot['establishments'] as List<Object?>).single!
                as Map<Object?, Object?>;
        expect(captures, 1);
        _expectUnpublished(lifecycle, project, provisional);
        if (afterResponse) {
          await gate.received.future.timeout(_bound);
          addTearDown(() {
            if (!gate.release.isCompleted) gate.release.complete();
          });
          await activation.close();
          activation = await start(
            lifecycle: lifecycle,
            options: {'initialState': true},
          );
          gate.release.complete();
        } else {
          final binding = capabilities.resolve(
            environmentProviderCapability,
            providerId: ProviderId('test.environment.a'),
          );
          await activation.retireProvider(binding);
          await _probe(activation, 'release');
          await failed;
          await activation.close();
          activation = await start(
            lifecycle: lifecycle,
            options: {'initialState': true},
          );
        }
        await failed;
        expect(captures, 1);
        _expectUnpublished(lifecycle, project, provisional);
        final fresh = await lifecycle.createTask(
          projectId: project.id,
          title: 'replacement-plan',
          providerId: ProviderId('test.environment.a'),
        );
        expect(captures, 2);
        expect(await _initialRows(activation, fresh.environment.id), [
          {
            'environment_id': fresh.environment.id.value,
            'task_id': fresh.task.id.value,
            'project_id': project.id.value,
            'value': 'replacement-plan',
          },
        ]);
        expect(
          await _query(
            activation,
            fresh.environment.id,
            'SELECT (SELECT COUNT(*) FROM adele_product_tasks) AS tasks, '
            '(SELECT COUNT(*) FROM adele_product_environments) AS environments',
          ),
          [
            {'tasks': 1, 'environments': 1},
          ],
        );
      },
    );
  }

  test(
    'real ready activation captures exact siblings and preserves generated context-free routes',
    () async {
      final activation = await start();
      final environmentA = capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.a'),
      );
      final environmentB = capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.b'),
      );
      expect(activation.connection.capabilityExposures, hasLength(6));
      expect(
        capabilities.resolve(resourceInspectCapability).provider.id.value,
        'test.callable.b',
      );
      final selected = activation.resolveAssociatedProvider(
        resourceInspectCapability,
        associatedWith: environmentA,
      );
      expect(selected.provider.id.value, 'test.callable.a');
      expect(
        activation.associationFor(selected)!.isSameRegistration(environmentA),
        isTrue,
      );
      expect(
        activation.associationFor(selected)!.isSameRegistration(environmentB),
        isFalse,
      );
      expect(
        activation
            .resolveAssociatedProvider(
              resourceInspectCapability,
              associatedWith: environmentA,
              providerId: ProviderId('test.callable.alternate'),
            )
            .provider
            .id
            .value,
        'test.callable.alternate',
      );
      for (final id in [
        'test.callable.b',
        'test.callable.unassociated',
        'test.callable.missing',
      ]) {
        expect(
          () => activation.resolveAssociatedProvider(
            resourceInspectCapability,
            associatedWith: environmentA,
            providerId: ProviderId(id),
          ),
          throwsA(isA<ProviderUnavailable>()),
        );
      }
      final resource = ResourceRef(uri: Uri.parse('test:/ordinary-data'));
      final result = await ResourceInspectorServiceClient(
        selected.requestChannel,
      ).inspect(resource).timeout(_bound);
      expect(result.providerLabel, 'callable-a');
      expect(result.resource.uri, resource.uri);
      final global = capabilities.resolve(resourceInspectCapability);
      expect(
        (await ResourceInspectorServiceClient(
          global.requestChannel,
        ).inspect(resource)).providerLabel,
        'callable-b',
      );
      final snapshot = await activation.connection
          .channelFor(
            activation.connection.defaultConfigurationContext,
            'probe',
          )
          .request('snapshot', {});
      expect((snapshot! as Map)['requests'], [
        for (final context in ['callable-a', 'callable-b'])
          {
            'configurationContext': context,
            'serviceId': resourceInspectorServiceId,
            'method': 'resourceInspector.inspect',
            'hostInvocationContext': null,
          },
      ]);
    },
  );

  test(
    'termination and same-ID replacement never revive captured associations or affect a sibling',
    () async {
      final first = await start();
      final sibling = await start(
        pluginId: 'test.independent.backend',
        exposures: _exposures(prefix: 'test.independent'),
      );
      final anchor = capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.a'),
      );
      final selected = first.resolveAssociatedProvider(
        resourceInspectCapability,
        associatedWith: anchor,
      );
      await expectLater(
        first.connection
            .channelFor(first.connection.defaultConfigurationContext, 'probe')
            .request('terminate', {}),
        throwsA(isA<PluginRemoteFailure>()),
      );
      await first.connection.terminated;
      await first.retire();
      final replacement = await start();
      expect(
        () => first.associationFor(selected),
        throwsA(isA<PluginConnectionClosed>()),
      );
      expect(
        () => selected.requestChannel,
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        () => replacement.resolveAssociatedProvider(
          resourceInspectCapability,
          associatedWith: anchor,
        ),
        throwsA(isA<ProviderUnavailable>()),
      );
      final freshAnchor = capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.a'),
      );
      expect(freshAnchor.isSameRegistration(anchor), isFalse);
      expect(
        replacement
            .resolveAssociatedProvider(
              resourceInspectCapability,
              associatedWith: freshAnchor,
            )
            .isSameRegistration(selected),
        isFalse,
      );
      final independentAnchor = capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.independent.environment.a'),
      );
      final independent = sibling.resolveAssociatedProvider(
        resourceInspectCapability,
        associatedWith: independentAnchor,
      );
      expect(
        (await ResourceInspectorServiceClient(
              independent.requestChannel,
            ).inspect(ResourceRef(uri: Uri.parse('test:/still-live'))))
            .providerLabel,
        'callable-a',
      );
    },
  );

  test(
    'independent eligibility preserves sibling order and explicit no-fallback selection',
    () async {
      final root = await Directory('${artifacts.path}/mixed').create();
      for (final id in ['siblings', 'independent']) {
        final directory = await Directory('${root.path}/$id').create();
        await probeArtifact.copy('${directory.path}/backend.aot');
        await File(
          '${directory.path}/adele_plugin.installation.json',
        ).writeAsString(
          jsonEncode({
            'manifestVersion': 1,
            'metadata': {
              'id': 'test.$id',
              'displayName': id,
              'version': '0.1.0',
              'description': 'Mixed eligibility fixture',
            },
            'components': {
              'backend': {'artifact': 'backend.aot'},
            },
          }),
        );
      }
      final bootstrap = ApplicationPluginBootstrap(capabilities, extensions);
      addTearDown(bootstrap.close);
      await bootstrap.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          'test.siblings': [
            jsonEncode({
              'exposures': _exposures().map((e) => e.toMap()).toList(),
            }),
          ],
          'test.independent': [
            jsonEncode({
              'exposures': [
                for (final id in [
                  'test.independent.first',
                  'test.independent.second',
                ])
                  _callable(
                    id,
                    'callable-a',
                    rank: 1000,
                    environmentBound: true,
                  ).toMap(),
              ],
            }),
          ],
        },
      );
      expect(
        bootstrap.backends.map((b) => b.state),
        everyElement(InstalledBackendState.active),
      );
      final environment = capabilities.resolve(
        environmentProviderCapability,
        providerId: ProviderId('test.environment.a'),
      );
      ProviderBinding select([String? id]) =>
          bootstrap.resolveEnvironmentCapabilityProvider(
            resourceInspectCapability,
            associatedWith: environment,
            providerId: id == null ? null : ProviderId(id),
          );
      // Higher-ranked independent providers cannot change existing sibling order.
      expect(select().provider.id.value, 'test.callable.a');
      final independent = select('test.independent.first');
      expect(
        bootstrap.backendForProvider(independent),
        isNot(same(bootstrap.backendForProvider(environment))),
      );
      expect(
        select('test.callable.alternate').provider.id.value,
        'test.callable.alternate',
      );
      for (final id in [
        'test.missing',
        'test.callable.b',
        'test.callable.unassociated',
      ]) {
        expect(() => select(id), throwsA(isA<ProviderUnavailable>()));
      }
      final siblingOwner = bootstrap.backendForProvider(environment)!;
      await siblingOwner.retireProvider(select('test.callable.a'));
      expect(select().provider.id.value, 'test.callable.alternate');
      await siblingOwner.retireProvider(select('test.callable.alternate'));
      // Ranking is not a selection policy for independent providers.
      expect(select, throwsStateError);
      await bootstrap
          .backendForProvider(independent)!
          .retireProvider(independent);
      expect(select().provider.id.value, 'test.independent.second');
      expect(
        () => select('test.independent.first'),
        throwsA(isA<ProviderUnavailable>()),
      );
      await siblingOwner.retireProvider(environment);
      expect(select, throwsA(isA<ProviderUnavailable>()));
    },
  );

  test(
    'bootstrap contains rollback and canonical nonprimary selection survives navigation during real restore',
    () async {
      final root = await Directory('${artifacts.path}/installations').create();
      for (final id in ['valid', 'invalid']) {
        final directory = await Directory('${root.path}/$id').create();
        await probeArtifact.copy('${directory.path}/backend.aot');
        await File(
          '${directory.path}/adele_plugin.installation.json',
        ).writeAsString(
          jsonEncode({
            'manifestVersion': 1,
            'metadata': {
              'id': 'test.$id',
              'displayName': id,
              'version': '0.1.0',
              'description': 'Association activation fixture',
            },
            'components': {
              'backend': {'artifact': 'backend.aot'},
            },
          }),
        );
      }
      final bootstrap = ApplicationPluginBootstrap(capabilities, extensions);
      addTearDown(bootstrap.close);
      final invalid = [
        _callable(
          'test.invalid.callable',
          'callable-a',
          target: 'test.missing.environment',
        ),
        _environment('test.invalid.environment'),
      ];
      await bootstrap.start(
        installationRoot: root.path,
        dartaotruntimeExecutable: aotRuntime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          'test.valid': [
            jsonEncode({
              'holdRestore': true,
              'exposures': _exposures().map((e) => e.toMap()).toList(),
            }),
          ],
          'test.invalid': [
            jsonEncode({'exposures': invalid.map((e) => e.toMap()).toList()}),
          ],
        },
      );
      expect(bootstrap.state, ApplicationPluginState.ready);
      expect(bootstrap.catalog!.issues, isEmpty);
      final failed = bootstrap.backends.singleWhere(
        (b) => b.installation.metadata.id.value == 'test.invalid',
      );
      expect(failed.state, InstalledBackendState.failed);
      expect(failed.failure, isA<InvalidProviderRegistration>());
      expect(failed.connection!.isClosed, isTrue);
      expect(
        capabilities.providersFor(environmentProviderCapability),
        hasLength(2),
      );
      expect(
        capabilities.providersFor(resourceInspectCapability),
        hasLength(4),
      );
      expect(
        bootstrap.backends
            .singleWhere(
              (b) => b.installation.metadata.id.value == 'test.valid',
            )
            .state,
        InstalledBackendState.active,
      );
      final store = InMemoryProductStore();
      final task = Task(
        id: TaskId('task'),
        projectId: ProjectId('project'),
        title: 'Provenance',
      );
      final session = Session(
        id: SessionId('nonprimary-session'),
        taskId: task.id,
        strategyId: OrchestrationStrategyId('test.absent-strategy'),
      );
      final other = Session(
        id: SessionId('primary-session'),
        taskId: task.id,
        strategyId: session.strategyId,
      );
      final primary = Environment(
        id: EnvironmentId('primary'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: ProviderId('test.environment.b'),
        providerState: const {},
      );
      final additional = Environment(
        id: EnvironmentId('additional'),
        taskId: task.id,
        role: EnvironmentRole.additional,
        providerId: ProviderId('test.environment.a'),
        providerState: const {},
      );
      store.publishRestoredProject(
        project: Project(
          id: task.projectId,
          sourceLocation: Uri.parse('test:/project'),
        ),
        tasks: [task],
        environments: [primary, additional],
        sessions: [session, other],
        authorities: [(session.id, additional.id), (other.id, primary.id)],
        runRecords: const [],
      );
      final environmentRuntime = EnvironmentRuntime(
        store: store,
        registry: capabilities,
        providerForBinding: (binding) => GeneratedEnvironmentProvider(
          providerId: binding.provider.id,
          service: EnvironmentProviderServiceClient(binding.requestChannel),
        ),
        retainEnvironment: store.replaceEnvironment,
      );
      var presented = session;
      final captured = CapturedEnvironmentCapabilities(
        environmentRuntime: environmentRuntime,
        backends: bootstrap,
        session: presented,
      );
      final pending = captured.resolve(resourceInspectCapability);
      final connection = bootstrap.backends
          .singleWhere((b) => b.state == InstalledBackendState.active)
          .connection!;
      final control = connection.channelFor(
        connection.defaultConfigurationContext,
        'probe',
      );
      await control.request('restoring', {}).timeout(_bound);
      presented = other;
      final otherCapture = CapturedEnvironmentCapabilities(
        environmentRuntime: environmentRuntime,
        backends: bootstrap,
        session: presented,
      );
      await control.request('release', {});
      final selected = await pending.timeout(_bound);
      expect(selected.session, same(session));
      expect(selected.environment.id, additional.id);
      expect(selected.materialization.environment.id, additional.id);
      expect(
        selected.materialization.binding.provider.id,
        additional.providerId,
      );
      expect(selected.binding.provider.id.value, 'test.callable.a');
      expect(selected.validate, returnsNormally);
      expect(
        (await otherCapture.resolve(
          resourceInspectCapability,
        )).binding.provider.id.value,
        'test.callable.b',
      );
      expect(
        (await ResourceInspectorServiceClient(
          selected.binding.requestChannel,
        ).inspect(ResourceRef(uri: Uri.parse('test:/captured')))).providerLabel,
        'callable-a',
      );
      final requests =
          ((await control.request('snapshot', {}))! as Map)['requests'] as List;
      expect(
        requests.where(
          (request) => (request as Map)['hostInvocationContext'] != null,
        ),
        isEmpty,
      );
      expect(
        (await ResourceInspectorServiceClient(
          capabilities.resolve(resourceInspectCapability).requestChannel,
        ).inspect(ResourceRef(uri: Uri.parse('test:/healthy')))).providerLabel,
        'callable-b',
      );
    },
  );
}

Future<Map<Object?, Object?>> _probe(
  PluginBackendActivation activation,
  String method, [
  Map<String, Object?> payload = const {},
]) async =>
    (await activation.connection
            .channelFor(
              activation.connection.defaultConfigurationContext,
              'probe',
            )
            .request(method, payload)
            .timeout(_bound))!
        as Map<Object?, Object?>;

Future<List<Object?>> _query(
  PluginBackendActivation activation,
  EnvironmentId environment,
  String sql,
) async {
  final result = await _probe(activation, 'queryEnvironment', {
    'environmentId': environment.value,
    'sql': sql,
    'parameters': <String, Object?>{},
  });
  expect(result.containsKey('error'), isFalse, reason: '$result');
  return result['rows'] as List<Object?>;
}

Future<List<Object?>> _initialRows(
  PluginBackendActivation activation,
  EnvironmentId environment,
) => _query(
  activation,
  environment,
  'SELECT r.environment_id, r.task_id, t.project_id, r.value '
  'FROM fixture_initial_records r '
  'JOIN adele_product_environments e ON e.id = r.environment_id '
  'JOIN adele_product_tasks t ON t.id = r.task_id '
  'ORDER BY r.environment_id',
);

void _expectUnpublished(
  ProductLifecycleCoordinator lifecycle,
  Project project,
  Map<Object?, Object?> provisional, {
  int existingTasks = 0,
}) {
  final task = TaskId(provisional['taskId'] as String);
  final environment = EnvironmentId(provisional['environmentId'] as String);
  expect(lifecycle.store.tasksFor(project.id), hasLength(existingTasks));
  expect(lifecycle.store.task(task), isNull);
  expect(lifecycle.store.environment(environment), isNull);
  expect(lifecycle.store.primaryEnvironmentFor(task), isNull);
  expect(
    lifecycle.environmentRuntime.currentMaterialization(environment),
    isNull,
  );
}

/// Holds only the real AOT response, after transport settlement but before the
/// generated client and lifecycle can accept it. It never fabricates a result.
final class _EstablishmentGate implements AdeleRequestChannel {
  _EstablishmentGate(this.delegate);

  final AdeleRequestChannel delegate;
  final received = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final result = await delegate.request(method, payload);
    if (method == environmentProviderServiceEstablishId) {
      received.complete();
      await release.future;
    }
    return result;
  }
}

List<AdeleCapabilityExposure> _exposures({String prefix = 'test'}) => [
  // Forward references, shared Environment route, and different callable routes
  // deliberately make configuration-context equality the wrong eligibility test.
  _callable(
    '$prefix.callable.a',
    'callable-a',
    target: '$prefix.environment.a',
    rank: 2,
  ),
  _callable(
    '$prefix.callable.b',
    'callable-b',
    target: '$prefix.environment.b',
    rank: 100,
  ),
  _callable(
    '$prefix.callable.alternate',
    'callable-alternate',
    target: '$prefix.environment.a',
  ),
  _callable('$prefix.callable.unassociated', 'shared', rank: 50),
  _environment('$prefix.environment.a'),
  _environment('$prefix.environment.b'),
];

AdeleCapabilityExposure _environment(String id) => AdeleCapabilityExposure(
  providerId: id,
  capabilityId: environmentProviderCapability.id.value,
  capabilityMajorVersion: environmentProviderCapability.majorVersion,
  serviceId: environmentProviderServiceId,
  displayName: id,
  configurationContext: 'shared',
);

AdeleCapabilityExposure _callable(
  String id,
  String context, {
  String? target,
  int rank = 0,
  bool environmentBound = false,
}) => AdeleCapabilityExposure(
  providerId: id,
  capabilityId: resourceInspectCapability.id.value,
  capabilityMajorVersion: resourceInspectCapability.majorVersion,
  serviceId: resourceInspectorServiceId,
  displayName: id,
  configurationContext: context,
  rank: rank,
  environmentBound: environmentBound,
  association: target == null
      ? null
      : AdeleProviderAssociation(
          capabilityId: environmentProviderCapability.id.value,
          capabilityMajorVersion: environmentProviderCapability.majorVersion,
          providerId: target,
        ),
);
