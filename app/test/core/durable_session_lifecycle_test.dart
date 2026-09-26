import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

final _projectProviderId = ProviderId('dev.adele.test.project');
final _environmentProviderId = ProviderId('dev.adele.test.environment');
final _strategyId = OrchestrationStrategyId('dev.adele.test.strategy');

void main() {
  late Directory source;
  late Project project;
  late List<Task> tasks;
  late List<Environment> environments;
  late List<Session> sessions;
  late List<(SessionId, EnvironmentId)> authorities;
  late List<RunRecord> runRecords;
  late Database inspection;

  setUp(() {
    source = Directory.systemTemp.createTempSync('adele-durable-session-');
    addTearDown(() => source.deleteSync(recursive: true));
    final backing = ProjectBacking(
      sourceLocation: source.uri,
      databaseRelativePath: 'data.db',
    );
    final database = ProjectDatabase.open(backing);
    addTearDown(database.close);
    project = database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('project'),
    );
    tasks = [
      for (final id in ['a', 'b'])
        Task(id: TaskId('task-$id'), projectId: project.id, title: 'Task $id'),
    ];
    environments = [
      for (final task in tasks)
        Environment(
          id: EnvironmentId('environment-${task.id}'),
          taskId: task.id,
          role: EnvironmentRole.primary,
          providerId: _environmentProviderId,
          providerState: {'retained': task.id.value},
        ),
    ];
    sessions = [
      for (final task in tasks)
        Session(
          id: SessionId('session-${task.id}'),
          taskId: task.id,
          strategyId: _strategyId,
        ),
    ];
    authorities = [
      for (var i = 0; i < tasks.length; i++)
        (sessions[i].id, environments[i].id),
    ];
    for (var i = 0; i < tasks.length; i++) {
      database.insertTaskWithPrimaryEnvironment(tasks[i], environments[i]);
      database.insertSessionWithAuthority(sessions[i], environments[i].id);
    }
    runRecords = [
      for (final state in RunTerminalState.values)
        RunRecord(
          id: RunId('run-${state.name}'),
          sessionId: state == RunTerminalState.cancelled
              ? sessions.last.id
              : sessions.first.id,
          state: state,
        ),
    ];
    for (final record in runRecords) {
      database.insertTerminalRun(record);
    }
    database.close();
    inspection = sqlite3.open(database.path);
    addTearDown(inspection.close);
  });

  Future<Project> open(ProductLifecycleCoordinator lifecycle) =>
      lifecycle.openProject(
        sourceLocation: source.uri,
        provider: lifecycle.resolveProjectProvider(_projectProviderId),
      );

  void expectUnpublished(ProductLifecycleCoordinator lifecycle) {
    expect(lifecycle.store.project(project.id), isNull);
    expect(lifecycle.store.tasksFor(project.id), isEmpty);
    for (final task in tasks) {
      expect(lifecycle.store.task(task.id), isNull);
      expect(lifecycle.store.primaryEnvironmentFor(task.id), isNull);
    }
    for (final environment in environments) {
      expect(lifecycle.store.environment(environment.id), isNull);
      expect(
        lifecycle.environmentRuntime.currentMaterialization(environment.id),
        isNull,
      );
    }
    for (final session in sessions) {
      expect(lifecycle.store.session(session.id), isNull);
      expect(lifecycle.store.sessionAuthority(session.id), isNull);
      expect(lifecycle.store.runsForSession(session.id), isEmpty);
    }
    for (final record in runRecords) {
      expect(lifecycle.store.runRecord(record.id), isNull);
    }
  }

  test(
    'reopen restores full graph without IDs, strategy, or materialization',
    () async {
      final before = _snapshot(inspection);
      final lifecycle = _lifecycle();
      final reopened = await open(lifecycle);
      expect(reopened.id, project.id);
      expect(reopened.sourceLocation, project.sourceLocation);
      expect(
        lifecycle.store.tasksFor(project.id).map((task) => task.id),
        tasks.map((task) => task.id),
      );
      for (var i = 0; i < sessions.length; i++) {
        final task = lifecycle.store.task(tasks[i].id)!;
        expect(task.projectId, project.id);
        expect(task.title, tasks[i].title);
        final environment = lifecycle.store.environment(environments[i].id)!;
        expect(environment.taskId, task.id);
        expect(environment.providerId, environments[i].providerId);
        expect(environment.role, EnvironmentRole.primary);
        expect(environment.providerState, environments[i].providerState);
        final session = lifecycle.store.session(sessions[i].id)!;
        expect(session.taskId, task.id);
        expect(session.strategyId, _strategyId);
        final authority = lifecycle.store.requireSessionAuthority(session.id);
        expect(authority.sessionId, session.id);
        expect(authority.taskId, task.id);
        expect(authority.environmentId, environment.id);
        expect(
          lifecycle.environmentRuntime.currentMaterialization(environment.id),
          isNull,
        );
        expect(
          () => lifecycle.resolveSessionStrategy(session.id),
          throwsA(isA<OrchestrationStrategyUnavailable>()),
        );
        await expectLater(
          lifecycle.environmentRuntime.materialize(environment.id),
          throwsA(isA<CapabilityUnavailable>()),
        );
        expect(lifecycle.store.session(session.id), same(session));
        expect(lifecycle.store.sessionAuthority(session.id), same(authority));
        expect(
          lifecycle.environmentRuntime.currentMaterialization(environment.id),
          isNull,
        );
      }
      for (final record in runRecords) {
        final restored = lifecycle.store.runRecord(record.id)!;
        expect(restored.sessionId, record.sessionId);
        expect(restored.state, record.state);
      }
      for (final session in sessions) {
        expect(
          lifecycle.store.runsForSession(session.id).map((record) => record.id),
          unorderedEquals(
            runRecords
                .where((record) => record.sessionId == session.id)
                .map((record) => record.id),
          ),
        );
      }
      expect(await open(lifecycle), same(reopened));
      expect(_snapshot(inspection), before);
    },
  );

  test(
    'creation commits primary and explicit additional authority before return',
    () async {
      final additionalId = EnvironmentId('additional');
      inspection.execute(
        "INSERT INTO adele_product_environments VALUES (?, ?, 'additional', ?, '{}')",
        [
          additionalId.value,
          tasks.first.id.value,
          _environmentProviderId.value,
        ],
      );
      final extensions = ExtensionRegistry();
      _registerStrategy(extensions);
      var allocations = 0;
      final lifecycle = _lifecycle(
        extensions: extensions,
        ids: _Ids(() => SessionId('created-${++allocations}')),
      );
      await open(lifecycle);
      final created = [
        lifecycle.createSession(
          taskId: tasks.first.id,
          strategyId: _strategyId,
        ),
        lifecycle.createSession(
          taskId: tasks.first.id,
          strategyId: _strategyId,
          environmentId: additionalId,
        ),
      ];
      final expectedEnvironments = [environments.first.id, additionalId];
      for (var i = 0; i < created.length; i++) {
        final session = created[i];
        expect(lifecycle.store.session(session.id), same(session));
        final authority = lifecycle.store.requireSessionAuthority(session.id);
        expect(authority.taskId, tasks.first.id);
        expect(authority.environmentId, expectedEnvironments[i]);
        expect(
          inspection.select(
            'SELECT * FROM adele_product_sessions WHERE id = ?',
            [session.id.value],
          ),
          [
            {
              'id': session.id.value,
              'task_id': tasks.first.id.value,
              'strategy_id': _strategyId.value,
            },
          ],
        );
        expect(
          inspection.select(
            'SELECT environment_id FROM adele_product_session_environment_authority WHERE session_id = ?',
            [session.id.value],
          ).single['environment_id'],
          expectedEnvironments[i].value,
        );
        expect(
          lifecycle.environmentRuntime.currentMaterialization(
            expectedEnvironments[i],
          ),
          isNull,
        );
      }
      await lifecycle.close();
      final fresh = _lifecycle();
      await open(fresh);
      for (var i = 0; i < created.length; i++) {
        expect(fresh.store.session(created[i].id)!.strategyId, _strategyId);
        expect(
          fresh.store.requireSessionAuthority(created[i].id).environmentId,
          expectedEnvironments[i],
        );
      }
    },
  );

  test(
    'failed Session COMMIT publishes neither identity nor authority',
    () async {
      final extensions = ExtensionRegistry();
      _registerStrategy(extensions);
      final id = SessionId('new-session');
      final lifecycle = _lifecycle(extensions: extensions, ids: _Ids(() => id));
      await open(lifecycle);
      final before = _snapshot(inspection);
      inspection.execute('''
        CREATE TABLE deferred_check (
          session_id TEXT REFERENCES adele_product_sessions(id) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TRIGGER fail_session_commit AFTER INSERT ON adele_product_session_environment_authority
        BEGIN INSERT INTO deferred_check VALUES ('missing'); END;
      ''');
      expect(
        () => lifecycle.createSession(
          taskId: tasks.first.id,
          strategyId: _strategyId,
        ),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.causingStatement,
            'causingStatement',
            'COMMIT',
          ),
        ),
      );
      expect(lifecycle.store.session(id), isNull);
      expect(lifecycle.store.sessionAuthority(id), isNull);
      expect(_snapshot(inspection), before);
      expect(inspection.select('SELECT * FROM deferred_check'), isEmpty);
      inspection.execute('DROP TRIGGER fail_session_commit');
      final retried = lifecycle.createSession(
        taskId: tasks.first.id,
        strategyId: _strategyId,
      );
      expect(lifecycle.store.session(id), same(retried));
      expect(
        lifecycle.store.requireSessionAuthority(id).environmentId,
        environments.first.id,
      );
    },
  );

  test(
    'creation validates selection, revalidates strategy, and rejects live conflicts before SQL',
    () async {
      final extensions = ExtensionRegistry();
      _registerStrategy(extensions);
      var allocations = 0;
      final lifecycle = _lifecycle(
        extensions: extensions,
        ids: _Ids(() {
          allocations++;
          return sessions.first.id;
        }),
      );
      await open(lifecycle);
      final before = _snapshot(inspection);
      final existing = lifecycle.store.session(sessions.first.id);
      final authority = lifecycle.store.requireSessionAuthority(
        sessions.first.id,
      );
      inspection.execute('''
        CREATE TRIGGER reject_session_insert BEFORE INSERT ON adele_product_sessions
        BEGIN SELECT RAISE(ABORT, 'unexpected SQL'); END;
      ''');
      for (final (taskId, environmentId) in [
        (TaskId('missing'), null),
        (tasks.first.id, EnvironmentId('missing')),
        (tasks.first.id, environments.last.id),
      ]) {
        expect(
          () => lifecycle.createSession(
            taskId: taskId,
            strategyId: _strategyId,
            environmentId: environmentId,
          ),
          throwsStateError,
        );
      }
      expect(
        () => lifecycle.createSession(
          taskId: tasks.first.id,
          strategyId: OrchestrationStrategyId('unavailable'),
        ),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
      expect(allocations, 0);
      expect(
        () => lifecycle.createSession(
          taskId: tasks.first.id,
          strategyId: _strategyId,
        ),
        throwsStateError,
      );
      expect(allocations, 1);
      expect(lifecycle.store.session(sessions.first.id), same(existing));
      expect(
        lifecycle.store.sessionAuthority(sessions.first.id),
        same(authority),
      );

      final newId = SessionId('new-session');
      final revalidating = _lifecycle(
        extensions: extensions,
        ids: _Ids(() {
          _registerStrategy(extensions, id: 'dev.adele.test.duplicate');
          return newId;
        }),
      );
      await open(revalidating);
      expect(
        () => revalidating.createSession(
          taskId: tasks.first.id,
          strategyId: _strategyId,
        ),
        throwsA(isA<AmbiguousOrchestrationStrategy>()),
      );
      expect(revalidating.store.session(newId), isNull);
      expect(revalidating.store.sessionAuthority(newId), isNull);
      expect(_snapshot(inspection), before);
    },
  );

  test(
    'terminal retention commits and reopens without live execution',
    () async {
      final lifecycle = _lifecycle();
      await open(lifecycle);
      final record = RunRecord(
        id: RunId('retained'),
        sessionId: sessions.first.id,
        state: RunTerminalState.completed,
      );
      lifecycle.retainTerminalRun(record);
      expect(lifecycle.store.runRecord(record.id), same(record));
      expect(
        lifecycle.databaseForSession(record.sessionId)!.autocommit,
        isTrue,
      );
      expect(
        inspection.select('SELECT * FROM adele_product_runs WHERE id = ?', [
          record.id.value,
        ]),
        [
          {
            'id': record.id.value,
            'session_id': record.sessionId.value,
            'terminal_state': record.state.name,
          },
        ],
      );
      await lifecycle.close();
      final fresh = _lifecycle();
      await open(fresh);
      final restored = fresh.store.runRecord(record.id)!;
      expect(restored.sessionId, record.sessionId);
      expect(restored.state, record.state);
      expect(
        fresh.environmentRuntime.currentMaterialization(environments.first.id),
        isNull,
      );
    },
  );

  test(
    'failed Run COMMIT publishes nothing and restores autocommit for retry',
    () async {
      final lifecycle = _lifecycle();
      await open(lifecycle);
      final record = RunRecord(
        id: RunId('retained'),
        sessionId: sessions.first.id,
        state: RunTerminalState.failed,
      );
      final database = lifecycle.databaseForSession(record.sessionId)!;
      final before = _snapshot(inspection);
      final liveBefore = lifecycle.store.runsForSession(record.sessionId);
      inspection.execute('''
      CREATE TABLE deferred_check (
        session_id TEXT REFERENCES adele_product_sessions(id) DEFERRABLE INITIALLY DEFERRED
      );
      CREATE TRIGGER fail_run_commit AFTER INSERT ON adele_product_runs
      BEGIN INSERT INTO deferred_check VALUES ('missing'); END;
    ''');
      expect(
        () => lifecycle.retainTerminalRun(record),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.causingStatement,
            'causingStatement',
            'COMMIT',
          ),
        ),
      );
      expect(database.autocommit, isTrue);
      expect(lifecycle.store.runRecord(record.id), isNull);
      expect(lifecycle.store.runsForSession(record.sessionId), liveBefore);
      expect(_snapshot(inspection), before);
      expect(inspection.select('SELECT * FROM deferred_check'), isEmpty);
      inspection.execute('DROP TRIGGER fail_run_commit');
      lifecycle.retainTerminalRun(record);
      expect(database.autocommit, isTrue);
      expect(lifecycle.store.runRecord(record.id), same(record));
      expect(
        database.loadProductGraph().runRecords.map((value) => value.id),
        contains(record.id),
      );
    },
  );

  test(
    'terminal retention prevalidates canonical Session and live IDs before SQL',
    () async {
      final lifecycle = _lifecycle();
      await open(lifecycle);
      final before = _snapshot(inspection);
      final existing = lifecycle.store.runRecord(runRecords.first.id);
      inspection.execute('''
      CREATE TRIGGER reject_run_insert BEFORE INSERT ON adele_product_runs
      BEGIN SELECT RAISE(ABORT, 'unexpected SQL'); END;
    ''');
      for (final record in [
        RunRecord(
          id: RunId('orphan'),
          sessionId: SessionId('missing'),
          state: RunTerminalState.completed,
        ),
        RunRecord(
          id: runRecords.first.id,
          sessionId: sessions.last.id,
          state: RunTerminalState.cancelled,
        ),
      ]) {
        expect(() => lifecycle.retainTerminalRun(record), throwsStateError);
      }
      expect(lifecycle.store.runRecord(RunId('orphan')), isNull);
      expect(lifecycle.store.runRecord(runRecords.first.id), same(existing));
      expect(_snapshot(inspection), before);
    },
  );

  test(
    'closed durable database never falls back to volatile Run retention',
    () async {
      final lifecycle = _lifecycle();
      await open(lifecycle);
      final record = RunRecord(
        id: RunId('closed'),
        sessionId: sessions.first.id,
        state: RunTerminalState.cancelled,
      );
      final before = _snapshot(inspection);
      lifecycle.databaseForSession(record.sessionId)!.close();
      expect(() => lifecycle.retainTerminalRun(record), throwsStateError);
      expect(lifecycle.store.runRecord(record.id), isNull);
      expect(_snapshot(inspection), before);
    },
  );

  test('terminal retention stops as soon as lifecycle close begins', () async {
    final lifecycle = _lifecycle();
    await open(lifecycle);
    final record = RunRecord(
      id: RunId('closing'),
      sessionId: sessions.first.id,
      state: RunTerminalState.cancelled,
    );
    final before = _snapshot(inspection);
    final closing = lifecycle.close();
    expect(() => lifecycle.retainTerminalRun(record), throwsStateError);
    await closing;
    expect(() => lifecycle.retainTerminalRun(record), throwsStateError);
    expect(lifecycle.store.runRecord(record.id), isNull);
    expect(_snapshot(inspection), before);
  });

  test(
    'store Run snapshots are immutable and publication rejects orphans and duplicates',
    () async {
      final lifecycle = _lifecycle();
      await open(lifecycle);
      final store = lifecycle.store;
      final before = store.runsForSession(sessions.first.id);
      final record = RunRecord(
        id: RunId('local'),
        sessionId: sessions.first.id,
        state: RunTerminalState.completed,
      );
      expect(() => before.add(record), throwsUnsupportedError);
      expect(() => before.clear(), throwsUnsupportedError);
      store.publishTerminalRun(record);
      expect(store.runRecord(record.id), same(record));
      expect(before.map((value) => value.id), isNot(contains(record.id)));
      expect(
        store.runsForSession(sessions.first.id),
        unorderedEquals([...before, record]),
      );
      for (final duplicate in [
        record,
        RunRecord(
          id: record.id,
          sessionId: sessions.last.id,
          state: RunTerminalState.failed,
        ),
      ]) {
        expect(() => store.publishTerminalRun(duplicate), throwsStateError);
      }
      final orphan = RunRecord(
        id: RunId('orphan'),
        sessionId: SessionId('missing'),
        state: RunTerminalState.failed,
      );
      expect(() => store.publishTerminalRun(orphan), throwsStateError);
      expect(store.runRecord(orphan.id), isNull);
      expect(store.runsForSession(orphan.sessionId), isEmpty);
      expect(store.runRecord(record.id), same(record));
    },
  );

  test('explicit createProject keeps Session and Run retention volatile', () {
    final extensions = ExtensionRegistry();
    _registerStrategy(extensions);
    final lifecycle = _lifecycle(
      extensions: extensions,
      ids: MonotonicProductIdSource(seed: 'volatile'),
    );
    final before = _snapshot(inspection);
    final volatile = lifecycle.createProject(source.uri);
    final task = Task(
      id: tasks.first.id,
      projectId: volatile.id,
      title: 'Volatile',
    );
    lifecycle.store.publishTaskWithPrimaryEnvironment(task, environments.first);
    final session = lifecycle.createSession(
      taskId: task.id,
      strategyId: _strategyId,
    );
    expect(lifecycle.store.session(session.id), same(session));
    expect(
      lifecycle.store.requireSessionAuthority(session.id).environmentId,
      environments.first.id,
    );
    final record = RunRecord(
      id: RunId('volatile'),
      sessionId: session.id,
      state: RunTerminalState.cancelled,
    );
    expect(lifecycle.databaseForSession(session.id), isNull);
    lifecycle.retainTerminalRun(record);
    expect(lifecycle.store.runRecord(record.id), same(record));
    expect(lifecycle.store.runsForSession(session.id), [record]);
    expect(_snapshot(inspection), before);
  });

  for (final (name, sql, error) in [
    (
      'invalid Run ID',
      "UPDATE adele_product_runs SET id = ' invalid' WHERE id = 'run-cancelled'",
      isA<FormatException>(),
    ),
    (
      'invalid Run Session ID',
      "UPDATE adele_product_runs SET session_id = '' WHERE id = 'run-cancelled'",
      isA<FormatException>(),
    ),
    (
      'orphan Run',
      "UPDATE adele_product_runs SET session_id = 'missing' WHERE id = 'run-cancelled'",
      isA<StateError>(),
    ),
    (
      'invalid Run state',
      "PRAGMA ignore_check_constraints = ON; UPDATE adele_product_runs SET terminal_state = 'running' WHERE id = 'run-cancelled'",
      isA<ArgumentError>(),
    ),
    (
      'invalid Session ID',
      "UPDATE adele_product_sessions SET id = ' invalid' WHERE id = 'session-task-b'",
      isA<FormatException>(),
    ),
    (
      'invalid strategy ID',
      "UPDATE adele_product_sessions SET strategy_id = '' WHERE id = 'session-task-b'",
      isA<FormatException>(),
    ),
    (
      'invalid Task ID',
      "UPDATE adele_product_sessions SET task_id = '' WHERE id = 'session-task-b'",
      isA<FormatException>(),
    ),
    (
      'invalid authority Session ID',
      "UPDATE adele_product_session_environment_authority SET session_id = '' WHERE session_id = 'session-task-b'",
      isA<FormatException>(),
    ),
    (
      'invalid authority Environment ID',
      "UPDATE adele_product_session_environment_authority SET environment_id = ' invalid' WHERE session_id = 'session-task-b'",
      isA<FormatException>(),
    ),
    (
      'missing Task',
      "UPDATE adele_product_sessions SET task_id = 'missing' WHERE id = 'session-task-b'",
      isA<StateError>(),
    ),
    (
      'missing Environment',
      "UPDATE adele_product_session_environment_authority SET environment_id = 'missing' WHERE session_id = 'session-task-b'",
      isA<StateError>(),
    ),
    (
      'wrong-Task authority',
      "UPDATE adele_product_session_environment_authority SET environment_id = 'environment-task-a' WHERE session_id = 'session-task-b'",
      isA<StateError>(),
    ),
    (
      'missing authority',
      "DELETE FROM adele_product_session_environment_authority WHERE session_id = 'session-task-b'",
      isA<StateError>(),
    ),
    (
      'orphan authority',
      "INSERT INTO adele_product_session_environment_authority VALUES ('orphan', 'environment-task-b')",
      isA<StateError>(),
    ),
  ]) {
    test('loading $name publishes no partial graph', () async {
      inspection.execute(sql);
      final before = _snapshot(inspection);
      final lifecycle = _lifecycle();
      await expectLater(open(lifecycle), throwsA(error));
      expectUnpublished(lifecycle);
      expect(_snapshot(inspection), before);
    });
  }

  for (final duplicate in [
    'Task',
    'Environment',
    'Session',
    'authority',
    'Run',
  ]) {
    test('duplicate restored $duplicate publishes no partial graph', () {
      final lifecycle = _lifecycle();
      expect(
        () => lifecycle.store.publishRestoredProject(
          project: project,
          tasks: [...tasks, if (duplicate == 'Task') tasks.last],
          environments: [
            ...environments,
            if (duplicate == 'Environment') environments.last,
          ],
          sessions: [...sessions, if (duplicate == 'Session') sessions.last],
          authorities: [
            ...authorities,
            if (duplicate == 'authority') authorities.last,
          ],
          runRecords: [...runRecords, if (duplicate == 'Run') runRecords.last],
        ),
        throwsStateError,
      );
      expectUnpublished(lifecycle);
    });
  }

  for (final conflict in ['Session', 'Run']) {
    test(
      'live $conflict conflict preserves existing graph and publishes none of the restored graph',
      () async {
        final lifecycle = _lifecycle();
        final existingProject = Project(
          id: ProjectId('existing'),
          sourceLocation: source.uri,
        );
        final existingTask = Task(
          id: TaskId('existing'),
          projectId: existingProject.id,
          title: 'Existing',
        );
        final existingEnvironment = Environment(
          id: EnvironmentId('existing'),
          taskId: existingTask.id,
          role: EnvironmentRole.primary,
          providerId: _environmentProviderId,
          providerState: {},
        );
        final existingSession = Session(
          id: conflict == 'Session' ? sessions.last.id : SessionId('existing'),
          taskId: existingTask.id,
          strategyId: _strategyId,
        );
        final existingRun = RunRecord(
          id: conflict == 'Run' ? runRecords.last.id : RunId('existing'),
          sessionId: existingSession.id,
          state: RunTerminalState.completed,
        );
        lifecycle.store.publishRestoredProject(
          project: existingProject,
          tasks: [existingTask],
          environments: [existingEnvironment],
          sessions: [existingSession],
          authorities: [(existingSession.id, existingEnvironment.id)],
          runRecords: [existingRun],
        );
        final existingAuthority = lifecycle.store.requireSessionAuthority(
          existingSession.id,
        );
        final before = _snapshot(inspection);
        await expectLater(open(lifecycle), throwsStateError);
        expect(lifecycle.store.project(project.id), isNull);
        expect(lifecycle.store.tasksFor(project.id), isEmpty);
        for (final task in tasks) {
          expect(lifecycle.store.task(task.id), isNull);
        }
        for (final environment in environments) {
          expect(lifecycle.store.environment(environment.id), isNull);
        }
        expect(lifecycle.store.session(sessions.first.id), isNull);
        expect(lifecycle.store.sessionAuthority(sessions.first.id), isNull);
        expect(lifecycle.store.runRecord(runRecords.first.id), isNull);
        if (conflict == 'Run') {
          for (final session in sessions) {
            expect(lifecycle.store.session(session.id), isNull);
            expect(lifecycle.store.sessionAuthority(session.id), isNull);
            expect(lifecycle.store.runsForSession(session.id), isEmpty);
          }
        }
        expect(lifecycle.store.runRecord(existingRun.id), same(existingRun));
        expect(lifecycle.store.runsForSession(existingSession.id), [
          existingRun,
        ]);
        expect(
          lifecycle.store.project(existingProject.id),
          same(existingProject),
        );
        expect(lifecycle.store.task(existingTask.id), same(existingTask));
        expect(
          lifecycle.store.environment(existingEnvironment.id),
          same(existingEnvironment),
        );
        expect(
          lifecycle.store.session(existingSession.id),
          same(existingSession),
        );
        expect(
          lifecycle.store.sessionAuthority(existingSession.id),
          same(existingAuthority),
        );
        expect(_snapshot(inspection), before);
      },
    );
  }
}

