import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const Duration _pluginLifecycleTimeout = Duration(seconds: 2);

typedef BackendHostSend = bool Function(Map<String, Object?> message);
typedef BackendHostDiagnostic = void Function(String message);

final class AdeleBackendHost {
  AdeleBackendHost({
    required BackendHostSend send,
    BackendHostDiagnostic? diagnostic,
  }) : _send = send,
       _diagnostic = diagnostic ?? stderr.writeln;

  final BackendHostSend _send;
  final BackendHostDiagnostic _diagnostic;
  final Map<String, _PluginIsolate> _plugins = <String, _PluginIsolate>{};
  final Map<int, (_PluginIsolate, int)> _hostRequests = {};
  final Map<int, _ReverseStream> _hostStreams = {};
  int _nextHostRequestId = 1;
  bool _shutDown = false;

  void noteStreamCancelRequested(Map<String, Object?> message) {
    if (message['protocolVersion'] != backendHostProtocolVersion ||
        message['kind'] != 'streamCancel') {
      return;
    }
    final Object? pluginId = message['pluginId'];
    final Object? requestId = message['requestId'];
    if (pluginId is! String || requestId is! int) return;
    _plugins[pluginId]?.noteStreamCancelRequested(requestId);
  }

  Future<bool> handle(Map<String, Object?> message) async {
    final Object? requestId = message['requestId'];
    if (message['protocolVersion'] != backendHostProtocolVersion) {
      _error(
        requestId,
        null,
        'unsupported_protocol',
        'Unsupported protocol version.',
      );
      return true;
    }
    try {
      if (_shutDown &&
          message['kind'] != 'hostResponse' &&
          !(message['kind'] is String &&
              (message['kind'] as String).startsWith('hostStream'))) {
        throw StateError('The backend host is shutting down.');
      }
      switch (message['kind']) {
        case 'hostResponse':
          _forwardHostResponse(message);
        case 'hostStreamItem':
        case 'hostStreamDone':
        case 'hostStreamFailure':
        case 'hostStreamCancelled':
          _forwardHostStreamResponse(message);
        case 'startPlugin':
          await _startPlugin(message);
        case 'stopPlugin':
          await _stopPlugin(message);
        case 'request':
          _forwardRequest(message);
        case 'streamOpen':
          _forwardStreamOpen(message);
        case 'streamCredit':
          _forwardStreamControl(message, 'streamCredit');
        case 'streamCancel':
          _forwardStreamControl(message, 'streamCancel');
        case 'shutdownHost':
          await shutdown(requestId: requestId);
          return false;
        default:
          _error(
            requestId,
            _pluginId(message),
            'unknown_kind',
            'Unknown host command.',
          );
      }
    } on Object catch (error, stackTrace) {
      _diagnostic('backend-host command failure: $error\n$stackTrace');
      if (message['kind'] is String &&
          (message['kind'] as String).startsWith('hostStream')) {
        await shutdown(notify: false);
        return false;
      }
      _error(
        requestId,
        _pluginId(message),
        'host_command_failed',
        error.toString(),
      );
    }
    return true;
  }

