import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:development_source_backend/development_source_backend.dart';
import 'package:development_source_contract/development_source_contract.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (arguments.length != 1 || bootstrapMessage is! Map) {
    stderr.writeln(
      'Expected one configured source root and bootstrap metadata.',
    );
    exitCode = 64;
    return;
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

  final DevelopmentSourceServiceDispatcher dispatcher =
      DevelopmentSourceServiceDispatcher(
        LocalDevelopmentSourceService(Directory(arguments.single)),
      );
  final AdeleConfigurationContextRouter router =
      AdeleConfigurationContextRouter.single(
        configurationContext: defaultConfigurationContext,
        serviceId: developmentSourceServiceId,
        dispatcher: dispatcher,
      );
  final ReceivePort requests = ReceivePort();
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
