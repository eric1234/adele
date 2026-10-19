import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

final _projectProvider = ProviderId('dev.adele.test.initial-project');
final _environmentProvider = ProviderId('dev.adele.test.initial-environment');
final _owner = PluginId('dev.adele.test.initial-owner');
const _advertisedOwner = 'dev.adele.test.descriptor-is-not-ownership';
final _strategy = OrchestrationStrategyId('dev.adele.test.initial-strategy');
const _providerState = <String, Object?>{'version': 1, 'location': 'opaque'};
const _schema = '''
CREATE TABLE fixture_initial (
  environment_id TEXT NOT NULL REFERENCES adele_product_environments(id),
  task_id TEXT NOT NULL REFERENCES adele_product_tasks(id),
  project_id TEXT NOT NULL REFERENCES adele_product_projects(id),
  slot INTEGER NOT NULL,
  value TEXT,
  PRIMARY KEY (environment_id, slot)
)
''';
const _insertSql =
    'INSERT INTO fixture_initial '
    '(environment_id, task_id, project_id, slot, value) '
    'VALUES (:environment, :task, :project, :slot, :value)';

void main() {
  for (final durable in [true, false]) {
    final label = durable ? 'durable' : 'volatile';
    final mode = durable
        ? ProjectStorageAccessMode.durable
        : ProjectStorageAccessMode.durableOrTemporary;

    test(
      '$label commits initial rows before any Session, then shares backing',
      () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        final started = Completer<void>();
        final result = Completer<EnvironmentProviderResult>();
        fixture.provider.onEstablish = (_) {
          started.complete();
          return result.future;
        };
        final creating = fixture.create(project);
        await started.future;
        final provisional = fixture.provider.established.single;
        _expectUnpublished(fixture, project);
        expect(provisional.providerState, isNull);
        expect(fixture.temporary.listSync(), isEmpty);
        if (durable) _expectNoRows(fixture.inspect(), project);

        final parameters = _parameters(provisional)
          ..addAll({':otherSlot': 2, ':otherValue': null});
        result.complete(
          _result(
            provisional,
            inserts: [
              EnvironmentInitialInsert(
                sql:
                    ' \n iNsErT INTO fixture_initial '
                    '(environment_id, task_id, project_id, slot, value) '
                    'VALUES (:environment, :task, :project, :slot, :value), '
                    '(:environment, :task, :project, :otherSlot, :otherValue); \t',
                parameters: parameters,
                expectedRows: 2,
              ),
              EnvironmentInitialInsert(
                sql:
                    'INSERT INTO fixture_initial '
                    '(environment_id, task_id, project_id, slot, value) '
                    r'VALUES (@environment, @task, @project, $slot, $value)',
                parameters: {
                  '@environment': provisional.id.value,
                  '@task': provisional.task.id.value,
                  '@project': project.id.value,
                  r'$slot': 3,
                  r'$value': 'third',
                },
                expectedRows: 1,
              ),
            ],
          ),
        );
        final created = await creating;

        // Inspect the actual file before any storage accessor could create one.
        final inspection = fixture.inspect();
        expect(
          inspection.select('SELECT * FROM fixture_initial ORDER BY slot'),
          [
            for (final (slot, value) in [
              (1, "quoted'; COMMIT"),
              (2, null),
              (3, 'third'),
            ])
              {
                'environment_id': created.environment.id.value,
                'task_id': created.task.id.value,
                'project_id': project.id.value,
                'slot': slot,
                'value': value,
              },
          ],
        );
        expect(
          fixture.lifecycle.store.task(created.task.id),
          same(created.task),
        );
        expect(
          fixture.lifecycle.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(
          fixture.lifecycle.store.primaryEnvironmentFor(created.task.id),
          same(created.environment),
        );
        expect(
          fixture.lifecycle.store.sessionsForTask(created.task.id),
          isEmpty,
        );
        expect(
          inspection.select('SELECT * FROM adele_product_sessions'),
          isEmpty,
        );
        expect(inspection.select('SELECT * FROM adele_product_tasks'), [
          {
            'id': created.task.id.value,
            'project_id': project.id.value,
            'title': 'Task',
          },
        ]);
        final environmentRow = inspection
            .select('SELECT * FROM adele_product_environments')
            .single;
        expect(environmentRow['id'], created.environment.id.value);
        expect(environmentRow['task_id'], created.task.id.value);
        expect(environmentRow['role'], 'primary');
        expect(environmentRow['provider_id'], _environmentProvider.value);
        expect(
          jsonDecode(environmentRow['provider_state_json']! as String),
          _providerState,
        );
        expect(
          inspection.select(
            'SELECT * FROM adele_schema_versions ORDER BY owner_id',
          ),
          [
            {'owner_id': 'dev.adele.execution', 'version': 1},
            {'owner_id': 'dev.adele.product', 'version': 1},
            {'owner_id': _owner.value, 'version': 1},
          ],
        );
        final materialization = fixture.lifecycle.environmentRuntime
            .currentMaterialization(created.environment.id)!;
        expect(materialization.environment, same(created.environment));
        materialization.validateBinding();
        expect(fixture.captures, hasLength(1));
        expect(fixture.registration.owns(fixture.captures.single), isTrue);

        final database = fixture.lifecycle.databaseForEnvironment(
          created.environment.id,
          accessMode: mode,
        )!;
        expect(database.path, fixture.databasePath);
        expect(database.autocommit, isTrue);
        expect(
          fixture.lifecycle.databaseForEnvironment(created.environment.id),
          durable ? same(database) : isNull,
        );
        final storage = fixture.storage();
        expect(
          await storage.queryForEnvironment(
            created.environment.id.value,
            'SELECT * FROM fixture_initial',
            {},
            mode,
          ),
          hasLength(3),
        );
        final session = fixture.lifecycle.createSession(
          taskId: created.task.id,
          strategyId: _strategy,
        );
        expect(
          fixture.lifecycle.databaseForSession(session.id, accessMode: mode),
          same(database),
        );
        expect(await storage.isDurableSession(session.id.value), durable);
        expect(
          fixture.lifecycle.store
              .requireSessionAuthority(session.id)
              .environmentId,
          created.environment.id,
        );
        expect(
          await storage.queryForSession(
            session.id.value,
            'SELECT * FROM fixture_initial',
            {},
            mode,
          ),
          hasLength(3),
        );
        await storage.transactionForSession(session.id.value, [
          RelationalStatement(
            sql: 'UPDATE fixture_initial SET value = :value WHERE slot = :slot',
            parameters: {':value': 'ordinary later write', ':slot': 1},
            expectedRows: 1,
          ),
        ], mode);
        expect(
          inspection
              .select('SELECT value FROM fixture_initial WHERE slot = 1')
              .single,
          {'value': 'ordinary later write'},
        );
        expect(database.loadProductGraph().sessions.single.id, session.id);
        expect(fixture.provider.established, hasLength(1));
        expect(fixture.provider.restored, isEmpty);

        final path = File(database.path);
        fixture.closeInspections();
        await fixture.lifecycle.close();
        expect(path.existsSync(), durable);
        if (!durable) {
          expect(path.parent.existsSync(), isFalse);
          expect(fixture.source.listSync(), isEmpty);
        }
      },
    );

    test(
      '$label providerState-only creation allocates no temporary database',
      () async {
        final fixture = _Fixture(captureOwner: false);
        final project = await fixture.open(durable: durable);
        fixture.provider.onEstablish = (_) =>
            EnvironmentProviderResult(providerState: _providerState);
        final created = await fixture.create(project);
        expect(fixture.temporary.listSync(), isEmpty);
        expect(
          fixture.lifecycle.store.environment(created.environment.id),
          same(created.environment),
        );
        fixture.lifecycle.environmentRuntime
            .currentMaterialization(created.environment.id)!
            .validateBinding();
        final session = fixture.lifecycle.createSession(
          taskId: created.task.id,
          strategyId: _strategy,
        );
        expect(fixture.temporary.listSync(), isEmpty);
        expect(
          fixture.lifecycle.databaseForSession(session.id),
          durable ? isNotNull : isNull,
        );
        if (durable) {
          final database = fixture.inspect();
          expect(
            database.select('SELECT * FROM adele_product_tasks'),
            hasLength(1),
          );
          expect(
            database.select('SELECT * FROM adele_product_sessions'),
            hasLength(1),
          );
          expect(_tableExists(database, 'fixture_initial'), isFalse);
          expect(
            database.select('SELECT * FROM adele_schema_versions'),
            hasLength(2),
          );
        } else {
          expect(fixture.source.listSync(), isEmpty);
        }
      },
    );

    for (final sql in _unsupportedSql) {
      test(
        '$label rejects initial SQL $sql without a committed prefix',
        () async {
          final fixture = _Fixture();
          final project = await fixture.open(durable: durable);
          fixture.provider.onEstablish = (environment) => _result(
            environment,
            inserts: [
              _insert(environment),
              EnvironmentInitialInsert(
                sql: sql,
                parameters: {':value': 'bad'},
                expectedRows: 1,
              ),
            ],
          );
          await expectLater(fixture.create(project), throwsArgumentError);
          _expectUnpublished(fixture, project);
          final database = fixture.inspect();
          _expectNoRows(database, project);
          // Schema preparation may commit independently; semantic inserts may not.
          expect(_tableExists(database, 'fixture_initial'), isTrue);
          expect(
            database.select(
              'SELECT version FROM adele_schema_versions WHERE owner_id = ?',
              [_owner.value],
            ),
            [
              {'version': 1},
            ],
          );
        },
      );
    }

    for (final (name, schema, failure) in <(String, String, Matcher)>[
      (
        'malformed table',
        'CREATE TABLE fixture_initial (',
        throwsA(isA<SqliteException>()),
      ),
      (
        'later malformed table',
        '$_schema; CREATE TABLE incomplete (',
        throwsA(isA<SqliteException>()),
      ),
      (
        'schema DML',
        '$_schema; INSERT INTO fixture_initial (slot) VALUES (1)',
        throwsArgumentError,
      ),
      ('schema transaction control', '$_schema; COMMIT', throwsArgumentError),
      (
        'data-producing schema',
        "CREATE TABLE fixture_initial AS SELECT 'uncommitted' AS environment_id",
        throwsArgumentError,
      ),
      (
        'data-producing later schema',
        "$_schema; CREATE TABLE leaked_initial AS SELECT 'uncommitted' AS environment_id",
        throwsArgumentError,
      ),
      (
        'schema view',
        'CREATE VIEW fixture_initial AS SELECT 1',
        throwsArgumentError,
      ),
      ('schema comment', '-- hidden\n$_schema', throwsArgumentError),
    ]) {
      test('$label $name leaves no initialization or semantic rows', () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        fixture.provider.onEstablish = (environment) =>
            _result(environment, schema: schema);
        await expectLater(fixture.create(project), failure);
        _expectUnpublished(fixture, project);
        final database = fixture.inspect();
        _expectNoRows(database, project);
        expect(_tableExists(database, 'fixture_initial'), isFalse);
        expect(_tableExists(database, 'leaked_initial'), isFalse);
        expect(
          database.select('SELECT * FROM adele_schema_versions'),
          hasLength(2),
        );
      });
    }

    for (final (name, inserts, failure)
        in <
          (
            String,
            List<EnvironmentInitialInsert> Function(LocalEnvironment),
            Matcher,
          )
        >[
          (
            'foreign key failure',
            (environment) => [
              _insert(environment),
              EnvironmentInitialInsert(
                sql: _insertSql,
                parameters: _parameters(environment, slot: 2)
                  ..[':environment'] = 'absent-environment',
                expectedRows: 1,
              ),
            ],
            throwsA(isA<SqliteException>()),
          ),
          (
            'affected row mismatch',
            (environment) => [
              _insert(environment),
              EnvironmentInitialInsert(
                sql: _insertSql,
                parameters: _parameters(environment, slot: 2),
                expectedRows: 2,
              ),
            ],
            throwsStateError,
          ),
          (
            'duplicate required row',
            (environment) => [_insert(environment), _insert(environment)],
            throwsA(isA<SqliteException>()),
          ),
          (
            'later missing table',
            (environment) => [
              _insert(environment),
              EnvironmentInitialInsert(
                sql: 'INSERT INTO absent_table (value) VALUES (:value)',
                parameters: {':value': 'bad'},
                expectedRows: 1,
              ),
            ],
            throwsA(isA<SqliteException>()),
          ),
          (
            'missing named parameter',
            (environment) => [
              _insert(environment),
              EnvironmentInitialInsert(
                sql: _insertSql,
                parameters: {},
                expectedRows: 1,
              ),
            ],
            throwsArgumentError,
          ),
        ]) {
      test('$label $name rolls back product and every plugin insert', () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        fixture.provider.onEstablish = (environment) =>
            _result(environment, inserts: inserts(environment));
        await expectLater(fixture.create(project), failure);
        _expectUnpublished(fixture, project);
        _expectNoRows(fixture.inspect(), project);
        // A later independent create proves rollback closed the transaction.
        fixture.provider.onEstablish = (environment) => _result(environment);
        final retried = await fixture.create(project);
        final database = fixture.inspect();
        expect(database.select('SELECT * FROM fixture_initial'), hasLength(1));
        expect(
          database.select('SELECT id FROM adele_product_tasks').single['id'],
          retried.task.id.value,
        );
        expect(
          database
              .select('SELECT id FROM adele_product_environments')
              .single['id'],
          retried.environment.id.value,
        );
        expect(fixture.lifecycle.store.tasksFor(project.id), [retried.task]);
      });
    }

    test(
      '$label deferred SQLite COMMIT failure rolls back all required rows',
      () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        fixture.provider.onEstablish = (environment) => _result(
          environment,
          schema:
              '$_schema; CREATE TABLE fixture_deferred ('
              'environment_id TEXT REFERENCES adele_product_environments(id) '
              'DEFERRABLE INITIALLY DEFERRED)',
          inserts: [
            _insert(environment),
            EnvironmentInitialInsert(
              sql:
                  'INSERT INTO fixture_deferred (environment_id) VALUES (:environment)',
              parameters: {':environment': 'absent-environment'},
              expectedRows: 1,
            ),
          ],
        );
        await expectLater(
          fixture.create(project),
          throwsA(
            isA<SqliteException>().having(
              (error) => error.causingStatement,
              'causingStatement',
              'COMMIT',
            ),
          ),
        );
        _expectUnpublished(fixture, project);
        final database = fixture.inspect();
        _expectNoRows(database, project);
        expect(database.select('SELECT * FROM fixture_deferred'), isEmpty);
        fixture.provider.onEstablish = (environment) =>
            _result(environment, schema: null);
        final retried = await fixture.create(project);
        expect(database.select('SELECT environment_id FROM fixture_initial'), [
          {'environment_id': retried.environment.id.value},
        ]);
      },
    );

    test('$label descriptor ownership cannot authorize initial SQL', () async {
      final fixture = _Fixture(captureOwner: false);
      final project = await fixture.open(durable: durable);
      await expectLater(fixture.create(project), throwsStateError);
      _expectUnpublished(fixture, project);
      expect(fixture.temporary.listSync(), isEmpty);
      if (durable) {
        final database = fixture.inspect();
        _expectNoRows(database, project);
        expect(_tableExists(database, 'fixture_initial'), isFalse);
      }
    });

    for (final initialState in [true, false]) {
      test(
        '$label retirement rejects ${initialState ? 'initial SQL' : 'ordinary'} settlement without replacement',
        () async {
          final fixture = _Fixture();
          final project = await fixture.open(durable: durable);
          final started = Completer<void>();
          final result = Completer<EnvironmentProviderResult>();
          fixture.provider.onEstablish = (_) {
            started.complete();
            return result.future;
          };
          final creating = fixture.create(project);
          await started.future;
          final captured = fixture.captures.single;
          await fixture.registration.close();
          final replacement = _Provider();
          final replacementRegistration = fixture.register(replacement);
          final fresh = fixture.lifecycle.environmentRuntime.resolveProvider(
            providerId: _environmentProvider,
          );
          expect(captured.isSameRegistration(fresh.binding), isFalse);
          expect(replacementRegistration.owns(captured), isFalse);
          final rejected = expectLater(
            creating,
            throwsA(
              isA<ProviderUnavailable>().having(
                (error) => error.stale,
                'stale',
                isTrue,
              ),
            ),
          );
          result.complete(
            initialState
                ? _result(fixture.provider.established.single)
                : EnvironmentProviderResult(providerState: _providerState),
          );
          await rejected;
          _expectUnpublished(fixture, project);
          expect(replacement.established, isEmpty);
          expect(replacement.restored, isEmpty);
          expect(fixture.captures, hasLength(1));
          expect(fixture.temporary.listSync(), isEmpty);
          if (durable) {
            final database = fixture.inspect();
            _expectNoRows(database, project);
            expect(_tableExists(database, 'fixture_initial'), isFalse);
          }
        },
      );
    }

    test(
      '$label captured owner revocation rejects a still-live registration',
      () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        fixture.provider.onEstablish = (environment) {
          fixture.ownerLive = false;
          return _result(environment);
        };
        await expectLater(fixture.create(project), throwsStateError);
        _expectUnpublished(fixture, project);
        expect(fixture.registration.isClosed, isFalse);
        expect(fixture.temporary.listSync(), isEmpty);
        if (durable) _expectNoRows(fixture.inspect(), project);
      },
    );

    test(
      '$label revalidates captured ownership after schema preparation',
      () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        fixture.onOwnerValidation = () {
          if (!durable && fixture.temporary.listSync().isEmpty) return;
          if (_tableExists(fixture.inspect(), 'fixture_initial')) {
            throw StateError('Captured owner retired before semantic commit.');
          }
        };
        await expectLater(fixture.create(project), throwsStateError);
        _expectUnpublished(fixture, project);
        final database = fixture.inspect();
        expect(_tableExists(database, 'fixture_initial'), isTrue);
        _expectNoRows(database, project);
      },
    );

    test(
      '$label live identity conflict rejects initial SQL before preparation',
      () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        final started = Completer<void>();
        final result = Completer<EnvironmentProviderResult>();
        fixture.provider.onEstablish = (_) {
          started.complete();
          return result.future;
        };
        final creating = fixture.create(project);
        await started.future;
        final provisional = fixture.provider.established.single;
        final existingTask = Task(
          id: TaskId('existing-task'),
          projectId: project.id,
          title: 'Existing live graph',
        );
        final existingEnvironment = Environment(
          id: provisional.id,
          taskId: existingTask.id,
          role: EnvironmentRole.primary,
          providerId: _environmentProvider,
          providerState: {'existing': true},
        );
        fixture.lifecycle.store.publishTaskWithPrimaryEnvironment(
          existingTask,
          existingEnvironment,
        );
        final rejected = expectLater(creating, throwsStateError);
        result.complete(_result(provisional));
        await rejected;
        final store = fixture.lifecycle.store;
        expect(store.project(project.id), same(project));
        expect(store.tasksFor(project.id), [existingTask]);
        expect(store.task(provisional.task.id), isNull);
        expect(store.primaryEnvironmentFor(provisional.task.id), isNull);
        expect(store.task(existingTask.id), same(existingTask));
        expect(store.environment(provisional.id), same(existingEnvironment));
        expect(
          store.primaryEnvironmentFor(existingTask.id),
          same(existingEnvironment),
        );
        expect(
          fixture.lifecycle.environmentRuntime.currentMaterialization(
            provisional.id,
          ),
          isNull,
        );
        expect(fixture.temporary.listSync(), isEmpty);
        if (durable) {
          final database = fixture.inspect();
          _expectNoRows(database, project);
          expect(_tableExists(database, 'fixture_initial'), isFalse);
        }
      },
    );

    test(
      '$label late initial plan cannot publish after lifecycle close',
      () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        final started = Completer<void>();
        final result = Completer<EnvironmentProviderResult>();
        fixture.provider.onEstablish = (_) {
          started.complete();
          return result.future;
        };
        final creating = fixture.create(project);
        await started.future;
        await fixture.lifecycle.close();
        final rejected = expectLater(creating, throwsStateError);
        result.complete(_result(fixture.provider.established.single));
        await rejected;
        _expectUnpublished(fixture, project);
        expect(fixture.temporary.listSync(), isEmpty);
        if (durable) _expectNoRows(fixture.inspect(), project);
      },
    );

    test(
      '$label native restore rejects initialization without state replacement',
      () async {
        final fixture = _Fixture();
        final project = await fixture.open(durable: durable);
        final created = await fixture.create(project);
        final database = fixture.inspect();
        final before = _snapshot(database);
        final original = fixture.lifecycle.environmentRuntime
            .currentMaterialization(created.environment.id)!;
        await fixture.registration.close();
        final replacement = _Provider()
          ..onRestore = (environment) => EnvironmentProviderResult(
            providerState: {'version': 2},
            initialState: EnvironmentInitialState(
              schema: 'CREATE TABLE forbidden_restore (value TEXT)',
              inserts: [_insert(environment, slot: 2)],
            ),
          );
        fixture.register(replacement);
        await expectLater(
          fixture.lifecycle.environmentRuntime.materialize(
            created.environment.id,
          ),
          throwsStateError,
        );
        expect(replacement.established, isEmpty);
        expect(replacement.restored.single.providerState, _providerState);
        expect(
          fixture.lifecycle.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(
          fixture.lifecycle.environmentRuntime.currentMaterialization(
            created.environment.id,
          ),
          same(original),
        );
        expect(_snapshot(database), before);
        expect(_tableExists(database, 'forbidden_restore'), isFalse);
        expect(original.validateBinding, throwsA(isA<ProviderUnavailable>()));
      },
    );

    test(
      '$label generated valid plan reaches the same atomic native path',
      () async {
        final fixture = _Fixture(generated: true);
        final project = await fixture.open(durable: durable);
        fixture.channel.onEstablish = (context) => {
          'providerState': _providerState,
          'initialState': _wirePlan(context),
        };
        final created = await fixture.create(project);
        expect(created.environment.providerState, _providerState);
        expect(fixture.inspect().select('SELECT * FROM fixture_initial'), [
          {
            'environment_id': created.environment.id.value,
            'task_id': created.task.id.value,
            'project_id': project.id.value,
            'slot': 1,
            'value': 'initial',
          },
        ]);
        expect(
          fixture.lifecycle.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(
          fixture.lifecycle.store.sessionsForTask(created.task.id),
          isEmpty,
        );
        fixture.lifecycle.environmentRuntime
            .currentMaterialization(created.environment.id)!
            .validateBinding();
        expect(fixture.channel.established, hasLength(1));
      },
    );

    for (final value in <Object>[true, 7, 'invalid', <Object?>[]]) {
      test(
        '$label generated non-object initialState $value is rejected',
        () async {
          final fixture = _Fixture(generated: true);
          final project = await fixture.open(durable: durable);
          fixture.channel.onEstablish = (_) => {
            'providerState': _providerState,
            'initialState': value,
          };
          await expectLater(
            fixture.create(project),
            throwsA(isA<AdeleProtocolException>()),
          );
          _expectUnpublished(fixture, project);
          expect(fixture.temporary.listSync(), isEmpty);
          if (durable) {
            final database = fixture.inspect();
            _expectNoRows(database, project);
            expect(_tableExists(database, 'fixture_initial'), isFalse);
          }
        },
      );
    }

    for (final (name, mutate) in _malformedPlans()) {
      test(
        '$label generated malformed $name rejects before SQL admission',
        () async {
          final fixture = _Fixture(generated: true);
          final project = await fixture.open(durable: durable);
          fixture.channel.onEstablish = (context) {
            final plan = _wirePlan(context);
            mutate(plan);
            return {'providerState': _providerState, 'initialState': plan};
          };
          await expectLater(
            fixture.create(project),
            throwsA(
              anyOf(isA<FormatException>(), isA<AdeleProtocolException>()),
            ),
          );
          _expectUnpublished(fixture, project);
          expect(fixture.temporary.listSync(), isEmpty);
          if (durable) {
            final database = fixture.inspect();
            _expectNoRows(database, project);
            expect(_tableExists(database, 'fixture_initial'), isFalse);
            expect(
              database.select('SELECT * FROM adele_schema_versions'),
              hasLength(2),
            );
          }
        },
      );
    }
  }
}

