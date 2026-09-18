import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final Map<Object?, Object?> bootstrap =
      bootstrapMessage! as Map<Object?, Object?>;
  final SendPort bootstrapPort = bootstrap['bootstrapPort']! as SendPort;
  final SendPort responsePort = bootstrap['responsePort']! as SendPort;
  final ReceivePort commands = ReceivePort();
  if (arguments.first == 'reverse-streams') {
    _serveHostStreams(bootstrapPort, responsePort, commands);
    return;
  }
  final ReceivePort? keepAlive = arguments.first == 'acknowledge-hang'
      ? ReceivePort()
      : null;
  final ServerSocket? resource = arguments.length > 2
      ? await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          int.parse(arguments[2]),
        )
      : null;
  final Map<int, String> streams = <int, String>{};
  final Map<int, int> sequences = <int, int>{};
  int streamCancels = 0;
  int nextHostRequestId = 0;
  final hostRequests = <int, int>{};
  int unexpectedHostResponses = 0;
  final Object? advertised = arguments.length > 1
      ? jsonDecode(arguments[1])
      : null;
  if (arguments.first.startsWith('oversized-')) {
    ((advertised! as List).single as Map)[arguments.first.substring(10)] =
        '!' * (8 * 1024 * 1024 + 1);
  }
  if (arguments.first == 'extensions-dag') {
    ((advertised! as List).single as Map)['metadata'] = <String, Object?>{
      'dag': _compactDag(),
    };
  }
  final Object? transported = arguments.first == 'extensions-serialized'
      ? <Object?>[
          for (final exposure in AdeleExtensionExposure.fromReady({
            'extensionExposures': advertised,
          }))
            exposure.toMap(),
        ]
      : advertised;
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': commands.sendPort,
    if (arguments.first != 'incompatible-handshake')
      'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    if (arguments.length > 1)
      (arguments.first.startsWith('extensions')
              ? 'extensionExposures'
              : 'capabilityExposures'):
          transported,
  });
  if (arguments.first == 'exit-immediately') {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    commands.close();
    return;
  }
  await for (final Object? raw in commands) {
    final Map<Object?, Object?> message = raw! as Map<Object?, Object?>;
    if (message['kind'] == 'hostResponse') {
      final outerId = hostRequests.remove(message['requestId']);
      if (outerId == null) {
        unexpectedHostResponses++;
      } else {
        responsePort.send({
          'kind': 'response',
          'requestId': outerId,
          'ok': true,
          'payload': message,
        });
      }
      continue;
    }
    if (message['method'] == 'reverse') {
      final payload = message['payload'] as Map;
      final id = payload['hostRequestId'] as int? ?? nextHostRequestId++;
      hostRequests[id] = message['requestId'] as int;
      final request = <String, Object?>{
        'kind': 'hostRequest',
        'requestId': id,
        'hostInvocationContext': payload['context'],
        'serviceId': payload['service'] ?? 'fixtureService',
        'method': payload['method'] ?? 'fixture.invoke',
        'payload': payload['compactDag'] == true
            ? <String, Object?>{'dag': _compactDag()}
            : payload['payload'] ?? <String, Object?>{},
        ...Map<String, Object?>.from(payload['extra'] as Map? ?? {}),
      };
      if (payload['omit'] is String) request.remove(payload['omit']);
      responsePort.send(request);
      if (payload['duplicate'] == true) responsePort.send(request);
      continue;
    }
    if (message['method'] == 'unexpected-host-responses') {
      responsePort.send({
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': unexpectedHostResponses,
      });
      continue;
    }
    if (message['kind'] == 'streamOpen') {
      final int id = message['requestId']! as int;
      streams[id] = message['method']! as String;
      sequences[id] = 0;
      continue;
    }
    if (message['kind'] == 'streamCredit') {
      final int id = message['requestId']! as int;
      final String? method = streams[id];
      if (method == null) continue;
      if (method == 'stream-malformed') {
        responsePort.send(<String, Object?>{
          'kind': 'response',
          'requestId': id,
          'ok': true,
        });
      } else if (method == 'stream-item-missing-request-id') {
        responsePort.send(<String, Object?>{
          'kind': 'streamItem',
          'payload': 'uncorrelatable',
        });
      } else if (method == 'stream-item-wrong-request-id') {
        responsePort.send(<String, Object?>{
          'kind': 'streamItem',
          'requestId': id + 1000000,
          'payload': 'uncorrelatable',
        });
      } else if (method == 'stream-item-missing-payload') {
        responsePort.send(<String, Object?>{
          'kind': 'streamItem',
          'requestId': id,
        });
      } else if (method == 'stream-item-extra-field') {
        responsePort.send(<String, Object?>{
          'kind': 'streamItem',
          'requestId': id,
          'payload': null,
          'extra': true,
        });
      } else if (method.startsWith('stream-large-item')) {
        responsePort.send(<String, Object?>{
          'kind': 'streamItem',
          'requestId': id,
          'payload': 'x' * (8 * 1024 * 1024 + 1),
        });
      } else if (method == 'stream-large-terminal') {
        responsePort.send(<String, Object?>{
          'kind': 'streamFailure',
          'requestId': id,
          'error': <String, Object?>{
            'code': 'fixture_failure',
            'message': 'large',
            'details': <String, Object?>{'value': 'x' * (8 * 1024 * 1024 + 1)},
          },
        });
      } else if (method.startsWith('stream-failure-')) {
        final Map<String, Object?> error = <String, Object?>{
          'code': 'fixture_failure',
          'message': 'failure',
        };
        if (method == 'stream-failure-compact') {
          // Compact undeclared failures intentionally omit optional metadata.
        } else if (method == 'stream-failure-declared') {
          error['declaredFailureType'] = 'fixture.failure';
          error['details'] = <String, Object?>{'value': 1};
        } else if (method == 'stream-failure-null-declared') {
          error['declaredFailureType'] = null;
        } else if (method == 'stream-failure-declared-no-details') {
          error['declaredFailureType'] = 'fixture.failure';
        } else if (method == 'stream-failure-null-details') {
          error['details'] = null;
        }
        responsePort.send(<String, Object?>{
          'kind': 'streamFailure',
          'requestId': id,
          'error': error,
        });
      } else {
        final int sequence = sequences[id]!;
        sequences[id] = sequence + 1;
        responsePort.send(<String, Object?>{
          'kind': 'streamItem',
          'requestId': id,
          'payload': <String, Object?>{'label': method, 'sequence': sequence},
        });
      }
      continue;
    }
    if (message['kind'] == 'streamCancel') {
      final int id = message['requestId']! as int;
      final String? method = streams[id];
      streamCancels++;
      if (method == 'stream-cancel-malformed-settle' ||
          method == 'stream-cancel-malformed-stuck') {
        responsePort.send(<String, Object?>{
          'kind': 'response',
          'requestId': id,
          'ok': true,
        });
        if (method == 'stream-cancel-malformed-settle') {
          responsePort.send(<String, Object?>{
            'kind': 'streamCancelled',
            'requestId': id,
          });
        }
        continue;
      }
      if (method == 'stream-large-item-no-ack') continue;
      streams.remove(id);
      sequences.remove(id);
      if (method == 'stream-large-item-then-done') {
        responsePort.send(<String, Object?>{
          'kind': 'streamDone',
          'requestId': id,
        });
      } else if (method == 'stream-large-item-then-failure') {
        responsePort.send(<String, Object?>{
          'kind': 'streamFailure',
          'requestId': id,
          'error': <String, Object?>{'code': 'late_failure', 'message': 'late'},
        });
      } else {
        responsePort.send(<String, Object?>{
          'kind': 'streamCancelled',
          'requestId': id,
        });
      }
      continue;
    }
    if (message['method'] == 'crash') {
      commands.close();
      return;
    }
    if (message['method'] == 'pending') continue;
    if (message['method'] == 'large-below') {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': 'x' * (8 * 1024 * 1024 - 2048),
      });
    }
    if (message['method'] == 'large-above') {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': 'x' * (8 * 1024 * 1024 + 1),
      });
    }
    if (message['method'] == 'unencodable') {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': responsePort,
      });
    }
    if (message['method'] == 'non-finite') {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': double.nan,
      });
    }
    if (message['method'] == 'ping') {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': <String, Object?>{'alive': true},
      });
    }
    if (message['method'] == 'startup-mode') {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': bootstrap['startupArgumentsOnly'],
      });
    }
    if (message['method'] == 'stream-cancel-count') {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': streamCancels,
      });
    }
    if (message['method'] == 'shutdown') {
      await resource?.close();
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': <String, Object?>{},
      });
      commands.close();
      if (keepAlive == null) return;
    }
  }
}

