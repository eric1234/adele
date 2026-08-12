import 'dart:async';
import 'dart:isolate';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final Map<Object?, Object?> bootstrap =
      bootstrapMessage! as Map<Object?, Object?>;
  final SendPort bootstrapPort = bootstrap['bootstrapPort']! as SendPort;
  final SendPort responsePort = bootstrap['responsePort']! as SendPort;
  final ReceivePort commands = ReceivePort();
  final ReceivePort? keepAlive = arguments.single == 'acknowledge-hang'
      ? ReceivePort()
      : null;
  final Map<int, String> streams = <int, String>{};
  final Map<int, int> sequences = <int, int>{};
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': commands.sendPort,
  });
  if (arguments.single == 'exit-immediately') {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    commands.close();
    return;
  }
  await for (final Object? raw in commands) {
    final Map<Object?, Object?> message = raw! as Map<Object?, Object?>;
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
      } else if (method == 'stream-large-item') {
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
      streams.remove(id);
      sequences.remove(id);
      responsePort.send(<String, Object?>{
        'kind': 'streamCancelled',
        'requestId': id,
      });
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
    if (message['method'] == 'shutdown') {
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
