import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';

// Test-only observer of public startup decoding and live reads. OpenAI has no
// corresponding observation method, readiness field, or registration.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final records = AdeleBackendRecords.fromBootstrap(bootstrapMessage).records;
  final settings = AdeleBackendSettings.fromBootstrap(bootstrapMessage).values;
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final context = bootstrap['hostInfrastructureContext'] as String;
  var exactRequests = true;
  final hostRequests = AdeleHostRequestMultiplexer(
    send: (message) {
      final payload = message['payload'];
      exactRequests =
          exactRequests &&
          message['serviceId'] == backendConfigurationServiceId &&
          message['method'] == 'currentRecords' &&
          payload is Map &&
          payload.isEmpty;
      responses.send(message);
    },
  );
  final client = AdeleConfigurationClient(
    hostRequests: hostRequests,
    hostInfrastructureContext: context,
  );
  final observations = <AdeleRecordObservation>[];
  Map<String, Object?> observe(AdeleRecordObservation observation) => {
    'records': observation.records,
    'isComplete': observation.isComplete,
  };
  Map<String, Object?> failure(AdeleConfigurationFailure error) => {
    'failure': error.kind.name,
    'display': error.toString(),
  };

  Future<Map<String, Object?>> control(Map<Object?, Object?> command) async {
    try {
      switch (command['method']) {
        case 'records':
          return {'records': records};
        case 'settings':
          return {...settings};
        case 'currentRecords':
          final observation = await client.currentRecords();
          observations.add(observation);
          return observe(observation);
        case 'retained':
          return {
            'observations': [for (final value in observations) observe(value)],
            'immutable': observations.every((observation) {
              final records = observation.records;
              return _rejectsMutation(() => records.length = records.length) &&
                  records.every((record) {
                    final values = record['values']! as Map<String, Object>;
                    return _rejectsMutation(
                          () => record['id'] = record['id']!,
                        ) &&
                        _rejectsMutation(values.clear);
                  });
            }),
            'exactRequests': exactRequests,
          };
        case 'attack':
          final payload = command['payload'] as Map;
          final result = await hostRequests
              .bindInfrastructure(
                hostInfrastructureContext: context,
                serviceId: backendConfigurationServiceId,
              )
              .request(
                payload['method'] as String? ?? 'currentRecords',
                Map<String, Object?>.from(payload['arguments'] as Map),
              );
          if (result is Map && result.length == 1) {
            for (final kind in AdeleConfigurationFailureKind.values) {
              if (result['failure'] == kind.name) {
                return failure(AdeleConfigurationFailure(kind));
              }
            }
          }
          // A negative-only raw probe must never return unexpected record data.
          return {'authorized': true};
        default:
          return {'failure': 'unsupportedTestOperation'};
      }
    } on AdeleConfigurationFailure catch (error) {
      return failure(error);
    } on AdeleRemoteFailure catch (error) {
      return failure(
        AdeleConfigurationFailure(switch (error.code) {
          'host_infrastructure_unavailable' || 'host_invocation_unavailable' =>
            AdeleConfigurationFailureKind.generationUnavailable,
          'service_unavailable' => AdeleConfigurationFailureKind.notAuthorized,
          _ => AdeleConfigurationFailureKind.configurationAccessFailed,
        }),
      );
    }
  }

  final requests = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': requests.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });
  try {
    await for (final request in requests) {
      if (hostRequests.handleResponse(request)) continue;
      if (request is! Map || request['kind'] != 'request') continue;
      if (request['method'] == 'shutdown') {
        hostRequests.close();
        responses.send({
          'kind': 'response',
          'requestId': request['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      // Reverse responses must remain receivable while forward work awaits them.
      unawaited(
        control(request).then((result) {
          responses.send({
            'kind': 'response',
            'requestId': request['requestId'],
            'ok': true,
            'payload': jsonDecode(jsonEncode(result)),
          });
        }),
      );
    }
  } finally {
    hostRequests.close();
    requests.close();
  }
}

bool _rejectsMutation(void Function() mutate) {
  try {
    mutate();
    return false;
  } on UnsupportedError {
    return true;
  }
}
