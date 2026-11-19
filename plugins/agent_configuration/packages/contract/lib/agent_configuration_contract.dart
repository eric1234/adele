/// Global Agent definitions and Session selection data, independent of execution.
library;

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_settings/adele_settings.dart' as settings;

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

abstract final class AgentSelectionLimits {
  static const int maxSessionIdLength = 512;
  static const int maxRevision = 2147483647;
}

/// A stored preference only, not a Run binding or inference-context contribution.
@AdeleService('agentSelection')
abstract interface class AgentSelectionService {
  @AdeleMethod('readSessionSelection')
  Future<AgentSelectionSnapshot> readSessionSelection(String sessionId);

  /// Requires a previously read revision. Null explicitly clears the selection.
  /// An unacknowledged mutation must be reconciled by reading, never replayed.
  @AdeleMethod('updateSessionSelection')
  Future<AgentSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedAgentId,
    int expectedRevision,
  );
}

@AdeleValue('agentSelection.snapshot')
final class AgentSelectionSnapshot {
  AgentSelectionSnapshot({
    required this.sessionId,
    required this.selectedAgentId,
    required this.revision,
  }) {
    if (sessionId.isEmpty ||
        sessionId.trim() != sessionId ||
        sessionId.length > AgentSelectionLimits.maxSessionIdLength ||
        revision < 0 ||
        revision > AgentSelectionLimits.maxRevision ||
        (revision == 0 && selectedAgentId != null)) {
      throw const FormatException('Invalid Agent selection snapshot.');
    }
    if (selectedAgentId != null) {
      try {
        settings.ConfigurationRecordId(selectedAgentId!);
      } on FormatException {
        throw const FormatException('Invalid selected Agent record ID.');
      }
    }
  }

  final String sessionId;

  /// May reference a subsequently deleted definition; reads never resolve it.
  final String? selectedAgentId;

  /// Zero means no stored row. Clearing retains a positive revision.
  final int revision;
}

/// Definite prewrite failures: invalid_request, agent_not_found,
/// catalog_incomplete, catalog_unavailable, storage_unavailable, corrupt_state,
/// stale_revision, revision_exhausted. outcome_uncertain means an admitted write
/// was not acknowledged, not that it rolled back. Read before another change.
@AdeleFailure('agentSelection.failure')
final class AgentSelectionFailure implements Exception {
  const AgentSelectionFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'AgentSelectionFailure($code): $message';
}
