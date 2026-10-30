import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';

// Retrieval-only fixture, not a strategy or persistence implementation. The
// separate control route is native test synchronization, never a renderer grant.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map<Object?, Object?>;
  final responses = bootstrap['responsePort'] as SendPort;
  final commands = ReceivePort();
  final identity = arguments.single;
  final requests = <Map<String, Object?>>[];
  final entered = <String, Completer<void>>{};
  final releases = <String, Completer<void>>{};
  const content = {
    'session/first': 'first content',
    'session/second': 'second content',
    'other/first': 'other content',
    'session/held-disappearance': 'late disappearance content',
    'session/held-dismissal': 'late dismissal content',
    'session/held-navigation': 'late navigation content',
  };

  Future<void> handle(Map<Object?, Object?> message) async {
    try {
      final payload = message['payload']! as Map<Object?, Object?>;
      final service = message['serviceId'];
      final method = message['method'];
      Object? result;
      if (service == 'fixture.control') {
        final key = payload['key'] as String?;
        switch (method) {
          case 'snapshot':
            result = requests;
          case 'wait':
            if (!content.containsKey(key)) throw StateError('Unknown key.');
            await (entered[key!] ??= Completer<void>()).future.timeout(
              const Duration(seconds: 10),
            );
            result = true;
          case 'release':
            if (!content.containsKey(key)) throw StateError('Unknown key.');
            final gate = releases[key!] ??= Completer<void>();
            if (!gate.isCompleted) gate.complete();
            result = true;
          default:
            throw StateError('Unknown control.');
        }
      } else {
        if (requests.length >= 64) throw StateError('Request limit.');
        requests.add({
          'configurationContext': message['configurationContext'],
          'serviceId': service,
          'method': method,
          'payload': payload,
          'hostInvocationContext': message['hostInvocationContext'],
        });
        if (message['configurationContext'] != 'default' ||
            message['hostInvocationContext'] != null ||
            (service != 'fixture.content' && service != 'fixture.private') ||
            method != 'read' ||
            payload.length != 2) {
          throw StateError('Only content retrieval is available.');
        }
        final key = '${payload['sessionId']}/${payload['occurrenceId']}';
        final text = content[key];
        if (text == null) throw StateError('Unknown content.');
        final gate = entered[key] ??= Completer<void>();
        if (!gate.isCompleted) gate.complete();
        if (key.contains('/held-')) {
          await (releases[key] ??= Completer<void>()).future.timeout(
            const Duration(seconds: 10),
          );
        }
        result = '$identity|$key|$text';
      }
      responses.send({
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        // Copy the bounded audit snapshot before later requests append to it.
        'payload': jsonDecode(jsonEncode(result)),
      });
    } on Object {
      responses.send({
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': false,
        'error': {'code': 'fixture_unavailable', 'message': 'Unavailable.'},
      });
    }
  }

  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });
  await for (final Object? message in commands) {
    if (message is! Map<Object?, Object?> || message['kind'] != 'request') {
      continue;
    }
    if (message['method'] == 'shutdown' && message['serviceId'] == null) {
      for (final gate in releases.values) {
        if (!gate.isCompleted) gate.complete();
      }
      responses.send({
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': null,
      });
      commands.close();
      break;
    }
    unawaited(handle(message));
  }
}
