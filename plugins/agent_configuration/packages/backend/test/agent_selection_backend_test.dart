import 'dart:async';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:agent_configuration_backend/agent_configuration_backend.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:test/test.dart';

void main() {
  late _Storage storage;
  late _Catalog catalog;
  late AgentSelectionBackend backend;
  setUp(() {
    storage = _Storage();
    catalog = _Catalog();
    backend = AgentSelectionBackend(storage, catalog);
  });

  test('absent rows read as revision zero without catalog or writes', () async {
    final snapshot = await backend.readSessionSelection('session');
    expect(snapshot.sessionId, 'session');
    expect(snapshot.selectedAgentId, isNull);
    expect(snapshot.revision, 0);
    expect(storage.calls, ['schema', 'query']);
    expect(storage.writes, isEmpty);
    expect(catalog.reads, 0);
  });

  test('invalid requests fail before any storage or catalog access', () async {
    for (final session in [
      '',
      ' \r\n\t',
      ' session',
      'session ',
      's' * (AgentSelectionLimits.maxSessionIdLength + 1),
    ]) {
      await expectLater(
        backend.readSessionSelection(session),
        throwsA(_failure('invalid_request')),
      );
      await expectLater(
        backend.updateSessionSelection(session, null, 0),
        throwsA(_failure('invalid_request')),
      );
    }
    for (final agent in ['', 'Work', '../private', 'aux', 'a' * 65]) {
      await expectLater(
        backend.updateSessionSelection('session', agent, 0),
        throwsA(_failure('invalid_request')),
      );
    }
    for (final revision in [-1, AgentSelectionLimits.maxRevision + 1]) {
      await expectLater(
        backend.updateSessionSelection('session', null, revision),
        throwsA(_failure('invalid_request')),
      );
    }
    expect(storage.calls, isEmpty);
    expect(catalog.reads, 0);
  });

  test('unknown Agent distinguishes complete and partial catalogs', () async {
    for (final complete in [true, false]) {
      catalog.read = () async =>
          AgentCatalogSnapshot(agents: [], isComplete: complete);
      await expectLater(
        backend.updateSessionSelection('session', 'unknown', 0),
        throwsA(_failure(complete ? 'agent_not_found' : 'catalog_incomplete')),
      );
    }
    expect(catalog.reads, 2);
    expect(storage.calls, ['schema', 'query', 'schema', 'query']);
    expect(storage.writes, isEmpty);
  });

  test('an Agent present in a partial catalog can be selected', () async {
    catalog.read = () async =>
        AgentCatalogSnapshot(agents: [_agent], isComplete: false);
    final result = await backend.updateSessionSelection('session', 'work', 0);
    expect(result.sessionId, 'session');
    expect(result.selectedAgentId, 'work');
    expect(result.revision, 1);
    expect(catalog.reads, 1);
    expect(storage.calls, ['schema', 'query', 'transaction']);
    final statement = storage.writes.single.single;
    expect(statement.sql, contains('INSERT INTO adele_agent_selections'));
    expect(statement.parameters, {
      ':session': 'session',
      ':agent': 'work',
      ':next': 1,
    });
    expect(statement.expectedRows, 1);
  });

  test('unavailable catalog is a definite prewrite failure', () async {
    catalog.read = () async => throw StateError('/private/agents.toml');
    await expectLater(
      backend.updateSessionSelection('session', 'work', 0),
      throwsA(_failure('catalog_unavailable')),
    );
    expect(storage.calls, ['schema', 'query']);
    expect(storage.writes, isEmpty);
    expect(catalog.reads, 1);
  });

  test('each write validates against a fresh catalog observation', () async {
    await backend.updateSessionSelection('session', 'work', 0);
    storage.query = () async => [_row(agent: 'work', revision: 1)];
    catalog.read = () async =>
        AgentCatalogSnapshot(agents: [], isComplete: true);
    await expectLater(
      backend.updateSessionSelection('session', 'work', 1),
      throwsA(_failure('agent_not_found')),
    );
    catalog.read = () async => throw StateError('catalog retired');
    await expectLater(
      backend.updateSessionSelection('session', 'work', 1),
      throwsA(_failure('catalog_unavailable')),
    );
    expect(catalog.reads, 3);
    expect(storage.writes, hasLength(1));
    expect(storage.calls.where((call) => call == 'query'), hasLength(3));
  });

  test(
    'reads observe current storage and never resolve dangling IDs',
    () async {
      catalog.read = () async => throw StateError('catalog must not be used');
      storage.query = () async => [_row(agent: 'deleted-agent', revision: 3)];
      final before = await backend.readSessionSelection('session');
      storage.query = () async => [_row(agent: null, revision: 4)];
      final after = await backend.readSessionSelection('session');
      storage.query = () async => throw StateError('storage retired');
      await expectLater(
        backend.readSessionSelection('session'),
        throwsA(_failure('storage_unavailable')),
      );
      expect(before.selectedAgentId, 'deleted-agent');
      expect(before.revision, 3);
      expect(after.selectedAgentId, isNull);
      expect(after.revision, 4);
      expect(catalog.reads, 0);
      expect(storage.calls, [
        'schema',
        'query',
        'schema',
        'query',
        'schema',
        'query',
      ]);
      expect(storage.writes, isEmpty);
    },
  );

  test(
    'clear bypasses catalog, including absent and already clear rows',
    () async {
      catalog.read = () async => throw StateError('catalog must not be used');
      for (final (agent, revision) in <(String?, int)>[
        (null, 0),
        ('deleted-agent', 4),
        (null, 5),
      ]) {
        storage.query = () async => [
          if (revision != 0) _row(agent: agent, revision: revision),
        ];
        final result = await backend.updateSessionSelection(
          'session',
          null,
          revision,
        );
        expect(result.selectedAgentId, isNull);
        expect(result.revision, revision + 1);
        final statement = storage.writes.last.single;
        expect(statement.expectedRows, 1);
        expect(statement.parameters, {
          ':session': 'session',
          ':agent': null,
          ':next': revision + 1,
          if (revision != 0) ':expected': revision,
        });
        if (revision != 0) {
          expect(statement.sql, contains('UPDATE adele_agent_selections'));
          expect(statement.sql, contains('revision = :expected'));
        }
      }
      expect(storage.writes, hasLength(3));
      expect(catalog.reads, 0);
    },
  );

  test(
    'stale revisions fail before catalog and even for unchanged values',
    () async {
      for (final agent in <String?>['work', null]) {
        storage.query = () async => [_row(agent: agent, revision: 7)];
        await expectLater(
          backend.updateSessionSelection('session', agent, 6),
          throwsA(_failure('stale_revision')),
        );
      }
      expect(storage.writes, isEmpty);
      expect(catalog.reads, 0);
    },
  );

  test(
    'an update rereads storage instead of reusing an earlier baseline',
    () async {
      storage.query = () async => [_row(agent: 'work', revision: 3)];
      final baseline = await backend.readSessionSelection('session');
      storage.query = () async => [_row(agent: null, revision: 4)];
      await expectLater(
        backend.updateSessionSelection('session', 'work', baseline.revision),
        throwsA(_failure('stale_revision')),
      );
      expect(storage.calls, ['schema', 'query', 'schema', 'query']);
      expect(storage.writes, isEmpty);
      expect(catalog.reads, 0);
    },
  );

  test('revision exhaustion never wraps, writes, or reads catalog', () async {
    storage.query = () async => [
      _row(agent: 'work', revision: AgentSelectionLimits.maxRevision),
    ];
    expect(
      (await backend.readSessionSelection('session')).revision,
      AgentSelectionLimits.maxRevision,
    );
    for (final agent in <String?>['work', null]) {
      await expectLater(
        backend.updateSessionSelection(
          'session',
          agent,
          AgentSelectionLimits.maxRevision,
        ),
        throwsA(_failure('revision_exhausted')),
      );
    }
    await expectLater(
      backend.updateSessionSelection('session', null, 0),
      throwsA(_failure('stale_revision')),
    );
    expect(storage.writes, isEmpty);
    expect(catalog.reads, 0);
  });

  test(
    'schema and query failures neither fall back nor attempt a write',
    () async {
      for (final stage in ['schema', 'query']) {
        storage = _Storage();
        backend = AgentSelectionBackend(storage, catalog);
        if (stage == 'schema') {
          storage.ensure = () async => throw StateError('/private/project.db');
        } else {
          storage.query = () async => throw StateError('unknown Session');
        }
        await expectLater(
          backend.updateSessionSelection('session', 'work', 0),
          throwsA(_failure('storage_unavailable')),
        );
        expect(
          storage.calls,
          stage == 'schema' ? ['schema'] : ['schema', 'query'],
        );
        expect(storage.writes, isEmpty);
      }
      expect(catalog.reads, 0);
    },
  );

  test('malformed stored rows fail reads and updates without repair', () async {
    final valid = <String, Object?>{
      'session_id': 'session',
      'selected_agent_id': 'work',
      'revision': 1,
    };
    final malformed = <List<RelationalRow>>[
      [_row(), _row()],
      for (final values in <Map<String, Object?>>[
        for (final key in valid.keys) {...valid}..remove(key),
        {...valid, 'extra': 'private'},
        {...valid, 'session_id': 'another-session'},
        {...valid, 'session_id': null},
        for (final revision in <Object?>[
          null,
          '1',
          0,
          -1,
          AgentSelectionLimits.maxRevision + 1,
        ])
          {...valid, 'revision': revision},
        for (final agent in <Object?>[1, '', '../private', 'con', 'a' * 65])
          {...valid, 'selected_agent_id': agent},
      ])
        [RelationalRow(values: values)],
    ];
    for (final rows in malformed) {
      storage.query = () async => rows;
      await expectLater(
        backend.readSessionSelection('session'),
        throwsA(_failure('corrupt_state')),
      );
      await expectLater(
        backend.updateSessionSelection('session', null, 1),
        throwsA(_failure('corrupt_state')),
      );
    }
    expect(storage.writes, isEmpty);
    expect(catalog.reads, 0);
    expect(storage.calls, [
      for (final _ in malformed) ...['schema', 'query', 'schema', 'query'],
    ]);
  });

  test(
    'update returns success only after the transaction acknowledgement',
    () async {
      final entered = Completer<void>();
      final ack = Completer<void>();
      addTearDown(() {
        if (!ack.isCompleted) ack.complete();
      });
      storage.transact = () {
        entered.complete();
        return ack.future;
      };
      var completed = false;
      final pending = backend.updateSessionSelection('session', 'work', 0).then(
        (result) {
          completed = true;
          return result;
        },
      );
      await entered.future;
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(storage.writes, hasLength(1));
      ack.complete();
      final result = await pending;
      expect(result.selectedAgentId, 'work');
      expect(result.revision, 1);
      expect(completed, isTrue);
      expect(storage.calls, ['schema', 'query', 'transaction']);
    },
  );

  test(
    'every unacknowledged write is uncertain with no retry or hidden read',
    () async {
      for (final observedRevision in [0, 1]) {
        storage = _Storage();
        backend = AgentSelectionBackend(storage, catalog);
        storage.transact = () async => throw StateError(
          'expected rows mismatch or lost reply: /private/project.db',
        );
        await expectLater(
          backend.updateSessionSelection('session', 'work', 0),
          throwsA(_failure('outcome_uncertain')),
        );
        expect(storage.calls, ['schema', 'query', 'transaction']);
        expect(storage.writes, hasLength(1));
        // Only an explicit caller read observes this scripted post-failure state.
        storage.query = () async => [
          if (observedRevision != 0) _row(agent: 'work', revision: 1),
        ];
        final observed = await backend.readSessionSelection('session');
        expect(observed.revision, observedRevision);
        expect(observed.selectedAgentId, observedRevision == 0 ? null : 'work');
        expect(storage.writes, hasLength(1));
        expect(storage.calls, [
          'schema',
          'query',
          'transaction',
          'schema',
          'query',
        ]);
      }
      expect(catalog.reads, 2);
    },
  );

  test(
    'direct concurrent calls retain independent write acknowledgements',
    () async {
      final reads = [
        Completer<List<RelationalRow>>(),
        Completer<List<RelationalRow>>(),
      ];
      final bothRead = Completer<void>();
      final acks = [Completer<void>(), Completer<void>()];
      final bothWritten = Completer<void>();
      var readCount = 0;
      var writeCount = 0;
      storage.query = () {
        final future = reads[readCount++].future;
        if (readCount == 2) bothRead.complete();
        return future;
      };
      storage.transact = () {
        final future = acks[writeCount++].future;
        if (writeCount == 2) bothWritten.complete();
        return future;
      };
      final first = backend.updateSessionSelection('session', null, 2);
      final second = backend.updateSessionSelection('session', null, 2);
      final rejected = expectLater(
        second,
        throwsA(_failure('outcome_uncertain')),
      );
      await bothRead.future;
      for (final read in reads) {
        read.complete([_row(agent: 'work', revision: 2)]);
      }
      await bothWritten.future;
      expect(storage.writes, hasLength(2));
      for (final statements in storage.writes) {
        expect(statements.single.parameters[':expected'], 2);
        expect(statements.single.expectedRows, 1);
      }
      // These are controlled acknowledgements, not a simulated SQL CAS engine.
      acks[1].completeError(StateError('unacknowledged transaction'));
      acks[0].complete();
      expect((await first).revision, 3);
      await rejected;
      expect(readCount, 2);
      expect(writeCount, 2);
      expect(catalog.reads, 0);
    },
  );
}

