import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/remote_tool_authorization.dart';

const _bound = Duration(seconds: 10);
const _recordLimit = 64;

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final options = jsonDecode(arguments.single) as Map;
  final exposures = AdeleExtensionExposure.fromReady({
    'extensionExposures': options['exposures'],
  });
  final probe = _Probe();
  final router = AdeleConfigurationContextRouter(
    contexts: {
      for (final context
          in exposures.map((e) => e.configurationContext).toSet())
        context: {
          remoteToolAuthorizationPolicyServiceId:
              RemoteToolAuthorizationPolicyServiceDispatcher(
                _Service(probe, context, {
                  for (final exposure in exposures)
                    if (exposure.configurationContext == context &&
                        exposure.metadata['routeId'] is String)
                      exposure.metadata['routeId']! as String,
                }),
              ),
        },
    },
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'extensionExposures': exposures.map((e) => e.toMap()).toList(),
  });
  try {
    await for (final Object? message in commands) {
      if (message is! Map) continue;
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        probe.unblock();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      // Controls must remain responsive while the generated dispatcher awaits.
      if (message['kind'] == 'request' && message['serviceId'] == 'probe') {
        if (message['method'] == 'terminate') Isolate.exit();
        unawaited(probe.control(message, responses));
        continue;
      }
      if (message['kind'] == 'request' || message['kind'] == 'streamOpen') {
        if (probe.requests.length == _recordLimit) {
          throw StateError('Probe request record limit exceeded.');
        }
        probe.requests.add({
          'configurationContext': message['configurationContext'],
          'serviceId': message['serviceId'],
          'method': message['method'],
          'payload': message['payload'],
        });
      }
      unawaited(
        router.handle(message, (response) {
          final payload = message['payload'];
          final route = payload is Map ? payload['routeId'] : null;
          // Corrupt only the response after actual generated request dispatch.
          if (response['ok'] == true &&
              route is String &&
              route.startsWith('malformed-')) {
            responses.send({
              ...response,
              'payload': switch (route) {
                'malformed-null' => null,
                'malformed-map' => {'decision': 'allow'},
                _ => 'ALLOW',
              },
            });
          } else {
            responses.send(response);
          }
        }),
      );
    }
  } finally {
    probe.unblock();
    commands.close();
    await router.close();
  }
}

final class _Probe {
  final requests = <Map<String, Object?>>[];
  final evaluations = <Map<String, Object?>>[];
  final ready = <int, Completer<void>>{};
  final release = Completer<void>();

  void unblock() {
    if (!release.isCompleted) release.complete();
  }

  Future<void> waitFor(int count) async {
    if (count < 1 || count > _recordLimit) {
      throw ArgumentError.value(count, 'count');
    }
    if (evaluations.length >= count) return;
    await (ready[count] ??= Completer<void>()).future.timeout(_bound);
  }

  Future<void> control(
    Map<Object?, Object?> request,
    SendPort responses,
  ) async {
    try {
      final payload = request['payload'] as Map;
      final Object? result = switch (request['method']) {
        'snapshot' => {'requests': requests, 'evaluations': evaluations},
        'ready' => await waitFor(payload['count'] as int).then((_) => true),
        'release' => (() {
          unblock();
          return true;
        })(),
        _ => throw StateError('Unknown probe command ${request['method']}'),
      };
      responses.send({
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': jsonDecode(jsonEncode(result)),
      });
    } on Object catch (error) {
      responses.send({
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': false,
        'error': {'code': 'probe_control_failed', 'message': '$error'},
      });
    }
  }
}

final class _Service implements RemoteToolAuthorizationPolicyService {
  const _Service(this.probe, this.configuration, this.routes);

  final _Probe probe;
  final String configuration;
  final Set<String> routes;

  @override
  Future<RemoteToolAuthorizationDecision> evaluate(
    String routeId,
    RemoteToolAuthorizationRequest request,
  ) async {
    if (!routes.contains(routeId)) throw StateError('Unknown route $routeId.');
    if (probe.evaluations.length == _recordLimit) {
      throw StateError('Probe evaluation record limit exceeded.');
    }
    final record = <String, Object?>{
      'configurationContext': configuration,
      'routeId': routeId,
      'request': {
        'toolId': request.toolId,
        'canonicalArguments': request.canonicalArguments,
        'effects': request.effects,
        'runId': request.runId,
        'sessionId': request.sessionId,
        'projectId': request.projectId,
        'toolInvocationId': request.toolInvocationId,
      },
      'state': 'started',
    };
    probe.evaluations.add(record);
    probe.ready[probe.evaluations.length]?.complete();
    if (routeId.startsWith('held-')) {
      record['state'] = 'held';
      await probe.release.future.timeout(_bound);
    }
    if (routeId == 'fail' || routeId == 'held-fail') {
      record['state'] = 'failed';
      throw StateError('private backend authorization diagnostic');
    }
    final decision = switch (routeId) {
      'deny' => RemoteToolAuthorizationDecision.deny,
      'ask' => RemoteToolAuthorizationDecision.ask,
      'abstain' => RemoteToolAuthorizationDecision.abstain,
      _ => RemoteToolAuthorizationDecision.allow,
    };
    record['state'] = 'completed';
    record['decision'] = decision.name;
    return decision;
  }
}
