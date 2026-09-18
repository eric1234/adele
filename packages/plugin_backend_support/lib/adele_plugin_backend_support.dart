/// Operation-scoped host calls, independent of host implementation.
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
  final Map<int, _HostStream> _streams = {};
  int _nextRequestId = 0;
  bool _closed = false;

  /// Binds a generated unary/stream client to an opaque invocation and service.
  /// Neither Session/Run identities nor paths establish host authority.
  AdeleStreamChannel bind({
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

  /// Consumes host replies, including late/unknown responses.
  /// Malformed correlated responses fail their request instead of leaving it open.
  bool handleResponse(Object? message) {
    if (message is Map &&
        message['kind'] is String &&
        (message['kind'] as String).startsWith('hostStream')) {
      _handleStreamResponse(message);
      return true;
    }
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
        pending.completeError(_parseFailure(message['error']));
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
    for (final entry in _streams.entries.toList()) {
      final stream = entry.value;
      if (!stream.cancelling) {
        stream.controller.addError(
          StateError('Host request multiplexer is closed.'),
        );
        unawaited(_cancelStream(entry.key, stream).catchError((Object _) {}));
      }
      _finishStream(entry.key);
    }
  }

  Stream<Object?> _stream(
    String context,
    String service,
    String method,
    Map<String, Object?> payload,
  ) {
    int? id;
    late final StreamController<Object?> controller;
    controller = StreamController<Object?>(
      sync: true,
      onListen: () {
        if (_closed) {
          controller.addError(
            StateError('Host request multiplexer is closed.'),
          );
          unawaited(controller.close());
          return;
        }
        final requestId = id = _nextRequestId++;
        final stream = _HostStream(controller);
        _streams[requestId] = stream;
        try {
          _send({
            'kind': 'hostStreamOpen',
            'requestId': requestId,
            'hostInvocationContext': context,
            'serviceId': service,
            'method': method,
            'payload': payload,
          });
          _credit(requestId, stream);
        } on Object catch (error, stack) {
          _finishStream(requestId, error: error, stack: stack);
        }
      },
      onResume: () {
        final stream = _streams[id];
        if (stream != null) _credit(id!, stream);
      },
      onCancel: () async {
        final stream = _streams[id];
        if (stream == null) return;
        await _cancelStream(id!, stream);
      },
    );
    return controller.stream;
  }

  Future<void> _cancelStream(int id, _HostStream stream) =>
      stream.cancellation ??= () async {
        stream.cancelling = true;
        try {
          _send({'kind': 'hostStreamCancel', 'requestId': id});
          // Cancelled acknowledges dispatch, not arbitrary producer cleanup.
          await stream.settled.future.timeout(const Duration(seconds: 2));
        } finally {
          _finishStream(id);
        }
      }();

  void _credit(int id, _HostStream stream) {
    if (_streams[id] != stream ||
        stream.cancelling ||
        stream.credit != 0 ||
        stream.controller.isPaused) {
      return;
    }
    stream.credit = 1;
    try {
      _send({'kind': 'hostStreamCredit', 'requestId': id, 'credit': 1});
    } on Object catch (error, stack) {
      _finishStream(id, error: error, stack: stack);
    }
  }

  void _handleStreamResponse(Map<Object?, Object?> message) {
    final id = message['requestId'];
    final stream = _streams[id];
    final kind = message['kind'];
    final terminal =
        kind == 'hostStreamDone' ||
        kind == 'hostStreamFailure' ||
        kind == 'hostStreamCancelled';
    if (stream == null) {
      // Shutdown settles locally without waiting for the transport. Still release
      // the host's terminal route if a reply arrives before the port closes.
      if (_closed && terminal && id is int && id >= 0 && id < _nextRequestId) {
        try {
          _send({'kind': 'hostStreamAck', 'requestId': id});
        } on Object {
          /* The connection may already be gone. */
        }
      }
      return;
    }
    try {
      final item = kind == 'hostStreamItem';
      final failure = kind == 'hostStreamFailure';
      if (message.length != (item || failure ? 3 : 2) ||
          (!item &&
              !failure &&
              kind != 'hostStreamDone' &&
              kind != 'hostStreamCancelled') ||
          (item && !message.containsKey('payload')) ||
          (kind == 'hostStreamCancelled' && !stream.cancelling)) {
        throw const AdeleProtocolException('Malformed host stream response.');
      }
      if (item) {
        if (stream.credit != 1) {
          throw const AdeleProtocolException(
            'Host stream item without credit.',
          );
        }
        stream.credit = 0;
        if (!stream.cancelling) stream.controller.add(message['payload']);
        _credit(id as int, stream);
      } else {
        final error = failure ? _parseFailure(message['error']) : null;
        _send({'kind': 'hostStreamAck', 'requestId': id});
        _finishStream(id as int, error: error);
      }
    } on Object catch (error, stack) {
      if (terminal) {
        try {
          _send({'kind': 'hostStreamAck', 'requestId': id});
        } on Object {
          /* Preserve the parsing failure. */
        }
        _finishStream(id as int, error: error, stack: stack);
      } else {
        // Keep correlation until cancellation receipt, but deliver the original
        // parser failure rather than a cleanup error to generated consumers.
        if (!stream.cancelling) {
          stream.controller.addError(error, stack);
          unawaited(_cancelStream(id as int, stream).catchError((Object _) {}));
          unawaited(stream.controller.close());
        }
      }
    }
  }

  void _finishStream(int id, {Object? error, StackTrace? stack}) {
    final stream = _streams.remove(id);
    if (stream == null) return;
    if (!stream.settled.isCompleted) stream.settled.complete();
    if (error != null && !stream.cancelling) {
      stream.controller.addError(error, stack);
    }
    unawaited(stream.controller.close());
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

final class _HostRequestChannel implements AdeleStreamChannel {
  const _HostRequestChannel(this._owner, this._context, this._serviceId);

  final AdeleHostRequestMultiplexer _owner;
  final String _context;
  final String _serviceId;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      _owner._request(_context, _serviceId, method, payload);

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      _owner._stream(_context, _serviceId, method, payload);
}

final class _HostStream {
  _HostStream(this.controller);
  final StreamController<Object?> controller;
  final Completer<void> settled = Completer<void>();
  Future<void>? cancellation;
  int credit = 0;
  bool cancelling = false;
}

_HostRemoteFailure _parseFailure(Object? error) {
  if (error is! Map ||
      error['code'] is! String ||
      error['message'] is! String ||
      (error.containsKey('declaredFailureType') &&
          (error['declaredFailureType'] is! String ||
              !error.containsKey('details')))) {
    throw const AdeleProtocolException('Malformed host failure.');
  }
  final details = error.containsKey('details')
      ? error['details']
      : <String, Object?>{};
  if (details is! Map || details.keys.any((Object? key) => key is! String)) {
    throw const AdeleProtocolException('Malformed host failure details.');
  }
  return _HostRemoteFailure(
    declaredFailureType: error['declaredFailureType'] as String?,
    code: error['code'] as String,
    message: error['message'] as String,
    details: adeleSnapshotJsonMap(
      Map<String, Object?>.from(details),
      maxNodes: adelePluginBackendJsonMaxNodes,
    ),
  );
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
