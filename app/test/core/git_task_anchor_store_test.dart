import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_backend/git_backend.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

final _projectProvider = ProviderId('dev.adele.test.project');
final _primary = AuthorizedEnvironmentIdentity(
  sessionId: 'primary-session',
  environmentId: 'primary-environment',
);
final _additional = AuthorizedEnvironmentIdentity(
  sessionId: 'additional-session',
  environmentId: 'additional-environment',
);
final _shared = AuthorizedEnvironmentIdentity(
  sessionId: 'shared-session',
  environmentId: _additional.environmentId,
);
const _anchorA = GitTaskComparisonAnchor(
  baselineCommit: '1111111111111111111111111111111111111111',
  expectedBranchRef: 'refs/heads/primary-task',
);
const _anchorB = GitTaskComparisonAnchor(
  baselineCommit:
      '2222222222222222222222222222222222222222222222222222222222222222',
  expectedBranchRef: 'refs/heads/additional-task',
);
const _access = ProjectStorageAccessMode.durableOrTemporary;

void main() {
  late _Fixture fixture;
  late GitTaskAnchorStore anchors;

  setUp(() async {
    fixture = await _Fixture.open();
    anchors = GitTaskAnchorStore(fixture.storage());
  });

  test(
    'Git owns a v1 Environment-keyed schema with an enforced core FK',
    () async {
      await anchors.enroll(identity: _additional, anchor: _anchorB);
      final inspection = fixture.inspect();
      expect(
        inspection.select(
          'SELECT * FROM adele_schema_versions ORDER BY owner_id',
        ),
        [
          {'owner_id': 'dev.adele.execution', 'version': 1},
          {'owner_id': gitPluginId, 'version': 1},
          {'owner_id': 'dev.adele.product', 'version': 1},
        ],
      );
      expect(
        inspection
            .select('PRAGMA table_info(adele_git_task_anchors)')
            .map(
              (row) => [row['name'], row['type'], row['notnull'], row['pk']],
            ),
        [
          ['environment_id', 'TEXT', 1, 1],
          ['baseline_commit', 'TEXT', 1, 0],
          ['expected_branch_ref', 'TEXT', 1, 0],
        ],
      );
      expect(
        inspection
            .select('PRAGMA foreign_key_list(adele_git_task_anchors)')
            .map((row) => [row['table'], row['from'], row['to']]),
        [
          ['adele_product_environments', 'environment_id', 'id'],
        ],
      );
      await expectLater(
        fixture.storage().transactionForSession(_additional.sessionId, [
          RelationalStatement(
            sql: '''INSERT INTO adele_git_task_anchors
            (environment_id, baseline_commit, expected_branch_ref)
            VALUES (:environment, :baseline, :branch)''',
            parameters: {
              ':environment': 'unpublished-environment',
              ':baseline': _anchorA.baselineCommit,
              ':branch': _anchorA.expectedBranchRef,
            },
            expectedRows: 1,
          ),
        ], _access),
        throwsA(isA<SqliteException>()),
      );
      expect(inspection.select('PRAGMA foreign_key_check'), isEmpty);
      expect(fixture.rows, [_row(_additional, _anchorB)]);
    },
  );

  test('two Environments in one Task retain independent baselines', () async {
    final store = fixture.lifecycle.store;
    expect(
      store.session(SessionId(_primary.sessionId))!.taskId,
      store.session(SessionId(_additional.sessionId))!.taskId,
    );
    await anchors.enroll(identity: _primary, anchor: _anchorA);
    await expectLater(
      anchors.read(_additional),
      throwsA(_failure('baseline_unavailable')),
    );
    await anchors.enroll(identity: _additional, anchor: _anchorB);
    expect(await anchors.read(_primary), _matchesAnchor(_anchorA));
    expect(await anchors.read(_additional), _matchesAnchor(_anchorB));
    expect(fixture.rows, [
      _row(_additional, _anchorB),
      _row(_primary, _anchorA),
    ]);
  });

  test('two Sessions in one Environment read one retained anchor', () async {
    await anchors.enroll(identity: _additional, anchor: _anchorB);
    final anotherStore = GitTaskAnchorStore(fixture.storage());
    expect(await anotherStore.read(_shared), _matchesAnchor(_anchorB));
    expect(await anchors.read(_additional), _matchesAnchor(_anchorB));
    expect(fixture.rows, [_row(_additional, _anchorB)]);
  });

  test(
    'distinct Project backings isolate even identical product IDs',
    () async {
      final other = await _Fixture.open();
      final otherStore = GitTaskAnchorStore(other.storage());
      expect(other.database.path, isNot(fixture.database.path));
      await anchors.enroll(identity: _additional, anchor: _anchorA);
      await expectLater(
        otherStore.read(_additional),
        throwsA(_failure('baseline_unavailable')),
      );
      await otherStore.enroll(identity: _additional, anchor: _anchorB);
      expect(await anchors.read(_additional), _matchesAnchor(_anchorA));
      expect(await otherStore.read(_additional), _matchesAnchor(_anchorB));
      expect(fixture.rows, [_row(_additional, _anchorA)]);
      expect(other.rows, [_row(_additional, _anchorB)]);
    },
  );

  test('missing baseline stays unavailable and is never synthesized', () async {
    for (final store in [anchors, GitTaskAnchorStore(fixture.storage())]) {
      await expectLater(
        store.read(_additional),
        throwsA(_failure('baseline_unavailable')),
      );
    }
    expect(fixture.rows, isEmpty);
  });

  for (final corrupt in [
    const GitTaskComparisonAnchor(
      baselineCommit: 'short-oid',
      expectedBranchRef: 'refs/heads/task',
    ),
    const GitTaskComparisonAnchor(
      baselineCommit: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      expectedBranchRef: 'refs/heads/task',
    ),
    GitTaskComparisonAnchor(
      baselineCommit: _anchorA.baselineCommit,
      expectedBranchRef: 'main',
    ),
    GitTaskComparisonAnchor(
      baselineCommit: _anchorA.baselineCommit,
      expectedBranchRef: 'refs/heads/task..other',
    ),
    GitTaskComparisonAnchor(
      baselineCommit: _anchorA.baselineCommit,
      expectedBranchRef: 'refs/heads/task.lock',
    ),
  ]) {
    test('corrupt row fails without repair: '
        '${corrupt.baselineCommit}/${corrupt.expectedBranchRef}', () async {
      await anchors.enroll(identity: _additional, anchor: _anchorB);
      expect(await anchors.read(_additional), _matchesAnchor(_anchorB));
      fixture.inspect().execute(
        '''UPDATE adele_git_task_anchors
          SET baseline_commit = ?, expected_branch_ref = ?
          WHERE environment_id = ?''',
        [
          corrupt.baselineCommit,
          corrupt.expectedBranchRef,
          _additional.environmentId,
        ],
      );
      for (final store in [anchors, GitTaskAnchorStore(fixture.storage())]) {
        await expectLater(
          store.read(_additional),
          throwsA(_failure('baseline_corrupt')),
        );
      }
      expect(fixture.rows, [_row(_additional, corrupt)]);
    });
  }

  test(
    'wrong Session/Environment pair cannot read or enroll another anchor',
    () async {
      await anchors.enroll(identity: _primary, anchor: _anchorA);
      final wrong = AuthorizedEnvironmentIdentity(
        sessionId: _additional.sessionId,
        environmentId: _primary.environmentId,
      );
      await expectLater(
        anchors.read(wrong),
        throwsA(_failure('baseline_association_mismatch')),
      );
      await expectLater(
        anchors.enroll(identity: wrong, anchor: _anchorB),
        throwsA(_failure('baseline_enrollment_failed')),
      );
      expect(fixture.rows, [_row(_primary, _anchorA)]);
    },
  );

  for (final corruption in ['missing authority', 'different Task']) {
    test(
      'persisted $corruption fails closed despite the live core graph',
      () async {
        await anchors.enroll(identity: _primary, anchor: _anchorA);
        final inspection = fixture.inspect();
        if (corruption == 'missing authority') {
          inspection.execute(
            'DELETE FROM adele_product_session_environment_authority '
            'WHERE session_id = ?',
            [_additional.sessionId],
          );
        } else {
          inspection.execute(
            "INSERT INTO adele_product_tasks (id, project_id, title) "
            "SELECT 'other-task', id, 'Other Task' FROM adele_product_projects",
          );
          inspection.execute(
            "UPDATE adele_product_environments SET task_id = 'other-task' "
            'WHERE id = ?',
            [_additional.environmentId],
          );
        }
        expect(
          fixture.lifecycle.store
              .requireSessionAuthority(SessionId(_additional.sessionId))
              .environmentId
              .value,
          _additional.environmentId,
        );
        await expectLater(
          anchors.read(_additional),
          throwsA(_failure('baseline_association_mismatch')),
        );
        await expectLater(
          anchors.enroll(identity: _additional, anchor: _anchorB),
          throwsA(_failure('baseline_enrollment_failed')),
        );
        expect(fixture.rows, [_row(_primary, _anchorA)]);
      },
    );
  }

  test(
    'identical and conflicting duplicate enrollment never replace a row',
    () async {
      await anchors.enroll(identity: _additional, anchor: _anchorA);
      for (final duplicate in [_anchorA, _anchorB]) {
        await expectLater(
          GitTaskAnchorStore(
            fixture.storage(),
          ).enroll(identity: _shared, anchor: duplicate),
          throwsA(_failure('baseline_enrollment_failed')),
        );
        expect(await anchors.read(_additional), _matchesAnchor(_anchorA));
        expect(fixture.rows, [_row(_additional, _anchorA)]);
      }
    },
  );

  test(
    'concurrent conflicting enrollments acknowledge exactly one winner',
    () async {
      final candidates = [_anchorA, _anchorB];
      final results = await Future.wait([
        for (final candidate in candidates)
          GitTaskAnchorStore(fixture.storage())
              .enroll(identity: _additional, anchor: candidate)
              .then<ChangeSetFailure?>(
                (_) => null,
                onError: (Object error) {
                  if (error is ChangeSetFailure) return error;
                  throw error;
                },
              ),
      ]);
      expect(results.where((result) => result == null), hasLength(1));
      expect(results.whereType<ChangeSetFailure>(), [
        _failure('baseline_enrollment_failed'),
      ]);
      final winner = candidates[results.indexOf(null)];
      expect(await anchors.read(_additional), _matchesAnchor(winner));
      expect(fixture.rows, [_row(_additional, winner)]);
    },
  );

  test(
    'concurrent readers across store instances retain complete independent rows',
    () async {
      await anchors.enroll(identity: _primary, anchor: _anchorA);
      await anchors.enroll(identity: _additional, anchor: _anchorB);
      final identities = [
        for (var i = 0; i < 8; i++) ...[_primary, _additional, _shared],
      ];
      final results = await Future.wait([
        for (final identity in identities)
          GitTaskAnchorStore(fixture.storage()).read(identity),
      ]);
      for (var i = 0; i < results.length; i++) {
        expect(
          results[i],
          _matchesAnchor(identities[i] == _primary ? _anchorA : _anchorB),
        );
      }
      expect(fixture.rows, [
        _row(_additional, _anchorB),
        _row(_primary, _anchorA),
      ]);
    },
  );

  test(
    'fresh lifecycle reopens durable anchors without enrollment or materialization',
    () async {
      await anchors.enroll(identity: _primary, anchor: _anchorA);
      await anchors.enroll(identity: _additional, anchor: _anchorB);
      final before = fixture.rows;
      final oldDatabase = fixture.database;
      await fixture.lifecycle.close();
      final reopened = await _Fixture.open(source: fixture.source, seed: false);
      expect(reopened.database, isNot(same(oldDatabase)));
      expect(reopened.database.path, oldDatabase.path);
      final fresh = GitTaskAnchorStore(reopened.storage());
      expect(await fresh.read(_primary), _matchesAnchor(_anchorA));
      expect(await fresh.read(_additional), _matchesAnchor(_anchorB));
      expect(await fresh.read(_shared), _matchesAnchor(_anchorB));
      expect(reopened.rows, before);
      for (final identity in [_primary, _additional]) {
        expect(
          reopened.lifecycle.environmentRuntime.currentMaterialization(
            EnvironmentId(identity.environmentId),
          ),
          isNull,
        );
      }
    },
  );

  test(
    'volatile Project retains actual temporary SQLite across store instances',
    () async {
      final volatile = await _Fixture.open(volatile: true);
      final storage = volatile.storage();
      expect(await storage.isDurableSession(_additional.sessionId), isFalse);
      final first = GitTaskAnchorStore(storage);
      await first.enroll(identity: _additional, anchor: _anchorB);
      final database = volatile.database;
      expect(File(database.path).existsSync(), isTrue);
      expect(database.path, isNot(startsWith(volatile.source.path)));
      final fresh = GitTaskAnchorStore(volatile.storage());
      expect(await fresh.read(_shared), _matchesAnchor(_anchorB));
      expect(volatile.database, same(database));
      expect(volatile.rows, [_row(_additional, _anchorB)]);
      expect(await storage.isDurableSession(_shared.sessionId), isFalse);
      await expectLater(
        fresh.read(_primary),
        throwsA(_failure('baseline_unavailable')),
      );
      expect(File('${volatile.source.path}/data.db').existsSync(), isFalse);
      await volatile.lifecycle.close();
      expect(File(database.path).parent.existsSync(), isFalse);
      await expectLater(
        fresh.read(_shared),
        throwsA(_failure('baseline_storage_failed')),
      );
    },
  );

  test(
    'closed durable storage never falls back to cached or temporary anchors',
    () async {
      await anchors.enroll(identity: _additional, anchor: _anchorB);
      expect(await anchors.read(_additional), _matchesAnchor(_anchorB));
      final database = fixture.database;
      database.close();
      for (final store in [anchors, GitTaskAnchorStore(fixture.storage())]) {
        await expectLater(
          store.read(_additional),
          throwsA(_failure('baseline_storage_failed')),
        );
        await expectLater(
          store.enroll(identity: _primary, anchor: _anchorA),
          throwsA(_failure('baseline_enrollment_failed')),
        );
      }
      expect(fixture.database, same(database));
      await fixture.lifecycle.close();
      final reopened = await _Fixture.open(source: fixture.source, seed: false);
      expect(reopened.rows, [_row(_additional, _anchorB)]);
    },
  );

  test(
    'unsupported owned schema fails without reset, replacement, or fallback',
    () async {
      await anchors.enroll(identity: _additional, anchor: _anchorB);
      final inspection = fixture.inspect();
      inspection.execute(
        'UPDATE adele_schema_versions SET version = 2 WHERE owner_id = ?',
        [gitPluginId],
      );
      await expectLater(
        anchors.read(_additional),
        throwsA(_failure('baseline_storage_failed')),
      );
      await expectLater(
        anchors.enroll(identity: _primary, anchor: _anchorA),
        throwsA(_failure('baseline_enrollment_failed')),
      );
      expect(fixture.rows, [_row(_additional, _anchorB)]);
      expect(
        inspection.select(
          'SELECT version FROM adele_schema_versions WHERE owner_id = ?',
          [gitPluginId],
        ).single['version'],
        2,
      );
    },
  );

  test(
    'retired local access gate cannot serve a cached read or enroll',
    () async {
      var live = true;
      final old = GitTaskAnchorStore(
        fixture.storage(
          validateAccess: () {
            if (!live) throw StateError('Retired generation');
          },
        ),
      );
      await old.enroll(identity: _additional, anchor: _anchorB);
      expect(await old.read(_additional), _matchesAnchor(_anchorB));
      live = false;
      await expectLater(
        old.read(_additional),
        throwsA(_failure('baseline_storage_failed')),
      );
      await expectLater(
        old.enroll(identity: _primary, anchor: _anchorA),
        throwsA(_failure('baseline_enrollment_failed')),
      );
      expect(await anchors.read(_additional), _matchesAnchor(_anchorB));
      expect(fixture.rows, [_row(_additional, _anchorB)]);
    },
  );

  for (final reading in [true, false]) {
    test(
      'revocation between schema and ${reading ? 'read' : 'enrollment'} prevents SQL access',
      () async {
        await anchors.enroll(identity: _additional, anchor: _anchorB);
        var live = true;
        var checks = 0;
        final gated = GitTaskAnchorStore(
          fixture.storage(
            validateAccess: () {
              checks++;
              if (!live) throw StateError('Retired generation');
            },
          ),
        );
        // The real host completes schema SQL synchronously; the store then yields.
        final pending = reading
            ? gated.read(_additional)
            : gated.enroll(identity: _primary, anchor: _anchorA);
        expect(checks, 1);
        live = false;
        await expectLater(
          pending,
          throwsA(
            _failure(
              reading
                  ? 'baseline_storage_failed'
                  : 'baseline_enrollment_failed',
            ),
          ),
        );
        expect(checks, 2);
        expect(fixture.rows, [_row(_additional, _anchorB)]);
      },
    );
  }
}

