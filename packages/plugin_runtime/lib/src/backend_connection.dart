import 'dart:async';
import 'dart:io';

import 'backend_host_protocol.dart';

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

final class PluginBackendHost {
  PluginBackendHost._({
    required Process process,
    required Duration shutdownTimeout,
    required PluginDiagnosticSink? onDiagnostic,
  }) : _process = process,
       _shutdownTimeout = shutdownTimeout,
       _onDiagnostic = onDiagnostic;

  final Process _process;
  final Duration _shutdownTimeout;
  final PluginDiagnosticSink? _onDiagnostic;
  final BackendHostFrameDecoder _decoder = BackendHostFrameDecoder();
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  final Map<int, String> _pendingPluginIds = <int, String>{};
  final Map<String, PluginBackendConnection> _plugins =
      <String, PluginBackendConnection>{};
  final Map<String, PluginBackendConnection> _startingPlugins =
      <String, PluginBackendConnection>{};
  late final StreamSubscription<List<int>> _stdoutSubscription;
  late final StreamSubscription<String> _stderrSubscription;
  int _nextRequestId = 1;
  bool _closed = false;
  bool _shuttingDown = false;
  Future<void>? _termination;

  static Future<PluginBackendHost> start({
    required String dartaotruntimeExecutable,
    required String hostArtifactPath,
    Duration startupTimeout = const Duration(seconds: 5),
    Duration shutdownTimeout = const Duration(seconds: 2),
    PluginDiagnosticSink? onDiagnostic,
  }) async {
    final Process process = await Process.start(
      dartaotruntimeExecutable,
      <String>[hostArtifactPath],
      runInShell: false,
    );
    final PluginBackendHost host = PluginBackendHost._(
      process: process,
      shutdownTimeout: shutdownTimeout,
      onDiagnostic: onDiagnostic,
    );
    final Completer<void> hello = Completer<void>();
    host._stdoutSubscription = process.stdout.listen(
      (List<int> bytes) {
        try {
          for (final Map<String, Object?> message in host._decoder.add(bytes)) {
            if (message['kind'] == 'hostHello' && !hello.isCompleted) {
              if (message['protocolVersion'] != backendHostProtocolVersion) {
                hello.completeError(
                  const BackendHostProtocolException(
                    'Unsupported host protocol.',
                  ),
                );
              } else {
                hello.complete();
              }
              continue;
            }
            host._handleMessage(message);
          }
        } on Object catch (error, stackTrace) {
          if (!hello.isCompleted) hello.completeError(error, stackTrace);
          unawaited(
            host._terminateAfterFailure(
              PluginConnectionClosed('Malformed host output: $error'),
            ),
          );
        }
      },
      onDone: () {
        if (!hello.isCompleted) {
          hello.completeError(
            const PluginConnectionClosed('Backend host exited before hello.'),
          );
        }
      },
    );
    host._stderrSubscription = process.stderr
        .transform(SystemEncoding().decoder)
        .listen(
          (String message) => onDiagnostic?.call('backend-host: $message'),
        );
    unawaited(
      process.exitCode.then((int code) {
        if (host._shuttingDown && host._pending.isEmpty) {
          host._closed = true;
          return;
        }
        host._failAll(
          PluginConnectionClosed('Backend host exited with code $code.'),
        );
      }),
    );
    try {
      await hello.future.timeout(startupTimeout);
      return host;
    } on Object {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(shutdownTimeout);
      await host._stdoutSubscription.cancel();
      await host._stderrSubscription.cancel();
      await process.stdin.close();
      rethrow;
    }
  }

  bool get isClosed => _closed;
  int get processId => _process.pid;

