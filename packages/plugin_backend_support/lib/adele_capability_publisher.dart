import 'package:adele_contract/adele_contract.dart';

import 'adele_plugin_backend_support.dart' show AdeleHostRequestMultiplexer;

/// Host-granted publication of this connection's own Capability registrations.
const backendCapabilityPublicationServiceId = 'adele.capabilityPublication';

enum AdeleCapabilityPublicationFailureKind {
  invalidRequest,
  notAuthorized,
  notReady,
  capacityExceeded,
  staleGroup,
  rejected,
  replacementUnavailable,
  generationUnavailable,
  outcomeUnknown,
}

/// Fixed diagnostics only: no backend payload, private route or native cause.
final class AdeleCapabilityPublicationFailure implements Exception {
  const AdeleCapabilityPublicationFailure(this.kind);

  final AdeleCapabilityPublicationFailureKind kind;

  @override
  String toString() => 'Capability publication failed (${kind.name}).';
}

/// Strict, bounded exposure decoding shared by the public client and host.
/// Semantic validation remains [AdeleCapabilityExposure]'s responsibility.
List<AdeleCapabilityExposure> adeleDecodeCapabilityPublication(Object? value) {
  const fields = {
    'providerId',
    'capabilityId',
    'capabilityMajorVersion',
    'serviceId',
    'displayName',
    'configurationContext',
    'rank',
    'association',
    'environmentBound',
    'environmentHostServices',
  };
  try {
    if (value is! List || value.isEmpty || value.length > 64) {
      throw const FormatException();
    }
    for (final item in value) {
      if (item is! Map || item.keys.any((key) => !fields.contains(key))) {
        throw const FormatException();
      }
      for (final entry in item.entries) {
        final field = entry.value;
        if (entry.key == 'association') {
          if (field is! Map ||
              field.length != 3 ||
              field.values.any(
                (v) => !(v is int || (v is String && v.length <= 1024)),
              )) {
            throw const FormatException();
          }
        } else if (entry.key == 'environmentHostServices') {
          if (field is! List ||
              field.length > 2 ||
              field.any((v) => v is! String || v.length > 32)) {
            throw const FormatException();
          }
        } else if (!(field is int ||
            field is bool ||
            (field is String && field.length <= 1024))) {
          throw const FormatException();
        }
      }
    }
    return AdeleCapabilityExposure.fromReady({'capabilityExposures': value});
  } on Object {
    throw const AdeleCapabilityPublicationFailure(
      AdeleCapabilityPublicationFailureKind.invalidRequest,
    );
  }
}

/// Publishes only to the host activation bound to this infrastructure grant.
/// Prepare immutable routes first. Do not wait for publication during readiness.
final class AdeleCapabilityPublisher {
  AdeleCapabilityPublisher({
    required AdeleHostRequestMultiplexer hostRequests,
    required String hostInfrastructureContext,
  }) : _channel = hostRequests.bindInfrastructure(
         hostInfrastructureContext: hostInfrastructureContext,
         serviceId: backendCapabilityPublicationServiceId,
       );

  final AdeleRequestChannel _channel;

  /// Adopts exact original ready registrations without re-registering them.
  Future<AdelePublishedCapabilityGroup> adoptAdvertised(
    List<AdeleCapabilityExposure> expected,
  ) => _publish('adoptAdvertised', expected);

  Future<AdelePublishedCapabilityGroup> publish(
    List<AdeleCapabilityExposure> exposures,
  ) => _publish('publish', exposures);

