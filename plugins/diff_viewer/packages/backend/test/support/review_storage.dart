import 'dart:convert';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:sqlite3/sqlite3.dart';

/// Real SQLite behind the public storage boundary; no application implementation.
final class ReviewTestStorage implements ProjectStorageService {
  ReviewTestStorage({String? path, this.durable = true})
    : database = path == null ? sqlite3.openInMemory() : sqlite3.open(path) {
    database.execute('PRAGMA foreign_keys = ON');
    database.execute('''
CREATE TABLE IF NOT EXISTS adele_product_sessions (id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS test_owner_schema (version INTEGER NOT NULL);
''');
    if (database.select('SELECT * FROM test_owner_schema').isEmpty) {
      database.execute('INSERT INTO test_owner_schema VALUES (0)');
    }
    for (final id in ['session', 'other']) {
      database.execute(
        'INSERT OR IGNORE INTO adele_product_sessions VALUES (?)',
        [id],
      );
    }
  }

  final Database database;
  final bool durable;
  int durabilityChecks = 0;
  int schemaChecks = 0;
  int transactions = 0;
  int queries = 0;
  int maximumQueryBytes = 0;
  final modes = <ProjectStorageAccessMode>[];
  final querySql = <String>[];
  Object? failure;
  Future<void> Function()? beforeSchema;
  Future<void> Function()? beforeQuery;
  Future<void> Function()? beforeTransaction;
  Future<void> Function()? afterCommit;
  bool _closed = false;

  void _check(String sessionId, ProjectStorageAccessMode mode) {
    modes.add(mode);
    if (_closed) throw StateError('Storage closed.');
    if (failure case final error?) throw error;
    if (!durable && mode == ProjectStorageAccessMode.durable) {
      throw StateError('Durable-only access rejected.');
    }
    if (database.select('SELECT id FROM adele_product_sessions WHERE id=?', [
      sessionId,
    ]).isEmpty) {
      throw StateError('Unknown canonical Session.');
    }
  }

  @override
  Future<bool> isDurableSession(String sessionId) async {
    durabilityChecks++;
    _check(sessionId, ProjectStorageAccessMode.durableOrTemporary);
    return durable;
  }

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async {
    schemaChecks++;
    await beforeSchema?.call();
    _check(sessionId, accessMode);
    if (migrations.any(
      (sql) => sql
          .split(';')
          .where((part) => part.trim().isNotEmpty)
          .any(
            (part) => !RegExp(
              r'^CREATE\s+TABLE\b',
              caseSensitive: false,
            ).hasMatch(part.trim()),
          ),
    )) {
      throw StateError('Host migrations permit only CREATE TABLE statements.');
    }
    final version =
        database
                .select('SELECT version FROM test_owner_schema')
                .single['version']
            as int;
    if (version > migrations.length) throw StateError('Newer owner schema.');
    if (version == migrations.length) return;
    database.execute('BEGIN');
    try {
      for (var index = version; index < migrations.length; index++) {
        database.execute(migrations[index]);
      }
      database.execute('UPDATE test_owner_schema SET version=?', [
        migrations.length,
      ]);
      database.execute('COMMIT');
    } on Object {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    queries++;
    querySql.add(sql);
    await beforeQuery?.call();
    _check(sessionId, accessMode);
    validateRelationalParameters(parameters.values);
    final statement = database.prepare(sql);
    try {
      if (!statement.isReadOnly) throw StateError('Query must be read-only.');
      final rows = [
        for (final row in statement.selectWith(
          StatementParameters.named(parameters),
        ))
          RelationalRow(values: Map<String, Object?>.from(row)),
      ];
      final bytes = utf8
          .encode(
            jsonEncode([
              for (final row in rows) {'values': row.values},
            ]),
          )
          .length;
      if (bytes > maximumQueryBytes) maximumQueryBytes = bytes;
      if (rows.length > relationalQueryRowLimit ||
          bytes > relationalQueryByteLimit) {
        throw StateError('Relational response exceeds host bounds.');
      }
      return rows;
    } finally {
      statement.close();
    }
  }

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) async {
    transactions++;
    await beforeTransaction?.call();
    _check(sessionId, accessMode);
    database.execute('BEGIN');
    try {
      for (final operation in statements) {
        validateRelationalParameters(operation.parameters.values);
        final statement = database.prepare(operation.sql);
        try {
          statement.executeWith(
            StatementParameters.named(operation.parameters),
          );
          if (operation.expectedRows != null &&
              database.updatedRows != operation.expectedRows) {
            throw StateError('expectedRows mismatch.');
          }
        } finally {
          statement.close();
        }
      }
      database.execute('COMMIT');
    } on Object {
      database.execute('ROLLBACK');
      rethrow;
    }
    // Deliberately outside rollback handling: SQL really committed before this
    // transport test hook withholds or loses its acknowledgement.
    await afterCommit?.call();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    database.close();
  }

  @override
  Future<void> ensureSchemaForEnvironment(
    String environmentId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) => throw UnsupportedError('Review drafts are Session-addressed.');

  @override
  Future<List<RelationalRow>> queryForEnvironment(
    String environmentId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) => throw UnsupportedError('Review drafts are Session-addressed.');

  @override
  Future<void> transactionForEnvironment(
    String environmentId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) => throw UnsupportedError('Review drafts are Session-addressed.');
}
