import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'application_plugin_bootstrap.dart';

typedef DiscoverModels =
    Future<ModelDiscoveryResult> Function(String providerId);

enum ModelDiscoveryStatus {
  success,
  unavailable,
  unsupported,
  ambiguous,
  failed,
}

/// One observation. Neither its data nor its liveness check grants a route.
final class ModelDiscoveryResult {
  const ModelDiscoveryResult._(
    this.status, {
    this.snapshot,
    this.isCurrent,
    this.changes,
  });

  const ModelDiscoveryResult.success(
    ModelCatalogSnapshot snapshot, {
    required bool Function() isCurrent,
    Stream<void>? changes,
  }) : this._(
         ModelDiscoveryStatus.success,
         snapshot: snapshot,
         isCurrent: isCurrent,
         changes: changes,
       );

  const ModelDiscoveryResult.unavailable()
    : this._(ModelDiscoveryStatus.unavailable);
  const ModelDiscoveryResult.unsupported()
    : this._(ModelDiscoveryStatus.unsupported);
  const ModelDiscoveryResult.ambiguous()
    : this._(ModelDiscoveryStatus.ambiguous);
  const ModelDiscoveryResult.failed() : this._(ModelDiscoveryStatus.failed);

  final ModelDiscoveryStatus status;
  final ModelCatalogSnapshot? snapshot;
  final bool Function()? isCurrent;
  final Stream<void>? changes;
}

/// Discovers through a unique catalog explicitly associated with the selected
/// inference registration. Never infers association from IDs, context or rank.
Future<ModelDiscoveryResult> discoverModelsForProvider(
  ApplicationPluginBootstrap bootstrap,
  String providerId,
) async {
  final registry = bootstrap.registry;
  try {
    final inference = registry.resolveExact(
      modelProviderCapability,
      ProviderId(providerId),
    );
    if (inference.provider.serviceId != modelProviderServiceId) {
      return const ModelDiscoveryResult.unavailable();
    }
    final owner = bootstrap.backendForProvider(inference);
    if (owner == null) return const ModelDiscoveryResult.unavailable();

    List<ProviderBinding> associatedCatalogs() {
      owner.validateProviderOwnership(inference);
      final matches = <ProviderBinding>[];
      for (final provider in registry.providersFor(modelCatalogCapability)) {
        if (provider.serviceId != modelCatalogServiceId) continue;
        try {
          final catalog = registry.resolveExact(
            modelCatalogCapability,
            provider.id,
          );
          if (owner.associationFor(catalog)?.isSameRegistration(inference) ==
              true) {
            matches.add(catalog);
          }
        } on ProviderUnavailable {
          // A catalog can outlive its own target. It cannot qualify for this one.
          continue;
        } on ProviderEndpointUnavailable {
          continue;
        }
      }
      return matches;
    }

    final matches = associatedCatalogs();
    if (matches.isEmpty) return const ModelDiscoveryResult.unavailable();
    if (matches.length != 1) return const ModelDiscoveryResult.ambiguous();
    final catalog = matches.single;

    ModelDiscoveryResult? invalidation() {
      try {
        // Recheck the original pair before checking for newly ambiguous choices.
        if (owner.associationFor(catalog)?.isSameRegistration(inference) !=
            true) {
          return const ModelDiscoveryResult.unavailable();
        }
        final current = associatedCatalogs();
        if (current.length > 1) return const ModelDiscoveryResult.ambiguous();
        if (current.length == 1 && current.single.isSameRegistration(catalog)) {
          return null;
        }
      } catch (_) {
        // Registration or generation retired; never migrate the capture.
      }
      return const ModelDiscoveryResult.unavailable();
    }

    try {
      final snapshot = await ModelCatalogServiceClient(
        catalog.requestChannel,
      ).listModels();
      return invalidation() ??
          ModelDiscoveryResult.success(
            snapshot,
            isCurrent: () => invalidation() == null,
            changes: registry.changes,
          );
    } catch (error) {
      // Classify known semantic codes only. Never surface provider diagnostics.
      return invalidation() ??
          switch (error) {
            ModelCatalogFailure(code: 'unsupported_discovery') =>
              const ModelDiscoveryResult.unsupported(),
            ModelCatalogFailure(code: 'unavailable') =>
              const ModelDiscoveryResult.unavailable(),
            _ => const ModelDiscoveryResult.failed(),
          };
    }
  } catch (_) {
    return const ModelDiscoveryResult.unavailable();
  }
}