  Future<void> shutdown({Object? requestId, bool notify = true}) async {
    if (_shutDown) return;
    _shutDown = true;
    for (final _PluginIsolate plugin in _plugins.values.toList()) {
      _revokeHostRequests(plugin);
      await plugin.stop();
    }
    _plugins.clear();
    if (notify) {
      _send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'hostStopped',
        if (requestId is int) 'requestId': requestId,
      });
    }
  }

  Future<void> _startPlugin(Map<String, Object?> message) async {
    final String pluginId = _requireString(message, 'pluginId');
    if (_plugins.containsKey(pluginId)) {
      throw StateError('Plugin $pluginId is already running.');
    }
    final String artifactUri = _requireString(message, 'artifactUri');
    final String generation = _requireString(message, 'generation');
    final String defaultConfigurationContext = _requireString(
      message,
      'defaultConfigurationContext',
    );
    final Object? rawArguments = message['arguments'];
    if (rawArguments is! List ||
        rawArguments.any((Object? value) => value is! String)) {
      throw const FormatException('Plugin arguments must be strings.');
    }
    final Object? startupArgumentsOnly =
        message.containsKey('startupArgumentsOnly')
        ? message['startupArgumentsOnly']
        : false;
    if (startupArgumentsOnly is! bool) {
      throw const FormatException('startupArgumentsOnly must be a boolean.');
    }
    final _PluginIsolate plugin = await _PluginIsolate.start(
      pluginId: pluginId,
      generation: generation,
      artifactUri: Uri.parse(artifactUri),
      arguments: rawArguments
          .map((Object? value) => value! as String)
          .toList(growable: false),
      defaultConfigurationContext: defaultConfigurationContext,
      startupArgumentsOnly: startupArgumentsOnly,
      send: _send,
      diagnostic: _diagnostic,
      onTerminated: _pluginTerminated,
      onHostRequest: _forwardHostRequest,
    );
    _plugins[pluginId] = plugin;
    try {
      await Future<void>.delayed(Duration.zero);
      if (_shutDown || plugin.isTerminated) {
        throw StateError('Plugin $pluginId terminated during startup.');
      }
      if (!_send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'pluginReady',
        'requestId': message['requestId'],
        'pluginId': pluginId,
        'capabilityExposures': [
          for (final exposure in plugin.capabilityExposures) exposure.toMap(),
        ],
        'extensionExposures': [
          for (final exposure in plugin.extensionExposures) exposure.toMap(),
        ],
      })) {
        throw StateError('Could not send plugin readiness.');
      }
    } on Object {
      if (identical(_plugins[pluginId], plugin)) _plugins.remove(pluginId);
      try {
        await plugin.stop();
      } on Object catch (error) {
        _diagnostic('Plugin $pluginId startup cleanup failed: $error');
      }
      rethrow;
    }
  }

  Future<void> _stopPlugin(Map<String, Object?> message) async {
    final String pluginId = _requireString(message, 'pluginId');
    final _PluginIsolate? plugin = _plugins.remove(pluginId);
    if (plugin == null) throw StateError('Plugin $pluginId is not running.');
    _revokeHostRequests(plugin);
    await plugin.stop();
    _send(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'pluginStopped',
      'requestId': message['requestId'],
      'pluginId': pluginId,
    });
  }

  void _forwardRequest(Map<String, Object?> message) {
    final String pluginId = _requireString(message, 'pluginId');
    final _PluginIsolate? plugin = _plugins[pluginId];
    if (plugin == null) throw StateError('Plugin $pluginId is not running.');
    plugin.request(message);
  }

  void _forwardStreamOpen(Map<String, Object?> message) {
    final String pluginId = _requireString(message, 'pluginId');
    final _PluginIsolate? plugin = _plugins[pluginId];
    if (plugin == null) throw StateError('Plugin $pluginId is not running.');
    plugin.openStream(message);
  }

  void _forwardStreamControl(Map<String, Object?> message, String kind) {
    final String pluginId = _requireString(message, 'pluginId');
    final _PluginIsolate? plugin = _plugins[pluginId];
    if (plugin == null) throw StateError('Plugin $pluginId is not running.');
    plugin.streamControl(message, kind);
  }

  void _forwardHostRequest(
    _PluginIsolate plugin,
    Map<Object?, Object?> request,
  ) {
    if (request['kind'] != 'hostRequest') {
      _forwardHostStream(plugin, request);
      return;
    }
    if (_shutDown || !identical(_plugins[plugin.pluginId], plugin)) {
      plugin.hostResponse(request['requestId'] as int, {
        'ok': false,
        'error': {
          'code': 'host_invocation_unavailable',
          'message': 'Plugin generation is not active.',
        },
      });
      return;
    }
    final id = _nextHostRequestId++;
    _hostRequests[id] = (plugin, request['requestId'] as int);
    final message = <String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'hostRequest',
      'requestId': id,
      'pluginId': plugin.pluginId,
      'generation': plugin.generation,
      'hostInvocationContext': request['hostInvocationContext'],
      'serviceId': request['serviceId'],
      'method': request['method'],
      'payload': request['payload'],
    };
    if (!_send(message)) {
      _hostRequests.remove(id);
      plugin.hostResponse(request['requestId'] as int, {
        'ok': false,
        'error': {
          'code': 'host_request_encoding_failed',
          'message': 'Host request could not be transported.',
        },
      });
    }
  }

  void _forwardHostStream(
    _PluginIsolate plugin,
    Map<Object?, Object?> request,
  ) {
    final kind = request['kind'];
    final localId = request['requestId'] as int;
    if (kind == 'hostStreamOpen') {
      if (_shutDown || !identical(_plugins[plugin.pluginId], plugin)) {
        plugin._reverseProtocolViolation();
        return;
      }
      final id = _nextHostRequestId++;
      final stream = _ReverseStream(plugin, localId, id);
      _hostStreams[id] = stream;
      plugin._hostStreamIds[localId] = id;
      final message = <String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': kind,
        'requestId': id,
        'pluginId': plugin.pluginId,
        'generation': plugin.generation,
        'hostInvocationContext': request['hostInvocationContext'],
        'serviceId': request['serviceId'],
        'method': request['method'],
        'payload': request['payload'],
      };
      if (!_send(message)) {
        // No runtime operation exists. Retain only until terminal receipt.
        stream.localFailure = true;
        _hostStreamTerminal(
          stream,
          'hostStreamFailure',
          error: {
            'code': 'host_request_encoding_failed',
            'message': 'Host stream request could not be transported.',
          },
        );
      }
      return;
    }
    final id = plugin._hostStreamIds[localId];
    final stream = _hostStreams[id];
    if (stream == null) {
      if (plugin._stopped || plugin.isTerminated) return;
      plugin._reverseProtocolViolation();
      return;
    }
    if (kind == 'hostStreamAck') {
      if (!stream.terminal) {
        plugin._reverseProtocolViolation();
        return;
      }
      _removeHostStream(stream);
    } else {
      if (kind == 'hostStreamCredit') {
        if (stream.credit != 0 || stream.cancelling) {
          plugin._reverseProtocolViolation();
          return;
        }
        stream.credit = 1;
      } else {
        if (stream.cancelling) {
          plugin._reverseProtocolViolation();
          return;
        }
        stream.cancelling = true;
      }
    }
    if (!stream.localFailure) {
      _send({
        'protocolVersion': backendHostProtocolVersion,
        'kind': kind,
        'requestId': id,
        'pluginId': plugin.pluginId,
        'generation': plugin.generation,
        if (kind == 'hostStreamCredit') 'credit': 1,
      });
    }
  }

  void _forwardHostStreamResponse(Map<String, Object?> message) {
    final stream = _hostStreams[message['requestId']];
    // A retired generation can have a response already in flight.
    if (stream == null) return;
    final kind = message['kind'];
    final item = kind == 'hostStreamItem';
    final failure = kind == 'hostStreamFailure';
    if (message['pluginId'] != stream.plugin.pluginId ||
        message['generation'] != stream.plugin.generation ||
        stream.terminal ||
        message.length != (item || failure ? 6 : 5) ||
        (item && (!message.containsKey('payload') || stream.credit != 1)) ||
        (failure &&
            !stream.plugin._validStreamFailureError(message['error'])) ||
        (kind == 'hostStreamCancelled' && !stream.cancelling)) {
      // This is corruption of the shared host connection, not plugin output.
      throw const FormatException('Malformed runtime host stream response.');
    }
    if (item) {
      stream.credit = 0;
      stream.plugin._commands.send({
        'kind': kind,
        'requestId': stream.localId,
        'payload': message['payload'],
      });
    } else {
      _hostStreamTerminal(stream, kind as String, error: message['error']);
    }
  }

  void _hostStreamTerminal(
    _ReverseStream stream,
    String kind, {
    Object? error,
  }) {
    stream.terminal = true;
    stream.plugin._commands.send({
      'kind': kind,
      'requestId': stream.localId,
      if (kind == 'hostStreamFailure') 'error': error,
    });
    // Bounded terminal tombstones allow in-flight credit/cancel until receipt.
    stream.ackTimeout = Timer(_pluginLifecycleTimeout, () {
      _removeHostStream(stream);
      stream.plugin._reverseProtocolViolation();
    });
  }

  void _removeHostStream(_ReverseStream stream) {
    _hostStreams.remove(stream.outerId);
    stream.plugin._hostStreamIds.remove(stream.localId);
    stream.ackTimeout?.cancel();
  }

  void _forwardHostResponse(Map<String, Object?> message) {
    final pending = _hostRequests[message['requestId']];
    if (pending == null) return;
    final (plugin, requestId) = pending;
    // The captured isolate, not the current plugin with the same ID, owns the reply.
    if (message['pluginId'] != plugin.pluginId ||
        message['generation'] != plugin.generation) {
      return;
    }
    _hostRequests.remove(message['requestId']);
    plugin.hostResponse(requestId, message);
  }

  void _revokeHostRequests(_PluginIsolate plugin) {
    for (final stream in _hostStreams.values.toList()) {
      if (!identical(stream.plugin, plugin)) continue;
      if (!stream.terminal) {
        _hostStreamTerminal(
          stream,
          'hostStreamFailure',
          error: {
            'code': 'host_invocation_unavailable',
            'message': 'Plugin generation is stopping.',
          },
        );
      }
      _removeHostStream(stream);
    }
    for (final entry in _hostRequests.entries.toList()) {
      if (!identical(entry.value.$1, plugin)) continue;
      _hostRequests.remove(entry.key);
      plugin.hostResponse(entry.value.$2, {
        'ok': false,
        'error': {
          'code': 'host_invocation_unavailable',
          'message': 'Plugin generation is stopping.',
        },
      });
    }
  }

  void _pluginTerminated(
    _PluginIsolate plugin,
    List<int> requestIds,
    String code,
    String message,
  ) {
    _hostRequests.removeWhere((_, request) => identical(request.$1, plugin));
    for (final stream in _hostStreams.values.toList()) {
      if (identical(stream.plugin, plugin)) _removeHostStream(stream);
    }
    final String pluginId = plugin.pluginId;
    if (!identical(_plugins[pluginId], plugin)) return;
    _plugins.remove(pluginId);
    _send(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'pluginFailed',
      'pluginId': pluginId,
      'requestIds': requestIds,
      'error': <String, Object?>{'code': code, 'message': message},
    });
  }

  void _error(
    Object? requestId,
    String? pluginId,
    String code,
    String message,
  ) {
    _send(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'error',
      if (requestId is int) 'requestId': requestId,
      'pluginId': ?pluginId,
      'error': <String, Object?>{'code': code, 'message': message},
    });
  }
}

