import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';

import 'backend_connection.dart';

final class AdeleRequestChannelEndpoint implements CapabilityEndpoint {
  const AdeleRequestChannelEndpoint({
    required this.channel,
    required this.serviceId,
    required bool Function() isAvailable,
  }) : _isAvailable = isAvailable;

  final AdeleRequestChannel channel;
  final bool Function() _isAvailable;
  @override
  final String serviceId;
  @override
  bool get isAvailable => _isAvailable();
}

final class PluginCapabilityExposure {
  const PluginCapabilityExposure({
    required this.provider,
    required this.configurationContext,
    this.association,
  });

  final ProviderDescriptor provider;
  final ConfigurationContextId configurationContext;
  final AdeleProviderAssociation? association;
}

extension ProviderBindingRequestChannel on ProviderBinding {
  AdeleRequestChannel get requestChannel =>
      endpointAs<AdeleRequestChannelEndpoint>().channel;

  AdeleStreamChannel get streamChannel {
    final AdeleRequestChannel channel = requestChannel;
    if (channel is! AdeleStreamChannel) {
      throw StateError('The provider does not support generated streaming.');
    }
    return channel;
  }
}

final class PluginCapabilityActivation {
  PluginCapabilityActivation._({
    required this.connection,
    required this.registrations,
    required CapabilityRegistry registry,
    required Map<ProviderBinding, ProviderBinding> associations,
  }) : _registry = registry,
       _associations = Map.unmodifiable(associations);

  final PluginBackendConnection connection;
  final CapabilityRegistrationGroup registrations;
  final CapabilityRegistry _registry;
  final Map<ProviderBinding, ProviderBinding> _associations;
  Future<void>? _retiring;

  bool owns(ProviderBinding binding) {
    binding.endpointAs<CapabilityEndpoint>();
    return _retiring == null &&
        !connection.isClosed &&
        registrations.owns(binding);
  }

  /// Retires only this exact owned provider; the connection and siblings survive.
  /// Unlike executable access, retirement does not require a healthy endpoint.
  Future<void> retireProvider(ProviderBinding binding) {
    if (_retiring != null ||
        connection.isClosed ||
        !registrations.owns(binding)) {
      throw const InvalidProviderRegistration(
        'The provider is not owned by this live activation.',
      );
    }
    return registrations.retire(binding);
  }

  /// Returns an exact live sibling, or null for an unassociated/foreign binding.
  /// Retirement fails validation; semantic IDs never re-resolve the target.
  ProviderBinding? associationFor(ProviderBinding binding) {
    if (!owns(binding)) return null;
    for (final entry in _associations.entries) {
      if (entry.key.isSameRegistration(binding)) {
        if (!owns(entry.value)) return null;
        return entry.value;
      }
    }
    return null;
  }

  /// Uses registry ordering only among exact siblings of [associatedWith].
  ProviderBinding resolveAssociatedProvider(
    CapabilityKey capability, {
    required ProviderBinding associatedWith,
    ProviderId? providerId,
  }) {
    if (!owns(associatedWith)) {
      throw const InvalidProviderRegistration(
        'The associated binding is not owned by this activation.',
      );
    }
    final eligible = <ProviderBinding>[];
    for (final provider in _registry.providersFor(capability)) {
      final binding = _registry.resolve(capability, providerId: provider.id);
      for (final entry in _associations.entries) {
        if (entry.key.isSameRegistration(binding) &&
            entry.value.isSameRegistration(associatedWith) &&
            associationFor(binding) != null) {
          eligible.add(binding);
          break;
        }
      }
    }
    if (providerId != null) {
      for (final binding in eligible) {
        if (binding.provider.id == providerId) return binding;
      }
      throw ProviderUnavailable(
        capability: capability,
        providerId: providerId,
        availableProviderIds: eligible.map((binding) => binding.provider.id),
      );
    }
    if (eligible.isEmpty) throw CapabilityUnavailable(capability);
    return eligible.first;
  }

  static Future<PluginCapabilityActivation> registerAdvertised({
    required PluginBackendConnection connection,
    required CapabilityRegistry registry,
    void Function()? beforeRollback,
  }) => register(
    connection: connection,
    registry: registry,
    beforeRollback: beforeRollback,
    exposures: connection.capabilityExposures.map(
      (AdeleCapabilityExposure exposure) => PluginCapabilityExposure(
        provider: ProviderDescriptor(
          id: ProviderId(exposure.providerId),
          capability: CapabilityKey(
            id: CapabilityId(exposure.capabilityId),
            majorVersion: exposure.capabilityMajorVersion,
          ),
          pluginId: connection.pluginId,
          displayName: exposure.displayName,
          serviceId: exposure.serviceId,
          rank: exposure.rank,
        ),
        configurationContext: connection.configurationContext(
          exposure.configurationContext,
        ),
        association: exposure.association,
      ),
    ),
  );

