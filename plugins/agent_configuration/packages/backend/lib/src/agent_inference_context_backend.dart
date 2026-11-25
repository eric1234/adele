import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';

/// Returns only the selected Agent's instructions; the host owns the Run capture.
final class AgentInferenceContextBackend
    implements RemoteRunBoundInferenceContextSourceService {
  const AgentInferenceContextBackend(this._selection, this._catalog);

  final AgentSelectionService _selection;
  final AgentCatalogService _catalog;

  @override
  Future<List<RemoteInferenceInstruction>> captureRun(
    String sessionId,
    String runId,
  ) async {
    final String? selectedId;
    try {
      final selection = await _selection.readSessionSelection(sessionId);
      selectedId = selection.selectedAgentId;
    } on Object {
      throw StateError('Agent selection could not be read.');
    }
    if (selectedId == null) return const [];

    final AgentCatalogSnapshot catalog;
    try {
      catalog = await _catalog.readAgents();
    } on Object {
      throw StateError('Agent configuration could not be read.');
    }
    for (final agent in catalog.agents) {
      if (agent.id != selectedId) continue;
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
          ? 'The selected Agent does not exist.'
          : 'The selected Agent was not observed in the incomplete catalog.',
    );
  }
}