const _agent = AgentDefinition(
  id: 'work',
  name: 'Work',
  description: null,
  whenToUse: null,
  instructions: 'Not persisted with a Session selection.',
);

RelationalRow _row({String? agent = 'work', int revision = 1}) => RelationalRow(
  values: {
    'session_id': 'session',
    'selected_agent_id': agent,
    'revision': revision,
  },
);

Matcher _failure(String code) => isA<AgentSelectionFailure>()
    .having((failure) => failure.code, 'code', code)
    .having(
      (failure) => failure.message,
      'safe message',
      isNot(contains('private')),
    )
    .having((failure) => failure.details, 'details', isEmpty);

final class _Catalog implements AgentCatalogService {
  int reads = 0;
  Future<AgentCatalogSnapshot> Function() read = () async =>
      AgentCatalogSnapshot(agents: [_agent], isComplete: true);

  @override
  Future<AgentCatalogSnapshot> readAgents() {
    reads++;
    return read();
  }
}

// Scripts observations and faults only; it never executes SQL or persists rows.
final class _Storage implements ProjectStorageService {
  final calls = <String>[];
  final writes = <List<RelationalStatement>>[];
  Future<void> Function() ensure = () async {};
  Future<List<RelationalRow>> Function() query = () async => [];
  Future<void> Function() transact = () async {};

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) {
    expect(sessionId, 'session');
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    expect(migrations, hasLength(1));
    calls.add('schema');
    return ensure();
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) {
    expect(sessionId, 'session');
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    expect(parameters, {':session': 'session'});
    calls.add('query');
    return query();
  }

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
    ProjectStorageAccessMode accessMode,
  ) {
    expect(sessionId, 'session');
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    calls.add('transaction');
    writes.add(statements);
    return transact();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected storage operation: ${invocation.memberName}',
  );
}
