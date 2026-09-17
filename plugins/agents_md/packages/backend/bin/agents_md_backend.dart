import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:agents_md_backend/agents_md_backend.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (arguments.isNotEmpty || bootstrapMessage is! Map) {
    stderr.writeln('Expected bootstrap metadata and no plugin arguments.');
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

  final hostRequests = AdeleHostRequestMultiplexer(send: responsePort.send);
  final router = AdeleConfigurationContextRouter.single(
    configurationContext: defaultConfigurationContext,
    serviceId: remoteInferenceContextSourceServiceId,
    dispatcher: RemoteInferenceContextSourceServiceDispatcher(
      AgentsMdBackend(hostRequests),
    ),
  );
  final requests = ReceivePort();
  try {
    bootstrapPort.send(<String, Object?>{
      'kind': 'ready',
      'commandPort': requests.sendPort,
      'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
      'extensionExposures': [
        AdeleExtensionExposure(
          extensionPointId: 'dev.adele.extension.inference-context-sources',
          extensionId: 'dev.adele.plugin.agents-md.instructions',
          serviceId: remoteInferenceContextSourceServiceId,
          configurationContext: defaultConfigurationContext,
          metadata: const <String, Object?>{'failureMode': 'required'},
        ).toMap(),
      ],
    });
    await for (final Object? request in requests) {
      if (hostRequests.handleResponse(request)) continue;
      if (request is! Map) continue;
      if (request['kind'] == 'request' &&
          request['method'] == 'shutdown' &&
          request['requestId'] is int) {
        hostRequests.close();
        await router.close();
        responsePort.send(<String, Object?>{
          'kind': 'response',
          'requestId': request['requestId'],
          'ok': true,
          'payload': <String, Object?>{'stopping': true},
        });
        break;
      }
      unawaited(router.handle(request, responsePort.send));
    }
  } finally {
    hostRequests.close();
    requests.close();
    await router.close();
  }
}
