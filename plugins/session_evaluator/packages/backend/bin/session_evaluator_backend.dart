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
  final storage = ProjectStorageServiceClient(
    hostRequests.bindInfrastructure(
      hostInfrastructureContext: hostInfrastructureContext,
      serviceId: projectStorageServiceId,
    ),
  );
  final localState = BackendLocalStateServiceClient(
    hostRequests.bindInfrastructure(
      hostInfrastructureContext: hostInfrastructureContext,
      serviceId: backendLocalStateServiceId,
    ),
  );
  final handoffs = SessionEvaluationHandoffServiceImpl(
    storage,
    outputRoot: () async => Directory(
      '${await localState.getLocalStateRoot()}${Platform.pathSeparator}evaluations',
    ),
  );
  final router = AdeleConfigurationContextRouter(
    contexts: {
      defaultConfigurationContext: {
        sessionEvaluatorServiceId: SessionEvaluatorServiceDispatcher(
          SessionEvidenceCollector(storage),
        ),
        sessionEvaluationHandoffServiceId:
            SessionEvaluationHandoffServiceDispatcher(handoffs),
      },
    },
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
        // Fence effects before settling reverse calls or draining transport.
        final drained = handoffs.close();
        hostRequests.close();
        await drained;
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
    final drained = handoffs.close();
    hostRequests.close();
    requests.close();
    await drained;
    await router.close();
  }
}
