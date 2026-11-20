import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';

/// The host retains the Agent ID for the Run, never the definition or its text.
final class AgentInferenceContextBackend
    implements RemoteRunBoundInferenceContextSourceService {
  const AgentInferenceContextBackend(this._selection, this._catalog);

  final AgentSelectionService _selection;
  final AgentCatalogService _catalog;

  @override
  Future<String?> captureRun(String sessionId, String runId) async {
    try {
      return (await _selection.readSessionSelection(sessionId)).selectedAgentId;
    } on Object {
      throw StateError('Agent selection could not be read.');
    }
  }

  @override
  Future<List<RemoteInferenceInstruction>> snapshot(
    String sessionId,
    String runId,
    String? binding,
  ) async {
    if (binding == null) return const [];
    final AgentCatalogSnapshot catalog;
    try {
      catalog = await _catalog.readAgents();
    } on Object {
      throw StateError('Agent configuration could not be read.');
    }
    for (final agent in catalog.agents) {
      if (agent.id != binding) continue;
      if (agent.instructions.trim().isEmpty) return const [];
      return [
        RemoteInferenceInstruction(
          key: 'instructions',
          text: agent.instructions,
          revision: null,
        ),
      ];
    }
    throw StateError(
      catalog.isComplete
          ? 'The captured Agent does not exist.'
          : 'The captured Agent was not observed in the incomplete catalog.',
    );
  }
}
