import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final configuration = bootstrap['defaultConfigurationContext'] as String;
  final options = Map<String, Object?>.from(
    jsonDecode(arguments.single) as Map,
  );
  final probe = _AttackProbe(responses);
  final router = AdeleConfigurationContextRouter.single(
    configurationContext: configuration,
    serviceId: remoteOrchestrationServiceId,
    dispatcher: RemoteOrchestrationServiceDispatcher(probe),
  );
  final commands = ReceivePort();
  const metadata = {
    'strategyId': 'dev.adele.test.orchestration-attack.strategy',
    'routeId': 'attack-route',
  };
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'capabilityExposures': [
      AdeleCapabilityExposure(
        providerId: 'dev.adele.test.orchestration-attack.provider',
        capabilityId: 'dev.adele.test.orchestration-attack.capability',
        capabilityMajorVersion: 1,
        displayName: 'Attack probe rollback sentinel',
        serviceId: remoteOrchestrationServiceId,
        configurationContext: configuration,
      ).toMap(),
    ],
    'extensionExposures': [
      // An invalid second exposure must roll back this valid first registration
      // as well as the capability registration above.
      AdeleExtensionExposure(
        extensionPointId: orchestrationStrategyContributions.value,
        extensionId: 'dev.adele.test.orchestration-attack.strategy',
        serviceId: remoteOrchestrationServiceId,
        configurationContext: configuration,
        metadata: metadata,
      ).toMap(),
      if (options.isNotEmpty)
        AdeleExtensionExposure(
          extensionPointId: orchestrationStrategyContributions.value,
          extensionId: 'dev.adele.test.orchestration-attack.invalid',
          serviceId:
              options['serviceId'] as String? ?? remoteOrchestrationServiceId,
          configurationContext: configuration,
          metadata: options.containsKey('metadata')
              ? Map<String, Object?>.from(options['metadata'] as Map)
              : metadata,
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
      if (message['kind'] == 'request' && message['serviceId'] == 'probe') {
        unawaited(probe.control(message, responses));
      } else {
        unawaited(router.handle(message, responses.send));
      }
    }
  } finally {
    probe.close();
    commands.close();
    await router.close();
  }
}

// Deliberately bypass RemoteOrchestrationBackend: these tests must reach the app
// adapter, not be rejected by the reusable backend's local provenance checks.
final class _AttackProbe implements RemoteOrchestrationService {
  _AttackProbe(this.responses);

  final SendPort responses;
  final pending = <int, Completer<Map<String, Object?>>>{};
  final ready = <String, Completer<Map<String, Object?>>>{};
  final finishes = <String, Completer<String>>{};
  final released = <String>[];
  int nextExecution = 0;
  int nextRequest = 0;
  bool failRelease = false;
  Completer<void>? releaseGate;
  final releaseEntered = Completer<void>();

  AdeleRequestChannel channel(String context) => _HostChannel(this, context);

  RemoteOrchestrationHostServiceClient client(String context) =>
      RemoteOrchestrationHostServiceClient(channel(context));

