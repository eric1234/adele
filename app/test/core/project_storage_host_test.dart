import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

final _projectProvider = ProviderId('dev.adele.test.project');
final _environmentProvider = ProviderId('dev.adele.test.environment');
final _strategy = OrchestrationStrategyId('dev.adele.test.strategy');
const _baseline = 'CREATE TABLE fixture_entries (value TEXT, number INTEGER)';
const _durable = ProjectStorageAccessMode.durable;
const _temporary = ProjectStorageAccessMode.durableOrTemporary;

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
      await storage.ensureSchemaForSession(session.id.value, [
        _baseline,
      ], _durable);
      await storage.ensureSchemaForSession(session.id.value, [
        _baseline,
      ], _durable);
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
      ], _durable);
      final rows = await storage.queryForSession(
        session.id.value,
        'SELECT value, number FROM fixture_entries ORDER BY number',
        {},
        _durable,
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
          {'owner_id': 'dev.adele.execution', 'version': 1},
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
        ], _durable),
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
        ], _durable),
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
        {'owner_id': 'dev.adele.execution', 'version': 1},
      ]);
      await storage.ensureSchemaForSession(session.id.value, [
        _baseline,
      ], _durable);
      final other = ProjectStorageHost(
        lifecycle: runtime.lifecycle,
        owner: PluginId('dev.adele.test.other-storage'),
        validateAccess: () {},
      );
      await other.ensureSchemaForSession(session.id.value, [
        'CREATE TABLE other_entries (id TEXT)',
      ], _durable);
      expect(
        database.select('SELECT * FROM adele_schema_versions'),
        hasLength(4),
      );
    },
  );

  test('plugins cannot initialize either core schema owner', () async {
    for (final owner in ['dev.adele.product', 'dev.adele.execution']) {
      final coreOwner = ProjectStorageHost(
        lifecycle: runtime.lifecycle,
        owner: PluginId(owner),
        validateAccess: () {},
      );
      await expectLater(
        coreOwner.ensureSchemaForSession(session.id.value, [
          _baseline,
        ], _durable),
        throwsArgumentError,
      );
    }
  });

  test(
    'Session scope selects its own currently open Project database',
    () async {
      await storage.ensureSchemaForSession(session.id.value, [
        _baseline,
      ], _durable);
      final otherDirectory = Directory('${temporary.path}/other')..createSync();
      final other = await _createSession(runtime, otherDirectory);
      await expectLater(
        storage.queryForSession(
          other.id.value,
          'SELECT * FROM fixture_entries',
          {},
          _durable,
        ),
        throwsA(isA<SqliteException>()),
      );
      await storage.ensureSchemaForSession(other.id.value, [
        _baseline,
      ], _durable);
      await storage.transactionForSession(other.id.value, [
        RelationalStatement(
          sql: "INSERT INTO fixture_entries VALUES ('other', 1)",
          parameters: {},
          expectedRows: 1,
        ),
      ], _durable);
      expect(
        await storage.queryForSession(
          session.id.value,
          'SELECT * FROM fixture_entries',
          {},
          _durable,
        ),
        isEmpty,
      );
      expect(
        (await storage.queryForSession(
          other.id.value,
          'SELECT * FROM fixture_entries',
          {},
          _durable,
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
        storage.ensureSchemaForSession(volatile.id.value, [
          _baseline,
        ], _durable),
        throwsStateError,
      );
      await expectLater(
        storage.queryForSession(volatile.id.value, 'SELECT 1', {}, _durable),
        throwsStateError,
      );
      await expectLater(
        storage.transactionForSession(volatile.id.value, [], _durable),
        throwsStateError,
      );
      expect(
        inspect().select('SELECT * FROM adele_product_sessions'),
        hasLength(1),
      );
    },
  );

  test(
    'temporary opt-in uses existing durable backing, never failure fallback',
    () async {
      final database = runtime.lifecycle.databaseForSession(session.id)!;
      await storage.ensureSchemaForSession(session.id.value, [
        _baseline,
      ], _temporary);
      await storage.transactionForSession(session.id.value, [
        RelationalStatement(
          sql: "INSERT INTO fixture_entries VALUES ('durable', 1)",
          parameters: {},
          expectedRows: 1,
        ),
      ], _temporary);
      expect(await storage.isDurableSession(session.id.value), isTrue);
      expect(
        runtime.lifecycle.databaseForSession(
          session.id,
          accessMode: _temporary,
        ),
        same(database),
      );
      expect(
        (await storage.queryForSession(
          session.id.value,
          'SELECT * FROM fixture_entries',
          {},
          _durable,
        )).single.values['value'],
        'durable',
      );
      database.close();
      await expectLater(
        storage.queryForSession(session.id.value, 'SELECT 1', {}, _temporary),
        throwsStateError,
      );
      expect(
        runtime.lifecycle.databaseForSession(
          session.id,
          accessMode: _temporary,
        ),
        same(database),
      );
      await runtime.close();
      expect(File(database.path).existsSync(), isTrue);
    },
  );

  test(
    'temporary SQLite is retained per Project, preserves identity FKs, and is removed on close',
    () async {
      final volatile = await _createSession(runtime, temporary, volatile: true);
      final sibling = runtime.lifecycle.createSession(
        taskId: volatile.taskId,
        strategyId: _strategy,
      );
      expect(runtime.lifecycle.databaseForSession(volatile.id), isNull);
      await storage.ensureSchemaForSession(volatile.id.value, [
        'CREATE TABLE fixture_sessions ('
            'session_id TEXT PRIMARY KEY REFERENCES adele_product_sessions(id), '
            'value TEXT NOT NULL)',
      ], _temporary);
      final database = runtime.lifecycle.databaseForSession(
        volatile.id,
        accessMode: _temporary,
      )!;
      expect(File(database.path).existsSync(), isTrue);
      expect(database.path, isNot(startsWith(temporary.path)));
      expect(
        runtime.lifecycle.databaseForSession(
          sibling.id,
          accessMode: _temporary,
        ),
        same(database),
      );
      final project = runtime.store.task(volatile.taskId)!.projectId;
      final laterTask = await runtime.lifecycle.createTask(
        projectId: project,
        title: 'Created after temporary storage',
        providerId: _environmentProvider,
      );
      final later = runtime.lifecycle.createSession(
        taskId: laterTask.task.id,
        strategyId: _strategy,
      );
      await storage.transactionForSession(volatile.id.value, [
        for (final id in [volatile.id, sibling.id, later.id])
          RelationalStatement(
            sql: 'INSERT INTO fixture_sessions VALUES (:session, :value)',
            parameters: {':session': id.value, ':value': 'retained'},
            expectedRows: 1,
          ),
      ], _temporary);
      expect(database.loadProductGraph().sessions, hasLength(3));
      expect(await storage.isDurableSession(volatile.id.value), isFalse);
      expect(runtime.lifecycle.databaseForSession(later.id), isNull);
      await expectLater(
        storage.queryForSession(volatile.id.value, 'SELECT 1', {}, _durable),
        throwsStateError,
      );
      live = false;
      await expectLater(
        storage.queryForSession(volatile.id.value, 'SELECT 1', {}, _temporary),
        throwsStateError,
      );
      final replacement = ProjectStorageHost(
        lifecycle: runtime.lifecycle,
        owner: storage.owner,
        validateAccess: () {},
      );
      expect(
        await replacement.queryForSession(
          later.id.value,
          'SELECT * FROM fixture_sessions',
          {},
          _temporary,
        ),
        hasLength(3),
      );
      final other = await _createSession(runtime, temporary, volatile: true);
      final otherDatabase = runtime.lifecycle.databaseForSession(
        other.id,
        accessMode: _temporary,
      )!;
      expect(otherDatabase.path, isNot(database.path));
      await expectLater(
        replacement.queryForSession(
          other.id.value,
          'SELECT * FROM fixture_sessions',
          {},
          _temporary,
        ),
        throwsA(isA<SqliteException>()),
      );
      final retainedPath = File(database.path);
      final otherPath = File(otherDatabase.path);
      await runtime.close();
      expect(retainedPath.existsSync(), isFalse);
      expect(retainedPath.parent.existsSync(), isFalse);
      expect(otherPath.parent.existsSync(), isFalse);
      expect(() => database.queryPluginRows('SELECT 1', {}), throwsStateError);
      expect(() => database.autocommit, throwsStateError);
      await expectLater(
        replacement.queryForSession(
          volatile.id.value,
          'SELECT 1',
          {},
          _temporary,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'temporary storage retains synchronous accepted work but rejects queued close races',
    () async {
      final volatile = await _createSession(runtime, temporary, volatile: true);
      await storage.ensureSchemaForSession(volatile.id.value, [
        _baseline,
      ], _temporary);
      final database = runtime.lifecycle.databaseForSession(
        volatile.id,
        accessMode: _temporary,
      )!;
      final dispatcher = ProjectStorageServiceDispatcher(storage);
      addTearDown(dispatcher.close);
      final acceptedWrite = storage.transactionForSession(volatile.id.value, [
        RelationalStatement(
          sql: "INSERT INTO fixture_entries VALUES ('accepted', 7)",
          parameters: {},
          expectedRows: 1,
        ),
      ], _temporary);
      final accepted = storage.queryForSession(
        volatile.id.value,
        'SELECT value, number FROM fixture_entries',
        {},
        _temporary,
      );
      final queued = dispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': projectStorageServiceTransactionForSessionId,
        'payload': {
          'sessionId': volatile.id.value,
          'accessMode': 'durableOrTemporary',
          'statements': [
            {
              'sql': "INSERT INTO fixture_entries VALUES ('late', 1)",
              'parameters': <String, Object?>{},
              'expectedRows': 1,
            },
          ],
        },
      });
      final closing = runtime.close();
      await acceptedWrite;
      expect((await accepted).single.values, {
        'value': 'accepted',
        'number': 7,
      });
      final response = await queued;
      expect(response['ok'], isFalse);
      expect((response['error']! as Map)['code'], 'internal_error');
      await closing;
      expect(File(database.path).parent.existsSync(), isFalse);
    },
  );

  test(
    'pending provider open does not keep storage admission alive during close',
    () async {
      final volatile = await _createSession(runtime, temporary, volatile: true);
      await storage.ensureSchemaForSession(volatile.id.value, [
        _baseline,
      ], _temporary);
      final database = runtime.lifecycle.databaseForSession(
        volatile.id,
        accessMode: _temporary,
      )!;
      final pending = Completer<Object?>();
      final channel = _ProviderChannel()..pending = pending;
      final provider = ProviderId('dev.adele.test.pending-project');
      final registration = runtime.registry.register(
        provider: ProviderDescriptor(
          id: provider,
          capability: projectProviderCapability,
          pluginId: 'dev.adele.test.provider',
          displayName: 'Pending project',
          serviceId: projectProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: projectProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(registration.close);
      final opening = runtime.lifecycle.openProject(
        sourceLocation: temporary.uri,
        provider: runtime.lifecycle.resolveProjectProvider(provider),
      );
      final failedOpen = expectLater(opening, throwsStateError);
      final closing = runtime.close();
      await expectLater(
        storage.queryForSession(volatile.id.value, 'SELECT 1', {}, _temporary),
        throwsStateError,
      );
      expect(File(database.path).existsSync(), isTrue);
      pending.complete({
        'sourceLocation': temporary.uri.toString(),
        'databaseRelativePath': '.adele/data.db',
      });
      await failedOpen;
      await closing;
      expect(File(database.path).parent.existsSync(), isFalse);
    },
  );

  test(
    'SELECT and DML classes tolerate whitespace and case, not other forms',
    () async {
      await storage.ensureSchemaForSession(session.id.value, [
        _baseline,
      ], _durable);
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
      ], _durable);
      expect(
        (await storage.queryForSession(
          session.id.value,
          '\t\n sElEcT value FROM fixture_entries; \r\n',
          {},
          _durable,
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
          storage.queryForSession(session.id.value, sql, {}, _durable),
          throwsArgumentError,
          reason: sql,
        );
      }
      expect(
        (await storage.queryForSession(
          session.id.value,
          'SELECT :value AS value;',
          {':value': 'literal; PRAGMA foreign_keys = OFF'},
          _durable,
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
          ], _durable),
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
        ], _durable),
        throwsA(anything),
      );
      await storage.transactionForSession(session.id.value, [
        RelationalStatement(
          sql: '\t dElEtE FROM fixture_entries;\n',
          parameters: {},
          expectedRows: 1,
        ),
      ], _durable);
      expect(
        await storage.queryForSession(
          session.id.value,
          'SELECT * FROM fixture_entries',
          {},
          _durable,
        ),
        isEmpty,
      );
    },
  );

  test('query column names must be unique even when no rows match', () async {
    await storage.ensureSchemaForSession(session.id.value, [
      _baseline,
    ], _durable);
    await storage.transactionForSession(session.id.value, [
      RelationalStatement(
        sql: "INSERT INTO fixture_entries VALUES ('retained', 1)",
        parameters: {},
        expectedRows: 1,
      ),
    ], _durable);
    expect(
      await storage.queryForSession(
        session.id.value,
        'SELECT value, number FROM fixture_entries WHERE 0',
        {},
        _durable,
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
          _durable,
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
      await storage.ensureSchemaForSession(session.id.value, [
        _baseline,
      ], _durable);
      await storage.transactionForSession(session.id.value, [
        for (var index = 0; index <= relationalQueryRowLimit; index++)
          RelationalStatement(
            sql: 'INSERT INTO fixture_entries VALUES (NULL, :number)',
            parameters: {':number': index},
            expectedRows: 1,
          ),
      ], _durable);
      await expectLater(
        storage.queryForSession(
          session.id.value,
          'SELECT number FROM fixture_entries',
          {},
          _durable,
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
          storage.queryForSession(session.id.value, sql, {}, _durable),
          throwsA(anything),
          reason: sql,
        );
      }
      await expectLater(
        storage.queryForSession(session.id.value, 'SELECT :value', {
          ':value': true,
        }, _durable),
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
        _durable,
      );
      expect(valid.single.values, {'value': 1});
    },
  );

  for (final mode in ProjectStorageAccessMode.values) {
    test(
      'revocation before queued $mode service entry prevents database effects',
      () async {
        final target = mode == _durable
            ? session
            : await _createSession(runtime, temporary, volatile: true);
        await storage.ensureSchemaForSession(target.id.value, [
          _baseline,
        ], mode);
        final database = runtime.lifecycle.databaseForSession(
          target.id,
          accessMode: mode,
        )!;
        final dispatcher = ProjectStorageServiceDispatcher(storage);
        addTearDown(dispatcher.close);
        final response = dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': projectStorageServiceTransactionForSessionId,
          'payload': {
            'sessionId': target.id.value,
            'accessMode': mode.name,
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
        expect(
          database.queryPluginRows('SELECT * FROM fixture_entries', {}),
          isEmpty,
        );
        await expectLater(
          storage.isDurableSession(target.id.value),
          throwsStateError,
        );
      },
    );

    test(
      'Environment $mode storage precedes Sessions and shares only its Project backing',
      () async {
        final graph = await _openEnvironmentGraph(
          runtime,
          Directory('${temporary.path}/environment')..createSync(),
          id: 'environment-project',
          volatile: mode == _temporary,
        );
        final environment = graph.additional;
        expect(runtime.store.sessionsForTask(graph.task.id), isEmpty);
        expect(
          runtime.lifecycle.environmentRuntime.currentMaterialization(
            environment.id,
          ),
          isNull,
        );
        expect(
          () => runtime.lifecycle.environmentRuntime.resolveProvider(
            providerId: environment.providerId,
          ),
          throwsA(isA<ProviderUnavailable>()),
        );
        const schema =
            'CREATE TABLE fixture_environments ('
            'environment_id TEXT PRIMARY KEY REFERENCES adele_product_environments(id), '
            'task_id TEXT NOT NULL REFERENCES adele_product_tasks(id), '
            'project_id TEXT NOT NULL REFERENCES adele_product_projects(id), '
            'value TEXT); '
            'CREATE TABLE fixture_later_sessions ('
            'session_id TEXT PRIMARY KEY REFERENCES adele_product_sessions(id))';
        if (mode == _temporary) {
          expect(
            runtime.lifecycle.databaseForEnvironment(environment.id),
            isNull,
          );
          await expectLater(
            storage.ensureSchemaForEnvironment(environment.id.value, [
              schema,
            ], _durable),
            throwsStateError,
          );
          await expectLater(
            storage.queryForEnvironment(
              environment.id.value,
              'SELECT 1',
              {},
              _durable,
            ),
            throwsStateError,
          );
          await expectLater(
            storage.transactionForEnvironment(
              environment.id.value,
              [],
              _durable,
            ),
            throwsStateError,
          );
        }
        await storage.ensureSchemaForEnvironment(environment.id.value, [
          schema,
        ], mode);
        final database = runtime.lifecycle.databaseForEnvironment(
          environment.id,
          accessMode: mode,
        )!;
        expect(database.loadProductGraph().sessions, isEmpty);
        expect(database.loadProductGraph().environments, hasLength(2));
        expect(
          runtime.lifecycle.databaseForEnvironment(
            graph.primary.id,
            accessMode: mode,
          ),
          same(database),
        );
        await storage.transactionForEnvironment(environment.id.value, [
          for (final target in [graph.primary, environment])
            RelationalStatement(
              sql:
                  'INSERT INTO fixture_environments VALUES (:environment, :task, :project, :value)',
              parameters: {
                ':environment': target.id.value,
                ':task': graph.task.id.value,
                ':project': graph.project.id.value,
                ':value': target.id.value,
              },
              expectedRows: 1,
            ),
        ], mode);
        expect(
          (await storage.queryForEnvironment(
            environment.id.value,
            'SELECT value FROM fixture_environments WHERE environment_id = :environment',
            {':environment': environment.id.value},
            mode,
          )).single.values,
          {'value': environment.id.value},
        );
        final later = runtime.lifecycle.createSession(
          taskId: graph.task.id,
          strategyId: _strategy,
          environmentId: environment.id,
        );
        expect(
          runtime.lifecycle.databaseForSession(later.id, accessMode: mode),
          same(database),
        );
        await storage.ensureSchemaForSession(later.id.value, [schema], mode);
        await storage.transactionForSession(later.id.value, [
          RelationalStatement(
            sql: 'INSERT INTO fixture_later_sessions VALUES (:session)',
            parameters: {':session': later.id.value},
            expectedRows: 1,
          ),
        ], mode);
        expect(database.loadProductGraph().sessions.single.id, later.id);
        expect(database.loadProductGraph().authorities, [
          (later.id, environment.id),
        ]);
        expect(
          await storage.queryForEnvironment(
            environment.id.value,
            'SELECT * FROM fixture_later_sessions',
            {},
            mode,
          ),
          hasLength(1),
        );
        expect(
          await storage.queryForSession(
            later.id.value,
            'SELECT * FROM fixture_environments',
            {},
            mode,
          ),
          hasLength(2),
        );
        expect(
          await storage.isDurableSession(later.id.value),
          mode == _durable,
        );
        expect(
          runtime.lifecycle.environmentRuntime.currentMaterialization(
            environment.id,
          ),
          isNull,
        );

        final other = await _openEnvironmentGraph(
          runtime,
          Directory('${temporary.path}/other-environment')..createSync(),
          id: 'other-environment-project',
          volatile: mode == _temporary,
        );
        await expectLater(
          storage.queryForEnvironment(
            other.additional.id.value,
            'SELECT * FROM fixture_environments',
            {},
            mode,
          ),
          throwsA(isA<SqliteException>()),
        );
        await storage.ensureSchemaForEnvironment(other.additional.id.value, [
          schema,
        ], mode);
        expect(
          await storage.queryForEnvironment(
            other.additional.id.value,
            'SELECT * FROM fixture_environments',
            {},
            mode,
          ),
          isEmpty,
        );
        expect(
          runtime.lifecycle.databaseForEnvironment(
            other.additional.id,
            accessMode: mode,
          ),
          isNot(same(database)),
        );

        final path = File(database.path);
        if (mode == _temporary) {
          expect(path.path, isNot(startsWith(temporary.path)));
        }
        await runtime.close();
        expect(path.existsSync(), mode == _durable);
        if (mode == _temporary) {
          expect(path.parent.existsSync(), isFalse);
        }
        await expectLater(
          storage.queryForEnvironment(
            environment.id.value,
            'SELECT 1',
            {},
            mode,
          ),
          throwsStateError,
        );
      },
    );

    test(
      'Environment $mode reuses owner, SQL validation, rollback, and limits',
      () async {
        final graph = await _openEnvironmentGraph(
          runtime,
          Directory('${temporary.path}/environment')..createSync(),
          id: 'sql-environment-project',
          volatile: mode == _temporary,
        );
        final id = graph.additional.id.value;
        final database = runtime.lifecycle.databaseForEnvironment(
          graph.additional.id,
          accessMode: mode,
        )!;
        for (final owner in ['dev.adele.product', 'dev.adele.execution']) {
          final reserved = ProjectStorageHost(
            lifecycle: runtime.lifecycle,
            owner: PluginId(owner),
            validateAccess: () {},
          );
          await expectLater(
            reserved.ensureSchemaForEnvironment(id, [_baseline], mode),
            throwsArgumentError,
          );
        }
        for (final (schema, failure) in <(String, Matcher)>[
          (
            'CREATE TABLE rollback_table (id TEXT); COMMIT',
            throwsArgumentError,
          ),
          (
            'CREATE TABLE rollback_table (id TEXT); CREATE TABLE incomplete (',
            throwsA(isA<SqliteException>()),
          ),
        ]) {
          await expectLater(
            storage.ensureSchemaForEnvironment(id, [schema], mode),
            failure,
          );
          expect(
            database.queryPluginRows(
              "SELECT name FROM sqlite_master WHERE name = 'rollback_table'",
              {},
            ),
            isEmpty,
          );
          expect(
            database.queryPluginRows(
              'SELECT version FROM adele_schema_versions WHERE owner_id = :owner',
              {':owner': storage.owner.value},
            ),
            isEmpty,
          );
        }
        await storage.ensureSchemaForEnvironment(id, [_baseline], mode);
        await storage.ensureSchemaForEnvironment(id, [_baseline], mode);
        final otherOwner = ProjectStorageHost(
          lifecycle: runtime.lifecycle,
          owner: PluginId('dev.adele.test.other-storage'),
          validateAccess: () {},
        );
        await otherOwner.ensureSchemaForEnvironment(id, [
          'CREATE TABLE other_entries (id TEXT)',
        ], mode);
        expect(
          database
              .queryPluginRows(
                'SELECT owner_id, version FROM adele_schema_versions ORDER BY owner_id',
                {},
              )
              .map((row) => row.values),
          [
            {'owner_id': 'dev.adele.execution', 'version': 1},
            {'owner_id': 'dev.adele.product', 'version': 1},
            {'owner_id': 'dev.adele.test.other-storage', 'version': 1},
            {'owner_id': 'dev.adele.test.storage', 'version': 1},
          ],
        );
        await storage.transactionForEnvironment(id, [
          RelationalStatement(
            sql: ' \n iNsErT INTO fixture_entries VALUES (:value, :number)',
            parameters: {':value': "quoted'; COMMIT", ':number': 7},
            expectedRows: 1,
          ),
          RelationalStatement(
            sql: 'INSERT INTO fixture_entries VALUES (:value, :number)',
            parameters: {':value': null, ':number': 8},
            expectedRows: 1,
          ),
        ], mode);
        final rows = await storage.queryForEnvironment(
          id,
          '\t sElEcT value, number FROM fixture_entries ORDER BY number; ',
          {},
          mode,
        );
        expect(rows.map((row) => row.values), [
          {'value': "quoted'; COMMIT", 'number': 7},
          {'value': null, 'number': 8},
        ]);
        expect(() => rows.clear(), throwsUnsupportedError);
        expect(() => rows.first.values.clear(), throwsUnsupportedError);
        for (final (sql, failure) in <(String, Matcher)>[
          (
            'UPDATE fixture_entries SET value = NULL WHERE number = 99',
            throwsStateError,
          ),
          (
            'INSERT INTO missing_table VALUES (1)',
            throwsA(isA<SqliteException>()),
          ),
          ('COMMIT', throwsArgumentError),
          ('DELETE FROM fixture_entries; COMMIT', throwsArgumentError),
        ]) {
          await expectLater(
            storage.transactionForEnvironment(id, [
              RelationalStatement(
                sql: "UPDATE fixture_entries SET value = 'must roll back'",
                parameters: {},
                expectedRows: 2,
              ),
              RelationalStatement(sql: sql, parameters: {}, expectedRows: 1),
            ], mode),
            failure,
          );
          expect(
            (await storage.queryForEnvironment(
              id,
              'SELECT value, number FROM fixture_entries ORDER BY number',
              {},
              mode,
            )).map((row) => row.values),
            rows.map((row) => row.values),
          );
          expect(database.autocommit, isTrue);
        }
        for (final sql in [
          'DELETE FROM fixture_entries',
          'SELECT 1; SELECT 2',
          '-- comment\nSELECT 1',
          'WITH n AS (SELECT 1) SELECT * FROM n',
        ]) {
          await expectLater(
            storage.queryForEnvironment(id, sql, {}, mode),
            throwsArgumentError,
          );
        }
        for (final sql in [
          'SELECT 1.5',
          "SELECT x'ff'",
          'SELECT 1 AS same, 2 AS same',
        ]) {
          await expectLater(
            storage.queryForEnvironment(id, sql, {}, mode),
            throwsFormatException,
          );
        }
        await expectLater(
          storage.queryForEnvironment(id, 'SELECT :value', {
            ':value': true,
          }, mode),
          throwsFormatException,
        );
        await expectLater(
          storage.queryForEnvironment(
            id,
            "SELECT printf('%.*c', ${relationalQueryByteLimit + 1}, 'x') AS oversized",
            {},
            mode,
          ),
          throwsStateError,
        );
        await storage.transactionForEnvironment(id, [
          for (var index = 0; index < relationalQueryRowLimit; index++)
            RelationalStatement(
              sql: 'INSERT INTO fixture_entries VALUES (NULL, :number)',
              parameters: {':number': index},
              expectedRows: 1,
            ),
        ], mode);
        await expectLater(
          storage.queryForEnvironment(
            id,
            'SELECT number FROM fixture_entries',
            {},
            mode,
          ),
          throwsStateError,
        );
      },
    );

    test(
      'Environment $mode revalidates generation before queued entry and identity parsing',
      () async {
        final graph = await _openEnvironmentGraph(
          runtime,
          Directory('${temporary.path}/environment')..createSync(),
          id: 'revoked-environment-project',
          volatile: mode == _temporary,
        );
        final id = graph.additional.id.value;
        await storage.ensureSchemaForEnvironment(id, [_baseline], mode);
        final database = runtime.lifecycle.databaseForEnvironment(
          graph.additional.id,
          accessMode: mode,
        )!;
        final dispatcher = ProjectStorageServiceDispatcher(storage);
        addTearDown(dispatcher.close);
        final response = dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': projectStorageServiceTransactionForEnvironmentId,
          'payload': {
            'environmentId': id,
            'accessMode': mode.name,
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
        expect(
          database.queryPluginRows('SELECT * FROM fixture_entries', {}),
          isEmpty,
        );
        final revoked = throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Retired generation',
          ),
        );
        for (final target in [id, 'absent', ' invalid']) {
          await expectLater(
            storage.ensureSchemaForEnvironment(target, [_baseline], mode),
            revoked,
          );
          await expectLater(
            storage.queryForEnvironment(target, 'SELECT 1', {}, mode),
            revoked,
          );
          await expectLater(
            storage.transactionForEnvironment(target, [], mode),
            revoked,
          );
        }
        final replacement = ProjectStorageHost(
          lifecycle: runtime.lifecycle,
          owner: storage.owner,
          validateAccess: () {},
        );
        expect(
          await replacement.queryForEnvironment(
            id,
            'SELECT * FROM fixture_entries',
            {},
            mode,
          ),
          isEmpty,
        );
        await runtime.close();
        await expectLater(
          replacement.ensureSchemaForEnvironment(id, [_baseline], mode),
          throwsStateError,
        );
        await expectLater(
          replacement.queryForEnvironment(id, 'SELECT 1', {}, mode),
          throwsStateError,
        );
        await expectLater(
          replacement.transactionForEnvironment(id, [], mode),
          throwsStateError,
        );
      },
    );
  }

  test(
    'unknown and unpublished Environments cannot select another published backing',
    () async {
      final unpublished = Environment(
        id: EnvironmentId('unpublished'),
        taskId: session.taskId,
        role: EnvironmentRole.additional,
        providerId: _environmentProvider,
        providerState: {},
      );
      for (final mode in ProjectStorageAccessMode.values) {
        for (final id in ['absent', unpublished.id.value]) {
          await expectLater(
            storage.ensureSchemaForEnvironment(id, [_baseline], mode),
            throwsStateError,
          );
          await expectLater(
            storage.queryForEnvironment(id, 'SELECT 1', {}, mode),
            throwsStateError,
          );
          await expectLater(
            storage.transactionForEnvironment(id, [], mode),
            throwsStateError,
          );
        }
        await expectLater(
          storage.queryForEnvironment(' invalid', 'SELECT 1', {}, mode),
          throwsFormatException,
        );
      }
      expect(
        inspect().select(
          'SELECT version FROM adele_schema_versions WHERE owner_id = ?',
          [storage.owner.value],
        ),
        isEmpty,
      );
    },
  );

  test(
    'malformed Environment associations are rejected before canonical publication',
    () async {
      final project = Project(
        id: ProjectId('malformed-project'),
        sourceLocation: temporary.uri,
      );
      final task = Task(
        id: TaskId('malformed-task'),
        projectId: project.id,
        title: 'Malformed',
      );
      final environment = Environment(
        id: EnvironmentId('malformed-environment'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: _environmentProvider,
        providerState: {},
      );
      // The final store's private maps have no malformed-graph injection/removal API.
      // Orphan Task/Project links and provisional records cannot reach storage entry;
      // test their real publication boundary instead of inventing a fake live graph.
      for (final (tasks, environments) in <(List<Task>, List<Environment>)>[
        ([], [environment]),
        (
          [
            Task(
              id: task.id,
              projectId: ProjectId('foreign'),
              title: task.title,
            ),
          ],
          [environment],
        ),
        (
          [task],
          [
            Environment(
              id: environment.id,
              taskId: TaskId('foreign'),
              role: environment.role,
              providerId: environment.providerId,
              providerState: {},
            ),
          ],
        ),
        (
          [task],
          [
            Environment(
              id: environment.id,
              taskId: task.id,
              role: environment.role,
              providerId: environment.providerId,
              providerState: null,
            ),
          ],
        ),
      ]) {
        expect(
          () => runtime.store.publishRestoredProject(
            project: project,
            tasks: tasks,
            environments: environments,
            sessions: [],
            authorities: [],
            runRecords: [],
          ),
          throwsStateError,
        );
        expect(runtime.store.project(project.id), isNull);
        expect(runtime.store.task(task.id), isNull);
        expect(runtime.store.environment(environment.id), isNull);
        await expectLater(
          storage.queryForEnvironment(
            environment.id.value,
            'SELECT 1',
            {},
            _temporary,
          ),
          throwsStateError,
        );
      }
    },
  );

  test(
    'provisional Environment storage fails during Task establishment',
    () async {
      final pending = Completer<Object?>();
      final entered = Completer<Map<Object?, Object?>>();
      final channel = _ProviderChannel()
        ..pendingEnvironment = pending
        ..onEstablish = (payload) =>
            entered.complete(payload['context']! as Map<Object?, Object?>);
      final provider = ProviderId('dev.adele.test.pending-environment');
      final registration = runtime.registry.register(
        provider: ProviderDescriptor(
          id: provider,
          capability: environmentProviderCapability,
          pluginId: 'dev.adele.test.provider',
          displayName: 'Pending Environment',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: channel,
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(registration.close);
      final project = runtime.store.task(session.taskId)!.projectId;
      final creating = runtime.lifecycle.createTask(
        projectId: project,
        title: 'Provisional',
        providerId: provider,
      );
      final context = await entered.future;
      final id = context['environmentId']! as String;
      expect(context['providerStateInitialized'], isFalse);
      for (final mode in ProjectStorageAccessMode.values) {
        await expectLater(
          storage.ensureSchemaForEnvironment(id, [_baseline], mode),
          throwsStateError,
        );
        await expectLater(
          storage.queryForEnvironment(id, 'SELECT 1', {}, mode),
          throwsStateError,
        );
        await expectLater(
          storage.transactionForEnvironment(id, [], mode),
          throwsStateError,
        );
      }
      expect(runtime.store.environment(EnvironmentId(id)), isNull);
      pending.complete({
        'providerState': <String, Object?>{},
        'initialState': null,
      });
      final created = await creating;
      expect(created.environment.id.value, id);
      expect(runtime.store.sessionsForTask(created.task.id), isEmpty);
      await storage.ensureSchemaForEnvironment(id, [_baseline], _durable);
    },
  );

  test(
    'Environment temporary opt-in never replaces failed durable storage',
    () async {
      final environment = runtime.store.primaryEnvironmentFor(session.taskId)!;
      final database = runtime.lifecycle.databaseForEnvironment(
        environment.id,
      )!;
      await storage.ensureSchemaForEnvironment(environment.id.value, [
        _baseline,
      ], _temporary);
      expect(
        runtime.lifecycle.databaseForEnvironment(
          environment.id,
          accessMode: _temporary,
        ),
        same(database),
      );
      final inspection = inspect();
      inspection.execute('PRAGMA user_version = 71');
      await expectLater(
        storage.transactionForEnvironment(environment.id.value, [
          RelationalStatement(
            sql: 'INSERT INTO missing_table VALUES (1)',
            parameters: {},
            expectedRows: 1,
          ),
        ], _temporary),
        throwsA(isA<SqliteException>()),
      );
      expect(
        inspection.select('PRAGMA user_version').single['user_version'],
        71,
      );
      database.close();
      await expectLater(
        storage.ensureSchemaForEnvironment(environment.id.value, [
          _baseline,
        ], _temporary),
        throwsStateError,
      );
      await expectLater(
        storage.queryForEnvironment(
          environment.id.value,
          'SELECT 1',
          {},
          _temporary,
        ),
        throwsStateError,
      );
      await expectLater(
        storage.transactionForEnvironment(environment.id.value, [], _temporary),
        throwsStateError,
      );
      expect(
        runtime.lifecycle.databaseForEnvironment(
          environment.id,
          accessMode: _temporary,
        ),
        same(database),
      );
      await runtime.close();
      expect(File(database.path).existsSync(), isTrue);
    },
  );
}

Future<
  ({Project project, Task task, Environment primary, Environment additional})
>
_openEnvironmentGraph(
  AdeleRuntime runtime,
  Directory directory, {
  required String id,
  required bool volatile,
}) async {
  final project = Project(id: ProjectId(id), sourceLocation: directory.uri);
  final task = Task(
    id: TaskId('$id-task'),
    projectId: project.id,
    title: 'No Session',
  );
  Environment environment(EnvironmentRole role) => Environment(
    id: EnvironmentId('$id-${role.name}'),
    taskId: task.id,
    role: role,
    providerId: ProviderId('dev.adele.test.absent-environment'),
    providerState: {},
  );
  final primary = environment(EnvironmentRole.primary);
  final additional = environment(EnvironmentRole.additional);
  if (volatile) {
    runtime.store.publishRestoredProject(
      project: project,
      tasks: [task],
      environments: [primary, additional],
      sessions: [],
      authorities: [],
      runRecords: [],
    );
  } else {
    final database = ProjectDatabase.open(
      ProjectBacking(
        sourceLocation: directory.uri,
        databaseRelativePath: '.adele/data.db',
      ),
    );
    try {
      database.openProject(
        sourceLocation: directory.uri,
        nextProjectId: () => project.id,
      );
      database.insertTaskWithPrimaryEnvironment(task, primary);
      final seed = sqlite3.open(database.path);
      try {
        seed.execute(
          "INSERT INTO adele_product_environments VALUES (?, ?, 'additional', ?, '{}')",
          [additional.id.value, task.id.value, additional.providerId.value],
        );
      } finally {
        seed.close();
      }
    } finally {
      database.close();
    }
    await runtime.lifecycle.openProject(
      sourceLocation: directory.uri,
      provider: runtime.lifecycle.resolveProjectProvider(_projectProvider),
    );
  }
  return (
    project: runtime.store.project(project.id)!,
    task: runtime.store.task(task.id)!,
    primary: runtime.store.environment(primary.id)!,
    additional: runtime.store.environment(additional.id)!,
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
  Completer<Object?>? pending;
  Completer<Object?>? pendingEnvironment;
  void Function(Map<String, Object?>)? onEstablish;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method == projectProviderServicePrepareSourceId) {
      if (pending case final value?) return value.future;
      return {
        'sourceLocation': payload['sourceLocation'],
        'databaseRelativePath': '.adele/data.db',
      };
    }
    expect(method, environmentProviderServiceEstablishId);
    onEstablish?.call(payload);
    if (pendingEnvironment case final value?) return value.future;
    return {'providerState': <String, Object?>{}, 'initialState': null};
  }
}