const _unsupportedSql = [
  'UPDATE fixture_initial SET value = :value',
  'DELETE FROM fixture_initial',
  'REPLACE INTO fixture_initial (value) VALUES (:value)',
  'INSERT OR REPLACE INTO fixture_initial (value) VALUES (:value)',
  'INSERT OR IGNORE INTO fixture_initial (value) VALUES (:value)',
  'INSERT INTO fixture_initial (value) VALUES (:value) ON CONFLICT DO NOTHING',
  'INSERT INTO fixture_initial (value) VALUES (:value) RETURNING value',
  'INSERT INTO fixture_initial (value) SELECT :value',
  'WITH value AS (SELECT :value) INSERT INTO fixture_initial (value) SELECT * FROM value',
  'INSERT INTO fixture_initial (value) VALUES (upper(:value))',
  "INSERT INTO fixture_initial (value) VALUES ('literal')",
  'INSERT INTO fixture_initial (value) VALUES (NULL)',
  'INSERT INTO fixture_initial (value) VALUES (?)',
  'INSERT INTO fixture_initial VALUES (:value)',
  'INSERT INTO main.fixture_initial (value) VALUES (:value)',
  'INSERT INTO "fixture_initial" (value) VALUES (:value)',
  'INSERT INTO fixture_initial ("value") VALUES (:value)',
  '-- comment\nINSERT INTO fixture_initial (value) VALUES (:value)',
  'INSERT /* comment */ INTO fixture_initial (value) VALUES (:value)',
  'INSERT INTO fixture_initial (value) VALUES (:value); COMMIT',
  'SELECT :value',
  'CREATE TABLE forbidden (value TEXT)',
  'PRAGMA foreign_keys = OFF',
  'BEGIN',
  'COMMIT',
  'ROLLBACK',
  'SAVEPOINT hidden',
  'RELEASE hidden',
  "ATTACH DATABASE ':memory:' AS other",
  'INSERT INTO adele_product_tasks (id) VALUES (:value)',
  'INSERT INTO ADELE_EXECUTION_EVENTS (id) VALUES (:value)',
  'INSERT INTO adele_schema_versions (owner_id) VALUES (:value)',
  'INSERT INTO sqlite_master (name) VALUES (:value)',
];