  @override
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  ) async => 'execution-${nextExecution++}';

  @override
  Future<RemoteRunState> start(String executionId, String context) async {
    final host = client(context);
    await host.transition(RemoteRunTransition.start, null);
    final turns = <RemoteStrategyModelTurn>[];
    for (var index = 0; index < 2; index++) {
      turns.add(
        await host.invokeModel(
          RemoteStrategyInferenceMaterial.fromLocal(
            StrategyInferenceMaterial(input: []),
          ),
        ),
      );
    }
    return hold('$executionId/start', context, turns);
  }

  @override
  Future<RemoteRunState> resolveApproval(
    String executionId,
    RemoteApprovalResolution resolution,
    String context,
  ) => hold('$executionId/resume', context, []);

  Future<RemoteRunState> hold(
    String operation,
    String context,
    List<RemoteStrategyModelTurn> turns,
  ) async {
    (ready[operation] ??= Completer<Map<String, Object?>>()).complete({
      'context': context,
      'turns': [
        for (final turn in turns)
          {
            'snapshot': turn.toolSnapshotHandle,
            'proposal': turn.output.single.proposalHandle,
          },
      ],
    });
    final finish = await (finishes[operation] ??= Completer<String>()).future;
    return switch (finish) {
      'waiting' => RemoteRunState.waiting,
      // Return without awaiting an independently issued reverse call.
      'detached' => RemoteRunState.completed,
      _ => client(context).transition(RemoteRunTransition.complete, null),
    };
  }

  @override
  Future<void> release(String executionId) async {
    if (!releaseEntered.isCompleted) releaseEntered.complete();
    await releaseGate?.future;
    if (failRelease) throw StateError('Probe release failed.');
    released.add(executionId);
  }

  Future<void> control(
    Map<Object?, Object?> request,
    SendPort responses,
  ) async {
    final payload = Map<String, Object?>.from(request['payload'] as Map);
    Object? result;
    try {
      switch (request['method']) {
        case 'ready':
          result =
              await (ready[payload['operation'] as String] ??=
                      Completer<Map<String, Object?>>())
                  .future;
        case 'finish':
          (finishes[payload['operation'] as String] ??= Completer<String>())
              .complete(payload['state'] as String? ?? 'complete');
          result = true;
        case 'released':
          result = released;
        case 'failRelease':
          failRelease = true;
          result = true;
        case 'holdRelease':
          releaseGate = Completer<void>();
          result = true;
        case 'releaseReady':
          await releaseEntered.future;
          result = true;
        case 'releaseContinue':
          releaseGate!.complete();
          result = true;
        case 'unblock':
          unblock();
          result = true;
        case 'proposal':
          await client(payload['context'] as String).processProposal(
            payload['snapshot'] as String,
            payload['proposal'] as String,
          );
          result = {'ok': true};
        case 'approval':
          await client(payload['context'] as String).applyCurrentApproval();
          result = {'ok': true};
        case 'forgedApproval':
          await channel(payload['context'] as String).request(
            remoteOrchestrationHostServiceApplyCurrentApprovalId,
            {'resolution': payload['resolution']},
          );
          result = {'ok': true};
        default:
          throw StateError('Unknown attack control ${request['method']}.');
      }
    } on _RejectedHostCall catch (error) {
      result = {'ok': false, ...error.error};
    } on Object catch (error) {
      result = {'ok': false, 'unexpected': error.toString()};
    }
    responses.send({
      'kind': 'response',
      'requestId': request['requestId'],
      'ok': true,
      'payload': jsonDecode(jsonEncode(result)),
    });
  }

  void unblock() {
    for (final finish in finishes.values) {
      if (!finish.isCompleted) finish.complete('detached');
    }
  }

  void close() {
    if (releaseGate != null && !releaseGate!.isCompleted) {
      releaseGate!.complete();
    }
    unblock();
    for (final request in pending.values) {
      request.complete({
        'ok': false,
        'error': {'code': 'probe_closed', 'message': 'Attack probe shutdown.'},
      });
    }
    pending.clear();
  }
}

// Proposal and approval calls use generated clients over handwritten framing.
final class _HostChannel implements AdeleRequestChannel {
  const _HostChannel(this.probe, this.context);

  final _AttackProbe probe;
  final String context;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final id = probe.nextRequest++;
    final pending = Completer<Map<String, Object?>>();
    probe.pending[id] = pending;
    probe.responses.send({
      'kind': 'hostRequest',
      'requestId': id,
      'hostContextKind': 'invocation',
      'hostContext': context,
      'serviceId': remoteOrchestrationHostServiceId,
      'method': method,
      'payload': payload,
    });
    final response = await pending.future;
    if (response['ok'] != true) {
      throw _RejectedHostCall(
        Map<String, Object?>.from(response['error'] as Map),
      );
    }
    return response['payload'];
  }
}

final class _RejectedHostCall implements Exception {
  const _RejectedHostCall(this.error);
  final Map<String, Object?> error;
}
