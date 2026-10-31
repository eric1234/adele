import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_backend_credentials.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'credential_service.dart';
import 'prepared_records.dart';

/// Read-only credential access for one captured installation and live connection.
/// The infrastructure grant is checked by transport before this dispatcher runs.
final class BackendCredentialHost implements AdeleBackendDispatcher {
  BackendCredentialHost({
    required this.connection,
    required PreparedPluginCatalog catalog,
    required PreparedPluginInstallation installation,
    required StartupRecordsView records,
    required StartupCredentialReader associations,
  }) : _records = records,
       _associations = associations {
    connection.validateInfrastructureContext();
    if (connection.pluginId != installation.metadata.id.value ||
        _claimedSnapshots[records] != null) {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.notAuthorized,
      );
    }
    final captured = records.recordsForInstallation(catalog, installation);
    for (final declaration in installation.backendConsumedCredentialSlots) {
      for (final record in captured) {
        if (record['type'] != declaration.recordType.value) continue;
        for (final slot in declaration.slots) {
          _allowed.add((
            record['collection']! as String,
            record['type']! as String,
            record['id']! as String,
            slot.value,
          ));
        }
      }
    }
    // Even after retirement a captured authority cannot be adopted by a new
    // generation. Expando does not retain the snapshot after its owners release it.
    _claimedSnapshots[records] = Object();
    _detachRevocation = connection.onInfrastructureRevoked(() {
      unawaited(close());
    });
  }

  static final _claimedSnapshots = Expando<Object>();

  final PluginBackendConnection connection;
  final StartupRecordsView _records;
  final StartupCredentialReader _associations;
  final _allowed = <(String, String, String, String)>{};
  bool _closed = false;
  void Function()? _detachRevocation;
  Future<void>? _closing;

  void _validateGeneration() {
    if (_closed) {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.generationUnavailable,
      );
    }
    try {
      connection.validateInfrastructureContext();
    } on Object {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.generationUnavailable,
      );
    }
  }

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    final requestId = request['requestId'];
    final safeRequestId = requestId is int && requestId >= 0 ? requestId : null;
    try {
      _validateGeneration();
      final payload = request['payload'];
      if (safeRequestId == null ||
          request.length != 4 ||
          request['kind'] != 'request' ||
          request['method'] != 'readCredential' ||
          payload is! Map ||
          payload.length != 4 ||
          payload['collection'] is! String ||
          payload['recordType'] is! String ||
          payload['recordId'] is! String ||
          payload['slot'] is! String) {
        throw const AdeleCredentialFailure(
          AdeleCredentialFailureKind.notAuthorized,
        );
      }
      // Copy only the four selectors. No reference, owner, path or alternative
      // generation from a caller can reach the association coordinator.
      final selection = (
        payload['collection'] as String,
        payload['recordType'] as String,
        payload['recordId'] as String,
        payload['slot'] as String,
      );
      if (!_allowed.contains(selection)) {
        throw const AdeleCredentialFailure(
          AdeleCredentialFailureKind.notAuthorized,
        );
      }
      final secret = await _associations.readStartupCredential(
        _records,
        collection: selection.$1,
        recordType: selection.$2,
        recordId: selection.$3,
        slot: selection.$4,
        validateGeneration: _validateGeneration,
      );
      _validateGeneration();
      return _response(safeRequestId, {
        'secret': CredentialSecret(secret).reveal(),
      });
    } on AdeleCredentialFailure catch (failure) {
      return _failure(safeRequestId, failure.kind);
    } on Object {
      return _failure(
        safeRequestId,
        AdeleCredentialFailureKind.credentialAccessFailed,
      );
    }
  }

  Map<String, Object?> _failure(
    int? requestId,
    AdeleCredentialFailureKind kind,
  ) {
    try {
      _validateGeneration();
    } on AdeleCredentialFailure {
      kind = AdeleCredentialFailureKind.generationUnavailable;
    }
    return _response(requestId, {'failure': kind.name});
  }

  static Map<String, Object?> _response(
    int? requestId,
    Map<String, Object?> payload,
  ) => {
    'kind': 'response',
    'requestId': requestId,
    'ok': true,
    'payload': payload,
  };

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  ) async {
    send(await dispatch(command));
  }

  /// Revokes publication synchronously, without pretending to cancel OS work.
  /// The retained settings/credential owners drain already admitted operations.
  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _allowed.clear();
    _detachRevocation?.call();
    _detachRevocation = null;
    return _closing =
        Future<void>.sync(
          () => _associations.releaseStartupRecords(_records),
        ).catchError((Object _) {
          // Bookkeeping may already be gone with the settings owner. Authority is
          // irrevocably closed regardless; never expose an underlying diagnostic.
        });
  }
}