final class _PluginIsolate {
  _PluginIsolate._({
    required this.pluginId,
    required this.generation,
    required this.capabilityExposures,
    required this.extensionExposures,
    required Isolate isolate,
    required SendPort commands,
    required ReceivePort responses,
    required Stream<Object?> errors,
    required Stream<Object?> exits,
    required void Function() closeLifecyclePorts,
    required BackendHostSend send,
    required BackendHostDiagnostic diagnostic,
    required _PluginTerminated onTerminated,
    required void Function(_PluginIsolate, Map<Object?, Object?>) onHostRequest,
  }) : _isolate = isolate,
       _commands = commands,
       _responses = responses,
       _errors = errors,
       _exits = exits,
       _closeLifecyclePorts = closeLifecyclePorts,
       _send = send,
       _diagnostic = diagnostic,
       _onTerminated = onTerminated,
       _onHostRequest = onHostRequest {
    _responseSubscription = _responses.listen(_handleResponse);
    _errorSubscription = _errors.listen(_handleError);
    _exitSubscription = _exits.listen(_handleExit);
  }

  final String pluginId;
  final String generation;
  final List<AdeleCapabilityExposure> capabilityExposures;
  final List<AdeleExtensionExposure> extensionExposures;
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final Stream<Object?> _errors;
  final Stream<Object?> _exits;
  final void Function() _closeLifecyclePorts;
  final BackendHostSend _send;
  final BackendHostDiagnostic _diagnostic;
  final _PluginTerminated _onTerminated;
  final void Function(_PluginIsolate, Map<Object?, Object?>) _onHostRequest;
  // Reverse IDs are nonnegative and strictly increasing per generation in
  // SendPort order, so replay rejection needs only a constant-space watermark.
  int _lastHostRequestId = -1;
  final Map<int, int> _hostStreamIds = {};
  final Map<int, int> _outerRequestIds = <int, int>{};
  final Map<int, _HostPluginStream> _streams = <int, _HostPluginStream>{};
  final Map<int, int> _pluginStreamIdsByOuter = <int, int>{};
  final Set<int> _pendingConsumerCancellationOuterIds = <int>{};
  late final StreamSubscription<Object?> _responseSubscription;
  late final StreamSubscription<Object?> _errorSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  int _nextPluginRequestId = 1;
  bool _stopped = false;
  bool _terminated = false;
  bool _cleanedUp = false;
  String? _uncaughtError;
  int? _shutdownRequestId;
  Completer<void>? _shutdownCompleter;
  final Completer<void> _exitCompleter = Completer<void>();

