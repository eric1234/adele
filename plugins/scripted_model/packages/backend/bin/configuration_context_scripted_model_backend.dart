import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:scripted_model_backend/scripted_model_backend.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';

const String _configurationB = 'configuration-b';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (bootstrapMessage is! Map) {
    throw StateError('Missing ADELE backend-host bootstrap metadata.');
  }
  final Object? bootstrapPort = bootstrapMessage['bootstrapPort'];
  final Object? responsePort = bootstrapMessage['responsePort'];
  final Object? defaultConfigurationContext =
      bootstrapMessage['defaultConfigurationContext'];
  if (bootstrapPort is! SendPort ||
      responsePort is! SendPort ||
      defaultConfigurationContext is! String) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }
  final ReceivePort requests = ReceivePort();
  final ScriptedModelFixtureServiceDispatcher configurationA =
      ScriptedModelFixtureServiceDispatcher(
        ScriptedModelProvider(configurationLabel: 'configuration-a'),
      );
  final ScriptedModelFixtureServiceDispatcher configurationB =
      ScriptedModelFixtureServiceDispatcher(
        ScriptedModelProvider(configurationLabel: 'configuration-b'),
      );
  final AdeleConfigurationContextRouter router =
      AdeleConfigurationContextRouter(
        contexts: <String, Map<String, AdeleBackendDispatcher>>{
          defaultConfigurationContext: <String, AdeleBackendDispatcher>{
            scriptedModelFixtureServiceId: configurationA,
          },
          _configurationB: <String, AdeleBackendDispatcher>{
            scriptedModelFixtureServiceId: configurationB,
          },
        },
      );
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': requests.sendPort,
    'configurationContextProtocolVersion': 1,
  });
  await for (final Object? request in requests) {
    if (request is! Map) continue;
    if (request['method'] == 'shutdown' && request['requestId'] is int) {
      await router.close();
      responsePort.send(<String, Object?>{
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': <String, Object?>{'stopping': true},
      });
      requests.close();
      continue;
    }
    unawaited(router.handle(request, responsePort.send));
  }
}
