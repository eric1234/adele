import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

/// Synthetic AOT backend. Positive calls use generated clients in both directions.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final options = jsonDecode(arguments.single) as Map;
  final exposures = AdeleCapabilityExposure.fromReady({
    'capabilityExposures': options['exposures'],
  });
  final hostRequests = AdeleHostRequestMultiplexer(send: responses.send);
  final state = _State(hostRequests);
  final router = AdeleConfigurationContextRouter(
    contexts: {
      for (final route in exposures.map((e) => e.configurationContext).toSet())
        route: {
          for (final exposure in exposures)
            if (exposure.configurationContext == route)
              exposure.serviceId:
                  exposure.capabilityId ==
                      environmentProviderCapability.id.value
                  ? EnvironmentProviderServiceDispatcher(
                      _EnvironmentService(state),
                      // All mutable admission bookkeeping is synchronous; gates
                      // are keyed per operation, never shared across requests.
                      concurrent: true,
                    )
                  : route == 'context-free'
                  ? ResourceInspectorServiceDispatcher(
                      _Inspector(state, route, null),
                    )
                  : AdeleContextualServiceDispatcher(
                      hostRequests: hostRequests,
                      createDispatcher: (context) =>
                          ResourceInspectorServiceDispatcher(
                            _Inspector(state, route, context),
                            concurrent: true,
                          ),
                    ),
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
        state.releaseAll();
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
        unawaited(state.control(message, responses.send));
        continue;
      }
      if (message['kind'] == 'request') {
        final payload = message['payload'] as Map;
        state.requests.add({
          'configurationContext': message['configurationContext'],
          'serviceId': message['serviceId'],
          'method': message['method'],
          'hostInvocationContext': message['hostInvocationContext'],
          'resource': payload['resource'],
        });
      }
      unawaited(router.handle(message, responses.send));
    }
  } finally {
    state.releaseAll();
    hostRequests.close();
    commands.close();
    await router.close();
  }
}

final class _State {
  _State(this.hostRequests);

  final AdeleHostRequestMultiplexer hostRequests;
  final requests = <Map<String, Object?>>[];
  final reads = <Map<String, Object?>>[];
  final environments = <String, String>{};
  final clients = <String, AuthorizedEnvironmentReadServiceClient>{};
  final _arrived = <String, Completer<void>>{};
  final _gates = <String, Completer<void>>{};

  Future<void> checkpoint(String key) async {
    final arrived = _arrived.putIfAbsent(key, Completer<void>.new);
    if (!arrived.isCompleted) arrived.complete();
    await _gates[key]?.future;
  }

  void releaseAll() {
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> control(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
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
          result = {'requests': requests, 'reads': reads};
        case 'retained':
          try {
            await clients[key]!.readFile('retained');
            result = {'ok': true};
          } on Object {
            result = {'ok': false};
          }
        case 'attack':
          // Negative-only probes deliberately bypass the operation's bound view.
          // Tokens are observations of actual requests, not authored authority.
          try {
            await hostRequests
                .bind(
                  hostInvocationContext: payload['token'] as String,
                  serviceId:
                      payload['service'] as String? ??
                      authorizedEnvironmentReadServiceId,
                )
                .request(
                  payload['method'] as String? ??
                      authorizedEnvironmentReadServiceReadFileId,
                  Map<String, Object?>.from(
                    payload['arguments'] as Map? ?? {'relativePath': 'attack'},
                  ),
                );
            result = {'ok': true};
          } on Object catch (error) {
            result = {'ok': false, 'error': error.toString()};
          }
        default:
          throw StateError('Unknown probe command.');
      }
      send({
        'kind': 'response',
        'requestId': command['requestId'],
        'ok': true,
        'payload': jsonDecode(jsonEncode(result)),
      });
    } on Object catch (error) {
      send({
        'kind': 'response',
        'requestId': command['requestId'],
        'ok': false,
        'error': {'code': 'probe_failure', 'message': error.toString()},
      });
    }
  }
}

final class _Inspector implements ResourceInspectorService {
  const _Inspector(this.state, this.route, this.context);

  final _State state;
  final String route;
  final AdeleBackendOperationContext? context;

  @override
  Future<ResourceInspection> inspect(ResourceRef resource) async {
    if (context == null) {
      return ResourceInspection(
        resource: resource,
        providerLabel: route,
        summary: 'context-free',
      );
    }
    final key = resource.uri.pathSegments.join('/');
    final read = AuthorizedEnvironmentReadServiceClient(
      context!.bind(authorizedEnvironmentReadServiceId),
    );
    state.clients[key] = read;
    await state.checkpoint('before:$key');
    final authority = await read.authority();
    final file = await read.readFile(key);
    await state.checkpoint('after:$key');
    if (resource.uri.queryParameters['fail'] == 'backend') {
      throw StateError('Synthetic backend operation failure.');
    }
    return ResourceInspection(
      resource: resource,
      providerLabel: route,
      summary: jsonEncode({
        'sessionId': authority.sessionId,
        'environmentId': authority.environmentId,
        'text': file.text,
        'revision': file.revision,
        'path': file.relativePath,
      }),
    );
  }
}

final class _EnvironmentService implements EnvironmentProviderService {
  const _EnvironmentService(this.state);
  final _State state;

  @override
  Future<EnvironmentProviderResult> establish(
    EnvironmentTransportContext environment,
  ) => restore(environment);

  @override
  Future<EnvironmentProviderResult> restore(
    EnvironmentTransportContext environment,
  ) async {
    state.environments[environment.environmentId] = environment.providerId;
    await state.checkpoint('restore:${environment.environmentId}');
    return EnvironmentProviderResult(
      providerState: {'provider': environment.providerId},
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(
    String environmentId,
    String relativePath,
  ) async {
    final provider = state.environments[environmentId]!;
    state.reads.add({
      'environmentId': environmentId,
      'providerId': provider,
      'path': relativePath,
    });
    await state.checkpoint('read:$relativePath');
    if (relativePath == 'host-failure') {
      throw EnvironmentFailure(
        code: 'synthetic_read_failure',
        message: 'Synthetic Environment read failure.',
        details: const {},
      );
    }
    final text = '$provider:$environmentId:$relativePath';
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: utf8.encode(text).length,
      revision: '$environmentId-revision',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Only read authority is implemented by this probe.',
  );
}
