import 'package:adele_contract/adele_contract.dart';

import 'adele_plugin_backend_support.dart' show AdeleHostRequestMultiplexer;
import 'capability_consumer.dart';

/// Discovers and resolves context-free unary Capabilities through the host.
///
/// Binding this facade does not grant access: the host enforces the calling
/// backend generation's prepared declarations and infrastructure allowlist.
final class AdeleCapabilityConsumer {
  AdeleCapabilityConsumer({
    required AdeleHostRequestMultiplexer hostRequests,
    required String hostInfrastructureContext,
  }) : _service = BackendCapabilityConsumerServiceClient(
         _BoundedConsumerChannel(
           hostRequests.bindInfrastructure(
             hostInfrastructureContext: hostInfrastructureContext,
             serviceId: backendCapabilityConsumerServiceId,
           ),
         ),
       );

  final BackendCapabilityConsumerService _service;

  /// Current compatible metadata in host selection order; no provider is empty.
  Future<List<BackendCapabilityProvider>> discover(
    String capabilityId,
    int majorVersion,
  ) async {
    final providers = await _service.discover(capabilityId, majorVersion);
    if (providers.any(
      (provider) =>
          provider.capabilityId != capabilityId ||
          provider.majorVersion != majorVersion,
    )) {
      throw const AdeleProtocolException('Mismatched capability discovery.');
    }
    return providers;
  }

  /// Captures one provider once, without fallback or later re-resolution.
  Future<AdeleResolvedCapability?> resolve(
    String capabilityId,
    int majorVersion, {
    required String expectedServiceId,
    String? providerId,
  }) async {
    final access = await _service.resolve(
      capabilityId,
      majorVersion,
      expectedServiceId,
      providerId,
    );
    if (access == null) return null;
    final provider = access.provider;
    if (provider.capabilityId != capabilityId ||
        provider.majorVersion != majorVersion ||
        provider.serviceId != expectedServiceId ||
        (providerId != null && provider.providerId != providerId)) {
      throw const AdeleProtocolException('Mismatched resolved capability.');
    }
    return AdeleResolvedCapability._(_service, access);
  }
}

/// Request-only generated-client access to one captured provider registration.
///
/// Release when no longer needed. This object never follows provider replacement
/// and exposes neither a stream channel nor a caller-selectable target route.
final class AdeleResolvedCapability {
  AdeleResolvedCapability._(this._service, this._access);

  final BackendCapabilityConsumerService _service;
  final BackendCapabilityAccess _access;
  bool _released = false;
  Future<void>? _releasing;

  BackendCapabilityProvider get provider => _access.provider;
  late final AdeleRequestChannel requestChannel = _CapabilityRequestChannel(
    this,
  );

  /// Synchronously fences new calls and late successful publication, before
  /// awaiting host cleanup. Does not cancel or roll back admitted provider work.
  Future<void> release() {
    _released = true;
    return _releasing ??= _service.release(_access.handle);
  }

  void _validate() {
    if (_released) throw StateError('Capability access has been released.');
  }
}

final class _CapabilityRequestChannel implements AdeleRequestChannel {
  const _CapabilityRequestChannel(this._owner);

  final AdeleResolvedCapability _owner;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    _owner._validate();
    // Bound before generated encoding expands shared acyclic containers.
    final arguments = _snapshot(payload) as Map<String, Object?>;
    final response = await _owner._service.invoke(
      _owner._access.handle,
      method,
      arguments,
    );
    _owner._validate();
    if (response.length == 2 &&
        response['ok'] == true &&
        response.containsKey('value')) {
      return response['value'];
    }
    if (response.length == 2 && response['ok'] == false) {
      final error = response['error'];
      if (error is Map<String, Object?> &&
          error.length == 4 &&
          error.containsKey('declaredFailureType') &&
          (error['declaredFailureType'] == null ||
              error['declaredFailureType'] is String) &&
          error['code'] is String &&
          error['message'] is String &&
          error['details'] is Map<String, Object?>) {
        throw _CapabilityRemoteFailure(
          declaredFailureType: error['declaredFailureType'] as String?,
          code: error['code'] as String,
          message: error['message'] as String,
          details: error['details']! as Map<String, Object?>,
        );
      }
    }
    throw const AdeleProtocolException(
      'Malformed capability invocation result.',
    );
  }
}

/// Bound all control responses before generated list/DTO/JSON decoding expands
/// them. The existing contract snapshot supplies node, depth and cycle checks.
final class _BoundedConsumerChannel implements AdeleRequestChannel {
  const _BoundedConsumerChannel(this._delegate);

  final AdeleRequestChannel _delegate;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      _snapshot(await _delegate.request(method, payload));
}

Object? _snapshot(Object? value) {
  try {
    return adeleSnapshotJsonMap({
      'value': value,
    }, maxNodes: adelePluginBackendJsonMaxNodes)['value'];
  } on FormatException {
    throw const AdeleProtocolException('Invalid capability structured value.');
  }
}

final class _CapabilityRemoteFailure implements AdeleRemoteFailure {
  const _CapabilityRemoteFailure({
    required this.declaredFailureType,
    required this.code,
    required this.message,
    required this.details,
  });

  @override
  final String? declaredFailureType;
  @override
  final String code;
  @override
  final String message;
  @override
  final Map<String, Object?> details;

  @override
  String toString() => 'Capability request failed ($code): $message';
}
