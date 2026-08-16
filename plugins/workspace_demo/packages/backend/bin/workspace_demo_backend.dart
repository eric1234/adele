import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:workspace_demo_backend/workspace_demo_backend.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

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
  final Object? defaultConfigurationContext =
      bootstrapMessage['defaultConfigurationContext'];
  if (defaultConfigurationContext is! String) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }

  final WorkspaceDemoServiceDispatcher dispatcher =
      WorkspaceDemoServiceDispatcher(
        WorkspaceDemoFileService(Directory(arguments.single)),
      );
  final AdeleConfigurationContextRouter router =
      AdeleConfigurationContextRouter.single(
        configurationContext: defaultConfigurationContext,
        serviceId: workspaceDemoServiceId,
        dispatcher: dispatcher,
      );
  final ReceivePort commands = ReceivePort();
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'configurationContextProtocolVersion': 1,
  });

  await for (final Object? message in commands) {
    if (message is! Map) continue;
    if (message['method'] == 'shutdown' && message['requestId'] is int) {
      await router.close();
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': message['requestId'],
        'ok': true,
        'payload': <String, Object?>{'stopping': true},
      });
      commands.close();
      continue;
    }
    unawaited(router.handle(message, responsePort.send));
  }
}
