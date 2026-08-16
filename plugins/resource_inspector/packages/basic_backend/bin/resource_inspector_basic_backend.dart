import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:resource_inspector_basic_backend/resource_inspector_basic_backend.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (bootstrapMessage is! Map) {
    throw StateError('Missing ADELE backend-host bootstrap metadata.');
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
  final ReceivePort requests = ReceivePort();
  final ResourceInspectorServiceDispatcher dispatcher =
      ResourceInspectorServiceDispatcher(const BasicResourceInspector());
  final AdeleConfigurationContextRouter router =
      AdeleConfigurationContextRouter.single(
        configurationContext: defaultConfigurationContext,
        serviceId: resourceInspectorServiceId,
        dispatcher: dispatcher,
      );
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': requests.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
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
