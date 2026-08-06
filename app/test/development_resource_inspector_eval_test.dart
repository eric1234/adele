import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/resource_inspector/resource_inspector_eval_bridge.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

void main() {
  test('plugin-facing bridge discovers and invokes selected providers', () async {
    final CapabilityRegistry registry = CapabilityRegistry();
    registry.register(
      provider: _provider(basicResourceInspectorProviderId, 'Basic Inspector'),
      endpoint: AdeleRequestChannelEndpoint(
        channel: _InspectionChannel('Basic Inspector'),
        serviceId: resourceInspectorServiceId,
        isAvailable: () => true,
      ),
    );
    registry.register(
      provider: _provider(
        alternateResourceInspectorProviderId,
        'Alternate Inspector',
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: _InspectionChannel('Alternate Inspector'),
        serviceId: resourceInspectorServiceId,
        isAvailable: () => true,
      ),
    );
    final ResourceInspectorEvalBridge bridge = ResourceInspectorEvalBridge(
      registry: registry,
      resource: ResourceRef(uri: Uri.parse('file:///tmp/example.txt')),
    );
    expect(await bridge.loadLinesForTest(), <String>[
      'Provider: dev.adele.resource_inspector.alternate | Alternate Inspector',
      'Provider: dev.adele.resource_inspector.basic | Basic Inspector',
      'Default: dev.adele.resource_inspector.alternate',
      'Default result: Alternate Inspector: Alternate Inspector result',
      'Explicit dev.adele.resource_inspector.alternate: Alternate Inspector: Alternate Inspector result',
      'Explicit dev.adele.resource_inspector.basic: Basic Inspector: Basic Inspector result',
    ]);
  });

  test('plugin-facing bridge reports structured unavailable state', () async {
    final ResourceInspectorEvalBridge bridge = ResourceInspectorEvalBridge(
      registry: CapabilityRegistry(),
      resource: ResourceRef(uri: Uri.parse('file:///tmp/example.txt')),
    );
    expect(await bridge.loadLinesForTest(), <String>[
      'Unavailable: no provider',
    ]);
  });
}

ProviderDescriptor _provider(ProviderId id, String displayName) =>
    ProviderDescriptor(
      id: id,
      capability: resourceInspectCapability,
      pluginId: 'dev.adele.test_plugin',
      displayName: displayName,
      serviceId: resourceInspectorServiceId,
    );

final class _InspectionChannel implements AdeleRequestChannel {
  const _InspectionChannel(this.label);

  final String label;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      <String, Object?>{
        'resource': payload['resource'],
        'providerLabel': label,
        'summary': '$label result',
      };
}
