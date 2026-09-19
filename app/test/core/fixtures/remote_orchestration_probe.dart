import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration_backend.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final responses = bootstrap['responsePort'] as SendPort;
  final configuration = bootstrap['defaultConfigurationContext'] as String;
  final options = Map<String, Object?>.from(jsonDecode(arguments[1]) as Map);
  final probe = _Probe(options);
  final calls = AdeleHostRequestMultiplexer(send: responses.send);
  probe.calls = calls;
  final strategyId =
      options['strategyId'] as String? ??
      'dev.adele.test.remote-orchestration.strategy';
  probe.backend = RemoteOrchestrationBackend(
    routes: {
      'probe-route': OrchestrationStrategyContribution(
        strategyId: OrchestrationStrategyId(strategyId),
        materialize: (context) async {
          probe.records.add({
            'operation': 'materialize.begin',
            'sessionId': context.session.id.value,
            'taskId': context.session.taskId.value,
            'strategyId': context.session.strategyId.value,
            'runId': context.host.id.value,
          });
          var denied = false;
          try {
            await context.host.invokeModel(
              StrategyInferenceMaterial(input: []),
            );
          } on Object catch (error) {
            denied = true;
            probe.records.add({
              'operation': 'materialize.denied',
              'error': error.toString(),
            });
          }
          if (!denied) throw StateError('Materialization invoked the model.');
          await probe.hold('materialize');
          if (options['fail'] == 'materialize') {
            throw StateError('Deliberate materialization failure.');
          }
          probe.records.add({'operation': 'materialize.end'});
          return _Execution(probe, context.host);
        },
      ),
    },
    hostChannel: (context) => _ObservedChannel(
      probe,
      context,
      calls.bind(
        hostInvocationContext: context,
        serviceId: remoteOrchestrationHostServiceId,
      ),
    ),
  );
  final router = AdeleConfigurationContextRouter.single(
    configurationContext: configuration,
    serviceId: remoteOrchestrationServiceId,
    dispatcher: RemoteOrchestrationServiceDispatcher(_Service(probe)),
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'extensionExposures': [
      AdeleExtensionExposure(
        extensionPointId: orchestrationStrategyContributions.value,
        extensionId: arguments.first,
        serviceId:
            options['serviceId'] as String? ?? remoteOrchestrationServiceId,
        configurationContext: configuration,
        metadata: options.containsKey('metadata')
            ? Map<String, Object?>.from(options['metadata'] as Map)
            : {'strategyId': strategyId, 'routeId': 'probe-route'},
      ).toMap(),
    ],
  });
  try {
    await for (final Object? message in commands) {
      if (calls.handleResponse(message)) continue;
      if (message is! Map) continue;
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        probe.unblock();
        calls.close();
        await router.close();
        await probe.backend.close();
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      // This test-only route stays responsive while a generated call is held.
      if (message['kind'] == 'request' && message['serviceId'] == 'probe') {
        if (message['method'] == 'terminate') Isolate.exit();
        unawaited(probe.control(message, responses));
        continue;
      }
      unawaited(router.handle(message, responses.send));
    }
  } finally {
    probe.unblock();
    calls.close();
    commands.close();
    await router.close();
    await probe.backend.close();
  }
}

final class _Probe {
  _Probe(this.options);

  final Map<String, Object?> options;
  late final RemoteOrchestrationBackend backend;
  late final AdeleHostRequestMultiplexer calls;
  final records = <Map<String, Object?>>[];
  final contexts = <String>[];
  final ready = <String, Completer<void>>{};
  final releases = <String, Completer<void>>{};

  Future<void> hold(String operation) async {
    final entered = ready[operation] ??= Completer<void>();
    if (!entered.isCompleted) entered.complete();
    if (options['hold'] == operation) {
      await (releases[operation] ??= Completer<void>()).future;
    }
  }

  void unblock() {
    for (final release in releases.values) {
      if (!release.isCompleted) release.complete();
    }
  }