ProductLifecycleCoordinator _lifecycle({
  ProductIdSource? ids,
  ExtensionRegistry? extensions,
}) {
  final registry = CapabilityRegistry();
  final registration = registry.register(
    provider: ProviderDescriptor(
      id: _projectProviderId,
      capability: projectProviderCapability,
      pluginId: 'dev.adele.test.project-plugin',
      displayName: 'Fixture Project',
      serviceId: projectProviderServiceId,
    ),
    endpoint: AdeleRequestChannelEndpoint(
      channel: _ProjectChannel(),
      serviceId: projectProviderServiceId,
      isAvailable: () => true,
    ),
  );
  addTearDown(registration.close);
  final lifecycle = ProductLifecycleCoordinator(
    store: InMemoryProductStore(),
    registry: registry,
    extensions: extensions ?? ExtensionRegistry(),
    ids: ids ?? _Ids(),
    providerForBinding: (_) =>
        fail('Unexpected Environment provider resolution'),
  );
  addTearDown(lifecycle.close);
  return lifecycle;
}

void _registerStrategy(
  ExtensionRegistry extensions, {
  String id = 'dev.adele.test.strategy',
}) {
  final registration = extensions.register(
    point: orchestrationStrategyContributions,
    id: ExtensionId(id),
    value: OrchestrationStrategyContribution(
      strategyId: _strategyId,
      materialize: (_) => fail('Unexpected strategy materialization'),
    ),
  );
  addTearDown(registration.close);
}

Map<String, List<List<Object?>>> _snapshot(Database database) => {
  for (final table in [
    'adele_product_projects',
    'adele_product_tasks',
    'adele_product_environments',
    'adele_product_sessions',
    'adele_product_session_environment_authority',
    'adele_product_runs',
  ])
    table: database
        .select('SELECT * FROM $table ORDER BY rowid')
        .map((row) => row.values.toList())
        .toList(),
};

final class _ProjectChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, projectProviderServicePrepareSourceId);
    return {
      'sourceLocation': payload['sourceLocation'],
      'databaseRelativePath': 'data.db',
    };
  }
}

final class _Ids implements ProductIdSource {
  _Ids([this.sessionId]);

  final SessionId Function()? sessionId;

  @override
  ProjectId nextProjectId() => fail('Unexpected Project allocation');

  @override
  TaskId nextTaskId() => fail('Unexpected Task allocation');

  @override
  EnvironmentId nextEnvironmentId() =>
      fail('Unexpected Environment allocation');

  @override
  SessionId nextSessionId() =>
      sessionId?.call() ?? fail('Unexpected Session allocation');
}