typedef _PlanMutation = void Function(Map<String, Object?>);

List<(String, _PlanMutation)> _malformedPlans() => [
  ('missing schema', (plan) => plan.remove('schema')),
  ('missing inserts', (plan) => plan.remove('inserts')),
  ('untrusted owner field', (plan) => plan['pluginId'] = _owner.value),
  ('non-string schema', (plan) => plan['schema'] = 7),
  ('empty schema', (plan) => plan['schema'] = ' \n'),
  (
    'oversized schema',
    (plan) => plan['schema'] = 'x' * (environmentInitialSchemaLimit + 1),
  ),
  ('non-list inserts', (plan) => plan['inserts'] = <String, Object?>{}),
  ('null inserts', (plan) => plan['inserts'] = null),
  ('empty inserts', (plan) => plan['inserts'] = <Object?>[]),
  (
    'too many inserts',
    (plan) => plan['inserts'] = List.filled(
      environmentInitialInsertLimit + 1,
      _wireInsert(plan),
    ),
  ),
  ('non-object insert', (plan) => plan['inserts'] = ['invalid']),
  ('missing SQL', (plan) => _wireInsert(plan).remove('sql')),
  ('non-string SQL', (plan) => _wireInsert(plan)['sql'] = 7),
  ('empty SQL', (plan) => _wireInsert(plan)['sql'] = ' \n'),
  (
    'oversized SQL',
    (plan) => _wireInsert(plan)['sql'] = 'x' * (environmentInitialSqlLimit + 1),
  ),
  ('missing parameters', (plan) => _wireInsert(plan).remove('parameters')),
  (
    'non-object parameters',
    (plan) => _wireInsert(plan)['parameters'] = <Object?>[],
  ),
  ('null parameters', (plan) => _wireInsert(plan)['parameters'] = null),
  (
    'unprefixed parameter',
    (plan) => _wireInsert(plan)['parameters'] = {'value': 'invalid'},
  ),
  (
    'numeric parameter',
    (plan) => _wireInsert(plan)['parameters'] = {':1': 'invalid'},
  ),
  (
    'too many parameters',
    (plan) => _wireInsert(plan)['parameters'] = {
      for (var index = 0; index <= environmentInitialParameterLimit; index++)
        ':p$index': index,
    },
  ),
  ('missing expectedRows', (plan) => _wireInsert(plan).remove('expectedRows')),
  for (final value in <Object?>[
    null,
    0,
    -1,
    environmentInitialExpectedRowsLimit + 1,
    true,
    1.5,
    '1',
  ])
    (
      'expectedRows $value',
      (plan) => _wireInsert(plan)['expectedRows'] = value,
    ),
  for (final value in <Object?>[true, 1.5, <Object?>[], <String, Object?>{}])
    (
      'unsupported scalar $value',
      (plan) => _wireInsert(plan)['parameters'] = {':value': value},
    ),
  (
    'oversized encoded plan',
    (plan) => _wireInsert(plan)['parameters'] = {
      ':value': 'x' * environmentInitialStateByteLimit,
    },
  ),
  ('unknown insert field', (plan) => _wireInsert(plan)['ignoreFailure'] = true),
];

