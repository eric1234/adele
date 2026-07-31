import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:workspace_demo_backend/workspace_demo_backend.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (arguments.length != 1 || bootstrapMessage is! Map) {
    stderr.writeln('Expected development root and portable bootstrap map.');
    exitCode = 64;
    return;
  }
  final Object? bootstrapPort = bootstrapMessage['bootstrapPort'];
  final Object? responsePort = bootstrapMessage['responsePort'];
  if (bootstrapPort is! SendPort || responsePort is! SendPort) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }

  final WorkspaceDemoServiceDispatcher dispatcher =
      WorkspaceDemoServiceDispatcher(
        WorkspaceDemoFileService(Directory(arguments.single)),
      );
  final ReceivePort commands = ReceivePort();
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': commands.sendPort,
  });

  await for (final Object? message in commands) {
    if (message is! Map) continue;
    if (message['method'] == 'shutdown' && message['requestId'] is int) {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': <String, Object?>{'stopping': true},
      });
      commands.close();
      continue;
    }
    responsePort.send(await dispatcher.dispatch(message));
  }
}
