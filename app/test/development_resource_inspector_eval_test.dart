import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/development/resource_inspector/resource_inspector_eval_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

void main() {
  test('interpreted consumer owns capability operation sequencing', () {
    final String source = File(
      '../plugins/resource_inspector/packages/consumer/lib/resource_inspector_consumer.dart',
    ).readAsStringSync();
    expect(source, contains('resourceInspectorProviders()'));
    expect(source, contains('resolveResourceInspector()'));
    expect(source, contains('resolveResourceInspector('));
    expect(source, contains('inspectResource('));
    expect(source, isNot(contains('loadCapabilityDemo')));
  });

  test('plugin-facing API exposes capability semantics separately', () async {
    final CapabilityRegistry registry = CapabilityRegistry();
    registry.register(
      provider: _provider(basicResourceInspectorProviderId, 'Basic Inspector'),
      endpoint: _endpoint(_InspectionChannel('Basic Inspector')),
    );
    registry.register(
      provider: _provider(
        alternateResourceInspectorProviderId,
        'Alternate Inspector',
      ),
      endpoint: _endpoint(_InspectionChannel('Alternate Inspector')),
    );
    final ResourceInspectorEvalBridge bridge = ResourceInspectorEvalBridge(
      registry: registry,
    );

    expect(await bridge.providersForTest(), <({String id, String displayName})>[
      (
        id: 'dev.adele.resource-inspector.alternate',
        displayName: 'Alternate Inspector',
      ),
      (
        id: 'dev.adele.resource-inspector.basic',
        displayName: 'Basic Inspector',
      ),
    ]);
    final ({String token, String providerId}) defaultProvider = await bridge
        .resolveForTest();
    expect(
      defaultProvider.providerId,
      'dev.adele.resource-inspector.alternate',
    );
    expect(
      await bridge.inspectForTest(
        defaultProvider.token,
        'file:///tmp/example.txt',
      ),
      (
        providerLabel: 'Alternate Inspector',
        summary: 'Alternate Inspector result',
        cancelled: false,
      ),
    );
    final ({String token, String providerId}) explicit = await bridge
        .resolveForTest(basicResourceInspectorProviderId.value);
    expect(explicit.providerId, basicResourceInspectorProviderId.value);
    expect(
      (await bridge.inspectForTest(
        explicit.token,
        'file:///tmp/example.txt',
      )).providerLabel,
      'Basic Inspector',
    );
  });

  test(
    'plugin-facing API reports capability and provider unavailable',
    () async {
      final ResourceInspectorEvalBridge empty = ResourceInspectorEvalBridge(
        registry: CapabilityRegistry(),
      );
      expect(await empty.providersForTest(), isEmpty);
      await expectLater(
        empty.resolveForTest(),
        throwsA(isA<CapabilityUnavailable>()),
      );

      final CapabilityRegistry registry = CapabilityRegistry();
      registry.register(
        provider: _provider(
          basicResourceInspectorProviderId,
          'Basic Inspector',
        ),
        endpoint: _endpoint(_InspectionChannel('Basic Inspector')),
      );
      final ResourceInspectorEvalBridge bridge = ResourceInspectorEvalBridge(
        registry: registry,
      );
      await expectLater(
        bridge.resolveForTest(alternateResourceInspectorProviderId.value),
        throwsA(isA<ProviderUnavailable>()),
      );
    },
  );

  test('invalidation suppresses a pending provider teardown failure', () async {
    final Completer<Object?> pending = Completer<Object?>();
    final CapabilityRegistry registry = CapabilityRegistry();
    registry.register(
      provider: _provider(basicResourceInspectorProviderId, 'Basic Inspector'),
      endpoint: _endpoint(_PendingChannel(pending)),
    );
    final ResourceInspectorEvalBridge bridge = ResourceInspectorEvalBridge(
      registry: registry,
    );
    final ({String token, String providerId}) binding = await bridge
        .resolveForTest();
    final Future<({String providerLabel, String summary, bool cancelled})>
    result = bridge.inspectForTest(binding.token, 'file:///tmp/example.txt');
    bridge.invalidate();
    pending.completeError(StateError('connection terminated'));

    expect(await result, (providerLabel: '', summary: '', cancelled: true));
  });
}

ProviderDescriptor _provider(ProviderId id, String displayName) =>
    ProviderDescriptor(
      id: id,
      capability: resourceInspectCapability,
      pluginId: 'dev.adele.test-plugin',
      displayName: displayName,
      serviceId: resourceInspectorServiceId,
    );

AdeleRequestChannelEndpoint _endpoint(AdeleRequestChannel channel) =>
    AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: resourceInspectorServiceId,
      isAvailable: () => true,
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

final class _PendingChannel implements AdeleRequestChannel {
  const _PendingChannel(this.pending);

  final Completer<Object?> pending;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      pending.future;
}
