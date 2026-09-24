import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:local_directory_project_backend/local_directory_project_backend.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (arguments.isNotEmpty || bootstrapMessage is! Map) {
    throw ArgumentError('Expected bootstrap metadata and no plugin arguments.');
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

  final router = AdeleConfigurationContextRouter.single(
    configurationContext: defaultConfigurationContext,
    serviceId: projectProviderServiceId,
    dispatcher: ProjectProviderServiceDispatcher(
      const LocalDirectoryProjectProviderService(),
    ),
  );
  final requests = ReceivePort();
  bootstrapPort.send(<String, Object?>{
    'kind': 'ready',
    'commandPort': requests.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'capabilityExposures': [
      AdeleCapabilityExposure(
        providerId: localDirectoryProjectProviderId,
        capabilityId: projectProviderCapability.id.value,
        capabilityMajorVersion: projectProviderCapability.majorVersion,
        serviceId: projectProviderServiceId,
        displayName: 'Local Directory',
        configurationContext: defaultConfigurationContext,
      ).toMap(),
    ],
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