Map<String, Object?> _wireInsert(Map<String, Object?> plan) =>
    (plan['inserts']! as List<Object?>).first as Map<String, Object?>;

Map<String, Object?> _wirePlan(Map<String, Object?> context) => {
  'schema': _schema,
  'inserts': [
    <String, Object?>{
      'sql': _insertSql,
      'parameters': <String, Object?>{
        ':environment': context['environmentId'],
        ':task': context['taskId'],
        ':project': context['projectId'],
        ':slot': 1,
        ':value': 'initial',
      },
      'expectedRows': 1,
    },
  ],
};

Map<String, Object?> _parameters(
  LocalEnvironment environment, {
  int slot = 1,
}) => {
  ':environment': environment.id.value,
  ':task': environment.task.id.value,
  ':project': environment.task.project.id.value,
  ':slot': slot,
  ':value': "quoted'; COMMIT",
};

EnvironmentInitialInsert _insert(
  LocalEnvironment environment, {
  int slot = 1,
}) => EnvironmentInitialInsert(
  sql: _insertSql,
  parameters: _parameters(environment, slot: slot),
  expectedRows: 1,
);

EnvironmentProviderResult _result(
  LocalEnvironment environment, {
  String? schema = _schema,
  List<EnvironmentInitialInsert>? inserts,
}) => EnvironmentProviderResult(
  providerState: _providerState,
  initialState: EnvironmentInitialState(
    schema: schema,
    inserts: inserts ?? [_insert(environment)],
  ),
);

