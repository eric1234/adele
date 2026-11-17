import 'dart:async';

import 'package:adele_contract/adele_contract.dart';

import 'adele_backend_records.dart';
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
/// credential reference. This client exposes no credential enumeration or mutation.
final class AdeleCredentialClient {
  AdeleCredentialClient({
    required AdeleHostRequestMultiplexer hostRequests,
    required String hostInfrastructureContext,
  }) : _channel = hostRequests.bindInfrastructure(
         hostInfrastructureContext: hostInfrastructureContext,
         serviceId: backendCredentialServiceId,
       );

  final AdeleRequestChannel _channel;

  /// Captures current nonsecret records and their host-owned credential scope.
  /// This does not change startup reads or any previously returned capture.
  Future<AdeleCredentialCapture> captureCurrentConfiguration() async {
    final response = await _credentialRequest(
      _channel,
      'captureCurrentConfiguration',
      <String, Object?>{},
    );
    if (response is Map<String, Object?> && response.length == 3) {
      final capture = response['capture'];
      final isComplete = response['isComplete'];
      if (capture is String &&
          capture.length == 49 &&
          _captureHandle.firstMatch(capture)?.end == capture.length &&
          capture.substring(33) != '0000000000000000' &&
          isComplete is bool) {
        try {
          return AdeleCredentialCapture._(
            _channel,
            capture,
            adeleCopyBackendRecords(response['records']),
            isComplete,
          );
        } on Object {
          throw const AdeleCredentialFailure(
            AdeleCredentialFailureKind.credentialAccessFailed,
          );
        }
      }
    }
    throw _credentialFailure(response);
  }

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

/// Immutable nonsecret records with one independently releasable credential scope.
///
/// The host owns authority and freshness. Retaining this object cannot extend its
/// generation or follow later configuration changes. Release it when no longer used.
final class AdeleCredentialCapture {
  AdeleCredentialCapture._(
    this._channel,
    this._capture,
    this.records,
    this.isComplete,
  );

  final AdeleRequestChannel _channel;
  final String _capture;

  /// Deeply copied records using the bounded [AdeleBackendRecords] grammar.
  final List<Map<String, Object>> records;

  /// False when invalid records were omitted, including an all-invalid result.
  final bool isComplete;

  bool _released = false;
  Future<void>? _releasing;

  /// Reads one declared slot from this capture, never the startup scope.
  /// No failure retains a response payload or underlying exception.
  Future<String> readCredential({
    required String collection,
    required String recordType,
    required String recordId,
    required String slot,
  }) async {
    _validate();
    Object? response;
    try {
      response = await _credentialRequest(_channel, 'readCapturedCredential', {
        'capture': _capture,
        'collection': collection,
        'recordType': recordType,
        'recordId': recordId,
        'slot': slot,
      });
    } finally {
      // Revocation also fences reads admitted before release, even on late success.
      _validate();
    }
    if (response is Map<String, Object?> && response.length == 1) {
      final secret = response['secret'];
      if (secret is String && _validSecret(secret)) return secret;
    }
    throw _credentialFailure(response);
  }

  /// Synchronously revokes local reads and late publication, then releases host
  /// bookkeeping. Repeated calls return the same future, including on failure.
  /// Already delivered secrets cannot be revoked or erased by this operation.
  Future<void> release() {
    _released = true;
    if (_releasing != null) return _releasing!;
    final releasing = Completer<void>();
    _releasing = releasing.future;
    releasing.complete(_release());
    return releasing.future;
  }

  Future<void> _release() async {
    final response = await _credentialRequest(_channel, 'releaseCapture', {
      'capture': _capture,
    });
    if (response is Map<String, Object?> &&
        response.length == 1 &&
        response['released'] == true) {
      return;
    }
    throw _credentialFailure(response);
  }

  void _validate() {
    if (_released) {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.staleConfiguration,
      );
    }
  }
}

final _captureHandle = RegExp(r'^[0-9a-f]{32}-[0-9a-f]{16}$');

Future<Object?> _credentialRequest(
  AdeleRequestChannel channel,
  String method,
  Map<String, Object?> payload,
) async {
  try {
    return await channel.request(method, payload);
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
}

AdeleCredentialFailure _credentialFailure(Object? response) {
  if (response is Map<String, Object?> && response.length == 1) {
    final failure = response['failure'];
    for (final kind in AdeleCredentialFailureKind.values) {
      if (failure == kind.name) return AdeleCredentialFailure(kind);
    }
  }
  return const AdeleCredentialFailure(
    AdeleCredentialFailureKind.credentialAccessFailed,
  );
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
