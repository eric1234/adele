import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:scripted_model_backend/scripted_model_provider_backend.dart';

/// Test-only catalogs and controls; stock scripted inference stays unchanged.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final options = jsonDecode(arguments.single) as Map;
  final catalogs = {
    if (options['advertiseCatalogs'] == true)
      for (final account in ['work', 'personal']) account: _Catalog(account),
  };
  final router = AdeleConfigurationContextRouter(
    contexts: {
      for (final account in ['work', 'personal', 'inference-only'])
        'inference-$account': {
          modelProviderServiceId: ModelProviderServiceDispatcher(
            ScriptedCommonModelProvider(),
          ),
        },
      for (final entry in catalogs.entries)
        'catalog-${entry.key}': {
          modelCatalogServiceId: ModelCatalogServiceDispatcher(entry.value),
        },
    },
  );
  final exposures = [
    for (final account in ['work', 'personal', 'inference-only'])
      AdeleCapabilityExposure(
        providerId: 'test.inference.$account',
        capabilityId: modelProviderCapability.id.value,
        capabilityMajorVersion: modelProviderCapability.majorVersion,
        serviceId: modelProviderServiceId,
        displayName: 'Inference $account',
        configurationContext: 'inference-$account',
      ),
    for (final account in catalogs.keys)
      AdeleCapabilityExposure(
        providerId: 'test.catalog.$account',
        capabilityId: modelCatalogCapability.id.value,
        capabilityMajorVersion: modelCatalogCapability.majorVersion,
        serviceId: modelCatalogServiceId,
        displayName: 'Catalog $account',
        configurationContext: 'catalog-$account',
        rank: account == 'personal' ? 20 : 10,
        association: AdeleProviderAssociation(
          capabilityId: modelProviderCapability.id.value,
          capabilityMajorVersion: modelProviderCapability.majorVersion,
          providerId: 'test.inference.$account',
        ),
      ),
  ];
  final requests = <Map<String, Object?>>[];
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'capabilityExposures': [
      for (final exposure in exposures) exposure.toMap(),
      ...?options['extraExposures'] as List?,
    ],
  });
  try {
    await for (final Object? message in commands) {
      if (message is! Map) continue;
      if (message['method'] == 'shutdown') {
        for (final catalog in catalogs.values) {
          catalog.release();
        }
        await router.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      if (message['serviceId'] == 'test.controller') {
        final payload = message['payload'] as Map;
        void respond(Object? result) => responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': result,
        });
        Object? result;
        switch (message['method']) {
          case 'setCatalog':
            final catalog = catalogs[payload['account']]!;
            catalog.mode = payload['mode'] as String? ?? 'models';
            catalog.revision = payload['revision'] as int? ?? 0;
          case 'hold':
            catalogs[payload['account']]!.hold();
          case 'wait':
            unawaited(
              catalogs[payload['account']]!.entered!.future.then(
                (_) => respond(null),
              ),
            );
            continue;
          case 'release':
            catalogs[payload['account']]!.release();
          case 'snapshot':
            result = {'requests': requests};
          default:
            throw StateError('Unknown catalog provider controller method.');
        }
        respond(result);
        continue;
      }
      requests.add({
        'configurationContext': message['configurationContext'],
        'serviceId': message['serviceId'],
        'method': message['method'],
        'payload': message['payload'],
        'hostInvocationContext': message['hostInvocationContext'],
        'hostInfrastructureContext': message['hostInfrastructureContext'],
      });
      if (message['configurationContext'] == 'catalog-work' &&
          catalogs['work']!.mode == 'malformed') {
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'models': 'SECRET malformed response'},
        });
      } else {
        unawaited(router.handle(message, responses.send));
      }
    }
  } finally {
    commands.close();
    await router.close();
  }
}

final class _Catalog implements ModelCatalogService {
  _Catalog(this.account);

  final String account;
  String mode = 'models';
  int revision = 0;
  Completer<void>? entered;
  Completer<void>? _gate;

  void hold() {
    entered = Completer<void>();
    _gate = Completer<void>();
  }

  void release() {
    _gate?.complete();
    _gate = null;
    entered = null;
  }

  @override
  Future<ModelCatalogSnapshot> listModels() async {
    if (_gate case final gate?) {
      entered!.complete();
      await gate.future;
    }
    switch (mode) {
      case 'empty':
        return ModelCatalogSnapshot(models: []);
      case 'declared-failure':
        throw const ModelCatalogFailure(
          code: 'authentication',
          message: 'Catalog authentication is unavailable.',
        );
      case 'unexpected-failure':
        throw StateError('SECRET catalog credential and endpoint diagnostics');
      case 'unsupported_discovery':
      case 'unavailable':
        throw ModelCatalogFailure(
          code: mode,
          message: 'SECRET untrusted diagnostic',
        );
      case 'models':
        return ModelCatalogSnapshot(
          models: [
            ModelCatalogEntry(
              modelId: ScriptedCommonModelProvider.model,
              displayName: 'Scripted $account v$revision',
              description: null,
            ),
          ],
        );
      default:
        throw StateError('Unknown catalog fixture mode.');
    }
  }
}
