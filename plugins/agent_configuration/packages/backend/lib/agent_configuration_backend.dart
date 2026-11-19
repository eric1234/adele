import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';

export 'src/agent_selection_backend.dart';

/// Projects each current, host-authorized observation; retains no Agent data.
final class AgentCatalogBackend implements AgentCatalogService {
  const AgentCatalogBackend(this._configuration);

  final AdeleConfigurationClient _configuration;

  @override
  Future<AgentCatalogSnapshot> readAgents() async {
    final AdeleRecordObservation observation;
    try {
      observation = await _configuration.currentRecords();
    } on AdeleConfigurationFailure {
      throw const AgentCatalogFailure(
        code: 'unavailable',
        message: 'Agent configuration could not be read.',
      );
    }
    final agents = observation.records.map(_project).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return AgentCatalogSnapshot(
      agents: agents,
      isComplete: observation.isComplete,
    );
  }
}

const _invalidObservation = AgentCatalogFailure(
  code: 'invalid_observation',
  message: 'Unexpected Agent record in the configuration observation.',
);

AgentDefinition _project(Map<String, Object> record) {
  // The host owns identity, uniqueness and transport bounds. Fail closed if
  // the delivered scope or field schema disagrees with the declared Agent type.
  if (record['collection'] != 'agents' ||
      record['type'] != 'dev.adele.plugin.agent-configuration.agent') {
    throw _invalidObservation;
  }
  final values = record['values'] as Map<String, Object>;
  final name = values['name'];
  final instructions = values['instructions'];
  final description = values['description'];
  final whenToUse = values['when-to-use'];
  if (name is! String ||
      instructions is! String ||
      description is! String? ||
      whenToUse is! String? ||
      !const {
        'name',
        'instructions',
        'description',
        'when-to-use',
      }.containsAll(values.keys)) {
    throw _invalidObservation;
  }
  return AgentDefinition(
    id: record['id'] as String,
    name: name,
    instructions: instructions,
    description: description,
    whenToUse: whenToUse,
  );
}
