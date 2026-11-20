import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

typedef SelectionGraph = ({
  Project project,
  Environment environment,
  Session session,
  Session otherSession,
});

/// Two canonical Sessions with no executable strategy or live Environment.
Future<SelectionGraph> createSelectionSessions(
  AdeleRuntime runtime,
  Project project,
  OrchestrationStrategyId strategyId,
) async {
  final environmentId = ProviderId('test.selection.environment');
  final channel = _EstablishmentOnlyChannel();
  final environment = runtime.registry.register(
    provider: ProviderDescriptor(
      id: environmentId,
      capability: environmentProviderCapability,
      pluginId: 'test.selection.environment',
      displayName: 'Establishment only',
      serviceId: environmentProviderServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: channel,
      serviceId: environmentProviderServiceId,
      isAvailable: () => true,
    ),
  );
  final strategy = runtime.extensions.register(
    point: orchestrationStrategyContributions,
    id: ExtensionId(strategyId.value),
    value: OrchestrationStrategyContribution(
      strategyId: strategyId,
      materialize: (_) =>
          throw StateError('A selection must not start execution.'),
    ),
  );
  try {
    final task = await runtime.lifecycle.createTask(
      projectId: project.id,
      title: 'Session selections',
      providerId: environmentId,
    );
    Session create() => runtime.lifecycle.createSession(
      taskId: task.task.id,
      strategyId: strategyId,
    );
    expect(channel.calls, 1);
    return (
      project: project,
      environment: task.environment,
      session: create(),
      otherSession: create(),
    );
  } finally {
    await environment.close();
    await strategy.close();
  }
}

final class _EstablishmentOnlyChannel implements AdeleRequestChannel {
  int calls = 0;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(
      method,
      environmentProviderServiceEstablishId,
      reason: 'A selection must not restore or execute in an Environment.',
    );
    calls++;
    return {'providerState': <String, Object?>{}, 'initialState': null};
  }
}
