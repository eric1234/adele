import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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
      switch (message['kind']) {
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
    final Object? rawArguments = message['arguments'];
    if (rawArguments is! List ||
        rawArguments.any((Object? value) => value is! String)) {
      throw const FormatException('Plugin arguments must be strings.');
    }
    final _PluginIsolate plugin = await _PluginIsolate.start(
      pluginId: pluginId,
      artifactUri: Uri.parse(artifactUri),
      arguments: rawArguments
          .map((Object? value) => value! as String)
          .toList(growable: false),
      send: _send,
      diagnostic: _diagnostic,
      onTerminated: _pluginTerminated,
    );
    _plugins[pluginId] = plugin;
    await Future<void>.delayed(Duration.zero);
    if (plugin.isTerminated) {
      _plugins.remove(pluginId);
      throw StateError('Plugin $pluginId terminated during startup.');
    }
    _send(<String, Object?>{
      'protocolVersion': backendHostProtocolVersion,
      'kind': 'pluginReady',
      'requestId': message['requestId'],
      'pluginId': pluginId,
    });
  }

  Future<void> _stopPlugin(Map<String, Object?> message) async {
    final String pluginId = _requireString(message, 'pluginId');
    final _PluginIsolate? plugin = _plugins.remove(pluginId);
    if (plugin == null) throw StateError('Plugin $pluginId is not running.');
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

  void _pluginTerminated(
    String pluginId,
    List<int> requestIds,
    String code,
    String message,
  ) {
    final _PluginIsolate? removed = _plugins.remove(pluginId);
    if (removed == null) return;
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
    required Isolate isolate,
    required SendPort commands,
    required ReceivePort responses,
    required Stream<Object?> errors,
    required Stream<Object?> exits,
    required void Function() closeLifecyclePorts,
    required BackendHostSend send,
    required BackendHostDiagnostic diagnostic,
    required _PluginTerminated onTerminated,
  }) : _isolate = isolate,
       _commands = commands,
       _responses = responses,
       _errors = errors,
       _exits = exits,
       _closeLifecyclePorts = closeLifecyclePorts,
       _send = send,
       _diagnostic = diagnostic,
       _onTerminated = onTerminated {
    _responseSubscription = _responses.listen(_handleResponse);
    _errorSubscription = _errors.listen(_handleError);
    _exitSubscription = _exits.listen(_handleExit);
  }

  final String pluginId;
  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final Stream<Object?> _errors;
  final Stream<Object?> _exits;
  final void Function() _closeLifecyclePorts;
  final BackendHostSend _send;
  final BackendHostDiagnostic _diagnostic;
  final _PluginTerminated _onTerminated;
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
    required Uri artifactUri,
    required List<String> arguments,
    required BackendHostSend send,
    required BackendHostDiagnostic diagnostic,
    required _PluginTerminated onTerminated,
  }) async {
    final ReceivePort bootstrap = ReceivePort();
    final ReceivePort responses = ReceivePort();
    final ReceivePort errorPort = ReceivePort();
    final ReceivePort exitPort = ReceivePort();
    final Stream<Object?> errors = errorPort.asBroadcastStream();
    final Stream<Object?> exits = exitPort.asBroadcastStream();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawnUri(
        artifactUri,
        arguments,
        <String, Object?>{
          'bootstrapPort': bootstrap.sendPort,
          'responsePort': responses.sendPort,
        },
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );
      final Object? ready = await Future.any(<Future<Object?>>[
        bootstrap.first,
        errors.first.then<Object?>((Object? error) {
          throw StateError('Plugin failed before handshake: $error');
        }),
        exits.first.then<Object?>((Object? _) {
          throw StateError('Plugin exited before handshake.');
        }),
      ]).timeout(const Duration(seconds: 5));
      if (ready is! Map || ready['commandPort'] is! SendPort) {
        throw StateError('Invalid plugin handshake: $ready');
      }
      final _PluginIsolate plugin = _PluginIsolate._(
        pluginId: pluginId,
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
      );
      return plugin;
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
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
    final Object? payload = message['payload'];
    if (payload is! Map) {
      throw const FormatException('Request payload must be a map.');
    }
    final int pluginRequestId = _nextPluginRequestId++;
    _outerRequestIds[pluginRequestId] = outerRequestId;
    _commands.send(<String, Object?>{
      'kind': 'request',
      'requestId': pluginRequestId,
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
    if (raw is! Map || raw['requestId'] is! int) {
      _diagnostic('Malformed response from $pluginId: $raw');
      if (raw is Map && _isPluginStreamResponseKind(raw['kind'])) {
        _isolate.kill(priority: Isolate.immediate);
      }
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
      pluginId,
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
      String pluginId,
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
