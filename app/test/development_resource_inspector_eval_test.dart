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
    final ({String status, String token, String providerId}) defaultProvider =
        await bridge.resolveForTest();
    expect(defaultProvider.status, 'success');
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
        status: 'success',
        providerLabel: 'Alternate Inspector',
        summary: 'Alternate Inspector result',
      ),
    );
    final ({String status, String token, String providerId}) explicit =
        await bridge.resolveForTest(basicResourceInspectorProviderId.value);
    expect(explicit.status, 'success');
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
      expect((await empty.resolveForTest()).status, 'capabilityUnavailable');

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
      expect(
        (await bridge.resolveForTest(
          alternateResourceInspectorProviderId.value,
        )).status,
        'providerUnavailable',
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
    final ({String status, String token, String providerId}) binding =
        await bridge.resolveForTest();
    final Future<({String status, String providerLabel, String summary})>
    result = bridge.inspectForTest(binding.token, 'file:///tmp/example.txt');
    bridge.invalidate();
    pending.completeError(StateError('connection terminated'));

    expect(await result, (status: 'cancelled', providerLabel: '', summary: ''));
  });

  test(
    'provider disappearance after discovery is a structured outcome',
    () async {
      final CapabilityRegistry registry = CapabilityRegistry();
      final CapabilityRegistration basic = registry.register(
        provider: _provider(
          basicResourceInspectorProviderId,
          'Basic Inspector',
        ),
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

      expect(await bridge.providersForTest(), hasLength(2));
      await basic.close();
      expect(
        (await bridge.resolveForTest(
          basicResourceInspectorProviderId.value,
        )).status,
        'providerUnavailable',
      );
      final ({String status, String token, String providerId}) remaining =
          await bridge.resolveForTest(
            alternateResourceInspectorProviderId.value,
          );
      expect(remaining.status, 'success');
      expect(
        (await bridge.inspectForTest(
          remaining.token,
          'file:///tmp/example.txt',
        )).status,
        'success',
      );
    },
  );

  test('stale and unknown tokens never retarget restarted providers', () async {
    final CapabilityRegistry registry = CapabilityRegistry();
    final ProviderDescriptor provider = _provider(
      basicResourceInspectorProviderId,
      'Basic Inspector',
    );
    final CapabilityRegistration first = registry.register(
      provider: provider,
      endpoint: _endpoint(_InspectionChannel('First Generation')),
    );
    final ResourceInspectorEvalBridge bridge = ResourceInspectorEvalBridge(
      registry: registry,
    );
    final ({String status, String token, String providerId}) stale =
        await bridge.resolveForTest(basicResourceInspectorProviderId.value);
    await first.close();
    registry.register(
      provider: provider,
      endpoint: _endpoint(_InspectionChannel('Second Generation')),
    );

    expect(
      (await bridge.inspectForTest(
        stale.token,
        'file:///tmp/example.txt',
      )).status,
      'providerUnavailable',
    );
    expect(
      (await bridge.inspectForTest(
        'unknown',
        'file:///tmp/example.txt',
      )).status,
      'providerUnavailable',
    );
    final ({String status, String token, String providerId}) fresh =
        await bridge.resolveForTest(basicResourceInspectorProviderId.value);
    expect(
      (await bridge.inspectForTest(
        fresh.token,
        'file:///tmp/example.txt',
      )).providerLabel,
      'Second Generation',
    );
    bridge.invalidate();
    expect(
      (await bridge.inspectForTest(
        fresh.token,
        'file:///tmp/example.txt',
      )).status,
      'cancelled',
    );
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
