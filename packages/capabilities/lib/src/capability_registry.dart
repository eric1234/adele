import 'dart:async';

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

  /// Registration identity, not semantic identity or a resolution wrapper.
  bool isSameRegistration(ProviderBinding other) =>
      identical(_registration, other._registration);

  /// Observes retirement of this exact registration, synchronously after it is
  /// fenced. Returns an idempotent detach callback. Already-retired bindings
  /// reject subscription; endpoint availability alone is not retirement.
  void Function() onRetire(void Function() listener) {
    if (!_registration.active) {
      throw ProviderUnavailable(
        capability: provider.capability,
        providerId: provider.id,
        availableProviderIds: const <Object>[],
        stale: true,
      );
    }
    final token = Object();
    _registration.retirementListeners[token] = listener;
    return () => _registration.retirementListeners.remove(token);
  }

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

  /// Captures this occurrence without resolving a semantic ID again.
  ProviderBinding get binding => ProviderBinding._(_registration);

  /// Exact ownership survives retirement; callers must separately check liveness.
  bool owns(ProviderBinding binding) =>
      identical(_registration, binding._registration);

  Future<void> close() async {
    _registry._remove(_registration);
  }
}

final class CapabilityRegistrationGroup {
  final List<CapabilityRegistration> _registrations =
      <CapabilityRegistration>[];
  final Object _identity = Object();
  bool _closed = false;

  bool get isClosed => _closed;

  /// Number of registrations still retained for cleanup, not historical members.
  int get length => _registrations.length;

  bool owns(ProviderBinding binding) =>
      binding._registration.owners.contains(_identity);

  void add(CapabilityRegistration registration) {
    if (_closed) {
      throw const InvalidProviderRegistration(
        'A closed registration group cannot accept registrations.',
      );
    }
    if (registration.isClosed) {
      throw const InvalidProviderRegistration(
        'A retired registration cannot join a registration group.',
      );
    }
    if (!registration._registration.owners.add(_identity)) return;
    _registrations.add(registration);
    registration._registration.retirementListeners[_identity] = () {
      _registrations.remove(registration);
    };
  }

  /// Retires one exact live owned registration, not a same-ID replacement.
  /// Endpoint availability does not gate registration retirement.
  /// Its retirement listeners run synchronously before this method returns.
  Future<void> retire(ProviderBinding binding) {
    if (_closed) {
      throw const InvalidProviderRegistration(
        'The registration group is closed.',
      );
    }
    if (owns(binding)) {
      if (!binding._registration.active) {
        throw ProviderUnavailable(
          capability: binding.provider.capability,
          providerId: binding.provider.id,
          availableProviderIds: const <Object>[],
          stale: true,
        );
      }
      return _registrations.singleWhere((entry) => entry.owns(binding)).close();
    }
    throw const InvalidProviderRegistration(
      'The provider is not owned by this registration group.',
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final retiring = _registrations.reversed.toList();
    _registrations.clear();
    // Fence the complete set before invoking any reentrant retirement observer.
    final fenced = [
      for (final registration in retiring)
        if (registration._registry._fence(registration._registration))
          registration,
    ];
    Object? firstError;
    StackTrace? firstStack;
    for (final registration in fenced) {
      try {
        registration._registry._notifyRetired(registration._registration);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

final class CapabilityRegistry {
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// Asynchronous invalidations after registration or retirement, not replay.
  Stream<void> get changes => _changes.stream;

  final Map<CapabilityKey, Map<ProviderId, _ActiveRegistration>> _providers =
      <CapabilityKey, Map<ProviderId, _ActiveRegistration>>{};

  CapabilityRegistration register({
    required ProviderDescriptor provider,
    required CapabilityEndpoint endpoint,
  }) {
    validateRegistration(provider: provider, endpoint: endpoint);
    final capabilityProviders = _providers.putIfAbsent(
      provider.capability,
      () => <ProviderId, _ActiveRegistration>{},
    );
    final registration = _ActiveRegistration(provider, endpoint);
    capabilityProviders[provider.id] = registration;
    _changes.add(null);
    return CapabilityRegistration._(this, registration);
  }

  /// Dry-run the same checks as [register], including unavailable registrations.
  /// Only the exact current occurrences in [replacing] exempt a collision. This
  /// reserves nothing; callers must still register after retiring those members.
  void validateRegistration({
    required ProviderDescriptor provider,
    required CapabilityEndpoint endpoint,
    Iterable<ProviderBinding> replacing = const [],
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
    final current = _providers[provider.capability]?[provider.id];
    if (current != null &&
        !replacing.any(
          (binding) => identical(binding._registration, current),
        )) {
      throw DuplicateProviderRegistration(
        'Provider ${provider.id} is already active for '
        '${provider.capability}.',
      );
    }
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

  /// Resolve a configured identity, distinguishing a missing registration from
  /// an unhealthy endpoint. Never rank or substitute an available sibling.
  ProviderBinding resolveExact(
    CapabilityKey capability,
    ProviderId providerId,
  ) {
    final registration = _providers[capability]?[providerId];
    if (registration == null) {
      throw ProviderUnavailable(
        capability: capability,
        providerId: providerId,
        availableProviderIds: providersFor(capability).map((p) => p.id),
      );
    }
    final binding = ProviderBinding._(registration);
    binding.endpointAs<CapabilityEndpoint>();
    return binding;
  }

  ProviderBinding resolve(CapabilityKey capability, {ProviderId? providerId}) {
    final Map<ProviderId, _ActiveRegistration>? capabilityProviders =
        _providers[capability];
    final List<ProviderDescriptor> available = providersFor(capability);
    if (available.isEmpty) {
      _throwUnavailable(capability);
    }
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
    return ProviderBinding._(capabilityProviders![available.first.id]!);
  }

  Never _throwUnavailable(CapabilityKey capability) {
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

  void _remove(_ActiveRegistration registration) {
    if (_fence(registration)) _notifyRetired(registration);
  }

  bool _fence(_ActiveRegistration registration) {
    if (!registration.active) return false;
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
    _changes.add(null);
    return true;
  }

  void _notifyRetired(_ActiveRegistration registration) {
    final listeners = registration.retirementListeners.values.toList();
    registration.retirementListeners.clear();
    Object? firstError;
    StackTrace? firstStack;
    for (final listener in listeners) {
      try {
        listener();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

final class _ActiveRegistration {
  _ActiveRegistration(this.provider, this.endpoint);

  final ProviderDescriptor provider;
  final CapabilityEndpoint endpoint;
  bool active = true;
  final Set<Object> owners = {};
  final Map<Object, void Function()> retirementListeners = {};
}

int _compareProviders(ProviderDescriptor left, ProviderDescriptor right) {
  final int rank = right.rank.compareTo(left.rank);
  return rank != 0 ? rank : left.id.value.compareTo(right.id.value);
}
