import 'dart:convert';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import 'evidence_tables.dart';
import 'evidence_validation.dart';

/// Trusted development diagnostic. SQL ownership knowledge is intentional;
/// connection ownership, authority, and lifetime stay with the storage host.
final class SessionEvidenceCollector implements SessionEvaluatorService {
  SessionEvidenceCollector(this.storage);

  final ProjectStorageService storage;

  @override
  Stream<String> collectSession(String sessionId) async* {
    if (sessionId.trim().isEmpty) {
      throw const SessionEvidenceFailure(
        code: 'invalid_session',
        message: 'An explicit nonblank canonical Session ID is required.',
      );
    }
    final collection = _Collection(storage, sessionId);
    final document = await collection.collect();
    final json = jsonEncode(document);
    if (utf8.encode(json).length > sessionEvidenceMaxBytes) {
      throw const SessionEvidenceFailure(
        code: 'collection_limit',
        message: 'The evidence document exceeds the supported byte bound.',
      );
    }
    // Emit nothing until collection and validation succeed. Transport remains
    // bounded even when the document is larger than one SQL response.
    for (var start = 0; start < json.length;) {
      var end = start + sessionEvidenceChunkCodeUnits;
      if (end > json.length) end = json.length;
      if (end < json.length &&
          json.codeUnitAt(end - 1) >= 0xd800 &&
          json.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      yield json.substring(start, end);
      start = end;
    }
  }
}

final class _Collection {
  _Collection(this.storage, this.sessionId);

  final ProjectStorageService storage;
  final String sessionId;
  var rowsRead = 0;
  var bytesRead = 0;

  Future<List<Map<String, Object?>>> query(
    String section,
    String sql, [
    Map<String, Object?> parameters = const {},
  ]) async {
    final List<RelationalRow> rows;
    try {
      rows = await storage.queryForSession(sessionId, sql, {
        ':session': sessionId,
        ...parameters,
      }, ProjectStorageAccessMode.durable);
    } catch (_) {
      // The host intentionally does not disclose unexpected SQLite exceptions
      // through generated transport. Do not guess whether this was a size,
      // schema, storage, or lifetime failure, and never turn it into empty data.
      throw SessionEvidenceFailure(
        code: 'storage_query_failed',
        message:
            'Could not read $section. Storage may be unavailable, incompatible, '
            'retired, or beyond the per-query row/byte limit.',
      );
    }
    rowsRead += rows.length;
    bytesRead += utf8
        .encode(jsonEncode(rows.map((r) => r.values).toList()))
        .length;
    if (rowsRead > sessionEvidenceMaxRows ||
        bytesRead > sessionEvidenceMaxBytes) {
      throw const SessionEvidenceFailure(
        code: 'collection_limit',
        message: 'Collection exceeds the supported total row/byte bound.',
      );
    }
    return [for (final row in rows) Map.of(row.values)];
  }

  String get sessionExists =>
      'EXISTS (SELECT 1 FROM adele_product_sessions WHERE id = :session)';

  Future<bool> hasTable(String table) async {
    final rows = await query(
      'schema $table',
      'SELECT name FROM sqlite_master WHERE type = :type AND name = :table '
          'AND $sessionExists ORDER BY name LIMIT 2',
      {':type': 'table', ':table': table},
    );
    evidenceRequire(rows.length <= 1, 'Duplicate table $table.');
    return rows.isNotEmpty;
  }

  Future<void> checkTable(EvidenceTable table) async {
    if (!await hasTable(table.name)) {
      incompatible('Missing expected table ${table.name}.');
    }
    final columns = await query(
      'columns ${table.name}',
      'SELECT name FROM pragma_table_info(:table) WHERE $sessionExists '
          'ORDER BY cid LIMIT 128',
      {':table': table.name},
    );
    final names = columns.map((row) => row['name']).toSet();
    if (columns.length == 128 ||
        !names.containsAll([...table.columns, ...table.excluded])) {
      incompatible('Incompatible columns in ${table.name}.');
    }
  }

