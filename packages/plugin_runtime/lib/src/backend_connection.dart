import 'dart:async';
import 'dart:io';

import 'package:adele_contract/adele_contract.dart';

import 'backend_host_protocol.dart';

typedef PluginDiagnosticSink = void Function(String message);

final class PluginRemoteFailure implements AdeleRemoteFailure {
  const PluginRemoteFailure({
    required this.code,
    required this.message,
    this.details = const <String, Object?>{},
    this.declaredFailureType,
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
  final Map<int, _PendingPluginStream> _streams = <int, _PendingPluginStream>{};
  final Map<int, String> _pendingPluginIds = <int, String>{};
  final Map<String, PluginBackendConnection> _plugins =
      <String, PluginBackendConnection>{};
  final Map<String, PluginBackendConnection> _startingPlugins =
      <String, PluginBackendConnection>{};
  final Map<PluginBackendConnection, Future<void>> _stoppingPlugins =
      <PluginBackendConnection, Future<void>>{};
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
                    'Unsupported host protocol. Runtime and backend-host artifacts must be deployed atomically.',
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
        if (host._shuttingDown &&
            host._pending.isEmpty &&
            host._streams.isEmpty) {
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

  Future<void> stopPlugin(
    String pluginId, {
    PluginBackendConnection? expected,
  }) {
    if (expected != null) {
      final Future<void>? stopping = _stoppingPlugins[expected];
      if (stopping != null) return stopping;
    }
    final PluginBackendConnection? connection = _plugins[pluginId];
    if (connection == null || (expected != null && connection != expected)) {
      return Future<void>.value();
    }
    late final Future<void> stopping;
    stopping = _stopPlugin(connection).whenComplete(() {
      _stoppingPlugins.remove(connection);
    });
    _stoppingPlugins[connection] = stopping;
    _plugins.remove(pluginId);
    return stopping;
  }

  Future<void> _stopPlugin(PluginBackendConnection connection) async {
    final String pluginId = connection.pluginId;
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

  Stream<Object?> _stream(
    PluginBackendConnection owner,
    String method,
    Map<String, Object?> payload,
  ) {
    final String pluginId = owner.pluginId;
    late final StreamController<Object?> controller;
    int? requestId;
    controller = StreamController<Object?>(
      sync: true,
      onListen: () {
        if (_closed) {
          controller.addError(
            const PluginConnectionClosed('The backend host is closed.'),
          );
          unawaited(controller.close());
          return;
        }
        if (owner.isClosed || _plugins[pluginId] != owner) {
          controller.addError(
            const PluginConnectionClosed(
              'The plugin connection generation is closed.',
            ),
          );
          unawaited(controller.close());
          return;
        }
        final int id = _nextRequestId++;
        requestId = id;
        final _PendingPluginStream stream = _PendingPluginStream(
          owner,
          controller,
        );
        _streams[id] = stream;
        _pendingPluginIds[id] = pluginId;
        try {
          _send(<String, Object?>{
            'protocolVersion': backendHostProtocolVersion,
            'kind': 'streamOpen',
            'requestId': id,
            'pluginId': pluginId,
            'method': method,
            'payload': payload,
          });
          _grantStreamCredit(id, stream);
        } on Object catch (error, stackTrace) {
          _finishStream(id, error: error, stackTrace: stackTrace);
        }
      },
      onResume: () {
        final int? id = requestId;
        final _PendingPluginStream? stream = id == null ? null : _streams[id];
        if (id != null &&
            stream != null &&
            stream.creditWithheld &&
            !stream.cancelSent) {
          stream.creditWithheld = false;
          _grantStreamCredit(id, stream);
        }
      },
      onCancel: () async {
        final int? id = requestId;
        if (id == null) return;
        final _PendingPluginStream? stream = _streams[id];
        if (stream == null) return;
        final Completer<void> cancellation = stream.cancelCompleter ??=
            Completer<void>();
        final Completer<void> forwarded = stream.cancelForwardedCompleter ??=
            Completer<void>();
        if (!stream.cancelSent) {
          stream.cancelSent = true;
          _sendStreamControl(id, pluginId, 'streamCancel');
        }
        await Future.any<void>(<Future<void>>[
          cancellation.future,
          forwarded.future,
        ]);
        if (!cancellation.isCompleted) {
          try {
            await cancellation.future.timeout(_shutdownTimeout);
          } on TimeoutException {
            await _retireCancellationOwner(id, stream);
          }
        }
      },
    );
    return controller.stream;
  }

  void _grantStreamCredit(int requestId, _PendingPluginStream stream) {
    if (stream.outstandingCredit != 0 || stream.cancelSent) return;
    stream.outstandingCredit = 1;
    _sendStreamControl(requestId, stream.pluginId, 'streamCredit', credit: 1);
  }

  Future<void> _retireCancellationOwner(
    int requestId,
    _PendingPluginStream stream,
  ) async {
    final PluginConnectionClosed failure = PluginConnectionClosed(
      'Plugin ${stream.pluginId} did not acknowledge stream cancellation.',
    );
    if (_streams[requestId] != stream) return;
    final Future<void>? stopping = _stoppingPlugins[stream.owner];
    if (_plugins[stream.pluginId] == stream.owner || stopping != null) {
      try {
        await (stopping ?? stopPlugin(stream.pluginId, expected: stream.owner));
      } on Object {
        if (_plugins[stream.pluginId] == stream.owner) {
          _plugins.remove(stream.pluginId);
          _failPluginRequests(stream.pluginId, failure);
          stream.owner._finish(failure);
        }
      }
    }
    _finishStream(requestId, error: failure);
  }

  void _send(Map<String, Object?> message) {
    _process.stdin.add(encodeBackendHostFrame(message));
  }

  void _sendStreamControl(
    int requestId,
    String pluginId,
    String kind, {
    int? credit,
  }) {
    try {
      _send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': kind,
        'requestId': requestId,
        'pluginId': pluginId,
        'credit': ?credit,
      });
    } on Object catch (error, stackTrace) {
      _finishStream(requestId, error: error, stackTrace: stackTrace);
    }
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
    try {
      final List<int> frame = encodeBackendHostFrame(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': kind,
        'requestId': requestId,
        'pluginId': ?pluginId,
        ...fields,
      });
      _process.stdin.add(frame);
    } on Object catch (error, stackTrace) {
      _pending.remove(requestId);
      _pendingPluginIds.remove(requestId);
      completer.completeError(error, stackTrace);
    }
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
      if (_isHostStreamKind(message['kind'])) {
        _hostProtocolViolation(
          'The backend host returned an uncorrelatable stream frame.',
        );
        return;
      }
      _onDiagnostic?.call('Host message without request ID ignored: $message');
      return;
    }
    if (_streams.containsKey(rawRequestId)) {
      _handleStreamMessage(rawRequestId, message);
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

  bool _isHostStreamKind(Object? kind) => switch (kind) {
    'streamItem' ||
    'streamDone' ||
    'streamFailure' ||
    'streamCancelled' ||
    'streamCancelForwarded' => true,
    _ => false,
  };

  void _handleStreamMessage(int requestId, Map<String, Object?> message) {
    final _PendingPluginStream? stream = _streams[requestId];
    if (stream == null) {
      _onDiagnostic?.call('Unknown or late stream response ID $requestId.');
      return;
    }
    if (message['pluginId'] != stream.pluginId) {
      _hostProtocolViolation(
        'The backend host returned a stream frame for the wrong plugin.',
      );
      return;
    }
    if (_isHostStreamKind(message['kind']) &&
        !_validHostStreamFrame(requestId, stream, message)) {
      _hostProtocolViolation(
        'The backend host returned a malformed stream frame.',
      );
      return;
    }
    switch (message['kind']) {
      case 'streamItem':
        if (stream.outstandingCredit != 1) {
          _hostProtocolViolation(
            'The backend host returned a stream item without credit.',
          );
          return;
        }
        stream.outstandingCredit = 0;
        stream.controller.add(message['payload']);
        if (!stream.controller.isPaused && !stream.controller.isClosed) {
          _grantStreamCredit(requestId, stream);
        } else {
          stream.creditWithheld = true;
        }
      case 'streamCancelForwarded':
        final Completer<void>? forwarded = stream.cancelForwardedCompleter;
        if (forwarded != null && !forwarded.isCompleted) forwarded.complete();
      case 'streamDone':
        _finishStream(requestId);
      case 'streamFailure':
        _finishStream(requestId, error: _remoteFailure(message));
      case 'streamCancelled':
        if (!stream.cancelSent) {
          _hostProtocolViolation(
            'The backend host returned an unsolicited stream cancellation.',
          );
          return;
        }
        _finishStream(requestId, cancelled: true);
      case 'error':
        _finishStream(requestId, error: _remoteFailure(message));
      default:
        _hostProtocolViolation(
          'The backend host returned an incompatible frame for an active stream.',
        );
    }
  }

  bool _validHostStreamFrame(
    int requestId,
    _PendingPluginStream stream,
    Map<String, Object?> message,
  ) {
    final Object? kind = message['kind'];
    final Set<String> expected = switch (kind) {
      'streamItem' => const <String>{
        'protocolVersion',
        'kind',
        'requestId',
        'pluginId',
        'payload',
      },
      'streamFailure' => const <String>{
        'protocolVersion',
        'kind',
        'requestId',
        'pluginId',
        'error',
      },
      'streamDone' || 'streamCancelled' || 'streamCancelForwarded' =>
        const <String>{'protocolVersion', 'kind', 'requestId', 'pluginId'},
      _ => const <String>{},
    };
    return expected.isNotEmpty &&
        message.length == expected.length &&
        message.keys.toSet().containsAll(expected) &&
        message['protocolVersion'] == backendHostProtocolVersion &&
        message['requestId'] == requestId &&
        message['pluginId'] == stream.pluginId;
  }

  void _finishStream(
    int requestId, {
    Object? error,
    StackTrace? stackTrace,
    bool cancelled = false,
  }) {
    final _PendingPluginStream? stream = _streams.remove(requestId);
    _pendingPluginIds.remove(requestId);
    if (stream == null) return;
    final Completer<void>? cancellation = stream.cancelCompleter;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    final Completer<void>? forwarded = stream.cancelForwardedCompleter;
    if (forwarded != null && !forwarded.isCompleted) forwarded.complete();
    if (cancelled && error == null) return;
    if (error != null) stream.controller.addError(error, stackTrace);
    unawaited(stream.controller.close());
  }

  void _handlePluginFailed(Map<String, Object?> message) {
    final Object? rawPluginId = message['pluginId'];
    if (rawPluginId is! String) {
      _onDiagnostic?.call('Plugin failure without plugin ID ignored.');
      return;
    }
    final Object? rawRequestIds = message['requestIds'];
    if (rawRequestIds is List) {
      for (final Object? rawRequestId in rawRequestIds) {
        if (rawRequestId is! int) continue;
        final String? knownOwner = _pendingPluginIds[rawRequestId];
        if (knownOwner != null && knownOwner != rawPluginId) {
          _hostProtocolViolation(
            'The backend host attributed a live request to the wrong plugin.',
          );
          return;
        }
      }
    }
    final PluginRemoteFailure failure = _remoteFailure(message);
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
        _finishStream(rawRequestId, error: failure);
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
      _finishStream(requestId, error: failure);
    }
    _plugins.remove(rawPluginId)?._finish(failure);
    _startingPlugins.remove(rawPluginId)?._finish(failure);
    _onDiagnostic?.call(
      'plugin-isolate: $rawPluginId terminated (${failure.code}).',
    );
  }

  void _failAll(Object error) {
    if (_closed && _pending.isEmpty && _streams.isEmpty && _plugins.isEmpty) {
      return;
    }
    _closed = true;
    for (final Completer<Map<String, Object?>> completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    for (final int requestId in _streams.keys.toList(growable: false)) {
      _finishStream(requestId, error: error);
    }
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
      _finishStream(requestId, error: error);
    }
  }

  Future<void> _terminateAfterFailure(Object error) {
    return _termination ??= _doTerminateAfterFailure(error);
  }

  void _hostProtocolViolation(String message) {
    unawaited(_terminateAfterFailure(PluginConnectionClosed(message)));
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

final class PluginBackendConnection implements AdeleStreamChannel {
  PluginBackendConnection._({
    required PluginBackendHost host,
    required this.pluginId,
  }) : _host = host;

  final PluginBackendHost _host;
  final String pluginId;
  final Completer<Object> _termination = Completer<Object>();
  bool _closed = false;

  bool get isClosed => _closed || _host.isClosed;
  Future<Object> get terminated => _termination.future;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    if (isClosed) {
      return Future<Object?>.error(
        const PluginConnectionClosed('The plugin connection is closed.'),
      );
    }
    return _host._request(pluginId, method, payload);
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    if (isClosed) {
      return Stream<Object?>.error(
        const PluginConnectionClosed('The plugin connection is closed.'),
      );
    }
    return _host._stream(this, method, payload);
  }

  Future<void> close() {
    if (_closed) return Future<void>.value();
    return _host.stopPlugin(pluginId, expected: this);
  }

  void _finish(Object reason) {
    _closed = true;
    if (!_termination.isCompleted) _termination.complete(reason);
  }
}

final class _PendingPluginStream {
  _PendingPluginStream(this.owner, this.controller);

  final PluginBackendConnection owner;
  String get pluginId => owner.pluginId;
  final StreamController<Object?> controller;
  Completer<void>? cancelCompleter;
  Completer<void>? cancelForwardedCompleter;
  bool cancelSent = false;
  bool creditWithheld = false;
  int outstandingCredit = 0;
}

PluginRemoteFailure _remoteFailure(Map<String, Object?> response) {
  final Object? rawError = response['error'];
  if (rawError is Map &&
      rawError['code'] is String &&
      rawError['message'] is String) {
    final Object? declaredFailureType = rawError['declaredFailureType'];
    final Object? rawDetails = rawError['details'];
    if (declaredFailureType != null &&
        (declaredFailureType is! String || !_isStringMap(rawDetails))) {
      return const PluginRemoteFailure(
        code: 'invalid_response',
        message: 'The backend host returned an invalid error response.',
      );
    }
    return PluginRemoteFailure(
      code: rawError['code'] as String,
      message: rawError['message'] as String,
      details: _stringMap(rawDetails),
      declaredFailureType: declaredFailureType as String?,
    );
  }
  return const PluginRemoteFailure(
    code: 'invalid_response',
    message: 'The backend host returned an invalid error response.',
  );
}

bool _isStringMap(Object? value) =>
    value is Map && value.keys.every((Object? key) => key is String);

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return <String, Object?>{
    for (final MapEntry<Object?, Object?> entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}
