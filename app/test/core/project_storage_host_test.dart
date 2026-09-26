import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

final _projectProvider = ProviderId('dev.adele.test.project');
final _environmentProvider = ProviderId('dev.adele.test.environment');
final _strategy = OrchestrationStrategyId('dev.adele.test.strategy');
const _baseline = 'CREATE TABLE fixture_entries (value TEXT, number INTEGER)';

void main() {
  late Directory temporary;
  late AdeleRuntime runtime;
  late Session session;
  late ProjectStorageHost storage;
  late bool live;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('adele-storage-host-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = AdeleRuntime();
    addTearDown(runtime.close);
    for (final descriptor in [
      ProviderDescriptor(
        id: _projectProvider,
        capability: projectProviderCapability,
        pluginId: 'dev.adele.test.provider',
        displayName: 'Project',
        serviceId: projectProviderServiceId,
      ),
      ProviderDescriptor(
        id: _environmentProvider,
        capability: environmentProviderCapability,
        pluginId: 'dev.adele.test.provider',
        displayName: 'Environment',
        serviceId: environmentProviderServiceId,
      ),
    ]) {
      final registration = runtime.registry.register(
        provider: descriptor,
        endpoint: AdeleRequestChannelEndpoint(
          channel: _ProviderChannel(),
          serviceId: descriptor.serviceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(registration.close);
    }
    final registration = runtime.extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId('dev.adele.test.strategy'),
      value: OrchestrationStrategyContribution(
        strategyId: _strategy,
        materialize: (_) =>
            throw StateError('Storage must not materialize a strategy.'),
      ),
    );
    addTearDown(registration.close);
    session = await _createSession(runtime, temporary);
    live = true;
    storage = ProjectStorageHost(
      lifecycle: runtime.lifecycle,
      owner: PluginId('dev.adele.test.storage'),
      validateAccess: () {
        if (!live) throw StateError('Retired generation');
      },
    );
  });

  Database inspect() {
    final database = sqlite3.open('${temporary.path}/.adele/data.db');
    addTearDown(database.close);
    return database;
  }

  test(
    'one owner baseline, named scalar query, and atomic mutation batch',
    () async {
      expect(await storage.isDurableSession(session.id.value), isTrue);
      await storage.ensureSchemaForSession(session.id.value, [_baseline]);
      await storage.ensureSchemaForSession(session.id.value, [_baseline]);
      await storage.transactionForSession(session.id.value, [
        RelationalStatement(
          sql: 'INSERT INTO fixture_entries VALUES (:value, :number)',
          parameters: {':value': 'retained', ':number': 4},
          expectedRows: 1,
        ),
        RelationalStatement(
          sql: 'INSERT INTO fixture_entries VALUES (:value, :number)',
          parameters: {':value': null, ':number': 5},
          expectedRows: 1,
        ),
      ]);
      final rows = await storage.queryForSession(
        session.id.value,
        'SELECT value, number FROM fixture_entries ORDER BY number',
        {},
      );
      expect(rows.map((row) => row.values), [
        {'value': 'retained', 'number': 4},
        {'value': null, 'number': 5},
      ]);
      expect(
        inspect().select(
          'SELECT * FROM adele_schema_versions ORDER BY owner_id',
        ),
        [
          {'owner_id': 'dev.adele.product', 'version': 1},
          {'owner_id': 'dev.adele.test.storage', 'version': 1},
        ],
      );
      await expectLater(
        storage.transactionForSession(session.id.value, [
          RelationalStatement(
            sql: "INSERT INTO fixture_entries VALUES ('rollback', 6)",
            parameters: {},
            expectedRows: 1,
          ),
          RelationalStatement(
            sql:
                "UPDATE fixture_entries SET value = 'no row' WHERE number = 99",
            parameters: {},
            expectedRows: 1,
          ),
        ]),
        throwsStateError,
      );
      expect(inspect().select('SELECT * FROM fixture_entries'), hasLength(2));
    },
  );

  test(
    'failed schema initialization leaves neither tables nor owner metadata',
    () async {
      final database = inspect();
      await expectLater(
        storage.ensureSchemaForSession(session.id.value, [
          'CREATE TABLE rollback_table (id TEXT); CREATE TABLE incomplete (',
        ]),
        throwsA(isA<SqliteException>()),
      );
      expect(
        database.select(
          "SELECT name FROM sqlite_master WHERE name = 'rollback_table'",
        ),
        isEmpty,
      );
      expect(database.select('SELECT * FROM adele_schema_versions'), [
        {'owner_id': 'dev.adele.product', 'version': 1},
      ]);
      await storage.ensureSchemaForSession(session.id.value, [_baseline]);
      final other = ProjectStorageHost(
        lifecycle: runtime.lifecycle,
        owner: PluginId('dev.adele.test.other-storage'),
        validateAccess: () {},
      );
      await other.ensureSchemaForSession(session.id.value, [
        'CREATE TABLE other_entries (id TEXT)',
      ]);
      expect(
        database.select('SELECT * FROM adele_schema_versions'),
        hasLength(3),
      );
    },
  );

  test(
    'Session scope selects its own currently open Project database',
    () async {
      await storage.ensureSchemaForSession(session.id.value, [_baseline]);
      final otherDirectory = Directory('${temporary.path}/other')..createSync();
      final other = await _createSession(runtime, otherDirectory);
      await expectLater(
        storage.queryForSession(
          other.id.value,
          'SELECT * FROM fixture_entries',
          {},
        ),
        throwsA(isA<SqliteException>()),
      );
      await storage.ensureSchemaForSession(other.id.value, [_baseline]);
      await storage.transactionForSession(other.id.value, [
        RelationalStatement(
          sql: "INSERT INTO fixture_entries VALUES ('other', 1)",
          parameters: {},
          expectedRows: 1,
        ),
      ]);
      expect(
        await storage.queryForSession(
          session.id.value,
          'SELECT * FROM fixture_entries',
          {},
        ),
        isEmpty,
      );
      expect(
        (await storage.queryForSession(
          other.id.value,
          'SELECT * FROM fixture_entries',
          {},
        )).single.values['value'],
        'other',
      );
      await expectLater(storage.isDurableSession('absent'), throwsStateError);
      await expectLater(
        storage.isDurableSession(' invalid'),
        throwsFormatException,
      );
      await runtime.close();
      await expectLater(
        storage.isDurableSession(session.id.value),
        throwsStateError,
      );
    },
  );

  test(
    'explicit volatile Sessions are not missing or failed durable storage',
    () async {
      final volatile = await _createSession(runtime, temporary, volatile: true);
      expect(await storage.isDurableSession(volatile.id.value), isFalse);
      await expectLater(
        storage.ensureSchemaForSession(volatile.id.value, [_baseline]),
        throwsStateError,
      );
      await expectLater(
        storage.queryForSession(volatile.id.value, 'SELECT 1', {}),
        throwsStateError,
      );
      await expectLater(
        storage.transactionForSession(volatile.id.value, []),
        throwsStateError,
      );
      expect(
        inspect().select('SELECT * FROM adele_product_sessions'),
        hasLength(1),
      );
    },
  );

  test(
    'SELECT and DML classes tolerate whitespace and case, not other forms',
    () async {
      await storage.ensureSchemaForSession(session.id.value, [_baseline]);
      await storage.transactionForSession(session.id.value, [
        RelationalStatement(
          sql: " \n\t iNsErT INTO fixture_entries VALUES ('original', 1)",
          parameters: {},
          expectedRows: 1,
        ),
        RelationalStatement(
          sql: "\r\n UpDaTe fixture_entries SET value = 'updated'",
          parameters: {},
          expectedRows: 1,
        ),
      ]);
      expect(
        (await storage.queryForSession(
          session.id.value,
          '\t\n sElEcT value FROM fixture_entries; \r\n',
          {},
        )).single.values,
        {'value': 'updated'},
      );
      for (final sql in [
        '-- comment\nSELECT 1',
        '/* comment */ SELECT 1',
        'WITH n AS (SELECT 1) SELECT * FROM n',
        'SELECTED 1',
        "SELECT ';'",
      ]) {
        await expectLater(
          storage.queryForSession(session.id.value, sql, {}),
          throwsArgumentError,
          reason: sql,
        );
      }
      expect(
        (await storage.queryForSession(
          session.id.value,
          'SELECT :value AS value;',
          {':value': 'literal; PRAGMA foreign_keys = OFF'},
        )).single.values,
        {'value': 'literal; PRAGMA foreign_keys = OFF'},
      );
      for (final sql in [
        'SELECT 1',
        'CREATE TABLE forbidden (id TEXT)',
        '-- comment\nDELETE FROM fixture_entries',
      ]) {
        await expectLater(
          storage.transactionForSession(session.id.value, [
            RelationalStatement(sql: sql, parameters: {}, expectedRows: null),
          ]),
          throwsArgumentError,
          reason: sql,
        );
      }
      await expectLater(
        storage.transactionForSession(session.id.value, [
          RelationalStatement(
            sql: "INSERT INTO fixture_entries VALUES ('tail', 2); COMMIT",
            parameters: {},
            expectedRows: null,
          ),
        ]),
        throwsA(anything),
      );
      await storage.transactionForSession(session.id.value, [
        RelationalStatement(
          sql: '\t dElEtE FROM fixture_entries;\n',
          parameters: {},
          expectedRows: 1,
        ),
      ]);
      expect(
        await storage.queryForSession(
          session.id.value,
          'SELECT * FROM fixture_entries',
          {},
        ),
        isEmpty,
      );
    },
  );

  test('query column names must be unique even when no rows match', () async {
    await storage.ensureSchemaForSession(session.id.value, [_baseline]);
    await storage.transactionForSession(session.id.value, [
      RelationalStatement(
        sql: "INSERT INTO fixture_entries VALUES ('retained', 1)",
        parameters: {},
        expectedRows: 1,
      ),
    ]);
    expect(
      await storage.queryForSession(
        session.id.value,
        'SELECT value, number FROM fixture_entries WHERE 0',
        {},
      ),
      isEmpty,
    );
    for (final suffix in [' WHERE 0', '']) {
      await expectLater(
        storage.queryForSession(
          session.id.value,
          'SELECT value AS duplicate, number AS duplicate '
          'FROM fixture_entries$suffix',
          {},
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Relational query column names must be unique.',
          ),
        ),
      );
    }
  });

  test(
    'query bounds and narrow value types fail without truncation or writes',
    () async {
      await storage.ensureSchemaForSession(session.id.value, [_baseline]);
      await storage.transactionForSession(session.id.value, [
        for (var index = 0; index <= relationalQueryRowLimit; index++)
          RelationalStatement(
            sql: 'INSERT INTO fixture_entries VALUES (NULL, :number)',
            parameters: {':number': index},
            expectedRows: 1,
          ),
      ]);
      await expectLater(
        storage.queryForSession(
          session.id.value,
          'SELECT number FROM fixture_entries',
          {},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('row limit'),
          ),
        ),
      );
      for (final sql in [
        "SELECT printf('%.*c', ${relationalQueryByteLimit + 1}, 'x') AS oversized",
        'SELECT 1.5 AS unsupported',
        "SELECT x'ff' AS unsupported",
        'SELECT 1 AS duplicate, 2 AS duplicate',
        'DELETE FROM adele_product_sessions',
        'SELECT 1; SELECT 2',
      ]) {
        await expectLater(
          storage.queryForSession(session.id.value, sql, {}),
          throwsA(anything),
          reason: sql,
        );
      }
      await expectLater(
        storage.queryForSession(session.id.value, 'SELECT :value', {
          ':value': true,
        }),
        throwsFormatException,
      );
      expect(
        inspect().select('SELECT * FROM adele_product_sessions'),
        hasLength(1),
      );
      final valid = await storage.queryForSession(
        session.id.value,
        'SELECT 1 AS value',
        {},
      );
      expect(valid.single.values, {'value': 1});
    },
  );

  test(
    'revocation before queued service entry prevents database effects',
    () async {
      await storage.ensureSchemaForSession(session.id.value, [_baseline]);
      final dispatcher = ProjectStorageServiceDispatcher(storage);
      addTearDown(dispatcher.close);
      final response = dispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': projectStorageServiceTransactionForSessionId,
        'payload': {
          'sessionId': session.id.value,
          'statements': [
            {
              'sql': "INSERT INTO fixture_entries VALUES ('late', 1)",
              'parameters': <String, Object?>{},
              'expectedRows': 1,
            },
          ],
        },
      });
      live = false;
      expect((await response)['ok'], isFalse);
      expect(inspect().select('SELECT * FROM fixture_entries'), isEmpty);
      await expectLater(
        storage.isDurableSession(session.id.value),
        throwsStateError,
      );
    },
  );
}

Future<Session> _createSession(
  AdeleRuntime runtime,
  Directory directory, {
  bool volatile = false,
}) async {
  final lifecycle = runtime.lifecycle;
  final project = volatile
      ? lifecycle.createProject(directory.uri)
      : await lifecycle.openProject(
          sourceLocation: directory.uri,
          provider: lifecycle.resolveProjectProvider(_projectProvider),
        );
  final task = await lifecycle.createTask(
    projectId: project.id,
    title: 'Storage scope',
    providerId: _environmentProvider,
  );
  return lifecycle.createSession(taskId: task.task.id, strategyId: _strategy);
}

final class _ProviderChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == projectProviderServicePrepareSourceId) {
      return {
        'sourceLocation': payload['sourceLocation'],
        'databaseRelativePath': '.adele/data.db',
      };
    }
    expect(method, environmentProviderServiceEstablishId);
    return {'providerState': <String, Object?>{}};
  }
}
