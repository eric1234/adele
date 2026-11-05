import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

final _projectProvider = ProviderId('dev.adele.test.project');
final _environmentProvider = ProviderId('dev.adele.test.environment');
final _strategy = OrchestrationStrategyId('dev.adele.test.strategy');

Future<void> main(List<String> arguments) async {
  final source = Directory(arguments.single);
  final runtime = AdeleRuntime(ids: MonotonicProductIdSource(seed: 'killed'));
  for (final (id, capability, service) in [
    (_projectProvider, projectProviderCapability, projectProviderServiceId),
    (
      _environmentProvider,
      environmentProviderCapability,
      environmentProviderServiceId,
    ),
  ]) {
    runtime.registry.register(
      provider: ProviderDescriptor(
        id: id,
        capability: capability,
        pluginId: 'dev.adele.test.provider',
        displayName: 'Fixture',
        serviceId: service,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: _Providers(),
        serviceId: service,
        isAvailable: () => true,
      ),
    );
  }
  runtime.extensions.register(
    point: orchestrationStrategyContributions,
    id: ExtensionId('dev.adele.test.strategy'),
    value: OrchestrationStrategyContribution(
      strategyId: _strategy,
      materialize: (context) => _Execution(context.host),
    ),
  );
  final project = await runtime.lifecycle.openProject(
    sourceLocation: source.uri,
    provider: runtime.lifecycle.resolveProjectProvider(_projectProvider),
  );
  final task = await runtime.lifecycle.createTask(
    projectId: project.id,
    title: 'Killed writer',
    providerId: _environmentProvider,
  );
  final session = runtime.lifecycle.createSession(
    taskId: task.task.id,
    strategyId: _strategy,
  );
  final run = await createSessionOrchestrationRun(
    lifecycle: runtime.lifecycle,
    sessionId: session.id,
    runId: RunId('run-killed'),
    contextComposer: runtime.contextComposer,
    model: _Model(),
    toolCatalog: ToolCatalog()
      ..register(
        ToolRegistration(
          definition: ToolDefinition(
            id: ToolId('dev.adele.test.kill-tool'),
            description: 'Fixture',
          ),
          modelDefinition: ModelToolDefinition(
            alias: 'kill_tool',
            description: 'Fixture',
            argumentsSchema: const {},
          ),
          executable: _Tool(runtime, '${source.path}/.adele/data.db'),
        ),
      ),
    policy: _Policy(),
  );
  // No close or finalizer: the parent kills this process at the committed marker.
  await run.start();
  throw StateError('Writer unexpectedly completed.');
}

final class _Providers implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == projectProviderServicePrepareSourceId) {
      return {
        'sourceLocation': payload['sourceLocation'],
        'databaseRelativePath': '.adele/data.db',
      };
    }
    if (method == environmentProviderServiceEstablishId) {
      return {'providerState': <String, Object?>{}, 'initialState': null};
    }
    throw StateError('Unexpected provider operation $method');
  }
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.host);
  final OrchestrationExecutionHost host;

  @override
  Future<void> start() async {
    host.start();
    final turn = await host.invokeModel(
      StrategyInferenceMaterial(input: const []),
    );
    await host.processProposal(
      tools: turn.tools,
      proposal: turn.output
          .whereType<ModelToolProposalOutput>()
          .single
          .proposal,
    );
    throw StateError('Tool unexpectedly returned.');
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async =>
      throw StateError('Unexpected approval.');

  @override
  Future<void> close() async => throw StateError('Unexpected cleanup.');
}

final class _Model implements ModelPort {
  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    yield ModelObservationEvent(
      invocationId: request.invocationId,
      observation: ModelTextDeltaObservation('Transient'),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput('Committed before kill'),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelToolProposalOutput(
        ProviderToolProposal(
          providerCallId: 'kill-call',
          alias: 'kill_tool',
          arguments: const {'target': 'fixture'},
        ),
      ),
    );
    yield ModelInvocationSettledEvent(invocationId: request.invocationId);
  }
}

final class _Tool implements ToolExecutable {
  _Tool(this.runtime, this.databasePath);
  final AdeleRuntime runtime;
  final String databasePath;

  @override
  CanonicalToolArguments validateAndNormalize(Map<String, Object?> arguments) =>
      CanonicalToolArguments(arguments);

  @override
  void validateBinding() {}

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const [ToolEffect.sourceMutation],
    targets: const [],
    summary: 'Fixture effect',
  );

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final database = runtime.lifecycle.databaseForSession(context.sessionId)!;
    final snapshot = database.loadExecutionRestoreSet([]).unsealed.single;
    final tool = snapshot.tools.single;
    if (!database.autocommit ||
        tool.changes.last.kind != ToolActivityKind.executionStarted ||
        tool.outcome != null) {
      throw StateError('Execution dispatched before its checkpoint committed.');
    }
    final independent = sqlite3.open(databasePath);
    try {
      final row = independent
          .select(
            'SELECT latest_sequence, terminal_run_id FROM adele_execution_run_activity',
          )
          .single;
      if (row['latest_sequence'] != snapshot.sequence ||
          row['terminal_run_id'] != null) {
        throw StateError('Checkpoint not visible to independent connection.');
      }
    } finally {
      independent.close();
    }
    stdout.writeln(
      jsonEncode({
        'checkpoint': 'committed',
        'runId': context.runId.value,
        'sessionId': context.sessionId.value,
        'sequence': snapshot.sequence,
        'modelId': snapshot.models.single.id.value,
        'toolId': tool.id.value,
        'proposalSequence': tool.proposalSequence,
      }),
    );
    await stdout.flush();
    await stdin.first;
    throw StateError('Writer released instead of killed.');
  }
}

final class _Policy implements ToolPolicy {
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) =>
      ToolPolicyDecision.allow;
}
