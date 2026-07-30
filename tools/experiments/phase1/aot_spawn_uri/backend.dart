import 'dart:isolate';

void main(List<String> arguments, Object? bootstrapMessage) {
  if (bootstrapMessage == null) {
    print('backend-aot=valid');
    return;
  }
  if (bootstrapMessage is! SendPort) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }

  final ReceivePort commands = ReceivePort();
  bootstrapMessage.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': commands.sendPort,
  });

  commands.listen((Object? message) {
    if (message is! Map) return;
    final Object? replyPort = message['replyPort'];
    final Object? requestId = message['requestId'];
    if (replyPort is! SendPort || requestId is! int) return;

    switch (message['method']) {
      case 'ping':
        replyPort.send(<String, Object?>{
          'kind': 'response',
          'requestId': requestId,
          'ok': true,
          'payload': <String, Object?>{
            'message': 'pong',
            'nested': <Object?>[
              1,
              true,
              <String, Object?>{'portable': true},
            ],
          },
        });
      case 'shutdown':
        replyPort.send(<String, Object?>{
          'kind': 'response',
          'requestId': requestId,
          'ok': true,
          'payload': <String, Object?>{'stopping': true},
        });
        commands.close();
      default:
        replyPort.send(<String, Object?>{
          'kind': 'response',
          'requestId': requestId,
          'ok': false,
          'error': <String, Object?>{
            'code': 'unknown_method',
            'message': 'Unknown method.',
          },
        });
    }
  });
}
