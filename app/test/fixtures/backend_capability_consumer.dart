import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

/// Independent AOT consumer. The controller supplies test inputs, never a peer
/// channel, provider implementation, or capability binding.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final hostRequests = AdeleHostRequestMultiplexer(send: responses.send);
  final context = bootstrap['hostInfrastructureContext'] as String?;
  final consumer = context == null
      ? null
      : AdeleCapabilityConsumer(
          hostRequests: hostRequests,
          hostInfrastructureContext: context,
        );
  final accesses = <String, AdeleResolvedCapability>{};

  Map<String, Object?> provider(BackendCapabilityProvider value) => {
    'capabilityId': value.capabilityId,
    'majorVersion': value.majorVersion,
    'providerId': value.providerId,
    'pluginId': value.pluginId,
    'displayName': value.displayName,
    'serviceId': value.serviceId,
  };

  Future<Map<String, Object?>> control(Map<Object?, Object?> command) async {
    try {
      final payload = Map<String, Object?>.from(command['payload'] as Map);
      final slot = payload['slot'] as String? ?? 'selected';
      final capabilityId =
          payload['capabilityId'] as String? ??
          resourceInspectCapability.id.value;
      final major = payload['majorVersion'] as int? ?? 1;
      switch (command['method']) {
        case 'identity':
          return {'ok': true, 'infrastructureContext': context};
        case 'storage':
          final service = ProjectStorageServiceClient(
            hostRequests.bindInfrastructure(
              hostInfrastructureContext: context!,
              serviceId: projectStorageServiceId,
            ),
          );
          return {
            'ok': true,
            'durable': await service.isDurableSession(
              payload['sessionId'] as String,
            ),
          };
        case 'discover':
          if (consumer == null) throw StateError('No infrastructure grant.');
          final providers = await consumer.discover(capabilityId, major);
          return {'ok': true, 'providers': providers.map(provider).toList()};
        case 'resolve':
          if (consumer == null) throw StateError('No infrastructure grant.');
          final access = await consumer.resolve(
            capabilityId,
            major,
            expectedServiceId:
                payload['expectedServiceId'] as String? ??
                resourceInspectorServiceId,
            providerId: payload['providerId'] as String?,
          );
          if (access == null) return {'ok': true, 'provider': null};
          accesses[slot] = access;
          return {
            'ok': true,
            'provider': provider(access.provider),
            'requestOnly': access.requestChannel is! AdeleStreamChannel,
          };
        case 'inspect':
          final inspection =
              await ResourceInspectorServiceClient(
                accesses[slot]!.requestChannel,
              ).inspect(
                ResourceRef(
                  uri: Uri.parse(payload['uri'] as String? ?? 'test:/ordinary'),
                  mediaType: payload['mediaType'] as String?,
                ),
              );
          return {
            'ok': true,
            'providerLabel': inspection.providerLabel,
            'resource': {
              'uri': inspection.resource.uri.toString(),
              'mediaType': inspection.resource.mediaType,
            },
            'summary': inspection.summary,
          };
        case 'request':
          return {
            'ok': true,
            'value': await accesses[slot]!.requestChannel.request(
              payload['method'] as String,
              Map<String, Object?>.from(payload['arguments'] as Map),
            ),
          };
        case 'release':
          await accesses[slot]!.release();
          return {'ok': true};
        case 'attack':
          // Negative-only bypass of the facade. Exposing test-observed tokens
          // lets another independent consumer attempt (and fail) to steal them.
          final channel = hostRequests.bindInfrastructure(
            hostInfrastructureContext:
                payload['context'] as String? ?? context ?? 'forged-context',
            serviceId:
                payload['serviceId'] as String? ?? 'adele.capabilityConsumer',
          );
          return {
            'ok': true,
            'value': await channel.request(
              payload['method'] as String,
              Map<String, Object?>.from(payload['arguments'] as Map),
            ),
          };
        default:
          throw StateError('Unknown consumer controller method.');
      }
    } on ResourceInspectorFailure catch (error) {
      return {
        'ok': false,
        'type': 'declared',
        'code': error.code,
        'message': error.message,
        'details': error.details,
      };
    } on AdeleRemoteFailure catch (error) {
      return {
        'ok': false,
        'type': 'remote',
        'declaredFailureType': error.declaredFailureType,
        'code': error.code,
        'message': error.message,
        'details': error.details,
      };
    } on Object catch (error) {
      return {'ok': false, 'type': 'local', 'message': '$error'};
    }
  }

  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
  });
  if (arguments.isNotEmpty) {
    final options = jsonDecode(arguments.single) as Map;
    if (options['discoveryGatePort'] case final int port) {
      // Shared-host startPlugin waits for the next backend's ready message.
      // Trigger this reverse call after ready without queuing a forward command
      // behind that pending start; the normal multiplexer handles its reply.
      unawaited(() async {
        final gate = await Socket.connect(InternetAddress.loopbackIPv4, port);
        final input = StreamIterator(gate);
        try {
          await input.moveNext();
          final discovery = await control({
            'method': 'discover',
            'payload': <String, Object?>{},
          });
          final selected = await control({
            'method': 'resolve',
            'payload': {'providerId': 'test.inspector.c'},
          });
          final defaultSelection = await control({
            'method': 'resolve',
            'payload': <String, Object?>{},
          });
          gate.writeln(
            jsonEncode({
              'discovery': discovery,
              'selected': selected,
              'default': defaultSelection,
            }),
          );
          await gate.flush();
        } finally {
          gate.destroy();
          await input.cancel();
        }
      }());
    }
  }
  try {
    await for (final Object? message in commands) {
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
      if (message['serviceId'] != 'test.controller') continue;
      if (message['method'] == 'terminate') Isolate.exit();
      // A controller request must not block the loop receiving its host reply.
      unawaited(
        control(message).then((result) {
          responses.send({
            'kind': 'response',
            'requestId': message['requestId'],
            'ok': true,
            // Public snapshots may be unmodifiable views, which spawnUri
            // isolates cannot send. Only the controller observation is thawed.
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
