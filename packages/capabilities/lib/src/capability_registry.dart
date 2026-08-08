import 'package:adele_plugin_api/adele_plugin_api.dart';

import 'capability_error.dart';
import 'capability_id.dart';

final class CapabilityKey {
  CapabilityKey({required this.id, required this.majorVersion}) {
    if (majorVersion <= 0) {
      throw InvalidCapabilityVersion(
        'Capability major version must be positive: $majorVersion.',
      );
    }
  }

  final CapabilityId id;
  final int majorVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CapabilityKey &&
          other.id == id &&
          other.majorVersion == majorVersion;

  @override
  int get hashCode => Object.hash(id, majorVersion);

  @override
  String toString() => '$id / $majorVersion';
}

final class ProviderId {
  factory ProviderId(String value) {
    try {
      validateAdelePublicId(value, label: 'provider ID');
    } on FormatException catch (error) {
      throw InvalidCapabilityIdentity(error.message);
    }
    return ProviderId._(value);
  }

  const ProviderId._(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProviderId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ProviderDescriptor {
  ProviderDescriptor({
    required this.id,
    required this.capability,
    required this.pluginId,
    required this.displayName,
    required this.serviceId,
    this.rank = 0,
  }) {
    PluginId(pluginId);
    if (displayName.trim().isEmpty) {
      throw const InvalidProviderRegistration(
        'Provider display name must not be empty.',
      );
    }
    if (serviceId.trim().isEmpty) {
      throw const InvalidProviderRegistration(
        'Provider service ID must not be empty.',
      );
    }
  }

  final ProviderId id;
  final CapabilityKey capability;
  final String pluginId;
  final String displayName;
  final String serviceId;
  final int rank;
}

abstract interface class CapabilityEndpoint {
  String get serviceId;
  bool get isAvailable;
}

final class ProviderBinding {
  ProviderBinding._(this._registration);

  final _ActiveRegistration _registration;

  ProviderDescriptor get provider => _registration.provider;

  T endpointAs<T extends CapabilityEndpoint>() {
    final CapabilityEndpoint endpoint = _registration.endpoint;
    if (!_registration.active) {
      throw ProviderUnavailable(
        capability: provider.capability,
        providerId: provider.id,
        availableProviderIds: const <Object>[],
        stale: true,
      );
    }
    if (!endpoint.isAvailable) {
      throw ProviderEndpointUnavailable(provider.id);
    }
    if (endpoint is! T) {
      throw InvalidProviderRegistration(
        'Provider ${provider.id} endpoint has an unexpected type.',
      );
    }
    return endpoint;
  }
}

final class CapabilityRegistration {
  CapabilityRegistration._(this._registry, this._registration);

  final CapabilityRegistry _registry;
  final _ActiveRegistration _registration;

  bool get isClosed => !_registration.active;

  Future<void> close() async {
    _registry._remove(_registration);
  }
}

final class CapabilityRegistrationGroup {
  final List<CapabilityRegistration> _registrations =
      <CapabilityRegistration>[];
  bool _closed = false;

  void add(CapabilityRegistration registration) {
    if (_closed) {
      throw const InvalidProviderRegistration(
        'A closed registration group cannot accept registrations.',
      );
    }
    _registrations.add(registration);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final CapabilityRegistration registration in _registrations.reversed) {
      await registration.close();
    }
  }
}

final class CapabilityRegistry {
  final Map<CapabilityKey, Map<ProviderId, _ActiveRegistration>> _providers =
      <CapabilityKey, Map<ProviderId, _ActiveRegistration>>{};

  CapabilityRegistration register({
    required ProviderDescriptor provider,
    required CapabilityEndpoint endpoint,
  }) {
    if (!endpoint.isAvailable) {
      throw InvalidProviderRegistration(
        'Provider ${provider.id} endpoint is unavailable.',
      );
    }
    if (provider.serviceId != endpoint.serviceId) {
      throw CapabilityContractMismatch(
        providerId: provider.id,
        expectedServiceId: provider.serviceId,
        actualServiceId: endpoint.serviceId,
      );
    }
    final Map<ProviderId, _ActiveRegistration> capabilityProviders = _providers
        .putIfAbsent(
          provider.capability,
          () => <ProviderId, _ActiveRegistration>{},
        );
    if (capabilityProviders.containsKey(provider.id)) {
      throw DuplicateProviderRegistration(
        'Provider ${provider.id} is already active for '
        '${provider.capability}.',
      );
    }
    final _ActiveRegistration registration = _ActiveRegistration(
      provider,
      endpoint,
    );
    capabilityProviders[provider.id] = registration;
    return CapabilityRegistration._(this, registration);
  }

  List<ProviderDescriptor> providersFor(CapabilityKey capability) {
    final List<ProviderDescriptor> providers =
        (_providers[capability]?.values ?? const <_ActiveRegistration>[])
            .where(
              (_ActiveRegistration registration) =>
                  registration.active && registration.endpoint.isAvailable,
            )
            .map((_ActiveRegistration registration) => registration.provider)
            .toList();
    providers.sort(_compareProviders);
    return List<ProviderDescriptor>.unmodifiable(providers);
  }

  ProviderBinding resolve(CapabilityKey capability, {ProviderId? providerId}) {
    final Map<ProviderId, _ActiveRegistration>? capabilityProviders =
        _providers[capability];
    final List<ProviderDescriptor> available = providersFor(capability);
    if (providerId != null) {
      final _ActiveRegistration? registration =
          capabilityProviders?[providerId];
      if (registration == null ||
          !registration.active ||
          !registration.endpoint.isAvailable) {
        throw ProviderUnavailable(
          capability: capability,
          providerId: providerId,
          availableProviderIds: available.map(
            (ProviderDescriptor provider) => provider.id,
          ),
        );
      }
      return ProviderBinding._(registration);
    }
    if (available.isEmpty) {
      final List<int> availableMajors =
          _providers.keys
              .where(
                (CapabilityKey key) =>
                    key.id == capability.id && providersFor(key).isNotEmpty,
              )
              .map((CapabilityKey key) => key.majorVersion)
              .toSet()
              .toList()
            ..sort();
      if (availableMajors.isNotEmpty) {
        throw CapabilityVersionUnavailable(
          capabilityId: capability.id,
          requestedMajorVersion: capability.majorVersion,
          availableMajorVersions: availableMajors,
        );
      }
      throw CapabilityUnavailable(capability);
    }
    return ProviderBinding._(capabilityProviders![available.first.id]!);
  }

  void _remove(_ActiveRegistration registration) {
    if (!registration.active) return;
    registration.active = false;
    final Map<ProviderId, _ActiveRegistration>? capabilityProviders =
        _providers[registration.provider.capability];
    if (identical(
      capabilityProviders?[registration.provider.id],
      registration,
    )) {
      capabilityProviders!.remove(registration.provider.id);
      if (capabilityProviders.isEmpty) {
        _providers.remove(registration.provider.capability);
      }
    }
  }
}

final class _ActiveRegistration {
  _ActiveRegistration(this.provider, this.endpoint);

  final ProviderDescriptor provider;
  final CapabilityEndpoint endpoint;
  bool active = true;
}

int _compareProviders(ProviderDescriptor left, ProviderDescriptor right) {
  final int rank = right.rank.compareTo(left.rank);
  return rank != 0 ? rank : left.id.value.compareTo(right.id.value);
}
