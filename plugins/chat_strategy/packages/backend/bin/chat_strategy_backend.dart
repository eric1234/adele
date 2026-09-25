import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';

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
  final sessions = ChatSessionStore(
    storage: ProjectStorageServiceClient(
      hostRequests.bindInfrastructure(
        hostInfrastructureContext: hostInfrastructureContext,
        serviceId: projectStorageServiceId,
      ),
    ),
  );
  final orchestration = ChatRemoteOrchestrationBackend(
    sessions: sessions,
    hostChannel: (context) => hostRequests.bind(
      hostInvocationContext: context,
      serviceId: remoteOrchestrationHostServiceId,
    ),
  );
  final router = AdeleConfigurationContextRouter(
    contexts: {
      defaultConfigurationContext: {
        chatSessionServiceId: ChatSessionServiceDispatcher(
          ChatSessionBackend(sessions),
        ),
        remoteOrchestrationServiceId: RemoteOrchestrationServiceDispatcher(
          orchestration,
        ),
      },
    },
  );
  final requests = ReceivePort();
  try {
    bootstrapPort.send(<String, Object?>{
      'kind': 'ready',
      'commandPort': requests.sendPort,
      'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
      'extensionExposures': [
        AdeleExtensionExposure(
          extensionPointId: orchestrationStrategyContributions.value,
          extensionId: chatStrategyExtensionId.value,
          serviceId: remoteOrchestrationServiceId,
          configurationContext: defaultConfigurationContext,
          metadata: {
            'strategyId': chatStrategyId.value,
            'routeId': chatStrategyRouteId,
          },
        ).toMap(),
      ],
    });
    await for (final Object? request in requests) {
      if (hostRequests.handleResponse(request)) continue;
      if (request is! Map) continue;
      if (request['kind'] == 'request' &&
          request['method'] == 'shutdown' &&
          request['requestId'] is int) {
        // Settle blocked reverse calls before draining active forward requests.
        hostRequests.close();
        await orchestration.close();
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
    try {
      await orchestration.close();
    } finally {
      await router.close();
    }
  }
}
