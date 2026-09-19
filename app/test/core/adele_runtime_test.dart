import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart'
    show modelProviderCapability;
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

void main() {
  test('startup has zero static plugins, providers or product state', () async {
    final runtime = AdeleRuntime();
    addTearDown(runtime.close);
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
    expect(runtime.store.session(SessionId('session-1')), isNull);
    expect(runtime.lifecycle.store, same(runtime.store));
    expect(runtime.lifecycle.environmentRuntime.store, same(runtime.store));
    expect(runtime.plugins.extensions, same(runtime.extensions));
    expect(runtime.plugins.registry, same(runtime.registry));
    expect(runtime.plugins.host, isNull);
    expect(runtime.plugins.catalog, isNull);
    expect(runtime.plugins.backends, isEmpty);
    final closing = runtime.close();
    expect(runtime.close(), same(closing));
    await closing;
    expect(runtime.close(), same(closing));
  });

  test(
    'explicit generic contributions use the shared product and Run graph',
    () async {
      final runtime = AdeleRuntime(
        ids: MonotonicProductIdSource(seed: 'runtime'),
      );
      addTearDown(runtime.close);
      final strategyId = OrchestrationStrategyId(
        'dev.example.runtime-strategy',
      );
      final strategyRegistration = runtime.extensions.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('dev.example.runtime-strategy'),
        value: OrchestrationStrategyContribution(
          strategyId: strategyId,
          materialize: (context) => _Execution(context.host),
        ),
      );
      addTearDown(strategyRegistration.close);
      final channel = _EnvironmentChannel();
      final provider = runtime.registry.register(
        provider: ProviderDescriptor(
          id: ProviderId('dev.example.environment'),
          capability: environmentProviderCapability,
          pluginId: 'dev.example.environment',
          displayName: 'Test environment',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(provider.close);
      final project = runtime.lifecycle.createProject(
        Uri.parse('file:///fixture/'),
      );
      final task = await runtime.lifecycle.createTask(
        projectId: project.id,
        title: 'Generic Run',
      );
      final session = runtime.lifecycle.createSession(
        taskId: task.task.id,
        strategyId: strategyId,
      );
      expect(runtime.store.session(session.id), same(session));
      expect(
        runtime.store.requireSessionAuthority(session.id).environmentId,
        task.environment.id,
      );
      final tools = await buildModelToolCatalogForSession(
        sessionId: session.id,
        environmentRuntime: runtime.lifecycle.environmentRuntime,
        extensions: runtime.extensions,
      );
      final model = _Model();
      final run = await createSessionOrchestrationRun(
        lifecycle: runtime.lifecycle,
        sessionId: session.id,
        runId: RunId('runtime-run'),
        contextComposer: runtime.contextComposer,
        model: model,
        toolCatalog: tools,
        policy: const _NoTools(),
      );
      expect(model.requests, isEmpty);
      await run.start();
      expect(run.run.state, RunState.completed);
      expect(model.requests.single.context.sourceResults, isEmpty);
      expect(model.requests.single.tools.tools, isEmpty);
      expect(channel.calls, 1);
      await runtime.close();
      // Only explicit owners retire their registrations; runtime invents none.
      expect(strategyRegistration.isClosed, isFalse);
      expect(provider.isClosed, isFalse);
      await run.close();
    },
  );
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.host);
  final OrchestrationExecutionHost host;
  @override
  Future<void> start() async {
    host.start();
    await host.invokeModel(StrategyInferenceMaterial(input: const []));
    host.complete();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      throw StateError('No approvals.');
  @override
  Future<void> close() async {}
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  int calls = 0;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    calls++;
    return {'providerState': <String, Object?>{}};
  }
}

final class _Model implements ModelPort {
  final requests = <SemanticModelRequest>[];
  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests.add(request);
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput('Result'),
    );
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
    );
  }
}

final class _NoTools implements ToolPolicy {
  const _NoTools();
  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) =>
      throw StateError('No tools.');
}