  Future<int?> ownerVersion(String owner) async {
    final rows = await query(
      'schema version $owner',
      'SELECT version FROM adele_schema_versions WHERE owner_id = :owner '
          'AND $sessionExists ORDER BY owner_id LIMIT 2',
      {':owner': owner},
    );
    if (rows.length > 1 ||
        (rows.isNotEmpty && rows.single['version'] is! int)) {
      incompatible('Malformed schema version for $owner.');
    }
    return rows.isEmpty ? null : rows.single['version'] as int;
  }

  Never incompatible(String message) => throw SessionEvidenceFailure(
    code: 'incompatible_schema',
    message: message,
  );

  Future<List<Map<String, Object?>>> readTable(
    EvidenceTable table, {
    String? runId,
  }) async {
    final scope =
        'FROM ${table.name} e '
        '${runId == null ? '' : 'JOIN adele_product_runs r ON r.id = e.run_id '} '
        'WHERE ${runId == null ? 'e.session_id' : 'r.session_id'} = :session '
        '${runId == null ? '' : 'AND e.run_id = :run '}';
    final count = await query(
      '${table.name} extent',
      'SELECT COUNT(*) AS row_count $scope LIMIT 1',
      {':run': ?runId},
    );
    evidenceRequire(
      count.length == 1 &&
          count.single['row_count'] is int &&
          (count.single['row_count'] as int) >= 0,
      'Invalid table extent.',
    );
    final expected = count.single['row_count'] as int;
    if (expected > sessionEvidenceMaxRows - rowsRead) {
      throw const SessionEvidenceFailure(
        code: 'collection_limit',
        message: 'Retained table exceeds the supported collection row bound.',
      );
    }
    final result = <Map<String, Object?>>[];
    Object? after;
    while (true) {
      final rows = await query(
        table.name,
        'SELECT ${table.columns.map((c) => 'e.$c').join(', ')} '
        '$scope '
        'AND (:after IS NULL OR e.${table.key} > :after) '
        'ORDER BY e.${table.key} LIMIT 1',
        {':after': after, ':run': ?runId},
      );
      evidenceRequire(rows.length <= 1, 'Query page exceeded its row bound.');
      if (rows.isEmpty) break;
      final row = rows.single;
      validateEvidenceRow(table, row);
      evidenceRequire(
        runId == null ? row['session_id'] == sessionId : row['run_id'] == runId,
        'Evidence escaped the requested Session/Run.',
      );
      final key = row[table.key]!;
      evidenceRequire(
        after == null ||
            (key is int && after is int && key > after) ||
            // SQLite's text collation, not Dart's UTF-16 comparison, orders IDs.
            (key is String && after is String && key != after),
        'Nonadvancing evidence cursor.',
      );
      result.add(row);
      after = key;
    }
    evidenceRequire(
      result.length == expected,
      'Evidence extent changed during collection or contains duplicate cursor keys.',
    );
    return result;
  }

