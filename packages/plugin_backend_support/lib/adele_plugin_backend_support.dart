/// Unary reverse calls for plugin backends, independent of host implementation.
library;

import 'dart:async';

import 'package:adele_contract/adele_contract.dart';

/// Multiplexes host calls over the backend's bootstrap response port.
///
/// Keep one multiplexer per backend generation; bound channels share its IDs.
/// Pass that port's `send` as [send]. Call [handleResponse] on each ordinary
/// command-port message before forwarding it to the configuration router.
/// On shutdown, call [close] before awaiting forward dispatcher closure: an
/// in-flight forward request may itself be waiting for a host response.
final class AdeleHostRequestMultiplexer {
  AdeleHostRequestMultiplexer({
    required void Function(Map<String, Object?> message) send,
  }) : _send = send;

  final void Function(Map<String, Object?> message) _send;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextRequestId = 0;
  bool _closed = false;

  /// Binds a generated unary client to an opaque host invocation and service.
  /// Neither Session/Run identities nor paths establish host authority.
  AdeleRequestChannel bind({
    required String hostInvocationContext,
    required String serviceId,
  }) {
    if (_closed) throw StateError('Host request multiplexer is closed.');
    if (hostInvocationContext.isEmpty || serviceId.isEmpty) {
      throw ArgumentError(
        'Host invocation context and service must be nonempty.',
      );
    }
    return _HostRequestChannel(this, hostInvocationContext, serviceId);
  }

  /// Consumes only `hostResponse` messages, including late/unknown responses.
  /// Malformed correlated responses fail their request instead of leaving it open.
  bool handleResponse(Object? message) {
    if (message is! Map || message['kind'] != 'hostResponse') return false;
    final Object? requestId = message['requestId'];
    final Completer<Object?>? pending = requestId is int
        ? _pending.remove(requestId)
        : null;
    if (pending == null) return true;
    try {
      if (message['ok'] == true && message.containsKey('payload')) {
        pending.complete(message['payload']);
      } else if (message['ok'] == false) {
        final Object? error = message['error'];
        if (error is! Map ||
            error['code'] is! String ||
            error['message'] is! String ||
            (error.containsKey('declaredFailureType') &&
                error['declaredFailureType'] is! String) ||
            (error.containsKey('declaredFailureType') &&
                !error.containsKey('details'))) {
          throw const AdeleProtocolException('Malformed host failure.');
        }
        final Object? details = error.containsKey('details')
            ? error['details']
            : <String, Object?>{};
        if (details is! Map ||
            details.keys.any((Object? key) => key is! String)) {
          throw const AdeleProtocolException('Malformed host failure details.');
        }
        pending.completeError(
          _HostRemoteFailure(
            declaredFailureType: error['declaredFailureType'] as String?,
            code: error['code'] as String,
            message: error['message'] as String,
            details: adeleSnapshotJsonMap(Map<String, Object?>.from(details)),
          ),
        );
      } else {
        throw const AdeleProtocolException('Malformed host response.');
      }
    } on Object catch (error, stackTrace) {
      pending.completeError(error, stackTrace);
    }
    return true;
  }

  /// Rejects new calls and settles all pending calls before returning.
  void close() {
    if (_closed) return;
    _closed = true;
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final request in pending) {
      request.completeError(StateError('Host request multiplexer is closed.'));
    }
  }

  Future<Object?> _request(
    String hostInvocationContext,
    String serviceId,
    String method,
    Map<String, Object?> payload,
  ) {
    if (_closed) {
      return Future<Object?>.error(
        StateError('Host request multiplexer is closed.'),
      );
    }
    final int requestId = _nextRequestId++;
    final pending = Completer<Object?>();
    _pending[requestId] = pending;
    try {
      _send(<String, Object?>{
        'kind': 'hostRequest',
        'requestId': requestId,
        'hostInvocationContext': hostInvocationContext,
        'serviceId': serviceId,
        'method': method,
        'payload': payload,
      });
    } on Object catch (error, stackTrace) {
      if (_pending.remove(requestId) != null) {
        pending.completeError(error, stackTrace);
      }
    }
    return pending.future;
  }
}

final class _HostRequestChannel implements AdeleRequestChannel {
  const _HostRequestChannel(this._owner, this._context, this._serviceId);

  final AdeleHostRequestMultiplexer _owner;
  final String _context;
  final String _serviceId;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      _owner._request(_context, _serviceId, method, payload);
}

final class _HostRemoteFailure implements AdeleRemoteFailure {
  const _HostRemoteFailure({
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
  String toString() => 'Host request failed ($code): $message';
}
