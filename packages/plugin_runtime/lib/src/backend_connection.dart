import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:adele_contract/adele_contract.dart';

import 'backend_host_protocol.dart';

const String _rawPluginServiceId = 'plugin';

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
  final Map<int, _HostServiceStream> _hostStreams = {};
  int _lastHostRequestId = -1;
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
  final Completer<Object> _terminated = Completer<Object>();
  Future<void>? _termination;

  static Future<PluginBackendHost> start({
    required String dartaotruntimeExecutable,
    required String hostArtifactPath,
    Duration startupTimeout = const Duration(seconds: 5),
    Duration shutdownTimeout = const Duration(seconds: 2),
    PluginDiagnosticSink? onDiagnostic,
    Map<String, String>? environment,
  }) async {
    final Process process = await Process.start(
      dartaotruntimeExecutable,
      <String>[hostArtifactPath],
      runInShell: false,
      environment: environment,
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
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object error) {
          if (host._closed) return;
          unawaited(
            host._terminateAfterFailure(
              PluginConnectionClosed('Backend host input failed: $error'),
            ),
          );
        },
      ),
    );
    unawaited(
      process.exitCode.then((int code) {
        if (host._shuttingDown &&
            host._pending.isEmpty &&
            host._streams.isEmpty) {
          host._closed = true;
          if (!host._terminated.isCompleted) {
            host._terminated.complete(
              const PluginConnectionClosed('The backend host was stopped.'),
            );
          }
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

  /// Completes with the first closure reason as a value, not a future error.
  /// This signals closure independently of plugin connections and cleanup.
  Future<Object> get terminated => _terminated.future;

  /// [startupArgumentsOnly] conveys explicit-configuration intent to the backend.
  /// It is bootstrap metadata, not process-environment isolation.
  /// [createInfrastructureServices] supplies only explicitly granted services for
  /// this exact connection. Dispatchers remain caller-owned. Capture the connection's
  /// [PluginBackendConnection.validateInfrastructureContext] for service-entry checks.
  Future<PluginBackendConnection> startPlugin({
    required String pluginId,
    required Uri artifactUri,
    List<String> arguments = const <String>[],
    bool startupArgumentsOnly = false,
    Map<String, AdeleBackendDispatcher> Function(
      PluginBackendConnection connection,
    )?
    createInfrastructureServices,
  }) async {
    if (_plugins.containsKey(pluginId)) {
      throw StateError('Plugin $pluginId is already connected.');
    }
    if (_startingPlugins.containsKey(pluginId)) {
      throw StateError('Plugin $pluginId is already starting.');
    }
    if (_stoppingPlugins.keys.any(
      (connection) => connection.pluginId == pluginId,
    )) {
      throw StateError('Plugin $pluginId is still stopping.');
    }
    final PluginBackendConnection connection = PluginBackendConnection._(
      host: this,
      pluginId: pluginId,
    );
    _startingPlugins[pluginId] = connection;
    bool readyReceived = false;
    try {
      final services =
          createInfrastructureServices?.call(connection) ??
          const <String, AdeleBackendDispatcher>{};
      for (final serviceId in services.keys) {
        adeleValidateServiceId(serviceId);
      }
      connection.validateInfrastructureContext();
      connection._infrastructure._services.addAll(services);
      final Map<String, Object?> response = await _command(
        kind: 'startPlugin',
        pluginId: pluginId,
        fields: <String, Object?>{
          'artifactUri': artifactUri.toString(),
          'generation': connection._generation,
          'hostInfrastructureContext': connection._infrastructure.id,
          'arguments': List<String>.of(arguments, growable: false),
          'startupArgumentsOnly': startupArgumentsOnly,
          'defaultConfigurationContext':
              connection.defaultConfigurationContext._wireValue,
        },
      );
      if (response['kind'] != 'pluginReady') {
        throw _remoteFailure(response);
      }
      readyReceived = true;
      if (connection.isClosed || _startingPlugins[pluginId] != connection) {
        throw const PluginRemoteFailure(
          code: 'plugin_exited',
          message: 'The plugin terminated during startup.',
        );
      }
      connection._capabilityExposures = AdeleCapabilityExposure.fromReady(
        response,
      );
      connection._extensionExposures = AdeleExtensionExposure.fromReady(
        response,
      );
      _startingPlugins.remove(pluginId);
      _plugins[pluginId] = connection;
      return connection;
    } on Object {
      connection.revokeInfrastructureContext();
      if (readyReceived && !connection.isClosed) {
        try {
          await _stopPlugin(connection).timeout(_shutdownTimeout);
        } on Object {
          await _terminateAfterFailure(
            const PluginConnectionClosed(
              'Invalid plugin readiness cleanup failed.',
            ),
          );
        }
      }
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
    connection._closing = true;
    connection.revokeInfrastructureContext();
    connection._revokeHostInvocations();
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
    _shuttingDown = true;
    for (final connection in [..._plugins.values, ..._startingPlugins.values]) {
      connection.revokeInfrastructureContext();
      connection._revokeHostInvocations();
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
    PluginBackendConnection owner,
    String configurationContext,
    String serviceId,
    String method,
    Map<String, Object?> payload,
  ) async {
    final String pluginId = owner.pluginId;
    if (owner.isClosed || _plugins[pluginId] != owner) {
      throw const PluginConnectionClosed(
        'The plugin connection generation is closed.',
      );
    }
    final Map<String, Object?> response = await _command(
      kind: 'request',
      pluginId: pluginId,
      fields: <String, Object?>{
        'configurationContext': configurationContext,
        'serviceId': serviceId,
        'method': method,
        'payload': payload,
      },
    );
    if (response['ok'] == true) return response['payload'];
    throw _remoteFailure(response);
  }

  Stream<Object?> _stream(
    PluginBackendConnection owner,
    String configurationContext,
    String serviceId,
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
            'configurationContext': configurationContext,
            'serviceId': serviceId,
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
    if (message['kind'] is String &&
        (message['kind'] as String).startsWith('hostStream')) {
      _handleHostStream(message);
      return;
    }
    if (message['kind'] == 'hostRequest') {
      unawaited(_handleHostRequest(message));
      return;
    }
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
    if (_isHostStreamKind(message['kind']) &&
        _pending.containsKey(rawRequestId)) {
      _hostProtocolViolation(
        'The backend host returned a stream frame for a non-stream request.',
      );
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

  Future<void> _handleHostRequest(Map<String, Object?> message) async {
    if (message.length != 10 ||
        message['protocolVersion'] != backendHostProtocolVersion ||
        message['requestId'] is! int ||
        message['pluginId'] is! String ||
        message['generation'] is! String ||
        !_validHostContext(message) ||
        message['serviceId'] is! String ||
        message['method'] is! String ||
        !_isStringKeyedMap(message['payload']) ||
        !_acceptHostRequestId(message['requestId'])) {
      _hostProtocolViolation('Malformed host request from shared host.');
      return;
    }
    final connection =
        _plugins[message['pluginId']] ?? _startingPlugins[message['pluginId']];
    final grant = connection?._hostGrant(message);
    final revoked = _hostContextRevoked(message);
    bool isLive() =>
        !_closed &&
        !_shuttingDown &&
        connection != null &&
        !connection.isClosed &&
        (_plugins[connection.pluginId] == connection ||
            _startingPlugins[connection.pluginId] == connection) &&
        connection._generation == message['generation'] &&
        grant != null &&
        !grant.isClosed;
    if (!isLive()) {
      _sendHostResponse(message, revoked);
      return;
    }
    final dispatcher = grant!._services[message['serviceId']];
    if (dispatcher == null) {
      _sendHostResponse(
        message,
        _hostFailure(
          'service_unavailable',
          'The service is not approved for this host context.',
        ),
      );
      return;
    }
    final requestId = message['requestId'] as int;
    if (grant._pending.containsKey(requestId)) {
      _hostProtocolViolation('Duplicate active host request from shared host.');
      return;
    }
    void settle(Map<String, Object?> response) =>
        _sendHostResponse(message, response);
    grant._pending[requestId] = settle;
    Map<String, Object?> response;
    try {
      response = await dispatcher.dispatch(<Object?, Object?>{
        'kind': 'request',
        'requestId': requestId,
        'method': message['method'],
        'payload': message['payload'],
      });
      if (response['kind'] != 'response' ||
          response['requestId'] != requestId ||
          (response['ok'] != true && response['ok'] != false) ||
          (response['ok'] == true
              ? !response.containsKey('payload')
              : !_validRemoteError(response['error']))) {
        response = _hostFailure(
          'internal_error',
          'Invalid host dispatcher response.',
        );
      }
    } on Object {
      response = _hostFailure(
        'internal_error',
        'Host service dispatch failed.',
      );
    }
    // Revocation already settled and removed this response, independently of host code.
    if (grant._pending.remove(requestId) == null) return;
    settle(isLive() ? response : revoked);
  }

  bool _acceptHostRequestId(Object? id) {
    if (id is! int || id < 0 || id <= _lastHostRequestId) return false;
    _lastHostRequestId = id;
    return true;
  }

  void _handleHostStream(Map<String, Object?> message) {
    final kind = message['kind'];
    final id = message['requestId'];
    final open = kind == 'hostStreamOpen';
    final credit = kind == 'hostStreamCredit';
    if (message['protocolVersion'] != backendHostProtocolVersion ||
        id is! int ||
        id < 0 ||
        message['pluginId'] is! String ||
        message['generation'] is! String ||
        message.length !=
            (open
                ? 10
                : credit
                ? 6
                : 5) ||
        (open &&
            (!_validHostContext(message) ||
                message['serviceId'] is! String ||
                message['method'] is! String ||
                !_isStringKeyedMap(message['payload']))) ||
        (!open &&
            !credit &&
            kind != 'hostStreamCancel' &&
            kind != 'hostStreamAck') ||
        (credit && (message['credit'] is! int || message['credit'] != 1))) {
      _hostProtocolViolation(
        'Malformed reverse stream frame from shared host.',
      );
      return;
    }
    if (open) {
      try {
        adeleValidateConfigurationContext(message['hostContext'] as String);
        adeleValidateServiceId(message['serviceId'] as String);
        if ((message['method'] as String).isEmpty) {
          throw const AdeleProtocolException('Empty host stream method.');
        }
        adeleSnapshotJsonMap(
          (message['payload'] as Map).cast<String, Object?>(),
          maxNodes: adelePluginBackendJsonMaxNodes,
        );
      } on Object {
        _hostProtocolViolation(
          'Malformed reverse stream open from shared host.',
        );
        return;
      }
      if (!_acceptHostRequestId(id)) {
        _hostProtocolViolation('Replayed reverse stream ID from shared host.');
        return;
      }
      final connection =
          _plugins[message['pluginId']] ??
          _startingPlugins[message['pluginId']];
      final grant = connection?._hostGrant(message);
      final live =
          !_closed &&
          !_shuttingDown &&
          connection != null &&
          !connection.isClosed &&
          connection._generation == message['generation'] &&
          grant != null &&
          !grant.isClosed;
      final dispatcher = live ? grant._services[message['serviceId']] : null;
      final stream = _HostServiceStream(
        message,
        live ? grant : null,
        dispatcher,
      );
      _hostStreams[id] = stream;
      if (dispatcher == null) {
        _finishHostStream(
          stream,
          'hostStreamFailure',
          error: live
              ? _hostFailure(
                  'service_unavailable',
                  'The service is not approved for this host context.',
                )['error']
              : _hostContextRevoked(message)['error'],
        );
        return;
      }
      grant!._streams.add(stream);
      _dispatchHostStream(stream, {
        'kind': 'streamOpen',
        'requestId': id,
        'method': message['method'],
        'payload': message['payload'],
      });
      return;
    }
    final stream = _hostStreams[id];
    if (stream == null ||
        stream.request['pluginId'] != message['pluginId'] ||
        stream.request['generation'] != message['generation']) {
      _hostProtocolViolation(
        'Unknown or cross-generation reverse stream control.',
      );
      return;
    }
    if (kind == 'hostStreamAck') {
      if (!stream.terminal) {
        _hostProtocolViolation(
          'Premature reverse stream terminal acknowledgement.',
        );
        return;
      }
      _hostStreams.remove(id);
    } else {
      if (credit) {
        if (stream.credit != 0 || stream.cancelRequested) {
          _hostProtocolViolation(
            'Excess reverse stream credit from shared host.',
          );
          return;
        }
        stream.credit = 1;
        if (stream.terminal) return;
        _dispatchHostStream(stream, {
          'kind': 'streamCredit',
          'requestId': id,
          'credit': 1,
        });
      } else {
        if (stream.cancelRequested) {
          _hostProtocolViolation('Duplicate reverse stream cancellation.');
          return;
        }
        stream.cancelRequested = true;
        _finishHostStream(stream, 'hostStreamCancelled', cancel: true);
      }
    }
  }

  void _dispatchHostStream(
    _HostServiceStream stream,
    Map<Object?, Object?> command,
  ) {
    try {
      unawaited(
        stream.dispatcher!
            .handle(command, (event) {
              if (stream.terminal) return;
              final kind = event['kind'];
              final item = kind == 'streamItem';
              final failure = kind == 'streamFailure';
              try {
                if (event['requestId'] != stream.request['requestId'] ||
                    event.length != (item || failure ? 3 : 2) ||
                    (!item && !failure && kind != 'streamDone') ||
                    (item &&
                        (!event.containsKey('payload') ||
                            stream.credit != 1)) ||
                    (failure && !_validRemoteError(event['error']))) {
                  throw const AdeleProtocolException(
                    'Malformed host dispatcher stream output.',
                  );
                }
                adeleSnapshotJsonMap(
                  event,
                  maxNodes: adelePluginBackendJsonMaxNodes,
                );
                if (item) {
                  stream.credit = 0;
                  _sendHostStream(
                    stream,
                    'hostStreamItem',
                    payload: event['payload'],
                  );
                } else {
                  _finishHostStream(
                    stream,
                    failure ? 'hostStreamFailure' : 'hostStreamDone',
                    error: event['error'],
                  );
                }
              } on Object {
                _failHostStream(stream);
              }
            })
            .catchError((Object _) => _failHostStream(stream)),
      );
    } on Object {
      _failHostStream(stream);
    }
  }

  void _failHostStream(_HostServiceStream stream) {
    if (stream.terminal) return;
    _finishHostStream(
      stream,
      'hostStreamFailure',
      cancel: true,
      error: _hostFailure(
        'internal_error',
        'Host stream dispatch or encoding failed.',
      )['error'],
    );
  }

  void _finishHostStream(
    _HostServiceStream stream,
    String kind, {
    Object? error,
    bool cancel = false,
  }) {
    if (stream.terminal) return;
    stream.terminal = true;
    stream.grant?._streams.remove(stream);
    // Revoke output first, initiate producer cancellation, then acknowledge it.
    // Never await user cleanup or let its failure replace the operation failure.
    if (cancel && stream.dispatcher != null) {
      try {
        unawaited(
          stream.dispatcher!
              .handle({
                'kind': 'streamCancel',
                'requestId': stream.request['requestId'],
              }, (_) {})
              .catchError((Object _) {}),
        );
      } on Object {
        /* Cancellation is best effort after revocation. */
      }
    }
    try {
      _sendHostStream(stream, kind, error: error);
    } on Object {
      try {
        _sendHostStream(
          stream,
          'hostStreamFailure',
          error: _hostFailure(
            'response_encoding_failed',
            'Host stream terminal could not be transported.',
          )['error'],
        );
      } on Object {
        _hostProtocolViolation('Failed to send host stream terminal.');
      }
    }
  }

  void _sendHostStream(
    _HostServiceStream stream,
    String kind, {
    Object? payload,
    Object? error,
  }) {
    if (_closed) return;
    _send({
      'protocolVersion': backendHostProtocolVersion,
      'kind': kind,
      'requestId': stream.request['requestId'],
      'pluginId': stream.request['pluginId'],
      'generation': stream.request['generation'],
      if (kind == 'hostStreamItem') 'payload': payload,
      if (kind == 'hostStreamFailure') 'error': error,
    });
  }

  void _sendHostResponse(
    Map<String, Object?> request,
    Map<String, Object?> response,
  ) {
    if (_closed) return;
    final envelope = <String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'hostResponse',
      'requestId': request['requestId'],
      'pluginId': request['pluginId'],
      'generation': request['generation'],
      'ok': response['ok'],
      if (response['ok'] == true)
        'payload': response['payload']
      else
        'error': response['error'],
    };
    try {
      _send(envelope);
    } on Object {
      try {
        _send(
          envelope
            ..remove('payload')
            ..addAll(
              _hostFailure(
                'response_encoding_failed',
                'Host response could not be transported.',
              ),
            ),
        );
      } on Object {
        _hostProtocolViolation('Failed to send host response.');
      }
    }
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
    if ((_isHostStreamKind(message['kind']) || message['kind'] == 'error') &&
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
        if (!stream.cancelSent) {
          _hostProtocolViolation(
            'The backend host returned an unsolicited stream cancellation forwarding acknowledgement.',
          );
          return;
        }
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
      'error' => const <String>{
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
    final Object? error = message['error'];
    final bool validError =
        (kind != 'error' && kind != 'streamFailure') ||
        _validRemoteError(error);
    return expected.isNotEmpty &&
        message.length == expected.length &&
        message.keys.toSet().containsAll(expected) &&
        message['protocolVersion'] == backendHostProtocolVersion &&
        message['requestId'] == requestId &&
        message['pluginId'] == stream.pluginId &&
        validError;
  }

  bool _isStringKeyedMap(Object? value) =>
      value is Map && value.keys.every((Object? key) => key is String);

  bool _validRemoteError(Object? value) {
    if (value is! Map ||
        value['code'] is! String ||
        value['message'] is! String) {
      return false;
    }
    final bool hasDetails = value.containsKey('details');
    if (hasDetails && !_isStringKeyedMap(value['details'])) return false;
    final bool hasDeclaredFailure = value.containsKey('declaredFailureType');
    if (hasDeclaredFailure && value['declaredFailureType'] is! String) {
      return false;
    }
    return !hasDeclaredFailure || hasDetails;
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
    if (!_terminated.isCompleted) _terminated.complete(error);
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
    _hostStreams.clear();
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
    try {
      await _process.stdin.close();
    } on Object catch (closeError) {
      _onDiagnostic?.call('Backend host input cleanup failed: $closeError');
    }
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
  }
}

final class ConfigurationContextId {
  const ConfigurationContextId._(this._owner, this._wireValue);

  final PluginBackendConnection _owner;
  final String _wireValue;
}

final class PluginBackendConnection implements AdeleStreamChannel {
  PluginBackendConnection._({
    required PluginBackendHost host,
    required this.pluginId,
  }) : _host = host;

  final PluginBackendHost _host;
  final String pluginId;
  final String _generation = _opaqueHostId();
  List<AdeleCapabilityExposure> _capabilityExposures = const [];
  List<AdeleCapabilityExposure> get capabilityExposures => _capabilityExposures;
  List<AdeleExtensionExposure> _extensionExposures = const [];
  List<AdeleExtensionExposure> get extensionExposures => _extensionExposures;
  final Map<String, PluginHostInvocation> _hostInvocations = {};
  late final _HostServiceGrant _infrastructure = _HostServiceGrant(
    this,
    const {},
    _hostInfrastructureRevoked,
  );
  late final ConfigurationContextId defaultConfigurationContext =
      ConfigurationContextId._(this, 'default');
  final Completer<Object> _termination = Completer<Object>();
  bool _closed = false;
  bool _closing = false;

  bool get isClosed => _closed || _closing || _host.isClosed;
  Future<Object> get terminated => _termination.future;

  /// Revalidates this generation's infrastructure grant at service entry, including
  /// calls queued by a generated dispatcher before retirement. Never re-resolves.
  void validateInfrastructureContext() {
    if (isClosed ||
        _host._shuttingDown ||
        _infrastructure.isClosed ||
        (_host._plugins[pluginId] != this &&
            _host._startingPlugins[pluginId] != this)) {
      throw const PluginConnectionClosed(
        'The host infrastructure context is not active for this connection generation.',
      );
    }
  }

  /// Permanently revokes infrastructure before any asynchronous cleanup. Pending
  /// calls and streams settle without waiting for caller-owned service code.
  void revokeInfrastructureContext() => _infrastructure.close();

  _HostServiceGrant? _hostGrant(Map<String, Object?> message) =>
      switch (message['hostContextKind']) {
        'invocation' => _hostInvocations[message['hostContext']]?._grant,
        'infrastructure' when message['hostContext'] == _infrastructure.id =>
          _infrastructure,
        _ => null,
      };

  /// Grants only these services to this exact connection until synchronous close.
  /// Dispatchers remain caller-owned; their cleanup need not block revocation.
  PluginHostInvocation openHostInvocation(
    Map<String, AdeleBackendDispatcher> services,
  ) {
    if (isClosed || _host._shuttingDown || _host._plugins[pluginId] != this) {
      throw const PluginConnectionClosed(
        'The plugin connection generation is closed.',
      );
    }
    for (final serviceId in services.keys) {
      adeleValidateServiceId(serviceId);
    }
    final invocation = PluginHostInvocation._(this, services);
    _hostInvocations[invocation.id] = invocation;
    return invocation;
  }

  void _revokeHostInvocations() {
    for (final invocation in _hostInvocations.values.toList()) {
      invocation.close();
    }
  }

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    if (isClosed) {
      return Future<Object?>.error(
        const PluginConnectionClosed('The plugin connection is closed.'),
      );
    }
    return _host._request(
      this,
      defaultConfigurationContext._wireValue,
      _rawPluginServiceId,
      method,
      payload,
    );
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    if (isClosed) {
      return Stream<Object?>.error(
        const PluginConnectionClosed('The plugin connection is closed.'),
      );
    }
    return _host._stream(
      this,
      defaultConfigurationContext._wireValue,
      _rawPluginServiceId,
      method,
      payload,
    );
  }

  ConfigurationContextId configurationContext(String opaqueId) {
    adeleValidateConfigurationContext(opaqueId);
    return ConfigurationContextId._(this, opaqueId);
  }

  AdeleStreamChannel channelFor(
    ConfigurationContextId context,
    String serviceId,
  ) {
    if (!identical(context._owner, this)) {
      throw ArgumentError.value(
        context,
        'context',
        'Configuration context belongs to another plugin generation.',
      );
    }
    if (serviceId.isEmpty) {
      throw ArgumentError.value(serviceId, 'serviceId', 'Service ID is empty.');
    }
    return _ConfigurationContextChannel(this, context._wireValue, serviceId);
  }

  Future<void> close() {
    if (_closed) return Future<void>.value();
    return _host.stopPlugin(pluginId, expected: this);
  }

  void _finish(Object reason) {
    _closed = true;
    revokeInfrastructureContext();
    _revokeHostInvocations();
    _host._hostStreams.removeWhere(
      (_, stream) =>
          stream.request['pluginId'] == pluginId &&
          stream.request['generation'] == _generation,
    );
    if (!_termination.isCompleted) _termination.complete(reason);
  }
}

final class PluginHostInvocation {
  PluginHostInvocation._(
    this._owner,
    Map<String, AdeleBackendDispatcher> services,
  ) : _grant = _HostServiceGrant(_owner, services, _hostInvocationRevoked);

  final PluginBackendConnection _owner;
  final _HostServiceGrant _grant;
  String get id => _grant.id;
  bool get isClosed => _grant.isClosed;

  /// Immediately revokes authority and settles pending responses, without waiting
  /// for arbitrary service code or taking ownership of dispatcher cleanup.
  void close() {
    _owner._hostInvocations.remove(id);
    _grant.close();
  }
}

final class _HostServiceGrant {
  _HostServiceGrant(
    this._owner,
    Map<String, AdeleBackendDispatcher> services,
    this._revoked,
  ) : _services = Map.of(services);

  final PluginBackendConnection _owner;
  final String id = _opaqueHostId();
  final Map<String, Object?> _revoked;
  final Map<String, AdeleBackendDispatcher> _services;
  final Map<int, void Function(Map<String, Object?>)> _pending = {};
  final Set<_HostServiceStream> _streams = {};
  bool _closed = false;
  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    _services.clear();
    for (final stream in _streams.toList()) {
      _owner._host._finishHostStream(
        stream,
        'hostStreamFailure',
        error: _revoked['error'],
        cancel: true,
      );
    }
    final pending = _pending.values.toList();
    _pending.clear();
    for (final settle in pending) {
      settle(_revoked);
    }
  }
}

final class _HostServiceStream {
  _HostServiceStream(this.request, this.grant, this.dispatcher);
  final Map<String, Object?> request;
  final _HostServiceGrant? grant;
  final AdeleBackendDispatcher? dispatcher;
  int credit = 0;
  bool terminal = false;
  bool cancelRequested = false;
}

final Random _hostRandom = Random.secure();
String _opaqueHostId() => List.generate(
  32,
  (_) => _hostRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

Map<String, Object?> _hostFailure(String code, String message) => {
  'ok': false,
  'error': <String, Object?>{'code': code, 'message': message},
};

final Map<String, Object?> _hostInvocationRevoked = _hostFailure(
  'host_invocation_unavailable',
  'The host invocation is not active for this connection generation.',
);

final Map<String, Object?> _hostInfrastructureRevoked = _hostFailure(
  'host_infrastructure_unavailable',
  'The host infrastructure context is not active for this connection generation.',
);

bool _validHostContext(Map<String, Object?> message) =>
    (message['hostContextKind'] == 'invocation' ||
        message['hostContextKind'] == 'infrastructure') &&
    message['hostContext'] is String &&
    (message['hostContext'] as String).isNotEmpty;

Map<String, Object?> _hostContextRevoked(Map<String, Object?> message) =>
    message['hostContextKind'] == 'infrastructure'
    ? _hostInfrastructureRevoked
    : _hostInvocationRevoked;

final class _ConfigurationContextChannel implements AdeleStreamChannel {
  const _ConfigurationContextChannel(
    this._connection,
    this._configurationContext,
    this._serviceId,
  );

  final PluginBackendConnection _connection;
  final String _configurationContext;
  final String _serviceId;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      _connection._host._request(
        _connection,
        _configurationContext,
        _serviceId,
        method,
        payload,
      );

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      _connection._host._stream(
        _connection,
        _configurationContext,
        _serviceId,
        method,
        payload,
      );
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