void _serveHostStreams(
  SendPort bootstrap,
  SendPort responses,
  ReceivePort commands,
) {
  final host = AdeleHostRequestMultiplexer(send: responses.send);
  final iterators = <int, StreamIterator<Object?>>{};
  bootstrap.send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });
  // A nested reverse stream must continue receiving replies during forward work.
  commands.listen((Object? raw) async {
    if (host.handleResponse(raw)) return;
    final message = raw! as Map;
    final id = message['requestId'] as int;
    final payload = message['payload'] as Map?;
    if (message['kind'] == 'streamOpen') {
      iterators[id] = StreamIterator(
        host
            .bind(
              hostInvocationContext: payload!['context'] as String,
              serviceId: payload['service'] as String? ?? 'fixtureService',
            )
            .stream(payload['method'] as String? ?? 'watch', {
              if (payload['oversize'] == true)
                'value': 'x' * (8 * 1024 * 1024 + 1),
              if (payload['compactDag'] == true) 'value': _compactDag(),
            }),
      );
    } else if (message['kind'] == 'streamCredit') {
      final iterator = iterators[id];
      if (iterator == null) return;
      try {
        final next = await iterator.moveNext();
        if (iterators[id] != iterator) return;
        responses.send({
          'kind': next ? 'streamItem' : 'streamDone',
          'requestId': id,
          if (next) 'payload': iterator.current,
        });
        if (!next) iterators.remove(id);
      } on Object catch (error) {
        if (iterators.remove(id) != iterator) return;
        responses.send({
          'kind': 'streamFailure',
          'requestId': id,
          'error': {
            'code': error is AdeleRemoteFailure ? error.code : 'fixture_error',
            'message': error.toString(),
            if (error is AdeleRemoteFailure &&
                error.declaredFailureType != null)
              'declaredFailureType': error.declaredFailureType,
            if (error is AdeleRemoteFailure)
              'details': jsonDecode(jsonEncode(error.details)),
          },
        });
      }
    } else if (message['kind'] == 'streamCancel') {
      await iterators.remove(id)?.cancel();
      responses.send({'kind': 'streamCancelled', 'requestId': id});
    } else if (message['method'] == 'raw') {
      responses.send(Map<String, Object?>.from(payload!));
    } else if (message['method'] == 'shutdown') {
      host.close();
      await Future.wait(iterators.values.map((iterator) => iterator.cancel()));
      responses.send({
        'kind': 'response',
        'requestId': id,
        'ok': true,
        'payload': null,
      });
      commands.close();
    } else if (message['method'] == 'crash') {
      commands.close();
    } else {
      responses.send({
        'kind': 'response',
        'requestId': id,
        'ok': true,
        'payload': 'alive',
      });
    }
  });
}

Object? _compactDag() {
  Object? value;
  for (int depth = 0; depth < 30; depth++) {
    value = <Object?>[value, value];
  }
  return value;
}
