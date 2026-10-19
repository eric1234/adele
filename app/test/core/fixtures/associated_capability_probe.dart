import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

/// Test-only backend using normal ready advertisements and generated services.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final options = jsonDecode(arguments.single) as Map<String, Object?>;
  final exposures = AdeleCapabilityExposure.fromReady({
    'capabilityExposures': options['exposures'],
  });
  final requests = <Map<String, Object?>>[];
  final reverseRequests = <Map<String, Object?>>[];
  final establishments = <Map<String, Object?>>[];
  final hostRequests = AdeleHostRequestMultiplexer(
    send: (message) {
      reverseRequests.add({
        'serviceId': message['serviceId'],
        'method': message['method'],
        'hostContextKind': message['hostContextKind'],
      });
      responses.send(message);
    },
  );
  final establishing = Completer<void>();
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
                        options: options,
                        establishing: establishing,
                        establishRelease: release.future,
                        establishments: establishments,
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
      if (hostRequests.handleResponse(message)) continue;
      if (message is! Map) continue;
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        if (!release.isCompleted) release.complete();
        hostRequests.close();
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
          if (message['method'] == 'establishing') {
            await establishing.future.timeout(const Duration(seconds: 10));
          }
          if (message['method'] == 'restoring') {
            await restoring.future.timeout(const Duration(seconds: 10));
          }
          if (message['method'] == 'release' && !release.isCompleted) {
            release.complete();
          }
          Object? payload = {
            'requests': requests,
            'reverseRequests': reverseRequests,
            'establishments': establishments,
          };
          if (message['method'] == 'queryEnvironment') {
            final arguments = message['payload'] as Map<Object?, Object?>;
            final storage = ProjectStorageServiceClient(
              hostRequests.bindInfrastructure(
                hostInfrastructureContext:
                    bootstrap['hostInfrastructureContext'] as String,
                serviceId: projectStorageServiceId,
              ),
            );
            try {
              final rows = await storage.queryForEnvironment(
                arguments['environmentId'] as String,
                arguments['sql'] as String,
                Map<String, Object?>.from(
                  arguments['parameters']! as Map<Object?, Object?>,
                ),
                ProjectStorageAccessMode.durableOrTemporary,
              );
              payload = {'rows': rows.map((row) => row.values).toList()};
            } on Object catch (error) {
              payload = {'error': '$error'};
            }
          }
          responses.send({
            'kind': 'response',
            'requestId': message['requestId'],
            'ok': true,
            'payload': jsonDecode(jsonEncode(payload)),
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
      unawaited(
        router.handle(message, (response) {
          if (message['method'] == environmentProviderServiceEstablishId &&
              response['ok'] == true &&
              ((message['payload'] as Map<Object?, Object?>)['context']
                      as Map<Object?, Object?>)['providerId'] ==
                  options['faultProviderId']) {
            // Corrupt an actual generated response, not a synthetic host result.
            final payload = Map<String, Object?>.from(
              response['payload']! as Map<Object?, Object?>,
            );
            final initial = Map<String, Object?>.from(
              payload['initialState']! as Map<Object?, Object?>,
            );
            if (options['fault'] == 'forgedOwner') {
              initial['ownerId'] = 'test.forged-owner';
            } else if (options['fault'] == 'malformed') {
              final inserts = initial['inserts'] as List<Object?>;
              initial['inserts'] = [
                {
                  ...Map<String, Object?>.from(
                    inserts.first! as Map<Object?, Object?>,
                  ),
                  'expectedRows': '1',
                },
                ...inserts.skip(1),
              ];
            }
            payload['initialState'] = initial;
            response = {...response, 'payload': payload};
          }
          responses.send(response);
        }),
      );
    }
  } finally {
    commands.close();
    if (!release.isCompleted) release.complete();
    hostRequests.close();
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
  const _EnvironmentService(
    this.providerIds,
    this.restoring,
    this.release, {
    required this.options,
    required this.establishing,
    required this.establishRelease,
    required this.establishments,
  });

  final Set<String> providerIds;
  final Completer<void> restoring;
  final Future<void>? release;
  final Map<String, Object?> options;
  final Completer<void> establishing;
  final Future<void> establishRelease;
  final List<Map<String, Object?>> establishments;

  @override
  Future<EnvironmentProviderTransportResult> establish(
    EnvironmentTransportContext environment,
  ) async {
    if (!providerIds.contains(environment.providerId)) {
      throw StateError('Unknown configured Environment provider.');
    }
    establishments.add({
      'taskId': environment.taskId,
      'environmentId': environment.environmentId,
    });
    if (!establishing.isCompleted) establishing.complete();
    if (options['holdEstablish'] == true) await establishRelease;
    final fault = environment.providerId == options['faultProviderId']
        ? options['fault']
        : null;
    return EnvironmentProviderTransportResult(
      providerState: {'provider': environment.providerId},
      initialState: options['initialState'] != true
          ? null
          : EnvironmentInitialState(
              schema:
                  'CREATE TABLE fixture_initial_records ('
                  'environment_id TEXT PRIMARY KEY '
                  'REFERENCES adele_product_environments(id), '
                  'task_id TEXT NOT NULL REFERENCES adele_product_tasks(id), '
                  'value TEXT NOT NULL)',
              inserts: [
                EnvironmentInitialInsert(
                  sql:
                      'INSERT INTO fixture_initial_records '
                      '(environment_id, task_id, value) '
                      'VALUES (:environment, :task, :value)',
                  parameters: {
                    ':environment': environment.environmentId,
                    ':task': environment.taskId,
                    ':value': environment.taskTitle,
                  },
                  expectedRows: fault == 'wrongRows' ? 2 : 1,
                ),
                if (fault == 'invalidSql')
                  EnvironmentInitialInsert(
                    sql: 'DELETE FROM fixture_initial_records',
                    parameters: const {},
                    expectedRows: 1,
                  ),
              ],
            ),
    );
  }

  @override
  Future<EnvironmentProviderTransportResult> restore(
    EnvironmentTransportContext environment,
  ) async {
    if (!providerIds.contains(environment.providerId)) {
      throw StateError('Unknown configured Environment provider.');
    }
    if (!restoring.isCompleted) restoring.complete();
    await release;
    return EnvironmentProviderTransportResult(
      providerState: {'provider': environment.providerId},
      initialState: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('No Environment effects in the provenance probe.');
}