  Future<Map<String, Object?>> replay(Map<String, Object?> payload) async {
    try {
      final result = await calls
          .bind(
            hostInvocationContext:
                payload['context'] as String? ?? contexts.last,
            serviceId:
                payload['serviceId'] as String? ??
                remoteOrchestrationHostServiceId,
          )
          .request(
            payload['method'] as String? ??
                remoteOrchestrationHostServiceApplyCurrentApprovalId,
            payload['payload'] == null
                ? const {}
                : Map<String, Object?>.from(payload['payload'] as Map),
          );
      return {'ok': true, 'payload': result};
    } on AdeleRemoteFailure catch (error) {
      return {'ok': false, 'code': error.code, 'message': error.message};
    } on Object catch (error) {
      return {'ok': false, 'error': error.toString()};
    }
  }

  Future<void> control(
    Map<Object?, Object?> request,
    SendPort responses,
  ) async {
    final payload = Map<String, Object?>.from(request['payload'] as Map);
    final Object? result = switch (request['method']) {
      'snapshot' => {
        'executionCount': backend.executionCount,
        'records': records,
        'contexts': contexts,
      },
      'ready' =>
        await (ready[payload['operation'] as String] ??= Completer<void>())
            .future
            .then((_) => true),
      'release' => (() {
        final release = releases[payload['operation'] as String] ??=
            Completer<void>();
        if (!release.isCompleted) release.complete();
        return true;
      })(),
      'replay' => await replay(payload),
      _ => throw StateError('Unknown probe command ${request['method']}'),
    };
    responses.send({
      'kind': 'response',
      'requestId': request['requestId'],
      'ok': true,
      'payload': jsonDecode(jsonEncode(result)),
    });
  }
}

final class _Service implements RemoteOrchestrationService {
  const _Service(this.probe);
  final _Probe probe;

  @override
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  ) => probe.backend.materialize(routeId, session, runId);

  @override
  Future<RemoteRunState> start(String executionId, String context) {
    probe.contexts.add(context);
    probe.records.add({'operation': 'start.call', 'executionId': executionId});
    return probe.backend.start(executionId, context);
  }

  @override
  Future<RemoteRunState> resolveApproval(
    String executionId,
    RemoteApprovalResolution resolution,
    String context,
  ) async {
    final previous = probe.contexts.last;
    probe.contexts.add(context);
    probe.records.add({
      'operation': 'resume.oldToken',
      'result': await probe.replay({'context': previous}),
    });
    return probe.backend.resolveApproval(executionId, resolution, context);
  }

  @override
  Future<void> release(String executionId) async {
    probe.records.add({
      'operation': 'release',
      'executionId': executionId,
      'executionCount': probe.backend.executionCount,
    });
    try {
      await probe.backend.release(executionId);
    } on Object catch (error) {
      probe.records.add({
        'operation': 'release.failed',
        'error': error.toString(),
        'executionCount': probe.backend.executionCount,
      });
      await probe.hold('release.failed');
      rethrow;
    }
  }
}

