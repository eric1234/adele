import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_backend_credentials.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart'
    show AdeleBackendRecords, AdeleBackendSettings, AdeleHostRequestMultiplexer;

// Test-only controller. Credentials are never read at readiness or advertised.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final records = AdeleBackendRecords.fromBootstrap(bootstrapMessage).records;
  final settings = AdeleBackendSettings.fromBootstrap(bootstrapMessage).values;
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final context = bootstrap['hostInfrastructureContext'] as String?;
  var exactRequests = true;
  final hostRequests = AdeleHostRequestMultiplexer(
    send: (message) {
      final payload = message['payload'];
      exactRequests =
          exactRequests &&
          message['serviceId'] == backendCredentialServiceId &&
          message['method'] == 'readCredential' &&
          payload is Map &&
          payload.length == 4 &&
          const [
            'collection',
            'recordType',
            'recordId',
            'slot',
          ].every((key) => payload[key] is String);
      responses.send(message);
    },
  );
  final client = AdeleCredentialClient(
    hostRequests: hostRequests,
    hostInfrastructureContext: context ?? 'absent-test-context',
  );

  Map<String, Object?> failure(AdeleCredentialFailure error) => {
    'failure': error.kind.name,
    'display': error.toString(),
  };

  Future<Map<String, Object?>> control(Map<Object?, Object?> command) async {
    try {
      final payload = Map<String, Object?>.from(command['payload'] as Map);
      switch (command['method']) {
        case 'records':
          return {'records': records};
        case 'snapshot':
          return {
            'records': records,
            'settings': settings,
            'exactRequests': exactRequests,
          };
        case 'context':
          return {'context': context};
        case 'servicePresent':
          try {
            await hostRequests
                .bindInfrastructure(
                  hostInfrastructureContext: context ?? 'absent-test-context',
                  serviceId: backendCredentialServiceId,
                )
                .request('readCredential', const {});
            return {'servicePresent': true};
          } on AdeleRemoteFailure catch (error) {
            if (error.code != 'service_unavailable') rethrow;
            return {'servicePresent': false};
          }
        case 'read':
          // Only this explicit test request can return a successful secret.
          return {
            'secret': await client.readCredential(
              collection: payload['collection'] as String,
              recordType: payload['recordType'] as String,
              recordId: payload['recordId'] as String,
              slot: payload['slot'] as String,
            ),
          };
        case 'attack':
          // Negative-only bypass tests strict host parsing and stolen grants.
          // Even an unexpected successful attack returns no credential content.
          final result = await hostRequests
              .bindInfrastructure(
                hostInfrastructureContext:
                    payload['context'] as String? ??
                    context ??
                    'absent-test-context',
                serviceId: backendCredentialServiceId,
              )
              .request(
                payload['method'] as String? ?? 'readCredential',
                Map<String, Object?>.from(payload['arguments'] as Map),
              );
          if (result is Map && result.length == 1) {
            for (final kind in AdeleCredentialFailureKind.values) {
              if (result['failure'] == kind.name) {
                return failure(AdeleCredentialFailure(kind));
              }
            }
          }
          return {'authorized': result is Map && result['secret'] is String};
        default:
          return {'failure': 'unsupportedTestOperation'};
      }
    } on AdeleCredentialFailure catch (error) {
      return failure(error);
    } on AdeleRemoteFailure catch (error) {
      return failure(
        AdeleCredentialFailure(switch (error.code) {
          'host_infrastructure_unavailable' || 'host_invocation_unavailable' =>
            AdeleCredentialFailureKind.generationUnavailable,
          'service_unavailable' => AdeleCredentialFailureKind.notAuthorized,
          _ => AdeleCredentialFailureKind.credentialAccessFailed,
        }),
      );
    } on Object {
      return failure(
        const AdeleCredentialFailure(
          AdeleCredentialFailureKind.credentialAccessFailed,
        ),
      );
    }
  }

  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });
  try {
    await for (final message in commands) {
      if (hostRequests.handleResponse(message)) continue;
      if (message is! Map || message['kind'] != 'request') continue;
      if (message['method'] == 'shutdown') {
        hostRequests.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      // Receiving reverse replies must not wait for the forward controller call.
      unawaited(
        control(message).then((result) {
          responses.send({
            'kind': 'response',
            'requestId': message['requestId'],
            'ok': true,
            'payload': jsonDecode(jsonEncode(result)),
          });
        }),
      );
    }
  } finally {
    hostRequests.close();
    commands.close();
  }
}
