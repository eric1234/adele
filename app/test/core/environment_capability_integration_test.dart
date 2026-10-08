@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

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
  }) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: probeArtifact.uri,
      arguments: [
        jsonEncode({
          'exposures': (exposures ?? _exposures())
              .map((e) => e.toMap())
              .toList(),
        }),
      ],
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
}) => AdeleCapabilityExposure(
  providerId: id,
  capabilityId: resourceInspectCapability.id.value,
  capabilityMajorVersion: resourceInspectCapability.majorVersion,
  serviceId: resourceInspectorServiceId,
  displayName: id,
  configurationContext: context,
  rank: rank,
  association: target == null
      ? null
      : AdeleProviderAssociation(
          capabilityId: environmentProviderCapability.id.value,
          capabilityMajorVersion: environmentProviderCapability.majorVersion,
          providerId: target,
        ),
);