  bool get isTerminated => _terminated;

  static Future<_PluginIsolate> start({
    required String pluginId,
    required String generation,
    required Uri artifactUri,
    required List<String> arguments,
    required String defaultConfigurationContext,
    required bool startupArgumentsOnly,
    required BackendHostSend send,
    required BackendHostDiagnostic diagnostic,
    required _PluginTerminated onTerminated,
    required void Function(_PluginIsolate, Map<Object?, Object?>) onHostRequest,
  }) async {
    final ReceivePort bootstrap = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final ReceivePort errorPort = ReceivePort();
    final ReceivePort exitPort = ReceivePort();
    final Stream<Object?> errors = errorPort.asBroadcastStream();
    final Stream<Object?> exits = exitPort.asBroadcastStream();
    Future<Object?>? exited;
    Isolate? isolate;
    try {
      isolate = await Isolate.spawnUri(
        artifactUri,
        arguments,
        <String, Object?>{
          'bootstrapPort': bootstrap.sendPort,
          'responsePort': responses.sendPort,
          'defaultConfigurationContext': defaultConfigurationContext,
          'startupArgumentsOnly': startupArgumentsOnly,
        },
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );
      exited = exits.first;
      final Object? ready = await Future.any(<Future<Object?>>[
        bootstrap.first,
        errors.first.then<Object?>((Object? error) {
          throw StateError('Plugin failed before handshake: $error');
        }),
        exited.then<Object?>((Object? _) {
          throw StateError('Plugin exited before handshake.');
        }),
      ]).timeout(const Duration(seconds: 5));
      if (ready is! Map ||
          ready['commandPort'] is! SendPort ||
          ready['pluginBackendProtocolVersion'] !=
              adelePluginBackendProtocolVersion) {
        throw StateError('Invalid plugin handshake.');
      }
      final _PluginIsolate plugin = _PluginIsolate._(
        pluginId: pluginId,
        generation: generation,
        capabilityExposures: AdeleCapabilityExposure.fromReady(ready),
        extensionExposures: AdeleExtensionExposure.fromReady(ready),
        isolate: isolate,
        commands: ready['commandPort'] as SendPort,
        responses: responses,
        errors: errors,
        exits: exits,
        closeLifecyclePorts: () {
          errorPort.close();
          exitPort.close();
        },
        send: send,
        diagnostic: diagnostic,
        onTerminated: onTerminated,
        onHostRequest: onHostRequest,
      );
      return plugin;
    } catch (_) {
      if (isolate != null) {
        isolate.kill(priority: Isolate.immediate);
        try {
          await exited!.timeout(_pluginLifecycleTimeout);
        } on Object catch (error) {
          diagnostic('Plugin $pluginId startup exit cleanup failed: $error');
        }
      }
      responses.close();
      errorPort.close();
      exitPort.close();
      rethrow;
    } finally {
      bootstrap.close();
    }
  }

