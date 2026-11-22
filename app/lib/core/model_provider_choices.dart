import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_model_provider/adele_model_provider.dart';

/// Presentation metadata only: no registration, channel or execution binding.
typedef ModelProviderChoice = ({
  String id,
  String displayName,
  String pluginId,
});

typedef DiscoverModelProviders = List<ModelProviderChoice>? Function();

List<ModelProviderChoice> modelProviderChoices(CapabilityRegistry registry) => [
  for (final provider in registry.providersFor(modelProviderCapability))
    if (provider.serviceId == modelProviderServiceId)
      (
        id: provider.id.value,
        displayName: provider.displayName,
        pluginId: provider.pluginId,
      ),
];
