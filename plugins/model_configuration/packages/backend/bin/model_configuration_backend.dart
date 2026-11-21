import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_run_model_preference.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:model_configuration_backend/model_configuration_backend.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (arguments.isNotEmpty || bootstrapMessage is! Map) {
    throw const FormatException(
      'Expected Model Configuration backend bootstrap metadata.',
    );
  }
  final bootstrapPort = bootstrapMessage['bootstrapPort'];
  final responsePort = bootstrapMessage['responsePort'];
  final defaultContext = bootstrapMessage['defaultConfigurationContext'];
  final infrastructureContext = bootstrapMessage['hostInfrastructureContext'];
  if (bootstrapPort is! SendPort ||
      responsePort is! SendPort ||
      defaultContext is! String ||
      infrastructureContext is! String) {
    throw const FormatException(
      'Invalid Model Configuration backend bootstrap metadata.',
    );
  }
  final hostRequests = AdeleHostRequestMultiplexer(send: responsePort.send);
  final catalog = ModelPresetCatalogBackend(
    AdeleConfigurationClient(
      hostRequests: hostRequests,
      hostInfrastructureContext: infrastructureContext,
    ),
  );
  final selection = ModelPresetSelectionBackend(
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
        modelPresetCatalogServiceId: ModelPresetCatalogServiceDispatcher(
          catalog,
        ),
        modelPresetSelectionServiceId: ModelPresetSelectionServiceDispatcher(
          selection,
        ),
        remoteRunModelPreferenceServiceId:
            RemoteRunModelPreferenceServiceDispatcher(
              ModelPresetRunPreferenceBackend(selection, catalog),
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
          extensionPointId: runModelPreferencesExtensionPoint.value,
          extensionId:
              'dev.adele.plugin.model-configuration.run-model-preference',
          serviceId: remoteRunModelPreferenceServiceId,
          configurationContext: defaultContext,
          metadata: const {},
        ).toMap(),
      ],
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
      // A dispatched call can await a reverse reply from this same ReceivePort.
      unawaited(router.handle(request, responsePort.send));
    }
  } finally {
    hostRequests.close();
    requests.close();
    await router.close();
  }
}
