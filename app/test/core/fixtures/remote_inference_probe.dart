import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/remote_inference_context.dart';

// Deliberately hostile, test-only framing. Production AGENTS uses generated
// clients and backend support; this fixture must also send invalid payloads.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final configuration = bootstrap['defaultConfigurationContext'] as String;
  final options = arguments.length == 1
      ? <String, Object?>{}
      : Map<String, Object?>.from(jsonDecode(arguments[1]) as Map);
  final probe = _Probe(
    responses,
    failSnapshot: options['failSnapshot'] == true,
    holdSnapshot: options['holdSnapshot'] == true,
    detachedReads: options['detachedReads'] == true,
    inspectReadAuthority: options['inspectReadAuthority'] == true,
  );
  final router = AdeleConfigurationContextRouter.single(
    configurationContext: configuration,
    serviceId: remoteInferenceContextSourceServiceId,
    dispatcher: RemoteInferenceContextSourceServiceDispatcher(probe),
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'extensionExposures': [
      AdeleExtensionExposure(
        extensionPointId: 'dev.adele.extension.inference-context-sources',
        extensionId: arguments.first,
        serviceId:
            options['serviceId'] as String? ??
            remoteInferenceContextSourceServiceId,
        configurationContext: configuration,
        metadata: options.containsKey('metadata')
            ? Map<String, Object?>.from(options['metadata'] as Map)
            : const {'failureMode': 'required'},
      ).toMap(),
    ],
  });
  try {
    await for (final Object? message in commands) {
      if (message is! Map) continue;
      if (message['kind'] == 'hostResponse') {
        probe.pending
            .remove(message['requestId'])
            ?.complete(Map<String, Object?>.from(message));
        continue;
      }
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        probe.close();
        await router.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      // A separate control route remains usable while snapshot awaits a read.
      if (message['kind'] == 'request' && message['serviceId'] == 'probe') {
        if (message['method'] == 'terminate') Isolate.exit();
        unawaited(probe.control(message));
        continue;
      }
      unawaited(router.handle(message, responses.send));
    }
  } finally {
    probe.close();
    commands.close();
    await router.close();
  }
}

final class _Probe implements RemoteInferenceContextSourceService {
  _Probe(
    this.responses, {
    required this.failSnapshot,
    required this.holdSnapshot,
    required this.detachedReads,
    required this.inspectReadAuthority,
  });

  final SendPort responses;
  final bool failSnapshot;
  final bool holdSnapshot;
  final bool detachedReads;
  final bool inspectReadAuthority;
  final snapshotReady = Completer<void>();
  final snapshotRelease = Completer<void>();
  final detachedResults = <Future<Map<String, Object?>>>[];
  final pending = <int, Completer<Map<String, Object?>>>{};
  int nextRequest = 0;
  String? savedContext;

  Future<Map<String, Object?>> call(
    String context, {
    String service = authorizedEnvironmentReadServiceId,
    String method = authorizedEnvironmentReadServiceReadFileId,
    Map<String, Object?> payload = const {'relativePath': 'AGENTS.md'},
    String? forgedPluginId,
  }) {
    final id = nextRequest++;
    final result = Completer<Map<String, Object?>>();
    pending[id] = result;
    responses.send({
      'kind': 'hostRequest',
      'requestId': id,
      'hostContextKind': 'invocation',
      'hostContext': context,
      'serviceId': service,
      'method': method,
      'payload': payload,
      'pluginId': ?forgedPluginId,
    });
    return result.future;
  }

  Future<void> control(Map<Object?, Object?> request) async {
    final payload = Map<String, Object?>.from(request['payload'] as Map);
    final Object? result = switch (request['method']) {
      'savedContext' => savedContext,
      'snapshotReady' => await snapshotReady.future.then((_) => true),
      'finishSnapshot' => (() {
        snapshotRelease.complete();
        return true;
      })(),
      'readResults' => await Future.wait(detachedResults),
      'replay' => await call(
        payload['hostInvocationContext'] as String? ?? savedContext!,
        forgedPluginId: payload['pluginId'] as String?,
      ),
      _ => throw StateError('Unknown probe command ${request['method']}'),
    };
    responses.send({
      'kind': 'response',
      'requestId': request['requestId'],
      'ok': true,
      'payload': result,
    });
  }

  @override
  Future<List<RemoteInferenceInstruction>> snapshot(
    String sessionId,
    String runId,
    String hostInvocationContext,
  ) async {
    savedContext = hostInvocationContext;
    if (detachedReads) {
      // Both requests reach the host before the release acknowledgement. The
      // generated host dispatcher serializes them behind the first acquisition.
      detachedResults.add(call(hostInvocationContext));
      detachedResults.add(call(hostInvocationContext));
      snapshotReady.complete();
      await snapshotRelease.future;
      return [
        RemoteInferenceInstruction(
          key: 'context',
          text: hostInvocationContext,
          revision: null,
        ),
      ];
    }
    final checks = <String, Object?>{
      'semanticIds': {'sessionId': sessionId, 'runId': runId},
      if (inspectReadAuthority) ...{
        'authority': await call(
          hostInvocationContext,
          method: authorizedEnvironmentReadServiceAuthorityId,
          payload: const {},
        ),
        'directory': await call(
          hostInvocationContext,
          method: authorizedEnvironmentReadServiceReadDirectoryId,
          payload: const {'relativePath': 'lib'},
        ),
      },
      'forgedSession': await call(
        hostInvocationContext,
        payload: {
          'relativePath': 'AGENTS.md',
          'sessionId': 'forged-$sessionId',
        },
      ),
      'forgedRun': await call(
        hostInvocationContext,
        payload: {'relativePath': 'AGENTS.md', 'runId': 'forged-$runId'},
      ),
      'mutationService': await call(
        hostInvocationContext,
        service: 'authorizedEnvironmentMutation',
        method: 'authorizedEnvironmentMutation.createTextFile',
        payload: {'relativePath': 'unauthorized.txt', 'text': 'forbidden'},
      ),
      'processService': await call(
        hostInvocationContext,
        service: 'authorizedEnvironmentProcess',
        method: 'authorizedEnvironmentProcess.runForegroundProcess',
        payload: {'program': 'forbidden', 'arguments': <String>[]},
      ),
      'mutationMethod': await call(
        hostInvocationContext,
        method: 'environment.deleteExistingTextFile',
      ),
      'inventedContext': await call('invented-host-context'),
      'read': await call(hostInvocationContext),
    };
    if (holdSnapshot) {
      snapshotReady.complete();
      await snapshotRelease.future;
    }
    if (failSnapshot) {
      throw StateError('Deliberate source failure after reading.');
    }
    return [
      RemoteInferenceInstruction(
        key: 'context',
        text: hostInvocationContext,
        revision: null,
      ),
      for (final entry in checks.entries)
        RemoteInferenceInstruction(
          key: entry.key,
          text: jsonEncode(entry.value),
          revision: null,
        ),
    ];
  }

  void close() {
    if (!snapshotRelease.isCompleted) snapshotRelease.complete();
    for (final request in pending.values) {
      request.complete({
        'kind': 'hostResponse',
        'ok': false,
        'error': {'code': 'probe_closed', 'message': 'Probe shutdown.'},
      });
    }
    pending.clear();
  }
}
