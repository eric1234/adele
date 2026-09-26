import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

void main() {
  late Directory temporary;
  late Directory source;
  late ProjectBacking backing;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('adele-project-db-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    source = Directory.fromUri(temporary.uri.resolve('source/'))..createSync();
    backing = ProjectBacking(
      sourceLocation: source.uri,
      databaseRelativePath: 'custom/state/project.sqlite',
    );
  });

  test('initializes metadata and the complete product v1 baseline', () {
    final ProjectDatabase database = _open(backing);
    expect(
      database.path,
      File.fromUri(
        Directory(
          source.resolveSymbolicLinksSync(),
        ).uri.resolve('custom/state/project.sqlite'),
      ).path,
    );
    final Database inspection = _connect(database.path);
    expect(
      inspection
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((Row row) => row['name']),
      unorderedEquals(<String>[
        'adele_schema_versions',
        'adele_product_projects',
        'adele_product_tasks',
        'adele_product_environments',
        'adele_product_sessions',
        'adele_product_session_environment_authority',
      ]),
    );
    expect(inspection.select('SELECT * FROM adele_schema_versions'), <Object?>[
      <String, Object?>{'owner_id': 'dev.adele.product', 'version': 1},
    ]);
    expect(
      inspection
          .select('PRAGMA table_info(adele_product_projects)')
          .map((Row row) => row['name']),
      <String>['id', 'source_location'],
    );
    expect(inspection.select('SELECT * FROM adele_product_projects'), isEmpty);
    expect(
      inspection
          .select('PRAGMA table_info(adele_product_tasks)')
          .map((row) => row['name']),
      ['id', 'project_id', 'title'],
    );
    expect(
      inspection
          .select('PRAGMA table_info(adele_product_environments)')
          .map((row) => row['name']),
      ['id', 'task_id', 'role', 'provider_id', 'provider_state_json'],
    );
    expect(
      inspection
          .select('PRAGMA foreign_key_list(adele_product_tasks)')
          .single['table'],
      'adele_product_projects',
    );
    expect(
      inspection
          .select('PRAGMA foreign_key_list(adele_product_environments)')
          .single['table'],
      'adele_product_tasks',
    );
    expect(
      inspection
          .select('PRAGMA table_info(adele_product_sessions)')
          .map((row) => (row['name'], row['type'], row['notnull'], row['pk'])),
      [
        ('id', 'TEXT', 0, 1),
        ('task_id', 'TEXT', 1, 0),
        ('strategy_id', 'TEXT', 1, 0),
      ],
    );
    expect(
      inspection
          .select(
            'PRAGMA table_info(adele_product_session_environment_authority)',
          )
          .map((row) => (row['name'], row['type'], row['notnull'], row['pk'])),
      [('session_id', 'TEXT', 0, 1), ('environment_id', 'TEXT', 1, 0)],
    );
    expect(
      inspection
          .select('PRAGMA foreign_key_list(adele_product_sessions)')
          .map((row) => (row['from'], row['table'], row['to'])),
      [('task_id', 'adele_product_tasks', 'id')],
    );
    expect(
      inspection
          .select(
            'PRAGMA foreign_key_list(adele_product_session_environment_authority)',
          )
          .map((row) => (row['from'], row['table'], row['to'])),
      unorderedEquals([
        ('session_id', 'adele_product_sessions', 'id'),
        ('environment_id', 'adele_product_environments', 'id'),
      ]),
    );
    expect(
      File(database.path).readAsBytesSync().take(16),
      'SQLite format 3\x00'.codeUnits,
    );
    expect(
      Directory.fromUri(source.uri.resolve('.adele/')).existsSync(),
      isFalse,
    );
  });

  for (final control in [
    'COMMIT',
    'BEGIN',
    'PRAGMA foreign_keys = OFF',
    "ATTACH DATABASE ':memory:' AS plugin",
  ]) {
    test('plugin migration rejects $control without partial schema or version', () {
      final database = _open(backing);
      const owner = 'dev.adele.test.migration';
      expect(
        () => database.ensurePluginSchema(owner, [
          'CREATE TABLE should_not_survive (id TEXT); '
              '$control; CREATE TABLE broken (',
        ]),
        throwsArgumentError,
      );
      expect(database.autocommit, isTrue);
      expect(
        database.queryPluginRows(
          "SELECT name FROM sqlite_master WHERE name = 'should_not_survive'",
          {},
        ),
        isEmpty,
      );
      expect(
        database.queryPluginRows(
          'SELECT version FROM adele_schema_versions WHERE owner_id = :owner',
          {':owner': owner},
        ),
        isEmpty,
      );
      expect(
        database
            .queryPluginRows('SELECT foreign_keys FROM pragma_foreign_keys', {})
            .single
            .values,
        {'foreign_keys': 1},
      );
      expect(
        database
            .queryPluginRows('SELECT name FROM pragma_database_list', {})
            .map((row) => row.values['name']),
        isNot(contains('plugin')),
      );
      database.ensurePluginSchema(owner, [
        " \n cReAtE TaBlE should_not_survive (id TEXT CHECK (id IN ('user', 'assistant'))); "
            'CREATE TABLE second_table (id TEXT); \n',
      ]);
      expect(database.autocommit, isTrue);
      expect(
        database
            .queryPluginRows(
              'SELECT version FROM adele_schema_versions WHERE owner_id = :owner',
              {':owner': owner},
            )
            .single
            .values,
        {'version': 1},
      );
      database.executePluginTransaction([
        RelationalStatement(
          sql: 'INSERT INTO should_not_survive VALUES (:id)',
          parameters: {':id': 'user'},
          expectedRows: 1,
        ),
      ]);
      expect(
        database
            .queryPluginRows('SELECT id FROM should_not_survive', {})
            .single
            .values,
        {'id': 'user'},
      );
      expect(
        database.queryPluginRows('SELECT * FROM second_table', {}),
        isEmpty,
      );
      expect(database.autocommit, isTrue);
    });
  }

  test(
    'plugin migration validates the whole script before executing its first statement',
    () {
      final database = _open(backing);
      expect(
        () => database.ensurePluginSchema('dev.adele.test.migration', [
          'CREATE TABLE incomplete (; COMMIT;',
        ]),
        // A statement-by-statement validation/execution loop would fail in SQLite
        // on the first CREATE instead of detecting the unsupported later COMMIT.
        throwsArgumentError,
      );
      expect(database.autocommit, isTrue);
    },
  );

  test(
    'plugin migration syntax rejects comments, double quotes and embedded literal separators',
    () {
      final database = _open(backing);
      for (final sql in [
        '-- comment\nCREATE TABLE unsupported (id TEXT)',
        'CREATE /* comment */ TABLE unsupported (id TEXT)',
        'CREATE TABLE "unsupported" (id TEXT)',
        "CREATE TABLE unsupported (id TEXT DEFAULT 'one;two')",
      ]) {
        expect(
          () => database.ensurePluginSchema('dev.adele.test.migration', [
            'CREATE TABLE should_not_survive (id TEXT); $sql',
          ]),
          throwsArgumentError,
          reason: sql,
        );
        expect(
          database.queryPluginRows(
            "SELECT name FROM sqlite_master WHERE name = 'should_not_survive'",
            {},
          ),
          isEmpty,
        );
        expect(database.autocommit, isTrue);
      }
    },
  );

  for (final (query, sql) in [
    (true, 'PRAGMA foreign_keys = OFF'),
    (true, 'BEGIN'),
    (true, 'SELECT 1; PRAGMA foreign_keys = OFF'),
    (false, 'COMMIT'),
    (false, 'SAVEPOINT plugin'),
    (false, 'PRAGMA defer_foreign_keys = ON'),
    (false, "ATTACH DATABASE ':memory:' AS plugin"),
  ]) {
    test(
      'rejected ${query ? 'query' : 'batch'} $sql leaves shared connection healthy',
      () {
        final database = _open(backing);
        final project = database.openProject(
          sourceLocation: source.uri,
          nextProjectId: () => ProjectId('project'),
        );
        database.ensurePluginSchema('dev.adele.test.storage', [
          'CREATE TABLE fixture_entries (value TEXT)',
        ]);
        if (query) {
          expect(() => database.queryPluginRows(sql, {}), throwsArgumentError);
        } else {
          expect(
            () => database.executePluginTransaction([
              RelationalStatement(
                sql: "INSERT INTO fixture_entries VALUES ('rollback')",
                parameters: {},
                expectedRows: 1,
              ),
              RelationalStatement(sql: sql, parameters: {}, expectedRows: null),
            ]),
            throwsArgumentError,
          );
        }
        // These inspect the owning connection, not a second inspection connection.
        expect(database.autocommit, isTrue);
        expect(
          database
              .queryPluginRows(
                'SELECT foreign_keys FROM pragma_foreign_keys',
                {},
              )
              .single
              .values,
          {'foreign_keys': 1},
        );
        expect(
          database.queryPluginRows('SELECT * FROM fixture_entries', {}),
          isEmpty,
        );
        expect(
          database
              .queryPluginRows('SELECT name FROM pragma_database_list', {})
              .map((row) => row.values['name']),
          isNot(contains('plugin')),
        );
        database.executePluginTransaction([
          RelationalStatement(
            sql: "INSERT INTO fixture_entries VALUES ('healthy')",
            parameters: {},
            expectedRows: 1,
          ),
        ]);
        expect(database.autocommit, isTrue);
        expect(
          database
              .queryPluginRows('SELECT value FROM fixture_entries', {})
              .single
              .values,
          {'value': 'healthy'},
        );
        final invalid = Task(
          id: TaskId('task'),
          projectId: ProjectId('missing'),
          title: 'Requires a Project',
        );
        expect(
          () => database.insertTaskWithPrimaryEnvironment(
            invalid,
            _environment(invalid),
          ),
          throwsA(
            isA<SqliteException>().having(
              (error) => error.message,
              'message',
              contains('FOREIGN KEY'),
            ),
          ),
        );
        expect(database.autocommit, isTrue);
        final valid = Task(
          id: invalid.id,
          projectId: project.id,
          title: 'Healthy',
        );
        database.insertTaskWithPrimaryEnvironment(valid, _environment(valid));
        expect(database.autocommit, isTrue);
        expect(database.loadProductGraph().tasks.single.id, valid.id);
      },
    );
  }

  test(
    'Task and primary Environment commit together and nested JSON reloads',
    () {
      final database = _open(backing);
      final project = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => ProjectId('project'),
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Retained title',
      );
      final state = <String, Object?>{
        'text': 'provider-owned snapshot',
        'nested': <String, Object?>{
          'list': <Object?>[
            null,
            true,
            false,
            42,
            1.25,
            <String, Object?>{'key': 'value'},
          ],
        },
        'empty': <Object?>[],
      };
      final environment = _environment(task, state: state);
      database.insertTaskWithPrimaryEnvironment(task, environment);
      final inspection = _connect(database.path);
      expect(inspection.select('SELECT * FROM adele_product_tasks'), [
        {
          'id': task.id.value,
          'project_id': project.id.value,
          'title': task.title,
        },
      ]);
      expect(inspection.select('SELECT * FROM adele_product_environments'), [
        {
          'id': environment.id.value,
          'task_id': task.id.value,
          'role': 'primary',
          'provider_id': environment.providerId.value,
          'provider_state_json': jsonEncode(state),
        },
      ]);
      database.close();
      final graph = _open(backing).loadProductGraph();
      expect(graph.tasks.single.id, task.id);
      expect(graph.tasks.single.projectId, project.id);
      expect(graph.tasks.single.title, task.title);
      final retained = graph.environments.single;
      expect(retained.id, environment.id);
      expect(retained.taskId, task.id);
      expect(retained.role, EnvironmentRole.primary);
      expect(retained.providerId, environment.providerId);
      expect(retained.providerState, state);
      expect(
        () => retained.providerState!['new'] = true,
        throwsUnsupportedError,
      );
      expect(
        () =>
            (retained.providerState!['nested'] as Map<String, Object?>)['new'] =
                true,
        throwsUnsupportedError,
      );
    },
  );

  test(
    'Session and authority commit together and reopen as semantic records',
    () {
      final database = _open(backing);
      final project = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => ProjectId('project'),
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Task',
      );
      final environment = _environment(task);
      database.insertTaskWithPrimaryEnvironment(task, environment);
      final session = Session(
        id: SessionId('session'),
        taskId: task.id,
        strategyId: OrchestrationStrategyId('dev.adele.test.strategy'),
      );
      database.insertSessionWithAuthority(session, environment.id);
      final inspection = _connect(database.path);
      expect(inspection.select('SELECT * FROM adele_product_sessions'), [
        {
          'id': session.id.value,
          'task_id': task.id.value,
          'strategy_id': session.strategyId.value,
        },
      ]);
      expect(
        inspection.select(
          'SELECT * FROM adele_product_session_environment_authority',
        ),
        [
          {
            'session_id': session.id.value,
            'environment_id': environment.id.value,
          },
        ],
      );
      database.close();
      final graph = _open(backing).loadProductGraph();
      expect(graph.sessions.single.id, session.id);
      expect(graph.sessions.single.taskId, task.id);
      expect(graph.sessions.single.strategyId, session.strategyId);
      expect(graph.authorities, [(session.id, environment.id)]);
    },
  );

  test('failed Session COMMIT rolls back both rows and permits retry', () {
    final database = _open(backing);
    final project = database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('project'),
    );
    final task = Task(id: TaskId('task'), projectId: project.id, title: 'Task');
    final environment = _environment(task);
    database.insertTaskWithPrimaryEnvironment(task, environment);
    final session = Session(
      id: SessionId('session'),
      taskId: task.id,
      strategyId: OrchestrationStrategyId('dev.adele.test.strategy'),
    );
    final inspection = _connect(database.path);
    inspection.execute('''
      CREATE TABLE deferred_check (
        session_id TEXT REFERENCES adele_product_sessions(id) DEFERRABLE INITIALLY DEFERRED
      );
      CREATE TRIGGER fail_session_commit AFTER INSERT ON adele_product_session_environment_authority
      BEGIN INSERT INTO deferred_check VALUES ('missing'); END;
    ''');
    expect(
      () => database.insertSessionWithAuthority(session, environment.id),
      throwsA(
        isA<SqliteException>().having(
          (error) => error.causingStatement,
          'causingStatement',
          'COMMIT',
        ),
      ),
    );
    expect(inspection.select('SELECT * FROM adele_product_sessions'), isEmpty);
    expect(
      inspection.select(
        'SELECT * FROM adele_product_session_environment_authority',
      ),
      isEmpty,
    );
    expect(inspection.select('SELECT * FROM deferred_check'), isEmpty);
    inspection.execute('DROP TRIGGER fail_session_commit');
    database.insertSessionWithAuthority(session, environment.id);
    expect(database.loadProductGraph().authorities, [
      (session.id, environment.id),
    ]);
  });

  test('direct Session writes require same-Task Environment and enforce FKs', () {
    final database = _open(backing);
    final project = database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('project'),
    );
    final tasks = [
      for (final id in ['a', 'b'])
        Task(id: TaskId(id), projectId: project.id, title: id),
    ];
    for (final task in tasks) {
      database.insertTaskWithPrimaryEnvironment(
        task,
        _environment(task, id: 'environment-${task.id}'),
      );
    }
    final session = Session(
      id: SessionId('session'),
      taskId: tasks.first.id,
      strategyId: OrchestrationStrategyId('dev.adele.test.strategy'),
    );
    for (final id in ['missing', 'environment-b']) {
      expect(
        () => database.insertSessionWithAuthority(session, EnvironmentId(id)),
        throwsStateError,
      );
      expect(database.loadProductGraph().sessions, isEmpty);
      expect(database.loadProductGraph().authorities, isEmpty);
    }
    final inspection = _connect(database.path)
      ..execute('PRAGMA foreign_keys = ON');
    database.insertSessionWithAuthority(
      session,
      EnvironmentId('environment-a'),
    );
    for (final sql in [
      "INSERT INTO adele_product_sessions VALUES ('orphan', 'missing', 'strategy')",
      "INSERT INTO adele_product_session_environment_authority VALUES ('missing', 'environment-a')",
      "UPDATE adele_product_session_environment_authority SET environment_id = 'missing'",
      "INSERT INTO adele_product_session_environment_authority VALUES ('session', 'environment-a')",
    ]) {
      expect(() => inspection.execute(sql), throwsA(isA<SqliteException>()));
    }
    expect(database.loadProductGraph().sessions.single.id, session.id);
    expect(database.loadProductGraph().authorities, [
      (session.id, EnvironmentId('environment-a')),
    ]);
  });

  test('failed Task commit rolls back both rows and accepts a later retry', () {
    final database = _open(backing);
    final project = database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('project'),
    );
    final task = Task(
      id: TaskId('task'),
      projectId: project.id,
      title: 'Atomic Task',
    );
    final environment = _environment(task);
    final inspection = _connect(database.path);
    inspection.execute('''
      CREATE TABLE deferred_check (
        task_id TEXT REFERENCES adele_product_tasks(id) DEFERRABLE INITIALLY DEFERRED
      );
      CREATE TRIGGER fail_task_commit AFTER INSERT ON adele_product_environments
      BEGIN INSERT INTO deferred_check VALUES ('missing'); END;
    ''');
    expect(
      () => database.insertTaskWithPrimaryEnvironment(task, environment),
      throwsA(isA<SqliteException>()),
    );
    expect(inspection.select('SELECT * FROM adele_product_tasks'), isEmpty);
    expect(
      inspection.select('SELECT * FROM adele_product_environments'),
      isEmpty,
    );
    expect(inspection.select('SELECT * FROM deferred_check'), isEmpty);
    inspection.execute('DROP TRIGGER fail_task_commit');
    database.insertTaskWithPrimaryEnvironment(task, environment);
    expect(database.loadProductGraph().tasks.single.id, task.id);
  });

  test('provisional state is rejected and SQL enforces one primary per Task', () {
    final database = _open(backing);
    final project = database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('project'),
    );
    final task = Task(
      id: TaskId('task'),
      projectId: project.id,
      title: 'One primary',
    );
    final provisional = _environment(task, state: null);
    expect(
      () => database.insertTaskWithPrimaryEnvironment(task, provisional),
      throwsStateError,
    );
    expect(database.loadProductGraph().tasks, isEmpty);
    database.insertTaskWithPrimaryEnvironment(task, _environment(task));
    final inspection = _connect(database.path);
    expect(
      () => inspection.execute(
        "INSERT INTO adele_product_environments VALUES ('second', ?, 'primary', ?, '{}')",
        [task.id.value, provisional.providerId.value],
      ),
      throwsA(isA<SqliteException>()),
    );
    inspection.execute(
      "INSERT INTO adele_product_environments VALUES ('additional', ?, 'additional', ?, '{}')",
      [task.id.value, provisional.providerId.value],
    );
    expect(
      database.loadProductGraph().environments.map((value) => value.role),
      unorderedEquals([EnvironmentRole.primary, EnvironmentRole.additional]),
    );
  });

  test(
    'refresh writes only provider state and requires matching semantic identity',
    () {
      final database = _open(backing);
      final project = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => ProjectId('project'),
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Refresh',
      );
      final original = _environment(task);
      database.insertTaskWithPrimaryEnvironment(task, original);
      final refreshed = _environment(
        task,
        state: {
          'generation': 2,
          'nested': [true, null],
        },
      );
      database.updateEnvironmentState(refreshed);
      final invalid = Environment(
        id: original.id,
        taskId: original.taskId,
        role: EnvironmentRole.additional,
        providerId: original.providerId,
        providerState: {},
      );
      expect(() => database.updateEnvironmentState(invalid), throwsStateError);
      database.close();
      final retained = _open(backing).loadProductGraph().environments.single;
      expect(retained.id, original.id);
      expect(retained.taskId, original.taskId);
      expect(retained.role, original.role);
      expect(retained.providerId, original.providerId);
      expect(retained.providerState, refreshed.providerState);
    },
  );

  for (final corruption in [
    "UPDATE adele_product_tasks SET id = ' invalid'",
    "UPDATE adele_product_tasks SET title = ' '",
    "UPDATE adele_product_environments SET id = ''",
    "UPDATE adele_product_environments SET role = 'unknown'",
    "UPDATE adele_product_environments SET provider_id = 'invalid provider'",
    "UPDATE adele_product_environments SET provider_state_json = 'null'",
    "UPDATE adele_product_environments SET provider_state_json = '[]'",
    "UPDATE adele_product_environments SET provider_state_json = '{broken'",
  ]) {
    test('rejects malformed semantic values: $corruption', () {
      final database = _open(backing);
      final project = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => ProjectId('project'),
      );
      final task = Task(
        id: TaskId('task'),
        projectId: project.id,
        title: 'Valid title',
      );
      database.insertTaskWithPrimaryEnvironment(task, _environment(task));
      _connect(database.path).execute(corruption);
      expect(
        database.loadProductGraph,
        throwsA(
          anyOf(
            isA<FormatException>(),
            isA<ArgumentError>(),
            isA<InvalidCapabilityIdentity>(),
          ),
        ),
      );
    });
  }

  test(
    'allocates once and commits before return, then reopens the identity',
    () {
      int allocations = 0;
      ProjectId nextId() => ProjectId('project-${++allocations}');
      final ProjectDatabase database = _open(backing);
      final Project first = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: nextId,
      );
      final Database inspection = _connect(database.path);
      expect(
        inspection.select('SELECT * FROM adele_product_projects'),
        <Object?>[
          <String, Object?>{
            'id': first.id.value,
            'source_location': source.uri.toString(),
          },
        ],
      );
      expect(
        database
            .openProject(sourceLocation: source.uri, nextProjectId: nextId)
            .id,
        first.id,
      );
      database.close();
      final Project second = _open(
        backing,
      ).openProject(sourceLocation: source.uri, nextProjectId: nextId);
      expect(second.id, first.id);
      expect(second.sourceLocation, source.uri);
      expect(allocations, 1);
    },
  );

  test('moved backing keeps identity and commits the newly selected URI', () {
    final ProjectDatabase original = _open(backing);
    final Project first = original.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('stable-project'),
    );
    original.close();
    final Directory moved = source.renameSync(
      Directory.fromUri(temporary.uri.resolve('moved/')).path,
    );
    final ProjectDatabase reopened = _open(
      ProjectBacking(
        sourceLocation: moved.uri,
        databaseRelativePath: backing.databaseRelativePath,
      ),
    );
    final Project restored = reopened.openProject(
      sourceLocation: moved.uri,
      nextProjectId: _unexpectedAllocation,
    );
    expect(restored.id, first.id);
    expect(restored.sourceLocation, moved.uri);
    expect(
      _connect(reopened.path)
          .select('SELECT source_location FROM adele_product_projects')
          .single['source_location'],
      moved.uri.toString(),
    );
  });

  test('unchanged source does not execute an update', () {
    final ProjectDatabase database = _open(backing);
    database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('p'),
    );
    _connect(database.path).execute('''
      CREATE TRIGGER reject_refresh BEFORE UPDATE ON adele_product_projects
      BEGIN SELECT RAISE(ABORT, 'unexpected refresh'); END;
    ''');
    expect(
      database
          .openProject(
            sourceLocation: source.uri,
            nextProjectId: _unexpectedAllocation,
          )
          .id,
      ProjectId('p'),
    );
  });

  for (final historicalSource in [
    'file:///C:/work/project/',
    'file:///home/user/project/',
  ]) {
    test(
      'historical source can use another platform path: $historicalSource',
      () {
        final database = _open(backing);
        final inspection = _connect(database.path);
        inspection.execute('INSERT INTO adele_product_projects VALUES (?, ?)', [
          'moved-project',
          historicalSource,
        ]);
        final project = database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        );
        expect(project.id, ProjectId('moved-project'));
        expect(project.sourceLocation, source.uri);
        expect(
          inspection
              .select('SELECT source_location FROM adele_product_projects')
              .single['source_location'],
          source.uri.toString(),
        );
      },
    );
  }

  test('separate backings do not share a Project', () {
    final Project first = _open(backing).openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('first'),
    );
    final Project second =
        _open(
          ProjectBacking(
            sourceLocation: source.uri,
            databaseRelativePath: 'other.sqlite',
          ),
        ).openProject(
          sourceLocation: source.uri,
          nextProjectId: () => ProjectId('second'),
        );
    expect(first.id, isNot(second.id));
  });

  test('close is idempotent and subsequent operations fail', () {
    final ProjectDatabase database = _open(backing);
    database.close();
    database.close();
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsStateError,
    );
    _open(backing);
  });

  test('schema initialization preserves unknown owners and their data', () {
    final String path = File.fromUri(source.uri.resolve('shared.sqlite')).path;
    final Database inspection = _connect(path);
    inspection.execute('''
      CREATE TABLE adele_schema_versions (owner_id TEXT PRIMARY KEY, version INTEGER NOT NULL);
      INSERT INTO adele_schema_versions VALUES ('unknown.owner', 900);
      CREATE TABLE unknown_data (value TEXT);
      INSERT INTO unknown_data VALUES ('untouched');
    ''');
    final ProjectBacking shared = ProjectBacking(
      sourceLocation: source.uri,
      databaseRelativePath: 'shared.sqlite',
    );
    _open(shared).close();
    _open(shared).close();
    expect(
      inspection.select(
        'SELECT * FROM adele_schema_versions ORDER BY owner_id',
      ),
      <Object?>[
        <String, Object?>{'owner_id': 'dev.adele.product', 'version': 1},
        <String, Object?>{'owner_id': 'unknown.owner', 'version': 900},
      ],
    );
    expect(
      inspection.select('SELECT value FROM unknown_data').single['value'],
      'untouched',
    );
  });

  test('future core schema is rejected without changing existing bytes', () {
    final ProjectDatabase database = _open(backing);
    database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('p'),
    );
    database.close();
    final Database inspection = _connect(database.path);
    inspection.execute(
      "UPDATE adele_schema_versions SET version = 2 WHERE owner_id = 'dev.adele.product'",
    );
    inspection.close();
    final List<int> before = File(database.path).readAsBytesSync();
    expect(() => ProjectDatabase.open(backing), throwsStateError);
    expect(File(database.path).readAsBytesSync(), before);
  });

  test('schema conflicts do not leave migration metadata behind', () {
    final String path = File.fromUri(
      source.uri.resolve('conflict.sqlite'),
    ).path;
    final Database inspection = _connect(path);
    inspection.execute('CREATE TABLE adele_product_projects (untouched TEXT)');
    expect(
      () => ProjectDatabase.open(
        ProjectBacking(
          sourceLocation: source.uri,
          databaseRelativePath: 'conflict.sqlite',
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      inspection
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((Row row) => row['name']),
      <String>['adele_product_projects'],
    );
  });

  test('sequential migrations roll back schema, data, and owner versions', () {
    final Database database = _connect(
      File.fromUri(source.uri.resolve('migration.sqlite')).path,
    );
    final MigrationCoordinator coordinator = MigrationCoordinator(database);
    final List<void Function(Database)> migrations = <void Function(Database)>[
      (Database db) => db.execute('CREATE TABLE synthetic (value TEXT)'),
      (Database db) {
        db.execute("INSERT INTO synthetic VALUES ('not committed')");
        throw StateError('synthetic migration failure');
      },
    ];
    expect(
      () => coordinator.migrate(ownerId: 'test.owner', migrations: migrations),
      throwsStateError,
    );
    expect(database.autocommit, isTrue);
    expect(
      database.select("SELECT name FROM sqlite_master WHERE type = 'table'"),
      isEmpty,
    );

    migrations[1] = (Database db) =>
        db.execute("INSERT INTO synthetic VALUES ('committed')");
    coordinator.migrate(ownerId: 'test.owner', migrations: migrations);
    expect(
      database
          .select('SELECT version FROM adele_schema_versions')
          .single['version'],
      2,
    );
    expect(
      database.select('SELECT value FROM synthetic').single['value'],
      'committed',
    );
    coordinator.migrate(ownerId: 'test.owner', migrations: migrations);
    expect(database.select('SELECT * FROM synthetic'), hasLength(1));

    migrations.add((Database db) {
      db.execute('ALTER TABLE synthetic ADD COLUMN rolled_back TEXT');
      db.execute("UPDATE synthetic SET value = 'changed'");
      throw StateError('upgrade failure');
    });
    expect(
      () => coordinator.migrate(ownerId: 'test.owner', migrations: migrations),
      throwsStateError,
    );
    expect(
      database
          .select('SELECT version FROM adele_schema_versions')
          .single['version'],
      2,
    );
    expect(
      database.select('SELECT value FROM synthetic').single['value'],
      'committed',
    );
    expect(database.select('PRAGMA table_info(synthetic)'), hasLength(1));
    expect(
      () => coordinator.migrate(
        ownerId: 'test.owner',
        migrations: migrations.take(1).toList(),
      ),
      throwsStateError,
    );
    expect(
      database
          .select('SELECT version FROM adele_schema_versions')
          .single['version'],
      2,
    );
  });

  for (final Object? invalidVersion in <Object?>[-1, 'invalid', 1.5]) {
    test('rejects malformed owner version $invalidVersion', () {
      final ProjectDatabase database = _open(backing)..close();
      final Database inspection = _connect(database.path);
      inspection.execute(
        'UPDATE adele_schema_versions SET version = ?',
        <Object?>[invalidVersion],
      );
      expect(() => ProjectDatabase.open(backing), throwsFormatException);
      expect(
        inspection
            .select('SELECT version FROM adele_schema_versions')
            .single['version'],
        invalidVersion,
      );
    });
  }

  for (final Object? invalidId in <Object?>[
    '',
    ' leading',
    'trailing ',
    null,
    Uint8List.fromList(<int>[1, 2]),
  ]) {
    test('rejects malformed persisted Project ID $invalidId', () {
      final ProjectDatabase database = _open(backing);
      final Database inspection = _connect(database.path);
      inspection.execute(
        'INSERT INTO adele_product_projects VALUES (?, ?)',
        <Object?>[invalidId, source.uri.toString()],
      );
      expect(
        () => database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        ),
        throwsFormatException,
      );
      expect(
        inspection.select('SELECT * FROM adele_product_projects'),
        hasLength(1),
      );
    });
  }

  for (final String invalidSource in <String>[
    '',
    'relative/path',
    'https://example.com/source/',
    'file://remote/source/',
    'file:////server/share/source/',
    'file:///source/?query',
    'file:///source/#fragment',
    'file:///source/%00',
    'file:///source/%2Fescape',
    'file:///source/%5Cescape',
    'file:///invalid%escape',
    ' file:///source/',
  ]) {
    test('rejects persisted source $invalidSource instead of repairing it', () {
      final ProjectDatabase database = _open(backing);
      final Database inspection = _connect(database.path);
      inspection.execute(
        'INSERT INTO adele_product_projects VALUES (?, ?)',
        <Object?>['p', invalidSource],
      );
      expect(
        () => database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        ),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
      expect(
        inspection
            .select('SELECT source_location FROM adele_product_projects')
            .single['source_location'],
        invalidSource,
      );
    });
  }

  test('rejects multiple Projects without allocating or modifying data', () {
    final ProjectDatabase database = _open(backing);
    final Database inspection = _connect(database.path);
    for (final String id in <String>['first', 'second']) {
      inspection.execute(
        'INSERT INTO adele_product_projects VALUES (?, ?)',
        <Object?>[id, source.uri.toString()],
      );
    }
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsStateError,
    );
    expect(
      inspection.select('SELECT * FROM adele_product_projects'),
      hasLength(2),
    );
  });

  test('failed allocation rolls back and allows a later attempt', () {
    final ProjectDatabase database = _open(backing);
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => throw StateError('allocation failure'),
      ),
      throwsStateError,
    );
    expect(
      _connect(database.path).select('SELECT * FROM adele_product_projects'),
      isEmpty,
    );
    expect(
      database
          .openProject(
            sourceLocation: source.uri,
            nextProjectId: () => ProjectId('retry'),
          )
          .id,
      ProjectId('retry'),
    );
  });

  test('foreign keys are enabled and failed commit returns no Project', () {
    final ProjectDatabase database = _open(backing);
    final Database inspection = _connect(database.path);
    inspection.execute('''
      CREATE TABLE deferred_check (
        project_id TEXT REFERENCES adele_product_projects(id) DEFERRABLE INITIALLY DEFERRED
      );
      CREATE TRIGGER fail_commit AFTER INSERT ON adele_product_projects
      BEGIN INSERT INTO deferred_check VALUES ('missing'); END;
    ''');
    Project? result;
    expect(
      () => result = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => ProjectId('p'),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(result, isNull);
    expect(inspection.select('SELECT * FROM adele_product_projects'), isEmpty);
    expect(inspection.select('SELECT * FROM deferred_check'), isEmpty);
    inspection.execute('DROP TRIGGER fail_commit');
    expect(
      database
          .openProject(
            sourceLocation: source.uri,
            nextProjectId: () => ProjectId('retry'),
          )
          .id,
      ProjectId('retry'),
    );
  });

  test('failed source refresh rolls back instead of returning a Project', () {
    final ProjectDatabase database = _open(backing);
    final Database inspection = _connect(database.path);
    final String previousSource = temporary.uri.resolve('previous/').toString();
    inspection.execute(
      'INSERT INTO adele_product_projects VALUES (?, ?)',
      <Object?>['p', previousSource],
    );
    inspection.execute('''
      CREATE TRIGGER reject_refresh BEFORE UPDATE ON adele_product_projects
      BEGIN SELECT RAISE(ABORT, 'refresh failure'); END;
    ''');
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      inspection
          .select('SELECT source_location FROM adele_product_projects')
          .single['source_location'],
      previousSource,
    );
  });

  for (final String invalidPath in <String>[
    '',
    '/',
    '/absolute.sqlite',
    '../escape.sqlite',
    'state/../../escape.sqlite',
    './db.sqlite',
    'state/./db.sqlite',
    'state//db.sqlite',
    'state/',
    r'..\escape.sqlite',
    r'state\..\escape.sqlite',
    r'C:\escape.sqlite',
    'C:/escape.sqlite',
    'C:escape.sqlite',
    '//server/share/db.sqlite',
    r'\\server\share\db.sqlite',
    r'\\?\C:\escape.sqlite',
    'file:///escape.sqlite',
    'state/%2e%2e/escape.sqlite',
    'state/%2fescape.sqlite',
    'state/%252e%252e/db.sqlite',
    'state/db.sqlite?mode=ro',
    'state/db.sqlite#part',
    'state/db.sqlite:stream',
    'state/.. /escape.sqlite',
    'state/.../escape.sqlite',
    'state/db.sqlite.',
    'state/db.sqlite ',
    'state/\x00db.sqlite',
    'NUL',
    'CON.sqlite',
  ]) {
    test('rejects non-confined or nonportable placement $invalidPath', () {
      expect(
        () => ProjectDatabase.open(
          ProjectBacking(
            sourceLocation: source.uri,
            databaseRelativePath: invalidPath,
          ),
        ),
        throwsArgumentError,
      );
      expect(source.listSync(), isEmpty);
    });
  }

  test('supports spaces and a source URI without a trailing slash', () {
    final Directory spaced = Directory.fromUri(
      temporary.uri.resolve('source%20space/'),
    )..createSync();
    final Uri selected = Uri.file(spaced.path);
    final ProjectDatabase database = _open(
      ProjectBacking(
        sourceLocation: selected,
        databaseRelativePath: 'state space/database.sqlite',
      ),
    );
    final Project project = database.openProject(
      sourceLocation: selected,
      nextProjectId: () => ProjectId('p'),
    );
    expect(project.sourceLocation, selected);
    expect(File(database.path).existsSync(), isTrue);
  });

  test('rejects invalid, nonexistent, and non-directory source locations', () {
    final File file = File.fromUri(temporary.uri.resolve('not-a-directory'))
      ..writeAsStringSync('unchanged');
    for (final Uri uri in <Uri>[
      Uri.parse('relative/'),
      Uri.parse('https://example.com/source/'),
      Uri.parse('file://remote/source/'),
      source.uri.replace(query: 'query'),
      source.uri.replace(fragment: 'fragment'),
      temporary.uri.resolve('missing/'),
      file.uri,
      if (!Platform.isWindows) Uri.parse('file:///C:/Windows/'),
    ]) {
      expect(
        () => ProjectDatabase.open(
          ProjectBacking(
            sourceLocation: uri,
            databaseRelativePath: 'db.sqlite',
          ),
        ),
        throwsA(anyOf(isA<ArgumentError>(), isA<FileSystemException>())),
      );
    }
    expect(file.readAsStringSync(), 'unchanged');
    expect(source.listSync(), isEmpty);
  });

  test('empty-authority UNC syntax fails before filesystem access', () {
    final uri = Uri.parse('file:////server/share/source/');
    expect(uri.authority, isEmpty);
    expect(
      () => ProjectDatabase.open(
        ProjectBacking(sourceLocation: uri, databaseRelativePath: 'db.sqlite'),
      ),
      throwsArgumentError,
    );
    expect(source.listSync(), isEmpty);
  });

  test('does not refresh to an unrelated directory', () {
    final ProjectDatabase database = _open(backing);
    expect(
      () => database.openProject(
        sourceLocation: temporary.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsArgumentError,
    );
    expect(
      _connect(database.path).select('SELECT * FROM adele_product_projects'),
      isEmpty,
    );
  });

  test('rejects a file in place of a parent or database directory', () {
    File.fromUri(source.uri.resolve('parent')).writeAsStringSync('unchanged');
    Directory.fromUri(source.uri.resolve('directory.sqlite/')).createSync();
    for (final String relative in <String>[
      'parent/db.sqlite',
      'directory.sqlite',
    ]) {
      expect(
        () => ProjectDatabase.open(
          ProjectBacking(
            sourceLocation: source.uri,
            databaseRelativePath: relative,
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
    }
  });

  for (final bool outside in <bool>[false, true]) {
    test(
      'rejects ${outside ? 'escaping' : 'in-root'} backing parent symlinks',
      () {
        final Directory target = Directory.fromUri(
          (outside ? temporary : source).uri.resolve('target/'),
        )..createSync();
        Link.fromUri(source.uri.resolve('link')).createSync(target.path);
        expect(
          () => ProjectDatabase.open(
            ProjectBacking(
              sourceLocation: source.uri,
              databaseRelativePath: 'link/nested/db.sqlite',
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(target.listSync(), isEmpty);
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires Windows privileges.'
          : false,
    );
  }

  for (final String suffix in <String>['', '-journal', '-wal', '-shm']) {
    test(
      'rejects database or sidecar symlink "$suffix" without writing outside',
      () {
        final File outside = File.fromUri(temporary.uri.resolve('outside'))
          ..writeAsStringSync('untouched');
        Link.fromUri(
          source.uri.resolve('db.sqlite$suffix'),
        ).createSync(outside.path);
        expect(
          () => ProjectDatabase.open(
            ProjectBacking(
              sourceLocation: source.uri,
              databaseRelativePath: 'db.sqlite',
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(outside.readAsStringSync(), 'untouched');
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires Windows privileges.'
          : false,
    );
  }

  test(
    'rejects dangling links and rechecks sidecars before writes',
    () {
      final ProjectDatabase database = _open(backing);
      final String missing = File.fromUri(
        temporary.uri.resolve('missing'),
      ).path;
      final Link sidecar = Link('${database.path}-wal')..createSync(missing);
      expect(
        () => database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        ),
        throwsA(isA<FileSystemException>()),
      );
      database.close();
      expect(
        () => ProjectDatabase.open(backing),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(missing).existsSync(), isFalse);
      sidecar.deleteSync();
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires Windows privileges.'
        : false,
  );

  test(
    'source aliases resolve to the same physical database path',
    () {
      final Link alias = Link.fromUri(temporary.uri.resolve('alias'))
        ..createSync(source.path);
      final ProjectDatabase first = _open(backing);
      final ProjectDatabase second = _open(
        ProjectBacking(
          sourceLocation: Directory(alias.path).uri,
          databaseRelativePath: backing.databaseRelativePath,
        ),
      );
      expect(second.path, first.path);
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires Windows privileges.'
        : false,
  );
}

ProjectDatabase _open(ProjectBacking backing) {
  final ProjectDatabase database = ProjectDatabase.open(backing);
  addTearDown(database.close);
  return database;
}

Database _connect(String path) {
  final Database database = sqlite3.open(path);
  addTearDown(database.close);
  return database;
}

ProjectId _unexpectedAllocation() =>
    throw TestFailure('Unexpected Project ID allocation.');

Environment _environment(
  Task task, {
  String id = 'environment',
  Map<String, Object?>? state = const {'generation': 1},
}) => Environment(
  id: EnvironmentId(id),
  taskId: task.id,
  role: EnvironmentRole.primary,
  providerId: ProviderId('dev.adele.test.environment'),
  providerState: state,
);