void _expectUnpublished(_Fixture fixture, Project project) {
  final store = fixture.lifecycle.store;
  expect(store.project(project.id), same(project));
  expect(store.tasksFor(project.id), isEmpty);
  expect(store.task(fixture.taskId), isNull);
  expect(store.environment(fixture.environmentId), isNull);
  expect(store.primaryEnvironmentFor(fixture.taskId), isNull);
  expect(store.sessionsForTask(fixture.taskId), isEmpty);
  expect(
    fixture.lifecycle.environmentRuntime.currentMaterialization(
      fixture.environmentId,
    ),
    isNull,
  );
}

bool _tableExists(Database database, String name) => database.select(
  'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
  ['table', name],
).isNotEmpty;

void _expectNoRows(Database database, Project project) {
  expect(database.select('SELECT * FROM adele_product_projects'), [
    {
      'id': project.id.value,
      'source_location': project.sourceLocation.toString(),
    },
  ]);
  for (final table in [
    'adele_product_tasks',
    'adele_product_environments',
    'adele_product_sessions',
    'adele_product_session_environment_authority',
    'adele_product_runs',
  ]) {
    expect(database.select('SELECT * FROM $table'), isEmpty, reason: table);
  }
  if (_tableExists(database, 'fixture_initial')) {
    expect(database.select('SELECT * FROM fixture_initial'), isEmpty);
  }
}

