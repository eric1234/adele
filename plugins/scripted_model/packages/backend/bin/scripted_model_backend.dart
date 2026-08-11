import 'dart:isolate';

import 'package:scripted_model_backend/scripted_model_backend.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (bootstrapMessage is! Map) {
    throw StateError('Missing ADELE backend-host bootstrap metadata.');
  }
  final Object? bootstrapPort = bootstrapMessage['bootstrapPort'];
  final Object? responsePort = bootstrapMessage['responsePort'];
  if (bootstrapPort is! SendPort || responsePort is! SendPort) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }
  final ReceivePort requests = ReceivePort();
  final ScriptedModelFixtureServiceDispatcher dispatcher =
      ScriptedModelFixtureServiceDispatcher(const ScriptedModelProvider());
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': requests.sendPort,
  });
  await for (final Object? request in requests) {
    if (request is! Map) continue;
    if (request['method'] == 'shutdown' && request['requestId'] is int) {
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': <String, Object?>{'stopping': true},
      });
      requests.close();
      continue;
    }
    responsePort.send(await dispatcher.dispatch(request));
  }
}
