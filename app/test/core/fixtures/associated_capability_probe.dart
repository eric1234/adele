import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

/// Test-only backend using normal ready advertisements and generated services.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final options = jsonDecode(arguments.single) as Map;
  final exposures = AdeleCapabilityExposure.fromReady({
    'capabilityExposures': options['exposures'],
  });
  final requests = <Map<String, Object?>>[];
  final restoring = Completer<void>();
  final release = Completer<void>();
  final router = AdeleConfigurationContextRouter(
    contexts: {
      for (final context
          in exposures.map((e) => e.configurationContext).toSet())
        context: {
          for (final exposure in exposures)
            if (exposure.configurationContext == context)
              exposure.serviceId:
                  exposure.capabilityId ==
                      environmentProviderCapability.id.value
                  ? EnvironmentProviderServiceDispatcher(
                      _EnvironmentService(
                        exposures
                            .where(
                              (e) =>
                                  e.capabilityId ==
                                  environmentProviderCapability.id.value,
                            )
                            .map((e) => e.providerId)
                            .toSet(),
                        restoring,
                        options['holdRestore'] == true ? release.future : null,
                      ),
                    )
                  : ResourceInspectorServiceDispatcher(_Inspector(context)),
        },
    },
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'capabilityExposures': exposures.map((e) => e.toMap()).toList(),
  });
  try {
    await for (final Object? message in commands) {
      if (message is! Map) continue;
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        if (!release.isCompleted) release.complete();
        await router.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      if (message['kind'] == 'request' && message['serviceId'] == 'probe') {
        if (message['method'] == 'terminate') Isolate.exit();
        unawaited(() async {
          if (message['method'] == 'restoring') {
            await restoring.future.timeout(const Duration(seconds: 10));
          }
          if (message['method'] == 'release' && !release.isCompleted) {
            release.complete();
          }
          responses.send({
            'kind': 'response',
            'requestId': message['requestId'],
            'ok': true,
            'payload': jsonDecode(jsonEncode({'requests': requests})),
          });
        }());
        continue;
      }
      if (message['kind'] == 'request') {
        if (requests.length >= 64) throw StateError('Probe request limit.');
        requests.add({
          'configurationContext': message['configurationContext'],
          'serviceId': message['serviceId'],
          'method': message['method'],
          'hostInvocationContext': message['hostInvocationContext'],
        });
      }
      unawaited(router.handle(message, responses.send));
    }
  } finally {
    commands.close();
    if (!release.isCompleted) release.complete();
    await router.close();
  }
}

final class _Inspector implements ResourceInspectorService {
  const _Inspector(this.context);

  final String context;

  @override
  Future<ResourceInspection> inspect(ResourceRef resource) async =>
      ResourceInspection(
        resource: resource,
        providerLabel: context,
        summary: 'context-free probe',
      );
}

final class _EnvironmentService implements EnvironmentProviderService {
  const _EnvironmentService(this.providerIds, this.restoring, this.release);

  final Set<String> providerIds;
  final Completer<void> restoring;
  final Future<void>? release;

  @override
  Future<EnvironmentProviderResult> establish(
    EnvironmentTransportContext environment,
  ) => restore(environment);

  @override
  Future<EnvironmentProviderResult> restore(
    EnvironmentTransportContext environment,
  ) async {
    if (!providerIds.contains(environment.providerId)) {
      throw StateError('Unknown configured Environment provider.');
    }
    if (!restoring.isCompleted) restoring.complete();
    await release;
    return EnvironmentProviderResult(
      providerState: {'provider': environment.providerId},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('No Environment effects in the provenance probe.');
}