  Future<Map<String, Object?>> collect() async {
    final identityRows = await query('Session identity', '''
SELECT s.id AS session_id, s.strategy_id, s.task_id,
 t.project_id, t.title AS task_title, p.source_location,
 a.environment_id, e.task_id AS environment_task_id,
 e.role AS environment_role, e.provider_id AS environment_provider_id
FROM adele_product_sessions s
LEFT JOIN adele_product_tasks t ON t.id = s.task_id
LEFT JOIN adele_product_projects p ON p.id = t.project_id
LEFT JOIN adele_product_session_environment_authority a ON a.session_id = s.id
LEFT JOIN adele_product_environments e ON e.id = a.environment_id
WHERE s.id = :session ORDER BY a.environment_id LIMIT 2
''');
    evidenceRequire(
      identityRows.length == 1,
      'Missing or ambiguous Session graph.',
    );
    final identity = identityRows.single;
    for (final key in identity.keys) {
      evidenceRequire(
        identity[key] is String && (identity[key] as String).trim().isNotEmpty,
        'Missing or malformed identity field $key.',
      );
    }
    evidenceRequire(
      identity['session_id'] == sessionId &&
          identity['task_id'] == identity['environment_task_id'] &&
          (Uri.tryParse(identity['source_location'] as String)?.hasScheme ??
              false) &&
          const [
            'primary',
            'additional',
          ].contains(identity['environment_role']),
      'Inconsistent Session Environment association.',
    );
    for (final owner in ['dev.adele.product', 'dev.adele.execution']) {
      if (await ownerVersion(owner) != 1) {
        incompatible('Expected current version 1 for $owner.');
      }
    }
    await checkTable(productRuns);
    for (final table in executionTables.values) {
      await checkTable(table);
    }

    final conversation = <String, Object?>{
      'status': 'unsupported_strategy',
      'configuration': null,
      'entries': <Map<String, Object?>>[],
    };
    if (identity['strategy_id'] == 'dev.adele.strategy.chat') {
      final version = await ownerVersion('dev.adele.plugin.chat-strategy');
      final hasSessions = await hasTable(chatSessions.name);
      final hasEntries = await hasTable(chatEntries.name);
      if (version == null && !hasSessions && !hasEntries) {
        conversation['status'] = 'unavailable';
      } else {
        if (version != 1 || !hasSessions || !hasEntries) {
          incompatible('Missing or incompatible Chat schema/version.');
        }
        await checkTable(chatSessions);
        await checkTable(chatEntries);
        final configuration = await readTable(chatSessions);
        evidenceRequire(configuration.length <= 1, 'Duplicate Chat Session.');
        conversation['status'] = configuration.isEmpty
            ? 'uninitialized'
            : 'available';
        if (configuration.isNotEmpty) {
          final config = configuration.single;
          conversation['configuration'] = Map<String, Object?>.of(config)
            ..remove('session_id');
          conversation['entries'] = await readTable(chatEntries);
        } else {
          evidenceRequire(
            (await readTable(chatEntries)).isEmpty,
            'Chat entries without Chat Session state.',
          );
        }
      }
    }
    validateConversation(conversation);

    final runs = await readTable(productRuns);
    for (final run in runs) {
      final evidence = <String, Object?>{};
      for (final entry in executionTables.entries) {
        final rows = await readTable(entry.value, runId: run['id'] as String);
        if (entry.key == 'root') {
          evidenceRequire(
            rows.length == 1,
            'Terminal Run lacks an evidence root.',
          );
          evidence[entry.key] = rows.single;
        } else {
          evidence[entry.key] = rows;
        }
      }
      run['evidence'] = evidence;
      validateRunEvidence(run);
    }

    final retained = {for (final run in runs) run['id']};
    final missing = <String>[];
    for (final entry in conversation['entries'] as List<Map<String, Object?>>) {
      final runId = entry['run_id'];
      if (runId is! String || retained.contains(runId)) continue;
      // Only a boolean ownership check is read, never another Session's record.
      final foreign = await query(
        'Chat Run association',
        'SELECT EXISTS (SELECT 1 FROM adele_product_runs '
            'WHERE id = :run AND session_id <> :session) AS foreign_run '
            'WHERE $sessionExists LIMIT 1',
        {':run': runId},
      );
      evidenceRequire(
        foreign.length == 1 && foreign.single['foreign_run'] == 0,
        'Chat Run association belongs to another Session.',
      );
      missing.add(runId);
    }
    return {
      'schema': sessionEvidenceSchema,
      'identity': identity,
      'conversation': conversation,
      'runs': runs,
      'coverage': {
        'status': conversation['status'] == 'available' && missing.isEmpty
            ? 'complete_retained_evidence'
            : 'partial',
        'consistency': 'independent_reads_not_atomic_snapshot',
        'run_order': 'lexical_id_not_chronology',
        'associated_runs_without_terminal_evidence': missing,
        'exclusions': [
          'unsent_chat_draft',
          'environment_provider_state',
          'provider_native_opaque_compatibility_and_data',
          'full_command_stdout_stderr_transcripts',
          'git_and_task_worktree_contents',
          'live_or_waiting_run_observation',
        ],
        'limitations': [
          'Only selected current version-1 SQL schemas are understood.',
          'Reads are independent; concurrent changes can prevent a coherent collection.',
          'Chat entries must agree with the independently observed next_entry counter.',
          'Run IDs and list order establish no cross-Run chronology.',
          'Missing terminal evidence does not establish an active Run state.',
          'Unassociated orphan execution rows cannot be attributed to this Session.',
          'Current Chat configuration is not historical per-Run configuration.',
          'JSON-text columns preserve their source encoding; null usage is unreported.',
        ],
      },
    };
  }
}
