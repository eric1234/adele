import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final options = jsonDecode(arguments.single) as Map;
  final inspector = _Inspector(options['identity'] as String);
  final context = options['context'] as String;
  final router = AdeleConfigurationContextRouter(
    contexts: {
      context: {
        resourceInspectorServiceId: ResourceInspectorServiceDispatcher(
          inspector,
          concurrent: true,
        ),
        // Routable on this backend, but deliberately never advertised.
        'test.private': ResourceInspectorServiceDispatcher(inspector),
      },
    },
  );
  final exposure = AdeleCapabilityExposure(
    providerId: options['providerId'] as String,
    capabilityId: resourceInspectCapability.id.value,
    capabilityMajorVersion: 1,
    serviceId: resourceInspectorServiceId,
    displayName: 'Inspector ${inspector.identity}',
    configurationContext: context,
    rank: options['rank'] as int,
  );
  final commands = ReceivePort();
  if (options['readyGatePort'] case final int port) {
    // The test owns this loopback gate. Readiness is released by an explicit
    // byte, not by a guessed delay or an external service.
    final gate = await Socket.connect(InternetAddress.loopbackIPv4, port);
    try {
      await gate.first;
    } finally {
      gate.destroy();
    }
  }
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'capabilityExposures': [exposure.toMap()],
  });
  try {
    await for (final Object? message in commands) {
      if (message is! Map || message['kind'] != 'request') continue;
      if (message['method'] == 'shutdown') {
        inspector.releaseAll();
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
        if (message['method'] == 'terminate') Isolate.exit();
        unawaited(inspector.control(message, responses));
        continue;
      }
      inspector.requests.add({
        'configurationContext': message['configurationContext'],
        'serviceId': message['serviceId'],
        'method': message['method'],
        'payload': message['payload'],
        'hostInvocationContext': message['hostInvocationContext'],
        'hostInfrastructureContext': message['hostInfrastructureContext'],
      });
      final payload = message['payload'] as Map;
      if ((payload['resource'] as Map?)?['uri'] == 'test:/diagnostic-failure') {
        // Simulate an untrusted backend's unsanitized, undeclared wire failure.
        // The normal dispatcher already sanitizes ordinary Dart exceptions.
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': false,
          'error': {
            'code': 'SECRET diagnostic code',
            'message': 'SECRET backend implementation detail',
            'details': {'private': 'SECRET'},
          },
        });
        continue;
      }
      unawaited(router.handle(message, responses.send));
    }
  } finally {
    inspector.releaseAll();
    commands.close();
    await router.close();
  }
}

final class _Inspector implements ResourceInspectorService {
  _Inspector(this.identity);

  final String identity;
  final requests = <Map<String, Object?>>[];
  final _arrived = <String, Completer<void>>{};
  final _gates = <String, Completer<void>>{};

  @override
  Future<ResourceInspection> inspect(ResourceRef resource) async {
    final key = resource.uri.path;
    final arrived = _arrived.putIfAbsent(key, Completer<void>.new);
    if (!arrived.isCompleted) arrived.complete();
    await _gates[key]?.future;
    if (key == '/declared-failure') {
      throw ResourceInspectorFailure(
        code: 'inspection_denied',
        message: 'Inspection denied by $identity.',
        details: {
          'provider': identity,
          'resource': resource.uri.toString(),
          'nested': {
            'retryable': false,
            'values': [1, null, 'public'],
          },
        },
      );
    }
    if (key == '/unknown-failure') throw StateError('SECRET private error');
    return ResourceInspection(
      resource: resource,
      providerLabel: identity,
      summary: '$identity inspected ${resource.uri}',
    );
  }

  void releaseAll() {
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> control(
    Map<Object?, Object?> command,
    SendPort responses,
  ) async {
    try {
      final payload = command['payload'] as Map;
      final key = payload['key'] as String?;
      Object? result;
      switch (command['method']) {
        case 'hold':
          _gates.putIfAbsent(key!, Completer<void>.new);
        case 'wait':
          await _arrived
              .putIfAbsent(key!, Completer<void>.new)
              .future
              .timeout(const Duration(seconds: 10));
        case 'release':
          final gate = _gates[key]!;
          if (!gate.isCompleted) gate.complete();
        case 'snapshot':
          result = {'requests': requests};
        default:
          throw StateError('Unknown provider controller method.');
      }
      responses.send({
        'kind': 'response',
        'requestId': command['requestId'],
        'ok': true,
        'payload': result,
      });
    } on Object catch (error) {
      responses.send({
        'kind': 'response',
        'requestId': command['requestId'],
        'ok': false,
        'error': {'code': 'controller_failed', 'message': '$error'},
      });
    }
  }
}
