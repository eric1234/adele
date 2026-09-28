import 'dart:async';
import 'dart:convert';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:sqlite3/sqlite3.dart';

/// Injected public storage boundary with real SQLite transactions and core IDs.
final class CommandTestStorage implements ProjectStorageService {
  CommandTestStorage() {
    database.execute('PRAGMA foreign_keys = ON');
    database.execute(
      'CREATE TABLE adele_product_sessions (id TEXT PRIMARY KEY)',
    );
    for (final id in ['session', 'other', 'session-command', 'session-data']) {
      database.execute('INSERT INTO adele_product_sessions VALUES (?)', [id]);
    }
  }

  final Database database = sqlite3.openInMemory();
  bool _schemaReady = false;
  int schemaChecks = 0;
  int queries = 0;
  int transactions = 0;
  int commits = 0;
  int rollbacks = 0;
  final transactionKinds = <String>[];
  FutureOr<void> Function()? beforeSchema;
  FutureOr<void> Function(List<RelationalStatement>)? beforeTransaction;
  FutureOr<void> Function(List<RelationalStatement>)? afterCommit;
  FutureOr<void> Function(String, List<RelationalRow>)? afterQuery;

  void _check(String sessionId, ProjectStorageAccessMode mode) {
    if (mode != ProjectStorageAccessMode.durableOrTemporary) {
      throw StateError('Capture must explicitly allow temporary storage.');
    }
    if (database.select('SELECT id FROM adele_product_sessions WHERE id=?', [
      sessionId,
    ]).isEmpty) {
      throw StateError('Unknown canonical Session.');
    }
  }

  @override
  Future<bool> isDurableSession(String sessionId) =>
      throw StateError('Capture must not branch into a memory fallback.');

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async {
    schemaChecks++;
    _check(sessionId, accessMode);
    await beforeSchema?.call();
    if (_schemaReady) return;
    database.execute(migrations.single);
    _schemaReady = true;
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    queries++;
    _check(sessionId, accessMode);
    validateRelationalParameters(parameters.values);
    final statement = database.prepare(sql);
    final List<RelationalRow> result;
    try {
      result = [
        for (final row in statement.selectWith(
          StatementParameters.named(parameters),
        ))
          RelationalRow(values: Map<String, Object?>.from(row)),
      ];
    } finally {
      statement.close();
    }
    if (result.length > relationalQueryRowLimit ||
        utf8
                .encode(
                  jsonEncode(
                    result.map((row) => {'values': row.values}).toList(),
                  ),
                )
                .length >
            relationalQueryByteLimit) {
      throw StateError('Relational query exceeded host bounds.');
    }
    await afterQuery?.call(sql, result);
    return result;
  }

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) async {
    transactions++;
    transactionKinds.add(kindOf(statements));
    _check(sessionId, accessMode);
    await beforeTransaction?.call(statements);
    database.execute('BEGIN');
    try {
      for (final value in statements) {
        final statement = database.prepare(value.sql);
        try {
          statement.executeWith(StatementParameters.named(value.parameters));
          if (value.expectedRows != null &&
              database.updatedRows != value.expectedRows) {
            throw StateError('expectedRows mismatch');
          }
        } finally {
          statement.close();
        }
      }
      database.execute('COMMIT');
      commits++;
    } on Object {
      database.execute('ROLLBACK');
      rollbacks++;
      rethrow;
    }
    // Deliberately outside rollback: a transport can lose a committed ack.
    await afterCommit?.call(statements);
  }

  static String kindOf(List<RelationalStatement> statements) {
    final sql = statements.first.sql;
    if (sql.startsWith('INSERT INTO adele_command_captures')) return 'setup';
    if (sql.contains('SET high_water=')) return 'append';
    if (sql.contains('SET state=')) {
      return statements.first.parameters[':state']! as String;
    }
    return 'other';
  }

  void close() => database.close();
}