Map<String, List<List<Object?>>> _snapshot(Database database) => {
  for (final table in [
    'adele_product_projects',
    'adele_product_tasks',
    'adele_product_environments',
    'adele_product_sessions',
    'adele_schema_versions',
    'fixture_initial',
  ])
    table: database
        .select('SELECT * FROM $table')
        .map((row) => row.values.toList())
        .toList(),
};

final class _Fixture {
  _Fixture({bool captureOwner = true, this.generated = false}) {
    root = Directory.systemTemp.createTempSync('adele-initial-state-');
    addTearDown(() => root.deleteSync(recursive: true));
    source = Directory('${root.path}/source')..createSync();
    temporary = Directory('${root.path}/temporary')..createSync();
    registration = generated
        ? registry.register(
            provider: _descriptor(),
            endpoint: AdeleRequestChannelEndpoint(
              channel: channel,
              serviceId: environmentProviderServiceId,
              isAvailable: () => true,
            ),
          )
        : register(provider);
    if (generated) {
      registrations.add(registration);
      addTearDown(registration.close);
    }
    final projectRegistration = registry.register(
      provider: ProviderDescriptor(
        id: _projectProvider,
        capability: projectProviderCapability,
        pluginId: 'dev.adele.test.project',
        displayName: 'Project',
        serviceId: projectProviderServiceId,
      ),
      endpoint: AdeleRequestChannelEndpoint(
        channel: _ProjectChannel(),
        serviceId: projectProviderServiceId,
        isAvailable: () => true,
      ),
    );
    addTearDown(projectRegistration.close);
    final strategyRegistration = extensions.register(
      point: orchestrationStrategyContributions,
      id: ExtensionId(_strategy.value),
      value: OrchestrationStrategyContribution(
        strategyId: _strategy,
        materialize: (_) =>
            throw StateError('Initialization must not run a strategy.'),
      ),
    );
    addTearDown(strategyRegistration.close);
    lifecycle = ProductLifecycleCoordinator(
      store: InMemoryProductStore(),
      registry: registry,
      extensions: extensions,
      ids: MonotonicProductIdSource(seed: 'initial'),
      providerForBinding: (binding) => generated
          ? GeneratedEnvironmentProvider(
              providerId: binding.provider.id,
              service: EnvironmentProviderServiceClient(binding.requestChannel),
            )
          : binding.endpointAs<_Endpoint>().provider,
      captureEstablishmentOwner: captureOwner
          ? (binding) {
              final registration = registrations.singleWhere(
                (item) => item.owns(binding),
              );
              captures.add(binding);
              return EnvironmentEstablishmentOwner(
                pluginId: _owner,
                validate: () {
                  expect(registration.owns(binding), isTrue);
                  binding.endpointAs<CapabilityEndpoint>();
                  if (!ownerLive) {
                    throw StateError('Captured backend owner retired.');
                  }
                  onOwnerValidation?.call();
                },
              );
            }
          : null,
    );
    addTearDown(lifecycle.close);
    addTearDown(closeInspections);
  }