  Future<PluginBackendConnection> startPlugin({
    required String pluginId,
    required Uri artifactUri,
    List<String> arguments = const <String>[],
  }) async {
    if (_plugins.containsKey(pluginId)) {
      throw StateError('Plugin $pluginId is already connected.');
    }
    if (_startingPlugins.containsKey(pluginId)) {
      throw StateError('Plugin $pluginId is already starting.');
    }
    final PluginBackendConnection connection = PluginBackendConnection._(
      host: this,
      pluginId: pluginId,
    );
    _startingPlugins[pluginId] = connection;
    try {
      final Map<String, Object?> response = await _command(
        kind: 'startPlugin',
        pluginId: pluginId,
        fields: <String, Object?>{
          'artifactUri': artifactUri.toString(),
          'arguments': List<String>.of(arguments, growable: false),
        },
      );
      if (response['kind'] != 'pluginReady') {
        throw _remoteFailure(response);
      }
      if (connection.isClosed || _startingPlugins[pluginId] != connection) {
        throw const PluginRemoteFailure(
          code: 'plugin_exited',
          message: 'The plugin terminated during startup.',
        );
      }
      _startingPlugins.remove(pluginId);
      _plugins[pluginId] = connection;
      return connection;
    } on Object {
      _startingPlugins.remove(pluginId);
      connection._finish(
        const PluginConnectionClosed('The plugin did not finish starting.'),
      );
      rethrow;
    }
  }

  Future<void> stopPlugin(String pluginId) async {
    final PluginBackendConnection? connection = _plugins.remove(pluginId);
    if (connection == null) return;
    final PluginConnectionClosed stopped = PluginConnectionClosed(
      'Plugin $pluginId was stopped.',
    );
    try {
      final Map<String, Object?> response = await _command(
        kind: 'stopPlugin',
        pluginId: pluginId,
        trackPluginRequest: false,
      );
      _failPluginRequests(pluginId, stopped);
      if (response['kind'] != 'pluginStopped') throw _remoteFailure(response);
    } finally {
      _failPluginRequests(pluginId, stopped);
      connection._finish(stopped);
    }
  }

  Future<void> close({bool graceful = true}) async {
    if (_closed) {
      await _termination;
      return;
    }
    if (graceful) {
      try {
        final Future<Map<String, Object?>> stopping = _command(
          kind: 'shutdownHost',
        );
        _shuttingDown = true;
        final Map<String, Object?> response = await stopping.timeout(
          _shutdownTimeout,
        );
        if (response['kind'] != 'hostStopped') throw _remoteFailure(response);
        await _process.exitCode.timeout(_shutdownTimeout);
      } on Object catch (error) {
        _onDiagnostic?.call('Backend host graceful shutdown failed: $error');
        _process.kill(ProcessSignal.sigkill);
        await _process.exitCode.timeout(_shutdownTimeout);
      }
    } else {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode.timeout(_shutdownTimeout);
    }
    _failAll(const PluginConnectionClosed('The backend host was stopped.'));
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
    await _process.stdin.close();
  }

  Future<Object?> _request(
    String pluginId,
    String method,
    Map<String, Object?> payload,
  ) async {
    final Map<String, Object?> response = await _command(
      kind: 'request',
      pluginId: pluginId,
      fields: <String, Object?>{'method': method, 'payload': payload},
    );
    if (response['ok'] == true) return response['payload'];
    throw _remoteFailure(response);
  }

