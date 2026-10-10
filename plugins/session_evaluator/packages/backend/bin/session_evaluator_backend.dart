import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:session_evaluator_backend/session_evaluator_backend.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

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
  final Object? hostInfrastructureContext =
      bootstrapMessage['hostInfrastructureContext'];
  if (bootstrapPort is! SendPort ||
      responsePort is! SendPort ||
      defaultConfigurationContext is! String ||
      hostInfrastructureContext is! String) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }

  final hostRequests = AdeleHostRequestMultiplexer(send: responsePort.send);
  final collector = SessionEvidenceCollector(
    ProjectStorageServiceClient(
      hostRequests.bindInfrastructure(
        hostInfrastructureContext: hostInfrastructureContext,
        serviceId: projectStorageServiceId,
      ),
    ),
  );
  final router = AdeleConfigurationContextRouter.single(
    configurationContext: defaultConfigurationContext,
    serviceId: sessionEvaluatorServiceId,
    dispatcher: SessionEvaluatorServiceDispatcher(collector),
  );
  final requests = ReceivePort();
  try {
    bootstrapPort.send(<String, Object?>{
      'kind': 'ready',
      'commandPort': requests.sendPort,
      'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    });
    await for (final Object? request in requests) {
      if (hostRequests.handleResponse(request)) continue;
      if (request is! Map) continue;
      if (request['kind'] == 'request' &&
          request['method'] == 'shutdown' &&
          request['requestId'] is int) {
        // Settle reverse calls before draining forward collection streams.
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