  void request(Map<String, Object?> message) {
    if (_stopped) throw StateError('Plugin $pluginId is stopped.');
    final Object? outerRequestId = message['requestId'];
    if (outerRequestId is! int) {
      throw const FormatException('Missing request ID.');
    }
    final String method = _requireString(message, 'method');
    final String configurationContext = _requireString(
      message,
      'configurationContext',
    );
    final String serviceId = _requireString(message, 'serviceId');
    final Object? payload = message['payload'];
    if (payload is! Map) {
      throw const FormatException('Request payload must be a map.');
    }
    final int pluginRequestId = _nextPluginRequestId++;
    _outerRequestIds[pluginRequestId] = outerRequestId;
    _commands.send(<String, Object?>{
      'kind': 'request',
      'requestId': pluginRequestId,
      'configurationContext': configurationContext,
      'serviceId': serviceId,
      'method': method,
      'payload': payload,
    });
  }

  void openStream(Map<String, Object?> message) {
    if (_stopped) throw StateError('Plugin $pluginId is stopped.');
    final Object? outerRequestId = message['requestId'];
    if (outerRequestId is! int) {
      throw const FormatException('Missing request ID.');
    }
    if (_pluginStreamIdsByOuter.containsKey(outerRequestId)) {
      _send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamFailure',
        'requestId': outerRequestId,
        'pluginId': pluginId,
        'error': <String, Object?>{
          'code': 'stream_protocol_violation',
          'message': 'A stream with this request ID is already active.',
        },
      });
      return;
    }
    final String method = _requireString(message, 'method');
    final String configurationContext = _requireString(
      message,
      'configurationContext',
    );
    final String serviceId = _requireString(message, 'serviceId');
    final Object? payload = message['payload'];
    if (payload is! Map) {
      throw const FormatException('Request payload must be a map.');
    }
    final int pluginRequestId = _nextPluginRequestId++;
    final _HostPluginStream stream = _HostPluginStream(
      pluginRequestId,
      outerRequestId,
    );
    stream.consumerCancellationRequested = _pendingConsumerCancellationOuterIds
        .remove(outerRequestId);
    _streams[pluginRequestId] = stream;
    _pluginStreamIdsByOuter[outerRequestId] = pluginRequestId;
    _commands.send(<String, Object?>{
      'kind': 'streamOpen',
      'requestId': pluginRequestId,
      'configurationContext': configurationContext,
      'serviceId': serviceId,
      'method': method,
      'payload': payload,
    });
  }

  bool streamControl(Map<String, Object?> message, String kind) {
    final Object? outerRequestId = message['requestId'];
    if (outerRequestId is! int) {
      throw const FormatException('Missing request ID.');
    }
    final int? pluginRequestId = _pluginStreamIdsByOuter[outerRequestId];
    if (pluginRequestId == null) {
      if (kind == 'streamCancel') {
        _pendingConsumerCancellationOuterIds.remove(outerRequestId);
      }
      return false;
    }
    final _HostPluginStream stream = _streams[pluginRequestId]!;
    if (kind == 'streamCredit') {
      final Object? credit = message['credit'];
      if (credit is! int ||
          credit <= 0 ||
          stream.credit + credit > backendHostStreamWindow) {
        _abortStream(
          stream,
          code: 'stream_protocol_violation',
          message: 'Invalid stream credit.',
        );
        return false;
      }
      stream.credit += credit;
      _commands.send(<String, Object?>{
        'kind': 'streamCredit',
        'requestId': pluginRequestId,
        'credit': credit,
      });
      return true;
    } else {
      return _forwardConsumerCancellation(stream);
    }
  }

  void noteStreamCancelRequested(int outerRequestId) {
    final int? pluginRequestId = _pluginStreamIdsByOuter[outerRequestId];
    if (pluginRequestId == null) {
      _pendingConsumerCancellationOuterIds.add(outerRequestId);
      return;
    }
    _streams[pluginRequestId]?.consumerCancellationRequested = true;
  }

  bool _forwardConsumerCancellation(_HostPluginStream stream) {
    stream.consumerCancellationRequested = true;
    if (stream.cancelling) return false;
    stream.cancelling = true;
    stream.cancelOrigin = _StreamCancelOrigin.consumer;
    _commands.send(<String, Object?>{
      'kind': 'streamCancel',
      'requestId': stream.pluginRequestId,
    });
    _send(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamCancelForwarded',
      'requestId': stream.outerRequestId,
      'pluginId': pluginId,
    });
    return true;
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    for (final _HostPluginStream stream in _streams.values.toList()) {
      stream.cancelling = true;
      stream.cancelOrigin = _StreamCancelOrigin.pluginStop;
      _commands.send(<String, Object?>{
        'kind': 'streamCancel',
        'requestId': stream.pluginRequestId,
      });
    }
    final int requestId = _nextPluginRequestId++;
    final Completer<void> stopped = Completer<void>();
    _shutdownRequestId = requestId;
    _shutdownCompleter = stopped;
    _outerRequestIds[requestId] = -1;
    _commands.send(<String, Object?>{
      'kind': 'request',
      'requestId': requestId,
      'method': 'shutdown',
      'payload': <String, Object?>{},
    });
    try {
      await stopped.future.timeout(_pluginLifecycleTimeout);
    } on Object catch (error) {
      _diagnostic('Plugin $pluginId shutdown acknowledgement failed: $error');
      _isolate.kill(priority: Isolate.immediate);
    }
    try {
      await _exitCompleter.future.timeout(_pluginLifecycleTimeout);
    } on Object catch (error) {
      _diagnostic('Plugin $pluginId exit timed out: $error');
      _isolate.kill(priority: Isolate.immediate);
      await _exitCompleter.future.timeout(_pluginLifecycleTimeout);
    }
    await _cleanup();
  }

  void _handleResponse(Object? raw) {
    if (raw is Map &&
        (raw['kind'] == 'hostRequest' ||
            (raw['kind'] is String &&
                (raw['kind'] as String).startsWith('hostStream')))) {
      _handleHostRequest(raw);
      return;
    }
    if (raw is! Map || raw['requestId'] is! int) {
      _diagnostic('Malformed response from $pluginId.');
      _isolate.kill(priority: Isolate.immediate);
      return;
    }
    final int pluginRequestId = raw['requestId'] as int;
    final _HostPluginStream? stream = _streams[pluginRequestId];
    if (stream != null) {
      _handleStreamResponse(stream, raw);
      return;
    }
    if (_isPluginStreamResponseKind(raw['kind'])) {
      _diagnostic(
        'Uncorrelatable stream response ID $pluginRequestId from $pluginId.',
      );
      _isolate.kill(priority: Isolate.immediate);
      return;
    }
    if (pluginRequestId == _shutdownRequestId) {
      final Completer<void>? completer = _shutdownCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
    final int? outerRequestId = _outerRequestIds.remove(pluginRequestId);
    if (outerRequestId == null) {
      _diagnostic('Unknown response ID $pluginRequestId from $pluginId.');
      return;
    }
    if (outerRequestId < 0) return;
    final Map<String, Object?> response = <String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'response',
      'requestId': outerRequestId,
      'pluginId': pluginId,
      'ok': raw['ok'],
      if (raw.containsKey('payload')) 'payload': raw['payload'],
      if (raw.containsKey('error')) 'error': raw['error'],
    };
    if (!_send(response)) {
      final String code;
      final String message;
      if (_isOversizedResponse(response)) {
        code = 'response_too_large';
        message = 'The plugin response exceeded the host frame limit.';
      } else {
        code = 'response_encoding_failed';
        message = 'The plugin response could not be encoded.';
      }
      if (!_send(<String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'response',
        'requestId': outerRequestId,
        'pluginId': pluginId,
        'ok': false,
        'error': <String, Object?>{'code': code, 'message': message},
      })) {
        _diagnostic('Failed to send response failure for $pluginId.');
      }
    }
  }

  void _handleHostRequest(Map<Object?, Object?> raw) {
    try {
      final kind = raw['kind'];
      if (kind != 'hostRequest' && kind != 'hostStreamOpen') {
        if (raw['requestId'] is! int ||
            raw.length != (kind == 'hostStreamCredit' ? 3 : 2) ||
            (kind == 'hostStreamCredit' &&
                (raw['credit'] is! int || raw['credit'] != 1)) ||
            (kind != 'hostStreamCredit' &&
                kind != 'hostStreamCancel' &&
                kind != 'hostStreamAck')) {
          throw const FormatException('Malformed host stream control.');
        }
        _onHostRequest(this, raw);
        return;
      }
      if (raw.length != 6 ||
          raw['requestId'] is! int ||
          raw['hostInvocationContext'] is! String ||
          raw['method'] is! String ||
          (raw['method'] as String).isEmpty ||
          raw['serviceId'] is! String ||
          !_isStringKeyedMap(raw['payload'])) {
        throw const FormatException('Malformed host request.');
      }
      adeleValidateServiceId(raw['serviceId'] as String);
      adeleValidateConfigurationContext(raw['hostInvocationContext'] as String);
      adeleSnapshotJsonMap(
        (raw['payload'] as Map).cast<String, Object?>(),
        maxNodes: adelePluginBackendJsonMaxNodes,
      );
      final int requestId = raw['requestId'] as int;
      if (requestId < 0 || requestId <= _lastHostRequestId) {
        throw const FormatException('Host request IDs must strictly increase.');
      }
      _lastHostRequestId = requestId;
    } on Object {
      _reverseProtocolViolation();
      return;
    }
    _onHostRequest(this, raw);
  }

  void _reverseProtocolViolation() {
    _diagnostic(
      'Plugin $pluginId sent a malformed host request or stream control.',
    );
    _isolate.kill(priority: Isolate.immediate);
  }

  void hostResponse(int requestId, Map<String, Object?> response) {
    if (_terminated || _cleanedUp) return;
    _commands.send(<String, Object?>{
      'kind': 'hostResponse',
      'requestId': requestId,
      'ok': response['ok'],
      if (response['ok'] == true)
        'payload': response['payload']
      else
        'error': response['error'],
    });
  }

  bool _isPluginStreamResponseKind(Object? kind) => switch (kind) {
    'streamItem' ||
    'streamDone' ||
    'streamFailure' ||
    'streamCancelled' => true,
    _ => false,
  };

  void _handleStreamResponse(
    _HostPluginStream stream,
    Map<Object?, Object?> raw,
  ) {
    final Object? kind = raw['kind'];
    if (kind == 'streamItem') {
      if (!_validStreamItem(stream, raw)) {
        _abortStream(
          stream,
          code: 'stream_protocol_violation',
          message: 'The plugin returned a malformed stream item.',
        );
        return;
      }
      if (stream.credit <= 0) {
        _abortStream(
          stream,
          code: 'stream_protocol_violation',
          message: 'The plugin emitted without stream credit.',
        );
        return;
      }
      stream.credit--;
      final Map<String, Object?> item = <String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamItem',
        'requestId': stream.outerRequestId,
        'pluginId': pluginId,
        'payload': raw['payload'],
      };
      if (!_send(item)) {
        _abortStream(
          stream,
          code: _isOversizedResponse(item)
              ? 'response_too_large'
              : 'response_encoding_failed',
          message: 'The plugin stream item could not be transported.',
        );
      }
      return;
    }
    if (kind == 'streamDone' ||
        kind == 'streamFailure' ||
        kind == 'streamCancelled') {
      if (!_validStreamTerminal(stream, raw)) {
        _abortStream(
          stream,
          code: 'stream_protocol_violation',
          message: 'The plugin returned a malformed stream terminal.',
        );
        return;
      }
      if (stream.containmentAbortPending) {
        if (stream.cancelOrigin == _StreamCancelOrigin.consumer) {
          stream.containmentAbortPending = false;
          stream.abortTimeout?.cancel();
          stream.abortTimeout = null;
          _finishStream(stream, raw);
          return;
        }
        _settleHostAbort(stream);
        return;
      }
      if (kind == 'streamCancelled') {
        final _StreamCancelOrigin? origin = stream.cancelOrigin;
        if (origin == _StreamCancelOrigin.pluginStop) {
          _removeStream(stream);
          return;
        }
      }
      _finishStream(stream, raw);
      return;
    }
    _diagnostic('Malformed stream response from $pluginId: $raw');
    _abortStream(
      stream,
      code: 'stream_protocol_violation',
      message: 'The plugin returned a malformed stream response.',
    );
  }

  bool _validStreamItem(_HostPluginStream stream, Map<Object?, Object?> raw) =>
      raw.length == 3 &&
      raw['kind'] == 'streamItem' &&
      raw['requestId'] == stream.pluginRequestId &&
      raw.containsKey('payload');

  bool _validStreamTerminal(
    _HostPluginStream stream,
    Map<Object?, Object?> raw,
  ) {
    final Object? kind = raw['kind'];
    if (kind == 'streamCancelled') {
      return stream.cancelling &&
          stream.cancelOrigin != null &&
          raw.length == 2 &&
          raw['requestId'] == stream.pluginRequestId;
    }
    if (kind == 'streamDone') {
      return raw.length == 2 && raw['requestId'] == stream.pluginRequestId;
    }
    if (kind != 'streamFailure' ||
        raw.length != 3 ||
        raw['requestId'] != stream.pluginRequestId) {
      return false;
    }
    return _validStreamFailureError(raw['error']);
  }

  bool _validStreamFailureError(Object? value) {
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

  bool _isStringKeyedMap(Object? value) =>
      value is Map && value.keys.every((Object? key) => key is String);

  void _finishStream(_HostPluginStream stream, Map<Object?, Object?> raw) {
    final Map<String, Object?> response = <String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': raw['kind'] as String,
      'requestId': stream.outerRequestId,
      'pluginId': pluginId,
      if (raw.containsKey('error')) 'error': raw['error'],
    };
    if (!_sendStreamTerminal(stream, response)) {
      _isolate.kill(priority: Isolate.immediate);
      return;
    }
    _removeStream(stream);
  }

  void _abortStream(
    _HostPluginStream stream, {
    required String code,
    required String message,
  }) {
    if (stream.containmentAbortPending) return;
    stream.containmentAbortPending = true;
    final bool consumerCancellation =
        stream.consumerCancellationRequested ||
        stream.cancelOrigin == _StreamCancelOrigin.consumer;
    if (consumerCancellation && !stream.cancelling) {
      _forwardConsumerCancellation(stream);
    }
    if (!stream.cancelling) {
      stream.cancelling = true;
      stream.cancelOrigin = _StreamCancelOrigin.hostAbort;
      _commands.send(<String, Object?>{
        'kind': 'streamCancel',
        'requestId': stream.pluginRequestId,
      });
    }
    if (!consumerCancellation) {
      stream.abortTerminalSent = true;
      final Map<String, Object?> terminal = <String, Object?>{
        'protocolVersion': backendHostProtocolVersion,
        'kind': 'streamFailure',
        'requestId': stream.outerRequestId,
        'pluginId': pluginId,
        'error': <String, Object?>{'code': code, 'message': message},
      };
      if (!_sendStreamTerminal(stream, terminal)) {
        _isolate.kill(priority: Isolate.immediate);
        return;
      }
    } else {
      _diagnostic(
        'Plugin $pluginId violated stream protocol while cancellation was pending.',
      );
    }
    stream.abortTimeout = Timer(_pluginLifecycleTimeout, () {
      if (_streams[stream.pluginRequestId] != stream ||
          !stream.containmentAbortPending) {
        return;
      }
      _diagnostic(
        'Plugin $pluginId did not settle host-aborted stream '
        '${stream.pluginRequestId}.',
      );
      _isolate.kill(priority: Isolate.immediate);
    });
  }

  void _settleHostAbort(_HostPluginStream stream) {
    stream.abortTimeout?.cancel();
    stream.abortTimeout = null;
    _removeStream(stream);
  }

  bool _sendStreamTerminal(
    _HostPluginStream stream,
    Map<String, Object?> preferred,
  ) {
    if (_send(preferred)) return true;
    final String code = _isOversizedResponse(preferred)
        ? 'response_too_large'
        : 'response_encoding_failed';
    final Map<String, Object?> fallback = <String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'streamFailure',
      'requestId': stream.outerRequestId,
      'pluginId': pluginId,
      'error': <String, Object?>{
        'code': code,
        'message': 'The plugin stream terminal could not be transported.',
      },
    };
    if (_send(fallback)) return true;
    _diagnostic('Failed to send stream terminal fallback for $pluginId.');
    return false;
  }

  void _removeStream(_HostPluginStream stream) {
    if (_streams.remove(stream.pluginRequestId) != stream) return;
    stream.abortTimeout?.cancel();
    stream.abortTimeout = null;
    _pluginStreamIdsByOuter.remove(stream.outerRequestId);
  }

  bool _isOversizedResponse(Map<String, Object?> response) {
    try {
      encodeBackendHostFrame(response);
    } on BackendHostProtocolException catch (error) {
      return error.message == 'Frame is too large.';
    }
    return false;
  }

  void _handleError(Object? error) {
    _uncaughtError = error.toString();
    _diagnostic('Plugin $pluginId uncaught error: $error');
    _send(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'diagnostic',
      'pluginId': pluginId,
      'stage': 'plugin-isolate',
      'message': error.toString(),
    });
  }

  void _handleExit(Object? _) {
    _diagnostic('Plugin $pluginId exited.');
    if (!_exitCompleter.isCompleted) _exitCompleter.complete();
    if (_stopped || _terminated) return;
    _terminated = true;
    final List<int> pending = _outerRequestIds.values
        .where((int requestId) => requestId >= 0)
        .toList();
    pending.addAll(
      _streams.values.map((_HostPluginStream value) => value.outerRequestId),
    );
    _outerRequestIds.clear();
    _streams.clear();
    _pluginStreamIdsByOuter.clear();
    _pendingConsumerCancellationOuterIds.clear();
    final String? uncaughtError = _uncaughtError;
    _onTerminated(
      this,
      pending,
      uncaughtError == null ? 'plugin_exited' : 'plugin_failed',
      uncaughtError == null
          ? 'The plugin isolate exited unexpectedly.'
          : 'The plugin isolate failed: $uncaughtError',
    );
    unawaited(_cleanup());
  }

  Future<void> _cleanup() async {
    if (_cleanedUp) return;
    _cleanedUp = true;
    await _responseSubscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
    _responses.close();
    _closeLifecyclePorts();
  }
}

final class _ReverseStream {
  _ReverseStream(this.plugin, this.localId, this.outerId);
  final _PluginIsolate plugin;
  final int localId;
  final int outerId;
  int credit = 0;
  bool cancelling = false;
  bool terminal = false;
  bool localFailure = false;
  Timer? ackTimeout;
}

final class _HostPluginStream {
  _HostPluginStream(this.pluginRequestId, this.outerRequestId);

  final int pluginRequestId;
  final int outerRequestId;
  int credit = 0;
  bool cancelling = false;
  _StreamCancelOrigin? cancelOrigin;
  bool abortTerminalSent = false;
  bool containmentAbortPending = false;
  bool consumerCancellationRequested = false;
  Timer? abortTimeout;
}

enum _StreamCancelOrigin { consumer, pluginStop, hostAbort }

typedef _PluginTerminated =
    void Function(
      _PluginIsolate plugin,
      List<int> requestIds,
      String code,
      String message,
    );

String _requireString(Map<String, Object?> message, String key) {
  final Object? value = message[key];
  if (value is! String || value.isEmpty) throw FormatException('Missing $key.');
  return value;
}

String? _pluginId(Map<String, Object?> message) {
  final Object? value = message['pluginId'];
  return value is String ? value : null;
}
