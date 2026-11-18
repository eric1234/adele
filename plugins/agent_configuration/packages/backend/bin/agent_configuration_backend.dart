import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:agent_configuration_backend/agent_configuration_backend.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (arguments.isNotEmpty || bootstrapMessage is! Map) {
    throw const FormatException('Expected Agent backend bootstrap metadata.');
  }
  final bootstrapPort = bootstrapMessage['bootstrapPort'];
  final responsePort = bootstrapMessage['responsePort'];
  final defaultContext = bootstrapMessage['defaultConfigurationContext'];
  final infrastructureContext = bootstrapMessage['hostInfrastructureContext'];
  if (bootstrapPort is! SendPort ||
      responsePort is! SendPort ||
      defaultContext is! String ||
      infrastructureContext is! String) {
    throw const FormatException('Invalid Agent backend bootstrap metadata.');
  }

  final hostRequests = AdeleHostRequestMultiplexer(send: responsePort.send);
  final configuration = AdeleConfigurationClient(
    hostRequests: hostRequests,
    hostInfrastructureContext: infrastructureContext,
  );
  final catalog = AgentCatalogBackend(configuration);
  final selection = AgentSelectionBackend(
    ProjectStorageServiceClient(
      hostRequests.bindInfrastructure(
        hostInfrastructureContext: infrastructureContext,
        serviceId: projectStorageServiceId,
      ),
    ),
    catalog,
  );
  final router = AdeleConfigurationContextRouter(
    contexts: {
      defaultContext: {
        agentCatalogServiceId: AgentCatalogServiceDispatcher(catalog),
        agentSelectionServiceId: AgentSelectionServiceDispatcher(selection),
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
          !request.containsKey('serviceId') &&
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