Matcher _failure(String code) =>
    isA<ChangeSetFailure>().having((failure) => failure.code, 'code', code);

Matcher _matchesAnchor(GitTaskComparisonAnchor anchor) =>
    isA<GitTaskComparisonAnchor>()
        .having(
          (value) => value.baselineCommit,
          'baselineCommit',
          anchor.baselineCommit,
        )
        .having(
          (value) => value.expectedBranchRef,
          'expectedBranchRef',
          anchor.expectedBranchRef,
        );

Map<String, Object?> _row(
  AuthorizedEnvironmentIdentity identity,
  GitTaskComparisonAnchor anchor,
) => {
  'environment_id': identity.environmentId,
  'baseline_commit': anchor.baselineCommit,
  'expected_branch_ref': anchor.expectedBranchRef,
};

final class _Fixture {
  _Fixture(this.source, this.lifecycle);

  final Directory source;
  final ProductLifecycleCoordinator lifecycle;

  static Future<_Fixture> open({
    Directory? source,
    bool seed = true,
    bool volatile = false,
  }) async {
    final directory =
        source ?? Directory.systemTemp.createTempSync('adele-git-anchors-');
    if (source == null) {
      addTearDown(() => directory.deleteSync(recursive: true));
    }
    final registry = CapabilityRegistry();
    final registration = registry.register(
      provider: ProviderDescriptor(
        id: _projectProvider,
        capability: projectProviderCapability,
        pluginId: 'dev.adele.test.project',
        displayName: 'Anchor storage fixture',
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
      extensions: ExtensionRegistry(),
      ids: MonotonicProductIdSource(),
      providerForBinding: (_) =>
          fail('Storage must not materialize an Environment.'),
    );
    addTearDown(lifecycle.close);
    final project = Project(
      id: ProjectId('project'),
      sourceLocation: directory.uri,
    );
    final task = Task(
      id: TaskId('task'),
      projectId: project.id,
      title: 'Anchors',
    );
    final environments = [
      for (final identity in [_primary, _additional])
        Environment(
          id: EnvironmentId(identity.environmentId),
          taskId: task.id,
          role: identity == _primary
              ? EnvironmentRole.primary
              : EnvironmentRole.additional,
          providerId: ProviderId('dev.adele.test.environment'),
          providerState: const {},
        ),
    ];
    final sessions = [
      for (final identity in [_primary, _additional, _shared])
        Session(
          id: SessionId(identity.sessionId),
          taskId: task.id,
          strategyId: OrchestrationStrategyId('dev.adele.test.strategy'),
        ),
    ];
    final authorities = [
      for (final identity in [_primary, _additional, _shared])
        (SessionId(identity.sessionId), EnvironmentId(identity.environmentId)),
    ];
    if (volatile) {
      lifecycle.store.publishRestoredProject(
        project: project,
        tasks: [task],
        environments: environments,
        sessions: sessions,
        authorities: authorities,
        runRecords: [],
      );
    } else {
      if (seed) {
        final database = ProjectDatabase.open(
          ProjectBacking(
            sourceLocation: directory.uri,
            databaseRelativePath: 'data.db',
          ),
        );
        try {
          database.openProject(
            sourceLocation: directory.uri,
            nextProjectId: () => project.id,
          );
          database.insertTaskWithPrimaryEnvironment(task, environments.first);
          // Additional Environment creation has no lifecycle API; seed core only.
          database.executePluginTransaction([
            RelationalStatement(
              sql: '''INSERT INTO adele_product_environments
                (id, task_id, role, provider_id, provider_state_json)
                VALUES (:id, :task, 'additional', :provider, '{}')''',
              parameters: {
                ':id': environments.last.id.value,
                ':task': task.id.value,
                ':provider': environments.last.providerId.value,
              },
              expectedRows: 1,
            ),
          ]);
          for (var i = 0; i < sessions.length; i++) {
            database.insertSessionWithAuthority(sessions[i], authorities[i].$2);
          }
        } finally {
          database.close();
        }
      }
      await lifecycle.openProject(
        sourceLocation: directory.uri,
        provider: lifecycle.resolveProjectProvider(_projectProvider),
      );
    }
    return _Fixture(directory, lifecycle);
  }

  ProjectStorageHost storage({void Function()? validateAccess}) =>
      ProjectStorageHost(
        lifecycle: lifecycle,
        owner: PluginId(gitPluginId),
        validateAccess: validateAccess ?? () {},
      );

  ProjectDatabase get database => lifecycle.databaseForSession(
    SessionId(_additional.sessionId),
    accessMode: _access,
  )!;

  List<Map<String, Object?>> get rows => database
      .queryPluginRows(
        'SELECT * FROM adele_git_task_anchors ORDER BY environment_id',
        {},
      )
      .map((row) => row.values)
      .toList();

  Database inspect() {
    final inspection = sqlite3.open(database.path);
    addTearDown(inspection.close);
    return inspection;
  }
}

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
