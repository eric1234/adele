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
    return CapturedEnvironmentCapabilities._(
      environmentRuntime: environmentRuntime,
      session: session,
      resolveProvider: backends.resolveEnvironmentCapabilityProvider,
      captureEligibility: (binding, environmentBinding) {
        final owner = backends.backendForProvider(binding);
        final environmentOwner = backends.backendForProvider(
          environmentBinding,
        );
        if (owner == null || environmentOwner == null) {
          throw StateError(
            'The selected providers require live backend owners.',
          );
        }
        final independent = owner.isEnvironmentBound(binding);
        // Capture owners once. Validation never searches for another activation.
        return () {
          owner.validateProviderOwnership(binding);
          environmentOwner.validateProviderOwnership(environmentBinding);
          if (independent) {
            if (!owner.isEnvironmentBound(binding)) {
              throw StateError(
                'The Environment-bound declaration has retired.',
              );
            }
          } else {
            if (!identical(owner, environmentOwner)) {
              throw StateError(
                'Associated providers require the same backend.',
              );
            }
            _validateAssociation(
              binding,
              environmentBinding,
              owner.associationFor,
            );
          }
        };
      },
    );
  }

  /// Trusted host composition seam; both callbacks must retain exact bindings.
  CapturedEnvironmentCapabilities.withResolvers({
    required EnvironmentRuntime environmentRuntime,
    required Session session,
    required AssociatedEnvironmentProviderResolver resolveAssociatedProvider,
    required ProviderBinding? Function(ProviderBinding) associationFor,
  }) : this._(
         environmentRuntime: environmentRuntime,
         session: session,
         resolveProvider: resolveAssociatedProvider,
         captureEligibility: (binding, environmentBinding) =>
             () => _validateAssociation(
               binding,
               environmentBinding,
               associationFor,
             ),
       );

  CapturedEnvironmentCapabilities._({
    required EnvironmentRuntime environmentRuntime,
    required Session session,
    required AssociatedEnvironmentProviderResolver resolveProvider,
    required void Function() Function(ProviderBinding, ProviderBinding)
    captureEligibility,
  }) : _captured = CapturedSessionEnvironment(
         session: session,
         environmentRuntime: environmentRuntime,
       ),
       _resolveProvider = resolveProvider,
       _captureEligibility = captureEligibility;

  final CapturedSessionEnvironment _captured;
  final AssociatedEnvironmentProviderResolver _resolveProvider;
  final void Function() Function(ProviderBinding, ProviderBinding)
  _captureEligibility;
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
    final binding = _resolveProvider(
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
      _captureEligibility(binding, materialization.binding),
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
    this._validateEligibility,
  );

  final CapturedSessionEnvironment _captured;
  final EnvironmentMaterialization materialization;
  final ProviderBinding binding;
  final void Function() _validateEligibility;

  Session get session => _captured.session;
  Environment get environment => _captured.environment;

  void validate() {
    _captured.validate();
    materialization.validateBinding();
    binding.endpointAs<CapabilityEndpoint>();
    _validateEligibility();
  }
}

void _validateAssociation(
  ProviderBinding binding,
  ProviderBinding environmentBinding,
  ProviderBinding? Function(ProviderBinding) associationFor,
) {
  final associated = associationFor(binding);
  if (associated == null ||
      !associated.isSameRegistration(environmentBinding)) {
    throw ProviderUnavailable(
      capability: binding.provider.capability,
      providerId: binding.provider.id,
      availableProviderIds: const [],
    );
  }
  associated.endpointAs<CapabilityEndpoint>();
}
