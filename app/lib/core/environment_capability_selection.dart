import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_product/adele_product.dart';

import 'application_plugin_bootstrap.dart';
import 'product_lifecycle.dart';

typedef AssociatedEnvironmentProviderResolver =
    ProviderBinding Function(
      CapabilityKey capability, {
      required ProviderBinding associatedWith,
      ProviderId? providerId,
    });

/// Host-only eligibility selection, not a plugin authority grant or discovery API.
final class CapturedEnvironmentCapabilities {
  factory CapturedEnvironmentCapabilities({
    required EnvironmentRuntime environmentRuntime,
    required ApplicationPluginBootstrap backends,
    required Session session,
  }) {
    InstalledBackendActivation? owner;
    return CapturedEnvironmentCapabilities.withResolvers(
      environmentRuntime: environmentRuntime,
      session: session,
      resolveAssociatedProvider:
          (capability, {required associatedWith, providerId}) {
            final backend = owner ??= backends.backendForProvider(
              associatedWith,
            );
            if (backend == null) {
              if (providerId == null) throw CapabilityUnavailable(capability);
              throw ProviderUnavailable(
                capability: capability,
                providerId: providerId,
                availableProviderIds: const [],
              );
            }
            return backend.resolveAssociatedProvider(
              capability,
              associatedWith: associatedWith,
              providerId: providerId,
            );
          },
      associationFor: (binding) => owner!.associationFor(binding),
    );
  }

  /// Trusted host composition seam; both callbacks must retain exact bindings.
  CapturedEnvironmentCapabilities.withResolvers({
    required EnvironmentRuntime environmentRuntime,
    required Session session,
    required AssociatedEnvironmentProviderResolver resolveAssociatedProvider,
    required ProviderBinding? Function(ProviderBinding) associationFor,
  }) : _captured = CapturedSessionEnvironment(
         session: session,
         environmentRuntime: environmentRuntime,
       ),
       _resolveAssociatedProvider = resolveAssociatedProvider,
       _associationFor = associationFor;

  final CapturedSessionEnvironment _captured;
  final AssociatedEnvironmentProviderResolver _resolveAssociatedProvider;
  final ProviderBinding? Function(ProviderBinding) _associationFor;
  final _selections =
      <(CapabilityKey, ProviderId?), Future<EnvironmentCapabilitySelection>>{};

  Session get session => _captured.session;
  Environment get environment => _captured.environment;

  Future<EnvironmentCapabilitySelection> resolve(
    CapabilityKey capability, {
    ProviderId? providerId,
  }) async {
    final selection = await _selections.putIfAbsent((
      capability,
      providerId,
    ), () => _resolve(capability, providerId));
    selection.validate();
    return selection;
  }

  Future<EnvironmentCapabilitySelection> _resolve(
    CapabilityKey capability,
    ProviderId? providerId,
  ) async {
    final materialization = await _captured.materialize();
    final binding = _resolveAssociatedProvider(
      capability,
      associatedWith: materialization.binding,
      providerId: providerId,
    );
    if (binding.provider.capability != capability ||
        (providerId != null && binding.provider.id != providerId)) {
      throw const InvalidProviderRegistration(
        'Environment selection returned a different capability or provider.',
      );
    }
    final selection = EnvironmentCapabilitySelection._(
      _captured,
      materialization,
      binding,
      _associationFor,
    );
    selection.validate();
    return selection;
  }
}

/// A callable and its actual Environment materialization, both generation-bound.
final class EnvironmentCapabilitySelection {
  EnvironmentCapabilitySelection._(
    this._captured,
    this.materialization,
    this.binding,
    this._associationFor,
  );

  final CapturedSessionEnvironment _captured;
  final EnvironmentMaterialization materialization;
  final ProviderBinding binding;
  final ProviderBinding? Function(ProviderBinding) _associationFor;

  Session get session => _captured.session;
  Environment get environment => _captured.environment;

  void validate() {
    materialization.validateBinding();
    binding.endpointAs<CapabilityEndpoint>();
    final associated = _associationFor(binding);
    if (associated == null ||
        !associated.isSameRegistration(materialization.binding)) {
      throw ProviderUnavailable(
        capability: binding.provider.capability,
        providerId: binding.provider.id,
        availableProviderIds: const [],
      );
    }
    associated.endpointAs<CapabilityEndpoint>();
  }
}
