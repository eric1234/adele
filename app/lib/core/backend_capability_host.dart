import 'dart:convert';
import 'dart:math';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/capability_consumer.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// One backend generation's explicitly declared, context-free peer access.
/// The owner lookup must search actual advertised activations, never plugin IDs.
final class BackendCapabilityHost implements BackendCapabilityConsumerService {
  BackendCapabilityHost({
    required this.connection,
    required CapabilityRegistry registry,
    required Iterable<CapabilityKey> allowedCapabilities,
    required PluginBackendActivation? Function(ProviderBinding)
    ownerForProvider,
  }) : _registry = registry,
       _allowedCapabilities = Set.unmodifiable(allowedCapabilities),
       _ownerForProvider = ownerForProvider {
    _detachRevocation = connection.onInfrastructureRevoked(close);
  }

  static const int maxHandles = 64;
  static final Random _random = Random.secure();

  final PluginBackendConnection connection;
  final CapabilityRegistry _registry;
  final Set<CapabilityKey> _allowedCapabilities;
  final PluginBackendActivation? Function(ProviderBinding) _ownerForProvider;
  final String _scope = base64UrlEncode(
    List<int>.generate(32, (_) => _random.nextInt(256)),
  );
  final Map<String, _CapabilityAccess> _handles = {};
  int _nextHandle = 0;
  bool _closed = false;
  void Function()? _detachRevocation;

  int get retainedHandleCount => _handles.length;

  CapabilityKey _authorize(String id, int majorVersion) {
    _validate();
    final key = CapabilityKey(id: CapabilityId(id), majorVersion: majorVersion);
    if (!_allowedCapabilities.contains(key)) {
      throw StateError('Capability consumption is not declared.');
    }
    return key;
  }

  void _validate() {
    if (_closed) throw StateError('Capability consumer is retired.');
    connection.validateInfrastructureContext();
  }

  PluginBackendActivation? _owner(ProviderBinding binding) {
    final owner = _ownerForProvider(binding);
    if (owner == null ||
        identical(owner.connection, connection) ||
        !owner.ownsProvider(binding)) {
      return null;
    }
    // Ownership proves this is the activation's actual configured route, not a
    // copied descriptor, matching PluginId, or caller-created channel endpoint.
    binding.requestChannel;
    return owner;
  }

  @override
  Future<List<BackendCapabilityProvider>> discover(
    String capabilityId,
    int majorVersion,
  ) async {
    final key = _authorize(capabilityId, majorVersion);
    return [
      for (final provider in _registry.providersFor(key))
        if (_owner(_registry.resolve(key, providerId: provider.id)) != null)
          _metadata(provider),
    ];
  }

  @override
  Future<BackendCapabilityAccess?> resolve(
    String capabilityId,
    int majorVersion,
    String expectedServiceId,
    String? providerId,
  ) async {
    final key = _authorize(capabilityId, majorVersion);
    adeleValidateServiceId(expectedServiceId);
    final selectedId = providerId == null ? null : ProviderId(providerId);
    final ProviderBinding binding;
    try {
      binding = _registry.resolve(key, providerId: selectedId);
    } on CapabilityUnavailable {
      return null;
    } on CapabilityVersionUnavailable {
      return null;
    } on ProviderUnavailable {
      return null;
    }
    if (binding.provider.serviceId != expectedServiceId) {
      throw StateError('The selected provider has an incompatible service.');
    }
    final owner = _owner(binding);
    if (owner == null) {
      throw StateError(
        'The selected provider is not an available peer backend.',
      );
    }
    if (_handles.length >= maxHandles) {
      throw StateError('Capability consumer handle capacity exceeded.');
    }
    final handle = '$_scope:${_nextHandle++}';
    _handles[handle] = _CapabilityAccess(
      binding,
      owner,
      binding.requestChannel,
    );
    return BackendCapabilityAccess(
      handle: handle,
      provider: _metadata(binding.provider),
    );
  }

  @override
  Future<Map<String, Object?>> invoke(
    String handle,
    String method,
    Map<String, Object?> payload,
  ) async {
    _validate();
    final access = _handles[handle];
    if (access == null || access.released) {
      throw StateError('Capability access is unavailable.');
    }
    if (!access.owner.ownsProvider(access.binding)) {
      throw StateError('The selected provider is retired.');
    }
    // Generated method identities include their service namespace. Bare backend
    // lifecycle commands must never reach an entrypoint through a peer handle.
    adeleValidateServiceId(method);
    if (!method.startsWith('${access.binding.provider.serviceId}.')) {
      throw StateError('The method does not belong to the selected service.');
    }
    final arguments = adeleSnapshotJsonMap(
      payload,
      maxNodes: adelePluginBackendJsonMaxNodes,
    );
    try {
      final value = await access.channel.request(method, arguments);
      _validatePublication(access);
      return adeleSnapshotJsonMap({
        'ok': true,
        'value': value,
      }, maxNodes: adelePluginBackendJsonMaxNodes);
    } on AdeleRemoteFailure catch (failure) {
      _validatePublication(access);
      if (failure.declaredFailureType != null) {
        // The provider's generated client, not the application, reconstructs its
        // declared failure. Unknown transport/internal diagnostics stay private.
        return adeleSnapshotJsonMap({
          'ok': false,
          'error': {
            'declaredFailureType': failure.declaredFailureType,
            'code': failure.code,
            'message': failure.message,
            'details': failure.details,
          },
        }, maxNodes: adelePluginBackendJsonMaxNodes);
      }
      return _unavailable();
    } on Object {
      _validatePublication(access);
      return _unavailable();
    }
  }

  void _validatePublication(_CapabilityAccess access) {
    _validate();
    if (access.released || access.owner.connection.isClosed) {
      throw StateError('Capability access is unavailable.');
    }
    // Registration-only retirement fences admission, not an admitted unary
    // result. Never re-resolve or validate the registration at this boundary.
  }

  @override
  Future<void> release(String handle) async {
    _validate();
    final access = _handles.remove(handle);
    if (access == null) throw StateError('Capability access is unavailable.');
    access.released = true;
  }

  /// Synchronous bookkeeping cleanup, not cancellation of admitted provider work.
  void close() {
    if (_closed) return;
    _closed = true;
    _detachRevocation?.call();
    _detachRevocation = null;
    for (final access in _handles.values) {
      access.released = true;
    }
    _handles.clear();
  }

  static BackendCapabilityProvider _metadata(ProviderDescriptor provider) =>
      BackendCapabilityProvider(
        capabilityId: provider.capability.id.value,
        majorVersion: provider.capability.majorVersion,
        providerId: provider.id.value,
        pluginId: provider.pluginId,
        displayName: provider.displayName,
        serviceId: provider.serviceId,
      );

  static Map<String, Object?> _unavailable() => {
    'ok': false,
    'error': {
      'declaredFailureType': null,
      'code': 'capability_unavailable',
      'message': 'The Capability request could not be completed.',
      'details': <String, Object?>{},
    },
  };
}

final class _CapabilityAccess {
  _CapabilityAccess(this.binding, this.owner, this.channel);

  final ProviderBinding binding;
  final PluginBackendActivation owner;
  final AdeleRequestChannel channel;
  bool released = false;
}