final class _ObservedChannel implements AdeleRequestChannel {
  const _ObservedChannel(this.probe, this.context, this.delegate);
  final _Probe probe;
  final String context;
  final AdeleRequestChannel delegate;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final result = await delegate.request(method, payload);
    probe.records.add({
      'operation': 'host.call',
      'context': context,
      'method': method,
      'payload': payload,
      'result': result,
    });
    return result;
  }
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.probe, this.host);

  final _Probe probe;
  final OrchestrationExecutionHost host;
  final replay = <SemanticModelInputItem>[
    SemanticMessageInput(
      role: SemanticMessageRole.user,
      content: 'Probe request',
    ),
  ];
  late StrategyModelTurn turn;
  late List<ProviderToolProposal> proposals;
  int nextProposal = 0;

  @override
  Future<void> start() async {
    probe.records.add({'operation': 'start.native'});
    host.start();
    await probe.hold('start');
    if (probe.options['fail'] == 'start') {
      throw StateError('Deliberate start failure.');
    }
    turn = await host.invokeModel(
      StrategyInferenceMaterial(
        instructions: 'Probe instructions.\n',
        input: replay,
      ),
    );
    probe.records.add({
      'operation': 'model.turn',
      'settlement': turn.settlement?.name,
      'incompleteReason': turn.incompleteReason?.name,
      'failure': turn.failure?.toString(),
      'failureData': switch (turn.failure) {
        RemoteStrategyFailure(:final code, :final message) => {
          'code': code,
          'message': message,
        },
        _ => null,
      },
      'output': turn.output.map((item) {
        final remote = RemoteModelOutput.fromLocal(item);
        return {'kind': remote.kind.name, 'payload': remote.payload};
      }).toList(),
      'metadata': turn.metadata == null
          ? null
          : {
              'effectiveModel': turn.metadata!.effectiveModel,
              'providerResponseId': turn.metadata!.providerResponseId,
              'providerRequestId': turn.metadata!.providerRequestId,
              'providerStopReason': turn.metadata!.providerStopReason,
              'nativeState': turn.metadata!.providerNativeState?.data,
              'usage': {
                'inputTokens': turn.metadata!.usage?.inputTokens,
                'outputTokens': turn.metadata!.usage?.outputTokens,
                'cacheReadTokens': turn.metadata!.usage?.cacheReadTokens,
                'cacheWriteTokens': turn.metadata!.usage?.cacheWriteTokens,
                'providerDetails': turn.metadata!.usage?.providerDetails,
              },
            },
      'presentations': [
        for (final item in turn.output.whereType<ModelNativeOutput>())
          if (item.presentation case final presentation?)
            {
              'kind': presentation.kind,
              'compactText': presentation.compactText,
              'data': presentation.data,
            },
      ],
    });
    await probe.hold('turn');
    if (turn.failure != null || turn.settlement != ModelSettlement.completed) {
      host.fail(turn.failure ?? StateError('Model did not complete.'));
      return;
    }
    for (final output in turn.output) {
      replay.add(switch (output) {
        ModelTextOutput() => SemanticMessageInput(
          role: SemanticMessageRole.assistant,
          content: output.content,
          providerItemId: output.providerItemId,
          providerNativeMetadata: output.providerNativeMetadata,
        ),
        ModelNativeOutput() => SemanticNativeInput(
          providerItemId: output.providerItemId,
          providerNativeMetadata: output.providerNativeMetadata,
        ),
        ModelToolProposalOutput() => SemanticToolProposalInput(
          proposal: output.proposal,
          providerItemId: output.providerItemId,
          providerNativeMetadata: output.providerNativeMetadata,
        ),
      });
    }
    proposals = turn.output
        .whereType<ModelToolProposalOutput>()
        .map((output) => output.proposal)
        .toList();
    await _continue();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    await probe.hold('resume');
    if (probe.options['attack'] == 'fabricatedApproval') {
      try {
        await host.resolveApproval(
          ToolApprovalResolution(
            interruptionId: resolution.interruptionId,
            toolInvocationId: resolution.toolInvocationId,
            approved: resolution.approved,
          ),
        );
      } on InvalidRunOperation catch (error) {
        probe.records.add({
          'operation': 'approval.fabricated.denied',
          'error': '$error',
        });
        rethrow;
      }
      throw StateError('Fabricated approval was accepted.');
    }
    replay.add(await host.resolveApproval(resolution));
    if (probe.options['attack'] == 'consumedProposal') {
      try {
        await host.processProposal(
          tools: turn.tools,
          proposal: proposals.first,
        );
      } on InvalidRunOperation catch (error) {
        probe.records.add({
          'operation': 'proposal.consumed.denied',
          'error': '$error',
        });
        rethrow;
      }
      throw StateError('Consumed proposal was accepted.');
    }
    await _continue();
  }

  Future<void> _continue() async {
    while (nextProposal < proposals.length) {
      final proposal = proposals[nextProposal++];
      probe.records.add({
        'operation': 'proposal',
        'callId': proposal.providerCallId,
      });
      final result = await host.processProposal(
        tools: turn.tools,
        proposal: proposal,
      );
      switch (result) {
        case StrategyToolWaiting():
          return;
        case StrategyToolContinuation(:final item):
          replay.add(item);
      }
    }
    final continuation = await host.invokeModel(
      StrategyInferenceMaterial(
        instructions: 'Probe instructions.\n',
        input: replay,
      ),
    );
    if (continuation.failure != null ||
        continuation.settlement != ModelSettlement.completed) {
      host.fail(
        continuation.failure ?? StateError('Continuation did not complete.'),
      );
      return;
    }
    host.complete();
  }

  @override
  Future<void> close() async {
    probe.records.add({'operation': 'close.native'});
    if (probe.options['failClose'] == true) {
      throw StateError('Deliberate native cleanup failure.');
    }
  }
}