  /// Failure rolls back only this attempt's registrations. A generation owner can
  /// supply [beforeRollback] to synchronously revoke before rollback cleanup.
  static Future<PluginCapabilityActivation> register({
    required PluginBackendConnection connection,
    required CapabilityRegistry registry,
    required Iterable<PluginCapabilityExposure> exposures,
    void Function()? beforeRollback,
  }) async {
    if (connection.isClosed) {
      throw InvalidProviderRegistration(
        'Plugin generation ${connection.pluginId} is inactive.',
      );
    }
    final CapabilityRegistrationGroup registrations =
        CapabilityRegistrationGroup();
    final acquired =
        <
          ({
            PluginCapabilityExposure exposure,
            CapabilityRegistration registration,
            ProviderBinding binding,
          })
        >[];
    final associations = <ProviderBinding, ProviderBinding>{};
    try {
      for (final PluginCapabilityExposure exposure in exposures) {
        final ProviderDescriptor provider = exposure.provider;
        if (provider.pluginId != connection.pluginId) {
          throw InvalidProviderRegistration(
            'Provider ${provider.id} belongs to ${provider.pluginId}, not '
            '${connection.pluginId}.',
          );
        }
        final registration = registry.register(
          provider: provider,
          endpoint: AdeleRequestChannelEndpoint(
            channel: connection.channelFor(
              exposure.configurationContext,
              provider.serviceId,
            ),
            serviceId: provider.serviceId,
            isAvailable: () => !connection.isClosed,
          ),
        );
        registrations.add(registration);
        final binding = registry.resolve(
          provider.capability,
          providerId: provider.id,
        );
        if (!registration.owns(binding)) {
          throw InvalidProviderRegistration(
            'Provider ${provider.id} registration was replaced.',
          );
        }
        acquired.add((
          exposure: exposure,
          registration: registration,
          binding: binding,
        ));
      }
      // Keep exposure iteration lazy, then allow forward sibling references.
      for (final source in acquired) {
        final declaration = source.exposure.association;
        if (declaration == null) continue;
        late final ProviderBinding target;
        try {
          target = registry.resolve(
            CapabilityKey(
              id: CapabilityId(declaration.capabilityId),
              majorVersion: declaration.capabilityMajorVersion,
            ),
            providerId: ProviderId(declaration.providerId),
          );
          source.binding.endpointAs<CapabilityEndpoint>();
          target.endpointAs<CapabilityEndpoint>();
        } on CapabilityException {
          throw InvalidProviderRegistration(
            'Provider ${source.binding.provider.id} association is unavailable.',
          );
        }
        final targets = acquired.where(
          (entry) => entry.registration.owns(target),
        );
        if (targets.isEmpty ||
            source.registration.owns(target) ||
            targets.single.exposure.association != null) {
          throw InvalidProviderRegistration(
            'Provider ${source.binding.provider.id} association must name an '
            'unassociated direct sibling owned by this activation.',
          );
        }
        associations[source.binding] = target;
      }
    } on Object {
      try {
        try {
          beforeRollback?.call();
        } finally {
          await registrations.close();
        }
      } on Object {
        // Rollback must finish, but cannot replace the original activation error.
      }
      rethrow;
    }
    final PluginCapabilityActivation activation = PluginCapabilityActivation._(
      connection: connection,
      registrations: registrations,
      registry: registry,
      associations: associations,
    );
    unawaited(
      connection.terminated
          .then((Object _) => activation.retire())
          .catchError((Object _) {}),
    );
    return activation;
  }

  Future<void> retire() {
    final retiring = _retiring;
    if (retiring != null) return retiring;
    final completion = Completer<void>();
    // Fence selection and join reentrant calls before synchronous observers run.
    _retiring = completion.future;
    completion.complete(registrations.close());
    return completion.future;
  }

  Future<void> close() async {
    connection.revokeInfrastructureContext();
    Object? firstError;
    StackTrace? firstStack;
    try {
      await retire();
    } catch (error, stack) {
      firstError = error;
      firstStack = stack;
    }
    try {
      if (!connection.isClosed) await connection.close();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    // Complete both obligations; a later shutdown error must not mask retirement.
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}
