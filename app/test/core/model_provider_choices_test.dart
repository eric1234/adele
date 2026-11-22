import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_provider_choices.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'only current inference registrations contribute picker metadata',
    () async {
      final registry = CapabilityRegistry();
      final model = _Endpoint(modelProviderServiceId);
      final catalog = _Endpoint(modelCatalogServiceId);
      CapabilityRegistration register(
        String id,
        CapabilityKey key,
        _Endpoint endpoint, {
        int rank = 0,
        String name = 'Local',
      }) => registry.register(
        provider: ProviderDescriptor(
          id: ProviderId(id),
          capability: key,
          pluginId: 'org.example.plugin',
          displayName: name,
          serviceId: endpoint.serviceId,
          rank: rank,
        ),
        endpoint: endpoint,
      );
      final v2 = CapabilityKey(id: modelProviderCapability.id, majorVersion: 2);
      register('org.example.catalog', modelCatalogCapability, catalog);
      register('org.example.v2', v2, model);
      register('org.example.mismatch', modelProviderCapability, catalog);
      expect(modelProviderChoices(registry), isEmpty);

      final old = register('test.z9', modelProviderCapability, model, rank: 1);
      register('test.a1', modelProviderCapability, model);
      expect(modelProviderChoices(registry).map((p) => p.id), [
        'test.z9',
        'test.a1',
      ]);
      await old.close();
      expect(modelProviderChoices(registry).single.id, 'test.a1');
      register(
        'test.z9',
        modelProviderCapability,
        model,
        rank: 1,
        name: 'Replacement',
      );
      expect(modelProviderChoices(registry).first, (
        id: 'test.z9',
        displayName: 'Replacement',
        pluginId: 'org.example.plugin',
      ));
      model.isAvailable = false;
      expect(modelProviderChoices(registry), isEmpty);
    },
  );
}

final class _Endpoint implements CapabilityEndpoint {
  _Endpoint(this.serviceId);

  @override
  final String serviceId;
  @override
  bool isAvailable = true;
}