  final bool generated;
  late final Directory root;
  late final Directory source;
  late final Directory temporary;
  final registry = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  final provider = _Provider();
  final channel = _RawChannel();
  final registrations = <CapabilityRegistration>[];
  final captures = <ProviderBinding>[];
  final inspections = <Database>[];
  late final CapabilityRegistration registration;
  late final ProductLifecycleCoordinator lifecycle;
  bool ownerLive = true;
  void Function()? onOwnerValidation;

  TaskId get taskId => generated
      ? TaskId(channel.established.last['taskId']! as String)
      : provider.established.last.task.id;
  EnvironmentId get environmentId => generated
      ? EnvironmentId(channel.established.last['environmentId']! as String)
      : provider.established.last.id;

  CapabilityRegistration register(_Provider provider) {
    final registration = registry.register(
      provider: _descriptor(),
      endpoint: _Endpoint(provider),
    );
    registrations.add(registration);
    addTearDown(registration.close);
    return registration;
  }

  Future<Project> open({required bool durable}) async => durable
      ? lifecycle.openProject(
          sourceLocation: source.uri,
          provider: lifecycle.resolveProjectProvider(_projectProvider),
        )
      : lifecycle.createProject(source.uri);

  Future<TaskCreationResult> create(Project project) => IOOverrides.runZoned(
    () => lifecycle.createTask(
      projectId: project.id,
      title: 'Task',
      providerId: _environmentProvider,
    ),
    getSystemTempDirectory: () => temporary,
  );

