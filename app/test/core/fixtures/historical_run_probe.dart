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
  final reads = (jsonDecode(arguments.single) as List).cast<String>();
  final calls = AdeleHostRequestMultiplexer(send: responses.send);
  final requests = <Map<String, Object?>>[];
  final phases = <Map<String, Object?>>[];
  OrchestrationExecutionHost? retainedHost;
  final backend = RemoteOrchestrationBackend(
    routes: {
      'history': OrchestrationStrategyContribution(
        strategyId: OrchestrationStrategyId('test.historical.strategy'),
        materialize: (context) async {
          retainedHost = context.host;
          phases.add({
            'phase': 'materialize',
            'runId': context.host.id.value,
            ...await _outsideOperation(context.host, reads.first),
          });
          return _Execution(context.host, reads, phases);
        },
      ),
    },
    hostChannel: (context) => _ObservedChannel(
      calls.bind(
        hostInvocationContext: context,
        serviceId: remoteOrchestrationHostServiceId,
      ),
      requests,
    ),
  );
  final router = AdeleConfigurationContextRouter.single(
    configurationContext: configuration,
    serviceId: remoteOrchestrationServiceId,
    dispatcher: RemoteOrchestrationServiceDispatcher(backend),
  );
  final commands = ReceivePort();
  (bootstrap['bootstrapPort'] as SendPort).send({
    'kind': 'ready',
    'commandPort': commands.sendPort,
    'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
    'extensionExposures': [
      AdeleExtensionExposure(
        extensionPointId: orchestrationStrategyContributions.value,
        extensionId: 'test.historical.registration',
        serviceId: remoteOrchestrationServiceId,
        configurationContext: configuration,
        metadata: {
          'strategyId': 'test.historical.strategy',
          'routeId': 'history',
        },
      ).toMap(),
    ],
  });
  try {
    await for (final Object? message in commands) {
      if (calls.handleResponse(message)) continue;
      if (message is! Map) continue;
      if (message['kind'] == 'request' && message['method'] == 'shutdown') {
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': {'stopping': true},
        });
        break;
      }
      if (message['kind'] == 'request' && message['serviceId'] == 'probe') {
        final result = switch (message['method']) {
          'snapshot' => {
            'requests': requests,
            'phases': phases,
            'executionCount': backend.executionCount,
          },
          'lateRead' => await _outsideOperation(retainedHost!, reads.first),
          _ => throw StateError('Unknown probe command.'),
        };
        responses.send({
          'kind': 'response',
          'requestId': message['requestId'],
          'ok': true,
          'payload': jsonDecode(jsonEncode(result)),
        });
        continue;
      }
      unawaited(router.handle(message, responses.send));
    }
  } finally {
    calls.close();
    commands.close();
    await router.close();
    await backend.close();
  }
}

Future<Map<String, Object?>> _outsideOperation(
  OrchestrationExecutionHost host,
  String id,
) async {
  try {
    await host.readHistoricalRun(RunId(id));
    return {'denied': false};
  } on InvalidRunOperation {
    return {'denied': true};
  }
}

final class _ObservedChannel implements AdeleRequestChannel {
  const _ObservedChannel(this.delegate, this.requests);
  final AdeleRequestChannel delegate;
  final List<Map<String, Object?>> requests;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) {
    requests.add({'method': method, 'payload': payload});
    return delegate.request(method, payload);
  }
}

final class _Execution implements OrchestrationExecution {
  const _Execution(this.host, this.reads, this.phases);
  final OrchestrationExecutionHost host;
  final List<String> reads;
  final List<Map<String, Object?>> phases;

  @override
  Future<void> start() async {
    host.start();
    final results = <Map<String, Object?>>[];
    if (!host.id.value.startsWith('seed-')) {
      for (final id in reads) {
        try {
          final evidence = await host.readHistoricalRun(RunId(id));
          final activity = evidence.activity;
          if (evidence.record.id != RunId(id) ||
              evidence.record.sessionId != host.sessionId ||
              activity.runId != evidence.record.id ||
              activity.state.name != evidence.record.state.name) {
            throw StateError('Historical read lost its canonical identity.');
          }
          results.add({
            'id': id,
            'state': evidence.record.state.name,
            'evidence': evidence.toJson(),
            // Inspect the typed value too, not only its transport encoder.
            'sanitized':
                activity.models.every(
                  (model) =>
                      model.metadata == null &&
                      (model.failure?.providerDetails.isEmpty ?? true) &&
                      model.outputs.every(
                        (output) => switch (output.item) {
                          ModelNativeOutput() => false,
                          ModelTextOutput(:final providerNativeMetadata) ||
                          ModelToolProposalOutput(
                            :final providerNativeMetadata,
                          ) => providerNativeMetadata == null,
                        },
                      ),
                ) &&
                (activity.failure?.providerDetails.isEmpty ?? true) &&
                activity.tools.every(
                  (tool) =>
                      (tool.outcome?.hostData.isEmpty ?? true) &&
                      tool.changes.every(
                        (change) => change.outcome?.hostData.isEmpty ?? true,
                      ),
                ),
          });
        } on HistoricalRunEvidenceFailure catch (error) {
          results.add({'id': id, 'failure': error.code});
        }
      }
    }
    final turn = await host.invokeModel(
      StrategyInferenceMaterial(
        input: [
          SemanticMessageInput(
            role: SemanticMessageRole.user,
            content: jsonEncode(results),
          ),
        ],
      ),
    );
    if (turn.failure case final failure?) {
      host.fail(failure);
    } else {
      host.complete();
    }
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      throw StateError('Historical evidence is not an actionable approval.');

  @override
  Future<void> close() async {
    phases.add({
      'phase': 'close',
      'runId': host.id.value,
      ...await _outsideOperation(host, reads.first),
    });
  }
}
