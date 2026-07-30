import 'dart:async';
import 'dart:isolate';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final Map<Object?, Object?> bootstrap =
      bootstrapMessage! as Map<Object?, Object?>;
  final SendPort bootstrapPort = bootstrap['bootstrapPort']! as SendPort;
  final SendPort responsePort = bootstrap['responsePort']! as SendPort;
  final ReceivePort commands = ReceivePort();
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
    if (message['method'] == 'crash') {
      commands.close();
      return;
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
    }
  }
}