  Future<AdelePublishedCapabilityGroup> _publish(
    String method,
    List<AdeleCapabilityExposure> exposures, {
    String? expected,
  }) async {
    final copied = adeleDecodeCapabilityPublication([
      for (final exposure in exposures) exposure.toMap(),
    ]);
    final result = await _request(method, {
      'group': ?expected,
      'exposures': [for (final exposure in copied) exposure.toMap()],
    });
    final handle = result['group'];
    if (result.length != 1 ||
        handle is! String ||
        !RegExp(r'^[0-9a-f]{32}-[0-9a-f]{16}$').hasMatch(handle)) {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.outcomeUnknown,
      );
    }
    return AdelePublishedCapabilityGroup._(this, handle);
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> payload,
  ) async {
    Object? response;
    try {
      response = await _channel.request(method, payload);
    } on AdeleRemoteFailure catch (failure) {
      throw AdeleCapabilityPublicationFailure(switch (failure.code) {
        'host_infrastructure_unavailable' || 'host_invocation_unavailable' =>
          AdeleCapabilityPublicationFailureKind.generationUnavailable,
        'service_unavailable' =>
          AdeleCapabilityPublicationFailureKind.notAuthorized,
        _ => AdeleCapabilityPublicationFailureKind.outcomeUnknown,
      });
    } on Object {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.outcomeUnknown,
      );
    }
    if (response is Map<String, Object?>) {
      if (response.length == 1 && response.containsKey('failure')) {
        for (final kind in AdeleCapabilityPublicationFailureKind.values) {
          if (response['failure'] == kind.name) {
            throw AdeleCapabilityPublicationFailure(kind);
          }
        }
      } else {
        return response;
      }
    }
    throw const AdeleCapabilityPublicationFailure(
      AdeleCapabilityPublicationFailureKind.outcomeUnknown,
    );
  }
}

/// An exact group incarnation, not a semantic provider selector.
/// Replacement returns a new handle; cleanup of this one never affects it.
final class AdelePublishedCapabilityGroup {
  AdelePublishedCapabilityGroup._(this._publisher, this._handle);

  final AdeleCapabilityPublisher _publisher;
  final String _handle;
  bool _retired = false;
  Future<void>? _retiring;

  bool get isRetired => _retired;

  Future<AdelePublishedCapabilityGroup> replace(
    List<AdeleCapabilityExposure> exposures,
  ) async {
    if (_retired || _retiring != null) {
      throw const AdeleCapabilityPublicationFailure(
        AdeleCapabilityPublicationFailureKind.staleGroup,
      );
    }
    try {
      final replacement = await _publisher._publish(
        'replace',
        exposures,
        expected: _handle,
      );
      _retired = true;
      return replacement;
    } on AdeleCapabilityPublicationFailure catch (failure) {
      if (switch (failure.kind) {
        AdeleCapabilityPublicationFailureKind.replacementUnavailable ||
        AdeleCapabilityPublicationFailureKind.staleGroup => true,
        _ => false,
      }) {
        _retired = true;
      }
      rethrow;
    }
  }

  /// Fences host selection, not admitted backend work. Retire the backend route
  /// separately, and release configured resources only after that route drains.
  Future<void> retire() {
    if (_retiring != null) return _retiring!;
    if (_retired) return Future<void>.value();
    return _retiring = _retire();
  }

  Future<void> _retire() async {
    try {
      final result = await _publisher._request('retire', {'group': _handle});
      if (result.length != 1 || result['retired'] != true) {
        throw const AdeleCapabilityPublicationFailure(
          AdeleCapabilityPublicationFailureKind.outcomeUnknown,
        );
      }
    } on AdeleCapabilityPublicationFailure catch (failure) {
      // A concurrent replacement/retirement may already have consumed this exact
      // incarnation. It is never permission to retire its replacement.
      if (failure.kind != AdeleCapabilityPublicationFailureKind.staleGroup) {
        if (failure.kind ==
            AdeleCapabilityPublicationFailureKind.replacementUnavailable) {
          _retired = true;
        }
        // An explicit pre-mutation refusal permits a later caller-initiated
        // attempt. Unknown outcomes must not trigger an automatic retry.
        if (switch (failure.kind) {
          AdeleCapabilityPublicationFailureKind.capacityExceeded ||
          AdeleCapabilityPublicationFailureKind.notReady ||
          AdeleCapabilityPublicationFailureKind.rejected ||
          AdeleCapabilityPublicationFailureKind.invalidRequest ||
          AdeleCapabilityPublicationFailureKind.notAuthorized => true,
          _ => false,
        }) {
          _retiring = null;
        }
        rethrow;
      }
    }
    _retired = true;
  }
}