  String get databasePath {
    final durable = File('${source.path}/.adele/data.db');
    if (durable.existsSync()) return durable.path;
    final directory = temporary.listSync().single as Directory;
    return '${directory.path}/project.sqlite';
  }

  Database inspect() {
    final path = databasePath;
    expect(File(path).existsSync(), isTrue);
    final database = sqlite3.open(path);
    inspections.add(database);
    return database;
  }

  void closeInspections() {
    for (final database in inspections) {
      database.close();
    }
    inspections.clear();
  }

  ProjectStorageHost storage() => ProjectStorageHost(
    lifecycle: lifecycle,
    owner: _owner,
    validateAccess: () {},
  );
}

ProviderDescriptor _descriptor() => ProviderDescriptor(
  id: _environmentProvider,
  capability: environmentProviderCapability,
  pluginId: _advertisedOwner,
  displayName: 'Initial state fixture',
  serviceId: environmentProviderServiceId,
);

final class _Endpoint implements CapabilityEndpoint {
  const _Endpoint(this.provider);
  final EnvironmentProvider provider;
  @override
  bool get isAvailable => true;
  @override
  String get serviceId => environmentProviderServiceId;
}

final class _Provider extends Fake implements EnvironmentProvider {
  final established = <LocalEnvironment>[];
  final restored = <LocalEnvironment>[];
  FutureOr<EnvironmentProviderResult> Function(LocalEnvironment)? onEstablish;
  FutureOr<EnvironmentProviderResult> Function(LocalEnvironment)? onRestore;

  @override
  ProviderId get providerId => _environmentProvider;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async {
    established.add(environment);
    return onEstablish?.call(environment) ?? _result(environment);
  }

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restored.add(environment);
    return onRestore?.call(environment) ??
        EnvironmentProviderResult(providerState: environment.providerState!);
  }
}

final class _ProjectChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, projectProviderServicePrepareSourceId);
    return {
      'sourceLocation': payload['sourceLocation'],
      'databaseRelativePath': '.adele/data.db',
    };
  }
}

final class _RawChannel implements AdeleRequestChannel {
  final established = <Map<String, Object?>>[];
  late Map<String, Object?> Function(Map<String, Object?>) onEstablish;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    expect(method, environmentProviderServiceEstablishId);
    final context = payload['context']! as Map<String, Object?>;
    established.add(context);
    return onEstablish(context);
  }
}
