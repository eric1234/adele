import 'dart:convert';
import 'dart:io';

import 'package:plugin_runtime/plugin_runtime.dart';

// A transport peer, not a replacement connection/activation. Held calls are
// acknowledged and completed by commands so retirement tests need no timers.
void main() {
  final decoder = BackendHostFrameDecoder();
  final starts = <String, Map<String, Object?>>{};
  final held = <String, Map<String, Object?>>{};
  final waiters = <String, List<Map<String, Object?>>>{};
  final reverse = <int, Map<String, Object?>>{};
  final calls = <Map<String, Object?>>[];
  var nextReverse = 0;

  void send(Map<String, Object?> message) => stdout.add(
    encodeBackendHostFrame({
      'protocolVersion': backendHostProtocolVersion,
      ...message,
    }),
  );

  void respond(Map<String, Object?> request, Object? value) => send({
    'kind': 'response',
    'requestId': request['requestId'],
    'pluginId': request['pluginId'],
    'ok': true,
    'payload': value,
  });

  void fail(Map<String, Object?> request, {required bool declared}) => send({
    'kind': 'response',
    'requestId': request['requestId'],
    'pluginId': request['pluginId'],
    'ok': false,
    'error': {
      'declaredFailureType': declared ? 'test.ProviderFailure' : null,
      'code': declared ? 'denied' : 'internal_error',
      'message': declared
          ? 'A declared refusal.'
          : 'SECRET unexpected exception',
      'details': declared
          ? {'resource': 'sample', 'retryable': false}
          : {'stack': 'SECRET private stack'},
    },
  });

  send({'kind': 'hostHello'});
  stdin.listen((bytes) {
    for (final message in decoder.add(bytes)) {
      final pluginId = message['pluginId'] as String?;
      switch (message['kind']) {
        case 'startPlugin':
          starts[pluginId!] = message;
          final arguments = message['arguments'] as List;
          final ready = jsonDecode(arguments.single as String) as Map;
          send({
            'kind': 'pluginReady',
            'requestId': message['requestId'],
            'pluginId': pluginId,
            ...ready.cast<String, Object?>(),
          });
        case 'stopPlugin':
          starts.remove(pluginId);
          send({
            'kind': 'pluginStopped',
            'requestId': message['requestId'],
            'pluginId': pluginId,
          });
        case 'request':
          final payload = (message['payload'] as Map).cast<String, Object?>();
          switch (message['method']) {
            case 'fixture.calls':
              respond(message, calls);
            case 'fixture.waitHeld':
              final gate = payload['gate'] as String;
              if (held.containsKey(gate)) {
                respond(message, null);
              } else {
                waiters.putIfAbsent(gate, () => []).add(message);
              }
            case 'fixture.finishHeld':
              final original = held.remove(payload['gate'])!;
              if (payload['failure'] == true) {
                fail(original, declared: true);
              } else {
                respond(original, {'settled': payload['gate']});
              }
              respond(message, null);
            case 'fixture.terminate':
              send({
                'kind': 'pluginFailed',
                'pluginId': payload['pluginId'],
                'error': {
                  'code': 'plugin_exited',
                  'message': 'SECRET target termination',
                },
              });
              respond(message, null);
            case 'fixture.exit':
              exit(9);
            case 'fixture.reverse':
              final id = nextReverse++;
              reverse[id] = message;
              send({
                'kind': 'hostRequest',
                'requestId': id,
                'pluginId': pluginId,
                'generation': starts[pluginId]!['generation'],
                'hostContextKind': 'infrastructure',
                'hostContext': starts[pluginId]!['hostInfrastructureContext'],
                'serviceId': payload['serviceId'],
                'method': 'test.read',
                'payload': <String, Object?>{},
              });
            default:
              calls.add(message);
              switch (message['method']) {
                case 'test.provider.hold':
                  final gate = payload['gate'] as String;
                  held[gate] = message;
                  for (final waiter
                      in waiters.remove(gate) ?? <Map<String, Object?>>[]) {
                    respond(waiter, null);
                  }
                case 'test.provider.declaredFailure':
                  fail(message, declared: true);
                case 'test.provider.unexpectedFailure':
                  fail(message, declared: false);
                default:
                  respond(message, {
                    'pluginId': pluginId,
                    'configurationContext': message['configurationContext'],
                    'serviceId': message['serviceId'],
                    'payload': payload,
                    'hasHostInvocationContext': message.containsKey(
                      'hostInvocationContext',
                    ),
                  });
              }
          }
        case 'hostResponse':
          respond(reverse.remove(message['requestId'])!, message);
        case 'shutdownHost':
          send({'kind': 'hostStopped', 'requestId': message['requestId']});
          exit(0);
      }
    }
  });
}
