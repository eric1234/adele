import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';

/// Project storage is authoritative; no selection or schema cache is retained.
final class AgentSelectionBackend implements AgentSelectionService {
  const AgentSelectionBackend(this._storage, this._catalog);

  final ProjectStorageService _storage;
  final AgentCatalogService _catalog;

  static const _access = ProjectStorageAccessMode.durableOrTemporary;
  static const _schema =
      '''
CREATE TABLE adele_agent_selections (
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES adele_product_sessions(id),
  selected_agent_id TEXT CHECK (
    selected_agent_id IS NULL OR typeof(selected_agent_id) = 'text'),
  revision INTEGER NOT NULL CHECK (
    typeof(revision) = 'integer' AND
    revision BETWEEN 1 AND ${AgentSelectionLimits.maxRevision})
);
''';

  @override
  Future<AgentSelectionSnapshot> readSessionSelection(String sessionId) async {
    final AgentSelectionSnapshot empty;
    try {
      empty = AgentSelectionSnapshot(
        sessionId: sessionId,
        selectedAgentId: null,
        revision: 0,
      );
    } on FormatException {
      throw _failure('invalid_request', 'Invalid Session identity.');
    }
    final List<RelationalRow> rows;
    try {
      await _storage.ensureSchemaForSession(sessionId, [_schema], _access);
      rows = await _storage.queryForSession(
        sessionId,
        '''SELECT session_id, selected_agent_id, revision
           FROM adele_agent_selections WHERE session_id = :session LIMIT 2''',
        {':session': sessionId},
        _access,
      );
    } on Object {
      throw _failure(
        'storage_unavailable',
        'Agent selection storage is unavailable.',
      );
    }
    if (rows.isEmpty) return empty;
    try {
      final row = rows.single.values;
      if (row.length != 3 ||
          !row.containsKey('selected_agent_id') ||
          row['session_id'] != sessionId ||
          row['revision'] is! int ||
          (row['revision']! as int) < 1) {
        throw const FormatException('Invalid stored selection.');
      }
      return AgentSelectionSnapshot(
        sessionId: sessionId,
        selectedAgentId: row['selected_agent_id'] as String?,
        revision: row['revision']! as int,
      );
    } on Object {
      throw _failure('corrupt_state', 'Stored Agent selection is invalid.');
    }
  }

  @override
  Future<AgentSelectionSnapshot> updateSessionSelection(
    String sessionId,
    String? selectedAgentId,
    int expectedRevision,
  ) async {
    final AgentSelectionSnapshot next;
    try {
      if (expectedRevision < 0 ||
          expectedRevision > AgentSelectionLimits.maxRevision) {
        throw const FormatException('Invalid expected revision.');
      }
      next = AgentSelectionSnapshot(
        sessionId: sessionId,
        selectedAgentId: selectedAgentId,
        revision: expectedRevision == AgentSelectionLimits.maxRevision
            ? expectedRevision
            : expectedRevision + 1,
      );
    } on FormatException {
      throw _failure('invalid_request', 'Invalid Agent selection request.');
    }
    final current = await readSessionSelection(sessionId);
    if (current.revision != expectedRevision) {
      throw _failure(
        'stale_revision',
        'Agent selection changed. Read it again.',
      );
    }
    if (expectedRevision == AgentSelectionLimits.maxRevision) {
      throw _failure(
        'revision_exhausted',
        'Agent selection revision limit reached.',
      );
    }
    if (selectedAgentId != null) {
      final AgentCatalogSnapshot catalog;
      try {
        catalog = await _catalog.readAgents();
      } on Object {
        throw _failure(
          'catalog_unavailable',
          'Agent configuration could not be read.',
        );
      }
      if (!catalog.agents.any((agent) => agent.id == selectedAgentId)) {
        throw catalog.isComplete
            ? _failure('agent_not_found', 'The requested Agent does not exist.')
            : _failure(
                'catalog_incomplete',
                'The Agent catalog observation is incomplete.',
              );
      }
    }
    final change = RelationalStatement(
      sql: expectedRevision == 0
          ? '''INSERT INTO adele_agent_selections
               (session_id, selected_agent_id, revision)
               VALUES (:session, :agent, :next)'''
          : '''UPDATE adele_agent_selections
               SET selected_agent_id = :agent, revision = :next
               WHERE session_id = :session AND revision = :expected''',
      parameters: {
        ':session': sessionId,
        ':agent': selectedAgentId,
        ':next': next.revision,
        if (expectedRevision != 0) ':expected': expectedRevision,
      },
      expectedRows: 1,
    );
    try {
      await _storage.transactionForSession(sessionId, [change], _access);
    } on Object {
      // Even a CAS loser is unconfirmed across this void transaction transport.
      // Never parse host errors, retry, or mistake a later read for this ack.
      throw _failure(
        'outcome_uncertain',
        'The selection write was not acknowledged. Read it before another change.',
      );
    }
    return next;
  }
}

AgentSelectionFailure _failure(String code, String message) =>
    AgentSelectionFailure(code: code, message: message);
