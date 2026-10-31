import 'package:adele_contract/adele_contract.dart';

import 'adele_plugin_backend_support.dart' show AdeleHostRequestMultiplexer;

/// The explicitly granted, generation-scoped credential infrastructure service.
const backendCredentialServiceId = 'adele.credentials';

/// Bounded credential outcomes, without native errors, references or secrets.
enum AdeleCredentialFailureKind {
  notAuthorized,
  notConfigured,
  missingLocally,
  storageUnavailable,
  invalidCredentialBinding,
  reconciliationRequired,
  staleConfiguration,
  generationUnavailable,
  credentialAccessFailed,
}

final class AdeleCredentialFailure implements Exception {
  const AdeleCredentialFailure(this.kind);

  final AdeleCredentialFailureKind kind;

  @override
  String toString() => 'Credential access failed (${kind.name}).';
}

/// Read-only access to declared record slots through one captured host grant.
///
/// Binding does not grant authority. The host checks the exact installation,
/// record binding and generation; neither a record ID nor this client is a
/// credential reference. This client exposes no enumeration or mutation.
final class AdeleCredentialClient {
  AdeleCredentialClient({
    required AdeleHostRequestMultiplexer hostRequests,
    required String hostInfrastructureContext,
  }) : _channel = hostRequests.bindInfrastructure(
         hostInfrastructureContext: hostInfrastructureContext,
         serviceId: backendCredentialServiceId,
       );

  final AdeleRequestChannel _channel;

  /// Returns a nonempty, NUL-free secret of at most 2560 strict UTF-8 bytes.
  /// No failure retains a response payload or underlying exception.
  Future<String> readCredential({
    required String collection,
    required String recordType,
    required String recordId,
    required String slot,
  }) async {
    Object? response;
    try {
      // A fresh plain map crosses AOT isolate groups; unmodifiable wrappers do not.
      response = await _channel.request('readCredential', {
        'collection': collection,
        'recordType': recordType,
        'recordId': recordId,
        'slot': slot,
      });
    } on AdeleRemoteFailure catch (failure) {
      throw AdeleCredentialFailure(switch (failure.code) {
        'host_infrastructure_unavailable' || 'host_invocation_unavailable' =>
          AdeleCredentialFailureKind.generationUnavailable,
        'service_unavailable' => AdeleCredentialFailureKind.notAuthorized,
        _ => AdeleCredentialFailureKind.credentialAccessFailed,
      });
    } on Object {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.credentialAccessFailed,
      );
    }

    // The multiplexer snapshots responses synchronously before completing calls.
    if (response is Map<String, Object?> && response.length == 1) {
      final secret = response['secret'];
      if (secret is String && _validSecret(secret)) return secret;
      final failure = response['failure'];
      for (final kind in AdeleCredentialFailureKind.values) {
        if (failure == kind.name) throw AdeleCredentialFailure(kind);
      }
    }
    throw const AdeleCredentialFailure(
      AdeleCredentialFailureKind.credentialAccessFailed,
    );
  }
}

bool _validSecret(String value) {
  const maximumBytes = 2560;
  if (value.isEmpty || value.length > maximumBytes) return false;
  var bytes = 0;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit == 0 || (unit >= 0xdc00 && unit <= 0xdfff)) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i == value.length) return false;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
      bytes += 4;
    } else {
      bytes += unit < 0x80 ? 1 : (unit < 0x800 ? 2 : 3);
    }
    if (bytes > maximumBytes) return false;
  }
  return true;
}