  Future<Map<String, Object?>> _command({
    required String kind,
    String? pluginId,
    Map<String, Object?> fields = const <String, Object?>{},
    bool trackPluginRequest = true,
  }) {
    if (_closed) {
      return Future<Map<String, Object?>>.error(
        const PluginConnectionClosed('The backend host is closed.'),
      );
    }
    final int requestId = _nextRequestId++;
    final Completer<Map<String, Object?>> completer =
        Completer<Map<String, Object?>>();
    _pending[requestId] = completer;
    if (pluginId != null && trackPluginRequest) {
      _pendingPluginIds[requestId] = pluginId;
    }
    _process.stdin.add(
      encodeBackendHostFrame(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': kind,
        'requestId': requestId,
        'pluginId': ?pluginId,
        ...fields,
      }),
    );
    return completer.future;
  }

  void _handleMessage(Map<String, Object?> message) {
    if (message['kind'] == 'diagnostic') {
      _onDiagnostic?.call(
        '${message['stage'] ?? 'backend-host'}: ${message['message']}',
      );
      return;
    }
    if (message['kind'] == 'pluginFailed') {
      _handlePluginFailed(message);
      return;
    }
    final Object? rawRequestId = message['requestId'];
    if (rawRequestId is! int) {
      _onDiagnostic?.call('Host message without request ID ignored: $message');
      return;
    }
    final Completer<Map<String, Object?>>? completer = _pending.remove(
      rawRequestId,
    );
    _pendingPluginIds.remove(rawRequestId);
    if (completer == null) {
      _onDiagnostic?.call(
        'Unknown or duplicate host response ID $rawRequestId.',
      );
      return;
    }
    completer.complete(message);
  }

  void _handlePluginFailed(Map<String, Object?> message) {
    final Object? rawPluginId = message['pluginId'];
    if (rawPluginId is! String) {
      _onDiagnostic?.call('Plugin failure without plugin ID ignored.');
      return;
    }
    final PluginRemoteFailure failure = _remoteFailure(message);
    final Object? rawRequestIds = message['requestIds'];
    if (rawRequestIds is List) {
      for (final Object? rawRequestId in rawRequestIds) {
        if (rawRequestId is! int) continue;
        final Completer<Map<String, Object?>>? completer = _pending.remove(
          rawRequestId,
        );
        _pendingPluginIds.remove(rawRequestId);
        if (completer != null && !completer.isCompleted) {
          completer.completeError(failure);
        }
      }
    }
    final List<int> remaining = _pendingPluginIds.entries
        .where((MapEntry<int, String> entry) => entry.value == rawPluginId)
        .map((MapEntry<int, String> entry) => entry.key)
        .toList(growable: false);
    for (final int requestId in remaining) {
      final Completer<Map<String, Object?>>? completer = _pending.remove(
        requestId,
      );
      _pendingPluginIds.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(failure);
      }
    }
    _plugins.remove(rawPluginId)?._finish(failure);
    _startingPlugins.remove(rawPluginId)?._finish(failure);
    _onDiagnostic?.call(
      'plugin-isolate: $rawPluginId terminated (${failure.code}).',
    );
  }

  void _failAll(Object error) {
    if (_closed && _pending.isEmpty && _plugins.isEmpty) return;
    _closed = true;
    for (final Completer<Map<String, Object?>> completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    _pendingPluginIds.clear();
    for (final PluginBackendConnection connection in _plugins.values) {
      connection._finish(error);
    }
    _plugins.clear();
    for (final PluginBackendConnection connection in _startingPlugins.values) {
      connection._finish(error);
    }
    _startingPlugins.clear();
  }

  void _failPluginRequests(String pluginId, Object error) {
    final List<int> requestIds = _pendingPluginIds.entries
        .where((MapEntry<int, String> entry) => entry.value == pluginId)
        .map((MapEntry<int, String> entry) => entry.key)
        .toList(growable: false);
    for (final int requestId in requestIds) {
      _pendingPluginIds.remove(requestId);
      final Completer<Map<String, Object?>>? completer = _pending.remove(
        requestId,
      );
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  Future<void> _terminateAfterFailure(Object error) {
    return _termination ??= _doTerminateAfterFailure(error);
  }

  Future<void> _doTerminateAfterFailure(Object error) async {
    _failAll(error);
    if (_process.kill(ProcessSignal.sigkill)) {
      try {
        await _process.exitCode.timeout(_shutdownTimeout);
      } on Object catch (reapError) {
        _onDiagnostic?.call('Backend host reap failed: $reapError');
      }
    } else {
      await _process.exitCode.timeout(_shutdownTimeout);
    }
    await _process.stdin.close();
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
  }
}

final class PluginBackendConnection {
  PluginBackendConnection._({
    required PluginBackendHost host,
    required this.pluginId,
  }) : _host = host;

  final PluginBackendHost _host;
  final String pluginId;
  bool _closed = false;

  bool get isClosed => _closed || _host.isClosed;

  Future<Object?> request(String method, Map<String, Object?> payload) {
    if (isClosed) {
      return Future<Object?>.error(
        const PluginConnectionClosed('The plugin connection is closed.'),
      );
    }
    return _host._request(pluginId, method, payload);
  }

  Future<void> close() => _host.stopPlugin(pluginId);

  void _finish(Object _) => _closed = true;
}

PluginRemoteFailure _remoteFailure(Map<String, Object?> response) {
  final Object? rawError = response['error'];
  if (rawError is Map &&
      rawError['code'] is String &&
      rawError['message'] is String) {
    return PluginRemoteFailure(
      code: rawError['code'] as String,
      message: rawError['message'] as String,
      details: _stringMap(rawError['details']),
    );
  }
  return const PluginRemoteFailure(
    code: 'invalid_response',
    message: 'The backend host returned an invalid error response.',
  );
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return <String, Object?>{
    for (final MapEntry<Object?, Object?> entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}
