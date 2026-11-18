/// Read-only access to Agent definitions, independent of selection or execution.
library;

import 'package:adele_contract/adele_contract.dart';

part 'agent_configuration_contract.g.dart';

@AdeleService('agentCatalog')
abstract interface class AgentCatalogService {
  /// Reads a fresh observation. Failure to read is not an empty observation.
  @AdeleMethod('readAgents')
  Future<AgentCatalogSnapshot> readAgents();
}

@AdeleValue('agentCatalog.snapshot')
final class AgentCatalogSnapshot {
  AgentCatalogSnapshot({
    required List<AgentDefinition> agents,
    required this.isComplete,
  }) : agents = List<AgentDefinition>.unmodifiable(agents);

  /// Current definitions in stable record ID order.
  final List<AgentDefinition> agents;

  /// False when the host omitted invalid records, even if [agents] is empty.
  final bool isComplete;
}

@AdeleValue('agentCatalog.definition')
final class AgentDefinition {
  const AgentDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.whenToUse,
    required this.instructions,
  });

  /// Stable record identity, independent of the mutable display name.
  final String id;
  final String name;
  final String? description;
  final String? whenToUse;
  final String instructions;
}

/// `unavailable` means configuration could not be read. `invalid_observation`
/// means the records did not match the expected Agent projection. Neither
/// carries record contents, host diagnostics, or other failure details.
@AdeleFailure('agentCatalog.failure')
final class AgentCatalogFailure implements Exception {
  const AgentCatalogFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'AgentCatalogFailure($code): $message';
}
