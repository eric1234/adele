import 'dart:async';
import 'dart:convert';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:sqlite3/sqlite3.dart';

/// Real relational semantics behind the public boundary, not an app database.
final class ChatTestStorage implements ProjectStorageService {
  ChatTestStorage({this.durable = true}) {
    database.execute('PRAGMA foreign_keys = ON');
    database.execute(
      'CREATE TABLE adele_product_sessions (id TEXT PRIMARY KEY)',
    );
    for (final id in ['session', 'other']) {
      database.execute('INSERT INTO adele_product_sessions VALUES (?)', [id]);
    }
  }

  final Database database = sqlite3.openInMemory();
  final bool durable;
  int durabilityChecks = 0;
  int schemaChecks = 0;
  int transactions = 0;
  int queries = 0;
  final List<String> querySql = [];
  bool _schemaReady = false;
  Object? failure;
  Future<void> Function()? beforeDurability;
  Future<void> Function()? beforeTransaction;

  void _check(String sessionId) {
    if (failure case final error?) throw error;
    if (database.select('SELECT id FROM adele_product_sessions WHERE id = ?', [
      sessionId,
    ]).isEmpty) {
      throw StateError('Unknown canonical Session.');
    }
  }

  @override
  Future<bool> isDurableSession(String sessionId) async {
    durabilityChecks++;
    await beforeDurability?.call();
    _check(sessionId);
    return durable;
  }

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
  ) async {
    schemaChecks++;
    _check(sessionId);
    if (_schemaReady) return;
    if (migrations.length != 1) throw StateError('Expected v1 baseline.');
    database.execute(migrations.single);
    _schemaReady = true;
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
  ) async {
    queries++;
    querySql.add(sql);
    _check(sessionId);
    validateRelationalParameters(parameters.values);
    final statement = database.prepare(sql);
    try {
      final rows = statement.selectWith(StatementParameters.named(parameters));
      final result = [
        for (final row in rows)
          RelationalRow(values: Map<String, Object?>.from(row)),
      ];
      var bytes = 2;
      for (final row in result) {
        bytes += utf8.encode(jsonEncode({'values': row.values})).length + 1;
      }
      if (result.length > relationalQueryRowLimit ||
          bytes > relationalQueryByteLimit) {
        throw StateError('Relational query response exceeds its bound.');
      }
      return result;
    } finally {
      statement.close();
    }
  }

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
  ) async {
    transactions++;
    await beforeTransaction?.call();
    _check(sessionId);
    database.execute('BEGIN');
    try {
      for (final value in statements) {
        final statement = database.prepare(value.sql);
        try {
          statement.executeWith(StatementParameters.named(value.parameters));
          if (value.expectedRows != null &&
              database.updatedRows != value.expectedRows) {
            throw StateError('Stale Chat state: expectedRows mismatch.');
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
  }

  void close() => database.close();
}
