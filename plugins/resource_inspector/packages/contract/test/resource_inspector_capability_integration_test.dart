import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';
import 'package:test/test.dart';

void main() {
  late Directory artifacts;
  late File hostArtifact;
  late File basicArtifact;
  late File alternateArtifact;
  late String dartaotruntime;

  setUpAll(() async {
    final String repository =
        Directory.current.parent.parent.parent.parent.path;
    artifacts = Directory(
      '$repository/.dart_tool/adele/integration/resource-inspector',
    )..createSync(recursive: true);
    final String dart = Platform.resolvedExecutable;
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    hostArtifact = File('${artifacts.path}/host.aot');
    basicArtifact = File('${artifacts.path}/basic.aot');
    alternateArtifact = File('${artifacts.path}/alternate.aot');
    await Future.wait(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/resource_inspector/packages/basic_backend/bin/resource_inspector_basic_backend.dart',
        basicArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/resource_inspector/packages/alternate_backend/bin/resource_inspector_alternate_backend.dart',
        alternateArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'discovers, resolves, invokes, contains, removes, and restarts providers',
    () async {
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      final int sharedHostProcess = host.processId;
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final PluginBackendConnection basic = await host.startPlugin(
        pluginId: 'dev.adele.resource-inspector.basic-plugin',
        artifactUri: basicArtifact.uri,
      );
      final PluginBackendConnection alternate = await host.startPlugin(
        pluginId: 'dev.adele.resource-inspector.alternate-plugin',
        artifactUri: alternateArtifact.uri,
      );
      final PluginCapabilityActivation basicActivation =
          await PluginCapabilityActivation.register(
            connection: basic,
            registry: registry,
            providers: <ProviderDescriptor>[
              _descriptor(
                id: basicResourceInspectorProviderId,
                pluginId: basic.pluginId,
                displayName: 'Basic Inspector',
              ),
            ],
          );
      final PluginCapabilityActivation alternateActivation =
          await PluginCapabilityActivation.register(
            connection: alternate,
            registry: registry,
            providers: <ProviderDescriptor>[
              _descriptor(
                id: alternateResourceInspectorProviderId,
                pluginId: alternate.pluginId,
                displayName: 'Alternate Inspector',
              ),
            ],
          );

      expect(host.processId, sharedHostProcess);
      expect(basic.pluginId, isNot(alternate.pluginId));
      expect(
        registry
            .providersFor(resourceInspectCapability)
            .map((ProviderDescriptor value) => value.id),
        <ProviderId>[
          alternateResourceInspectorProviderId,
          basicResourceInspectorProviderId,
        ],
      );
      final ResourceRef resource = ResourceRef(
        uri: Uri.parse('file:///tmp/example.txt'),
      );
      final ProviderBinding defaultBinding = registry.resolve(
        resourceInspectCapability,
      );
      expect(defaultBinding.provider.id, alternateResourceInspectorProviderId);
      expect(
        (await ResourceInspectorServiceClient(
          defaultBinding.requestChannel,
        ).inspect(resource)).providerLabel,
        'Alternate Inspector',
      );
      expect(
        (await _client(
          registry,
          basicResourceInspectorProviderId,
        ).inspect(resource)).providerLabel,
        'Basic Inspector',
      );
      expect(
        (await _client(
          registry,
          alternateResourceInspectorProviderId,
        ).inspect(resource)).providerLabel,
        'Alternate Inspector',
      );

      await expectLater(
        _client(
          registry,
          basicResourceInspectorProviderId,
        ).inspect(ResourceRef(uri: Uri.parse('fail:///example'))),
        throwsA(
          isA<ResourceInspectorFailure>().having(
            (ResourceInspectorFailure value) => value.code,
            'code',
            'basic_rejected',
          ),
        ),
      );
      expect(
        (await _client(
          registry,
          alternateResourceInspectorProviderId,
        ).inspect(resource)).providerLabel,
        'Alternate Inspector',
      );
      await expectLater(
        basic.request(
          resourceInspectorServiceInspectId,
          const <String, Object?>{'resource': 'malformed'},
        ),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (PluginRemoteFailure value) => value.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(
        (await _client(
          registry,
          basicResourceInspectorProviderId,
        ).inspect(resource)).providerLabel,
        'Basic Inspector',
      );

      final ProviderBinding staleBasic = registry.resolve(
        resourceInspectCapability,
        providerId: basicResourceInspectorProviderId,
      );
      await basicActivation.close();
      expect(registry.providersFor(resourceInspectCapability), hasLength(1));
      expect(
        (await ResourceInspectorServiceClient(
          registry.resolve(resourceInspectCapability).requestChannel,
        ).inspect(resource)).providerLabel,
        'Alternate Inspector',
      );
      final PluginBackendConnection restartedBasic = await host.startPlugin(
        pluginId: 'dev.adele.resource-inspector.basic-plugin',
        artifactUri: basicArtifact.uri,
      );
      final PluginCapabilityActivation restartedActivation =
          await PluginCapabilityActivation.register(
            connection: restartedBasic,
            registry: registry,
            providers: <ProviderDescriptor>[
              _descriptor(
                id: basicResourceInspectorProviderId,
                pluginId: restartedBasic.pluginId,
                displayName: 'Basic Inspector',
              ),
            ],
          );
      expect(
        () => staleBasic.requestChannel,
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(
        (await _client(
          registry,
          basicResourceInspectorProviderId,
        ).inspect(resource)).providerLabel,
        'Basic Inspector',
      );

      await restartedActivation.close();
      await alternateActivation.close();
      expect(registry.providersFor(resourceInspectCapability), isEmpty);
      expect(
        () => registry.resolve(resourceInspectCapability),
        throwsA(isA<CapabilityUnavailable>()),
      );
      await host.close();
      expect(host.isClosed, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

ProviderDescriptor _descriptor({
  required ProviderId id,
  required String pluginId,
  required String displayName,
}) => ProviderDescriptor(
  id: id,
  capability: resourceInspectCapability,
  pluginId: pluginId,
  displayName: displayName,
  serviceId: resourceInspectorServiceId,
);

ResourceInspectorService _client(
  CapabilityRegistry registry,
  ProviderId providerId,
) => ResourceInspectorServiceClient(
  registry
      .resolve(resourceInspectCapability, providerId: providerId)
      .requestChannel,
);

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}
