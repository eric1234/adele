import 'dart:async';
import 'dart:math';

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
  }) : _catalog = catalog,
       _installation = installation,
       _records = records,
       _associations = associations {
    connection.validateInfrastructureContext();
    if (connection.pluginId != installation.metadata.id.value ||
        _claimedSnapshots[records] != null ||
        installation.backendConsumedRecordTypes.isEmpty ||
        !installation.backendConsumedCredentialSlots.any(
          (declaration) => declaration.slots.isNotEmpty,
        )) {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.notAuthorized,
      );
    }
    _allowed.addAll(_allowedFor(records));
    // Even after retirement a captured authority cannot be adopted by a new
    // generation. Expando does not retain the snapshot after its owners release it.
    _claimedSnapshots[records] = Object();
    _detachRevocation = connection.onInfrastructureRevoked(() {
      unawaited(close());
    });
  }

  Set<(String, String, String, String)> _allowedFor(StartupRecordsView view) {
    final captured = view.recordsForInstallation(_catalog, _installation);
    return {
      for (final declaration in _installation.backendConsumedCredentialSlots)
        for (final record in captured)
          if (record['type'] == declaration.recordType.value)
            for (final slot in declaration.slots)
              (
                record['collection']! as String,
                record['type']! as String,
                record['id']! as String,
                slot.value,
              ),
    };
  }

  static final _claimedSnapshots = Expando<Object>();
  static final _random = Random.secure();
  static final _handlePattern = RegExp(r'^[0-9a-f]{32}-[0-9a-f]{16}$');

  /// Allows refresh overlap without retaining unbounded record batches. Pending
  /// captures and released captures still draining reads also consume capacity.
  static const maxCaptures = 8;

  final PluginBackendConnection connection;
  final PreparedPluginCatalog _catalog;
  final PreparedPluginInstallation _installation;
  final StartupRecordsView _records;
  final StartupCredentialReader _associations;
  final _allowed = <(String, String, String, String)>{};
  final _scope = List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _captures = <String, _CredentialCapture>{};
  final _pendingCaptures = <Future<void>>{};
  final _releases = <Future<void>>{};
  int _captureCount = 0;
  int _nextCapture = 0;
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
      final method = request['method'];
      if (safeRequestId == null ||
          request.length != 4 ||
          request['kind'] != 'request' ||
          payload is! Map) {
        throw const AdeleCredentialFailure(
          AdeleCredentialFailureKind.notAuthorized,
        );
      }
      if (method == 'captureCurrentConfiguration' && payload.isEmpty) {
        final result = await _capture();
        _validateGeneration();
        return _response(safeRequestId, result);
      }
      if (method == 'releaseCapture' && payload.length == 1) {
        final handle = _validateHandle(payload['capture']);
        final capture = _captures.remove(handle);
        if (capture != null) _release(capture.records, live: true);
        return _response(safeRequestId, {'released': true});
      }
      final live = method == 'readCapturedCredential';
      if ((!live && method != 'readCredential') ||
          payload.length != (live ? 5 : 4) ||
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
      final handle = live ? _validateHandle(payload['capture']) : null;
      final capture = live ? _captures[handle] : null;
      void validate() {
        _validateGeneration();
        if (live &&
            (capture == null || !identical(_captures[handle], capture))) {
          throw const AdeleCredentialFailure(
            AdeleCredentialFailureKind.staleConfiguration,
          );
        }
      }

      validate();
      if (!(capture?.allowed ?? _allowed).contains(selection)) {
        throw const AdeleCredentialFailure(
          AdeleCredentialFailureKind.notAuthorized,
        );
      }
      final secret = await _associations.readStartupCredential(
        capture?.records ?? _records,
        collection: selection.$1,
        recordType: selection.$2,
        recordId: selection.$3,
        slot: selection.$4,
        validateGeneration: validate,
      );
      validate();
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

  String _validateHandle(Object? value) {
    if (value is! String ||
        value.length != 49 ||
        !_handlePattern.hasMatch(value) ||
        !value.startsWith('$_scope-')) {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.notAuthorized,
      );
    }
    final sequence = int.tryParse(value.substring(33), radix: 16);
    if (sequence == null || sequence <= 0 || sequence > _nextCapture) {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.notAuthorized,
      );
    }
    return value;
  }

  Future<Map<String, Object?>> _capture() {
    if (_captureCount >= maxCaptures || _nextCapture >= 0x1fffffffffffff) {
      throw const AdeleCredentialFailure(
        AdeleCredentialFailureKind.credentialAccessFailed,
      );
    }
    // Reserve synchronously, including overlapping worker requests and cleanup.
    _captureCount++;
    final result = () async {
      StartupRecordsView? view;
      var installed = false;
      try {
        view = await _associations.captureCurrentConfiguration(
          _catalog,
          _installation,
        );
        if (_claimedSnapshots[view] != null) {
          // A trusted loader must return a new, genuine capture, not another
          // generation's authority. Do not release somebody else's batch.
          view = null;
          throw const AdeleCredentialFailure(
            AdeleCredentialFailureKind.notAuthorized,
          );
        }
        _validateGeneration();
        final allowed = _allowedFor(view);
        final payload = <String, Object?>{
          'records': [
            for (final record in view.records)
              <String, Object>{
                'collection': record['collection']!,
                'type': record['type']!,
                'id': record['id']!,
                'values': Map<String, Object>.of(
                  record['values']! as Map<String, Object>,
                ),
              },
          ],
          'isComplete': view.diagnostics.isEmpty,
        };
        final handle =
            '$_scope-${(++_nextCapture).toRadixString(16).padLeft(16, '0')}';
        _claimedSnapshots[view] = Object();
        _captures[handle] = _CredentialCapture(view, allowed);
        installed = true;
        payload['capture'] = handle;
        return payload;
      } finally {
        if (!installed) {
          if (view != null) {
            _release(view, live: true);
          } else {
            _captureCount--;
          }
        }
      }
    }();
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pendingCaptures.add(settled);
    unawaited(settled.then((_) => _pendingCaptures.remove(settled)));
    return result;
  }

  void _release(StartupRecordsView records, {required bool live}) {
    // The coordinator synchronously revokes authority, then drains its OS reads.
    // A release reply need not wait for an unlock prompt, but capacity is retained.
    final settled =
        Future<void>.sync(() => _associations.releaseStartupRecords(records))
            .then((_) {
              if (live) _captureCount--;
            })
            .catchError((Object _) {
              // Owner shutdown can already have removed bookkeeping. Never disclose it.
              // Unconfirmed cleanup does not free capacity for another retained batch.
            });
    _releases.add(settled);
    unawaited(settled.then((_) => _releases.remove(settled)));
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
    for (final capture in _captures.values) {
      _release(capture.records, live: true);
    }
    _captures.clear();
    _release(_records, live: false);
    _detachRevocation?.call();
    _detachRevocation = null;
    return _closing = () async {
      await Future.wait(_pendingCaptures);
      await Future.wait(_releases);
    }();
  }
}

final class _CredentialCapture {
  _CredentialCapture(this.records, this.allowed);

  final StartupRecordsView records;
  final Set<(String, String, String, String)> allowed;
}
