import 'dart:async';
import 'dart:isolate';

typedef PluginDiagnosticSink = void Function(String message);

final class PluginRemoteFailure implements Exception {
  const PluginRemoteFailure({
    required this.code,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'PluginRemoteFailure($code): $message';
}

final class PluginConnectionClosed implements Exception {
  const PluginConnectionClosed(this.message);

  final String message;

  @override
  String toString() => 'PluginConnectionClosed: $message';
}

final class PluginBackendLauncher {
  const PluginBackendLauncher({
    this.startupTimeout = const Duration(seconds: 5),
    this.shutdownTimeout = const Duration(seconds: 2),
  });

  final Duration startupTimeout;
  final Duration shutdownTimeout;

  Future<PluginBackendConnection> launch({
    required Uri artifactUri,
    List<String> arguments = const <String>[],
    PluginDiagnosticSink? onDiagnostic,
  }) async {
    final ReceivePort bootstrap = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final ReceivePort errors = ReceivePort();
    final ReceivePort exits = ReceivePort();
    Isolate? isolate;
    final Completer<Object?> earlyFailure = Completer<Object?>();
    final StreamSubscription<Object?> errorSubscription = errors.listen((
      Object? error,
    ) {
      if (!earlyFailure.isCompleted) earlyFailure.complete(error);
    });
    final StreamSubscription<Object?> exitSubscription = exits.listen((
      Object? _,
    ) {
      if (!earlyFailure.isCompleted) {
        earlyFailure.complete(
          const PluginConnectionClosed('Backend exited before handshake.'),
        );
      }
    });
    try {
      isolate = await Isolate.spawnUri(
        artifactUri,
        arguments,
        <String, Object?>{
          'bootstrapPort': bootstrap.sendPort,
          'responsePort': responses.sendPort,
        },
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );
      final Object? ready = await Future.any(<Future<Object?>>[
        bootstrap.first,
        earlyFailure.future.then<Object?>((Object? error) => throw error!),
      ]).timeout(startupTimeout);
      if (ready is! Map || ready['commandPort'] is! SendPort) {
        throw StateError('Invalid backend handshake: $ready');
      }
      return PluginBackendConnection._(
        commandPort: ready['commandPort'] as SendPort,
        responses: responses,
        errors: errors,
        exits: exits,
        isolate: isolate,
        ownsIsolate: true,
        shutdownTimeout: shutdownTimeout,
        onDiagnostic: onDiagnostic,
      );
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      bootstrap.close();
      responses.close();
      errors.close();
      exits.close();
      rethrow;
    } finally {
      await errorSubscription.cancel();
      await exitSubscription.cancel();
      bootstrap.close();
    }
  }
}

final class PluginBackendConnection {
  PluginBackendConnection._({
    required SendPort commandPort,
    required ReceivePort responses,
    required ReceivePort errors,
    required ReceivePort exits,
    required Isolate isolate,
    required bool ownsIsolate,
    required Duration shutdownTimeout,
    PluginDiagnosticSink? onDiagnostic,
  }) : _commandPort = commandPort,
       _responses = responses,
       _errors = errors,
       _exits = exits,
       _isolate = isolate,
       _ownsIsolate = ownsIsolate,
       _shutdownTimeout = shutdownTimeout,
       _onDiagnostic = onDiagnostic {
    _responseSubscription = _responses.listen(_handleResponse);
    _errorSubscription = _errors.listen(_handleBackendError);
    _exitSubscription = _exits.listen(_handleExit);
  }

  factory PluginBackendConnection.testPeer({
    required SendPort commandPort,
    required ReceivePort responses,
    PluginDiagnosticSink? onDiagnostic,
  }) {
    return PluginBackendConnection._(
      commandPort: commandPort,
      responses: responses,
      errors: ReceivePort(),
      exits: ReceivePort(),
      isolate: Isolate.current,
      ownsIsolate: false,
      shutdownTimeout: const Duration(milliseconds: 50),
      onDiagnostic: onDiagnostic,
    );
  }

  final SendPort _commandPort;
  final ReceivePort _responses;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final Isolate _isolate;
  final bool _ownsIsolate;
  final Duration _shutdownTimeout;
  final PluginDiagnosticSink? _onDiagnostic;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  late final StreamSubscription<Object?> _responseSubscription;
  late final StreamSubscription<Object?> _errorSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  int _nextRequestId = 1;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<Object?> request(String method, Map<String, Object?> payload) {
    if (_closed) {
      return Future<Object?>.error(
        const PluginConnectionClosed('The backend connection is closed.'),
      );
    }
    final int requestId = _nextRequestId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[requestId] = completer;
    _commandPort.send(<String, Object?>{
      'kind': 'request',
      'requestId': requestId,
      'method': method,
      'payload': payload,
    });
    return completer.future;
  }

  Future<void> close({bool graceful = true}) async {
    if (_closed) return;
    if (graceful) {
      try {
        await request(
          'shutdown',
          const <String, Object?>{},
        ).timeout(_shutdownTimeout);
        await _waitForClosed().timeout(_shutdownTimeout);
        return;
      } on Object catch (error) {
        _onDiagnostic?.call('Graceful shutdown failed: $error');
        if (_ownsIsolate) _isolate.kill(priority: Isolate.immediate);
      }
    } else if (_ownsIsolate) {
      _isolate.kill(priority: Isolate.immediate);
    }
    await _finish(
      const PluginConnectionClosed('The backend connection was stopped.'),
    );
  }

  Future<void> _waitForClosed() async {
    while (!_closed) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void _handleResponse(Object? message) {
    if (message is! Map || message['kind'] != 'response') {
      _onDiagnostic?.call('Malformed backend response ignored: $message');
      return;
    }
    final Object? rawRequestId = message['requestId'];
    if (rawRequestId is! int) {
      _onDiagnostic?.call('Response without integer request ID ignored.');
      return;
    }
    final Completer<Object?>? completer = _pending.remove(rawRequestId);
    if (completer == null) {
      _onDiagnostic?.call('Unknown or duplicate response ID $rawRequestId.');
      return;
    }
    if (message['ok'] == true) {
      completer.complete(message['payload']);
      return;
    }
    final Object? rawError = message['error'];
    if (rawError is Map &&
        rawError['code'] is String &&
        rawError['message'] is String) {
      completer.completeError(
        PluginRemoteFailure(
          code: rawError['code'] as String,
          message: rawError['message'] as String,
          details: _stringMap(rawError['details']),
        ),
      );
      return;
    }
    completer.completeError(
      const PluginRemoteFailure(
        code: 'invalid_response',
        message: 'The backend returned an invalid error response.',
      ),
    );
  }

  void _handleBackendError(Object? error) {
    _onDiagnostic?.call('Backend uncaught error: $error');
    unawaited(_finish(PluginConnectionClosed('The backend failed: $error')));
  }

  void _handleExit(Object? _) {
    _onDiagnostic?.call('Backend exit observed.');
    unawaited(_finish(const PluginConnectionClosed('The backend exited.')));
  }

  Future<void> _finish(Object error) async {
    if (_closed) return;
    _closed = true;
    for (final Completer<Object?> completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    await _responseSubscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
    _responses.close();
    _errors.close();
    _exits.close();
  }
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (entry.key is String) result[entry.key as String] = entry.value;
  }
  return result;
}
