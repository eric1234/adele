import 'dart:async';
import 'dart:convert';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:test/test.dart';

import 'support/chat_storage.dart';

void main() {
  late ChatTestStorage storage;
  late ChatSessionStore store;
  late ChatSessionBackend service;

  setUp(() {
    storage = ChatTestStorage();
    store = ChatSessionStore(storage: storage);
    service = ChatSessionBackend(store);
  });
  tearDown(() => storage.close());

  test('lazy hydration deduplicates and persists defaults once', () async {
    expect(storage.durabilityChecks, 0);
    expect(storage.schemaChecks, 0);
    final gate = Completer<void>();
    storage.beforeDurability = () => gate.future;
    final first = store.load(SessionId('session'));
    expect(store.load(SessionId('session')), same(first));
    final snapshot = ChatSessionBackend(store).snapshot('session');
    expect(storage.durabilityChecks, 1);
    expect(storage.transactions, 0);
    gate.complete();
    final state = await first;
    expect((await snapshot).instructions, chatDefaultInstructions);
    expect(state.snapshot().entries, isEmpty);
    expect(state.draftRequest, '');
    expect((await snapshot).draftRequest, '');
    expect(state.maxModelInvocations, 8);
    expect(storage.schemaChecks, 1);
    expect(storage.transactions, 1);
    expect(
      storage.database.select('SELECT * FROM adele_chat_sessions').single,
      {
        'session_id': 'session',
        'instructions': chatDefaultInstructions,
        'max_model_invocations': 8,
        'next_entry': 0,
        'draft_request': '',
      },
    );
    expect(() => store.obtain(SessionId('session')), throwsStateError);
    expect(() => state.instructions = 'Bypass.', throwsStateError);
    expect(() => state.maxModelInvocations = 2, throwsStateError);
    expect(() => state.appendUserMessage('Bypass.'), throwsStateError);
  });

  test(
    'fresh generation reloads exact configuration, entries and counter',
    () async {
      const instructions = '  Raw\r\n\t\u0000instructions';
      const content = '  Raw\r\n\t\u0000message';
      const draft = '  Raw\r\n\t\u0000draft\u00e9\u{1f600}  ';
      await service.setDraftRequest('session', draft);
      await service.configureSession('session', instructions, 3);
      expect(
        (await service.appendUserMessage('session', content)).id,
        'entry-0',
      );
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      final snapshot = await reloaded.snapshot('session');
      expect(snapshot.instructions, instructions);
      expect(snapshot.maxModelInvocations, 3);
      expect(snapshot.entries.single.content, content);
      expect(snapshot.entries.single.role, 'user');
      expect(snapshot.draftRequest, draft);
      expect(
        (await reloaded.appendUserMessage('session', content)).id,
        'entry-1',
      );
      await reloaded.configureSession('session', '', 1);
      final again = await ChatSessionBackend(
        ChatSessionStore(storage: storage),
      ).snapshot('session');
      expect(again.instructions, '');
      expect(again.maxModelInvocations, 1);
      expect(again.entries.map((entry) => entry.id), ['entry-0', 'entry-1']);
      expect(again.draftRequest, draft);
      final submitted = await reloaded.submitDraftRequest('session');
      expect(
        (submitted.id, submitted.role, submitted.content),
        ('entry-2', 'user', draft),
      );
      final cleared = await ChatSessionBackend(
        ChatSessionStore(storage: storage),
      ).snapshot('session');
      expect(cleared.draftRequest, '');
      expect(cleared.entries.last.content, draft);
      expect(again.draftRequest, draft);
    },
  );

  for (final draft in ['', ' ', '\t\r\n']) {
    test(
      'blank draft ${draft.length} saves exactly but cannot submit',
      () async {
        await service.setDraftRequest('session', draft);
        final writes = storage.transactions;
        await expectLater(
          service.submitDraftRequest('session'),
          _invalidContent,
        );
        expect(storage.transactions, writes);
        for (final reader in [
          service,
          ChatSessionBackend(ChatSessionStore(storage: storage)),
        ]) {
          final snapshot = await reader.snapshot('session');
          expect(snapshot.draftRequest, draft);
          expect(snapshot.entries, isEmpty);
        }
        await service.setDraftRequest('session', '  Exact.\r\n\t');
        final entry = await service.submitDraftRequest('session');
        expect(entry.id, 'entry-0');
        expect(entry.content, '  Exact.\r\n\t');
        expect((await service.snapshot('session')).draftRequest, '');
        await expectLater(
          service.submitDraftRequest('session'),
          _invalidContent,
        );
        expect((await service.snapshot('session')).entries, hasLength(1));
      },
    );
  }

  for (final configure in [false, true]) {
    test(
      '${configure ? 'configuration' : 'user append'} commits before publication and response',
      () async {
        await service.setDraftRequest('session', 'Retained draft.');
        final before = await service.snapshot('session');
        final peer = ChatSessionBackend(store);
        final entered = Completer<void>();
        final gate = Completer<void>();
        storage.beforeTransaction = () {
          entered.complete();
          return gate.future;
        };
        final writing = configure
            ? service.configureSession('session', 'Both fields.', 2)
            : service.appendUserMessage('session', 'Accepted.');
        var returned = false;
        final completed = writing.then((_) => returned = true);
        await entered.future;
        expect(returned, isFalse);
        final pending = await peer.snapshot('session');
        expect(pending.instructions, before.instructions);
        expect(pending.maxModelInvocations, before.maxModelInvocations);
        expect(pending.entries, isEmpty);
        expect(pending.draftRequest, before.draftRequest);
        expect(
          storage.database
              .select('SELECT next_entry FROM adele_chat_sessions')
              .single['next_entry'],
          0,
        );
        await expectLater(peer.appendUserMessage('session', 'Blocked.'), _busy);
        await expectLater(
          peer.configureSession('session', 'Blocked.', 5),
          _busy,
        );
        await expectLater(peer.setDraftRequest('session', ''), _busy);
        await expectLater(peer.submitDraftRequest('session'), _busy);
        gate.complete();
        await completed;
        final after = await peer.snapshot('session');
        expect(
          after.instructions,
          configure ? 'Both fields.' : before.instructions,
        );
        expect(after.maxModelInvocations, configure ? 2 : 8);
        expect(after.entries.length, configure ? 0 : 1);
        expect(after.draftRequest, before.draftRequest);
        final reloaded = await ChatSessionBackend(
          ChatSessionStore(storage: storage),
        ).snapshot('session');
        expect(reloaded.instructions, after.instructions);
        expect(reloaded.maxModelInvocations, after.maxModelInvocations);
        expect(reloaded.draftRequest, before.draftRequest);
        expect(
          reloaded.entries.map((e) => e.id),
          after.entries.map((e) => e.id),
        );
      },
    );
  }

  for (final submit in [false, true]) {
    test(
      'draft ${submit ? 'submit' : 'set'} holds claim through commit',
      () async {
        const draft = '  Original draft.\r\n';
        await service.setDraftRequest('session', draft);
        await service.snapshot('other');
        final backend = ChatRemoteOrchestrationBackend(
          sessions: store,
          hostChannel: (_) => throw StateError('No execution expected.'),
        );
        final entered = Completer<void>();
        final gate = Completer<void>();
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await backend.close();
        });
        storage.beforeTransaction = () {
          entered.complete();
          return gate.future;
        };
        final writes = storage.transactions;
        final Future<Object?> writing = submit
            ? service.submitDraftRequest('session')
            : service
                  .setDraftRequest('session', '  Replacement.\t')
                  .then((_) => null);
        var returned = false;
        final completed = writing.then((value) {
          returned = true;
          return value;
        });
        await entered.future;
        final peer = ChatSessionBackend(store);
        expect(returned, isFalse);
        expect((await peer.snapshot('session')).draftRequest, draft);
        expect((await peer.snapshot('session')).entries, isEmpty);
        expect((await peer.snapshot('other')).draftRequest, '');
        expect(
          storage.database
              .select(
                'SELECT draft_request, next_entry FROM adele_chat_sessions '
                "WHERE session_id = 'session'",
              )
              .single,
          {'draft_request': draft, 'next_entry': 0},
        );
        await expectLater(peer.setDraftRequest('session', ''), _busy);
        await expectLater(peer.submitDraftRequest('session'), _busy);
        await expectLater(peer.appendUserMessage('session', 'Blocked.'), _busy);
        await expectLater(peer.configureSession('session', '', 1), _busy);
        await expectLater(
          backend.materialize(
            chatStrategyRouteId,
            RemoteOrchestrationSession(
              sessionId: 'session',
              taskId: 'task',
              strategyId: chatStrategyId.value,
            ),
            'run',
          ),
          _busy,
        );
        gate.complete();
        final result = await completed;
        expect(storage.transactions, writes + 1);
        if (submit) {
          expect(result, isA<ChatEntry>());
          expect((result as ChatEntry).id, 'entry-0');
          expect(result.content, draft);
        }
        storage.beforeTransaction = null;
        for (final reader in [
          service,
          ChatSessionBackend(ChatSessionStore(storage: storage)),
        ]) {
          final after = await reader.snapshot('session');
          expect(after.draftRequest, submit ? '' : '  Replacement.\t');
          expect(after.entries.length, submit ? 1 : 0);
        }
        await service.setDraftRequest('session', 'No leaked claim.');
      },
    );
  }

  for (final submit in [false, true]) {
    test(
      'real SQL draft ${submit ? 'submit' : 'set'} failure rolls back all state',
      () async {
        await service.appendUserMessage('session', 'Prior history.');
        await service.setDraftRequest('session', '  Retained draft.\r\n');
        final before = storage.database.select(
          'SELECT * FROM adele_chat_sessions',
        );
        final entries = storage.database.select(
          'SELECT * FROM adele_chat_entries',
        );
        storage.database.execute(
          submit
              ? '''
CREATE TRIGGER reject_draft AFTER INSERT ON adele_chat_entries
WHEN (SELECT draft_request FROM adele_chat_sessions WHERE session_id = NEW.session_id) = ''
BEGIN SELECT RAISE(ABORT, 'submit failed after clearing draft'); END;
'''
              : '''
CREATE TRIGGER reject_draft AFTER UPDATE OF draft_request ON adele_chat_sessions
BEGIN SELECT RAISE(ABORT, 'draft update failed'); END;
''',
        );
        final writes = storage.transactions;
        await expectLater(
          submit
              ? service.submitDraftRequest('session')
              : service.setDraftRequest('session', 'Rejected.'),
          throwsA(isA<Exception>()),
        );
        expect(storage.transactions, writes + 1);
        expect(
          storage.database.select('SELECT * FROM adele_chat_sessions'),
          before,
        );
        expect(
          storage.database.select('SELECT * FROM adele_chat_entries'),
          entries,
        );
        for (final reader in [
          service,
          ChatSessionBackend(ChatSessionStore(storage: storage)),
        ]) {
          final snapshot = await reader.snapshot('session');
          expect(snapshot.draftRequest, '  Retained draft.\r\n');
          expect(snapshot.entries.single.content, 'Prior history.');
        }
        storage.database.execute('DROP TRIGGER reject_draft');
        if (!submit) await service.setDraftRequest('session', 'Retry draft.');
        final retried = await service.submitDraftRequest('session');
        expect(retried.id, 'entry-1');
        expect(
          retried.content,
          submit ? '  Retained draft.\r\n' : 'Retry draft.',
        );
        expect((await service.snapshot('session')).draftRequest, '');
      },
    );
  }

  test(
    'SQL entry failure rolls back counter and does not mutate memory',
    () async {
      await service.snapshot('session');
      storage.database.execute('''
CREATE TRIGGER reject_entry BEFORE INSERT ON adele_chat_entries
BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
''');
      await expectLater(
        service.appendUserMessage('session', 'Not accepted.'),
        throwsA(isA<Exception>()),
      );
      expect((await service.snapshot('session')).entries, isEmpty);
      expect(
        storage.database
            .select('SELECT next_entry FROM adele_chat_sessions')
            .single['next_entry'],
        0,
      );
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        isEmpty,
      );
      expect(storage.transactions, 2);
      storage.database.execute('DROP TRIGGER reject_entry');
      expect(
        (await service.appendUserMessage('session', 'Accepted.')).id,
        'entry-0',
      );
    },
  );

  test(
    'configuration failure preserves both fields without translating storage errors',
    () async {
      final before = await service.snapshot('session');
      final error = ArgumentError('Storage unavailable.');
      storage.failure = error;
      await expectLater(
        service.configureSession('session', 'Not accepted.', 2),
        throwsA(same(error)),
      );
      final after = await service.snapshot('session');
      expect(after.instructions, before.instructions);
      expect(after.maxModelInvocations, before.maxModelInvocations);
      expect(storage.transactions, 2);
    },
  );

  for (final change in ['configuration', 'counter', 'draft']) {
    test(
      'stale generation $change preconditions reject all mutations',
      () async {
        await service.setDraftRequest('session', 'Original draft.');
        final stale = ChatSessionBackend(ChatSessionStore(storage: storage));
        await stale.snapshot('session');
        if (change == 'configuration') {
          await service.configureSession('session', 'New configuration.', 2);
        } else if (change == 'counter') {
          await service.appendUserMessage('session', 'New occurrence.');
        } else {
          await service.setDraftRequest('session', 'New draft.');
        }
        await expectLater(
          stale.configureSession('session', 'Stale.', 4),
          throwsStateError,
        );
        await expectLater(
          stale.appendUserMessage('session', 'Stale.'),
          throwsStateError,
        );
        await expectLater(
          stale.setDraftRequest('session', ''),
          throwsStateError,
        );
        await expectLater(
          stale.submitDraftRequest('session'),
          throwsStateError,
        );
        final unchanged = await stale.snapshot('session');
        expect(unchanged.instructions, chatDefaultInstructions);
        expect(unchanged.maxModelInvocations, 8);
        expect(unchanged.entries, isEmpty);
        expect(unchanged.draftRequest, 'Original draft.');
        final actual = await ChatSessionBackend(
          ChatSessionStore(storage: storage),
        ).snapshot('session');
        expect(
          actual.instructions,
          change == 'configuration'
              ? 'New configuration.'
              : chatDefaultInstructions,
        );
        expect(actual.entries.length, change == 'counter' ? 1 : 0);
        expect(
          actual.draftRequest,
          change == 'draft' ? 'New draft.' : 'Original draft.',
        );
      },
    );
  }

  test(
    'storage failures never become volatile or input failures and are not retried',
    () async {
      const error = FormatException('Storage response corrupt.');
      storage.failure = error;
      await expectLater(
        service.appendUserMessage('session', 'Valid.'),
        throwsA(same(error)),
      );
      storage.failure = null;
      await expectLater(service.snapshot('session'), throwsA(same(error)));
      await expectLater(
        service.setDraftRequest('session', ''),
        throwsA(same(error)),
      );
      await expectLater(
        service.submitDraftRequest('session'),
        throwsA(same(error)),
      );
      expect(storage.durabilityChecks, 1);
      expect(storage.schemaChecks, 0);
      expect(storage.transactions, 0);
      await expectLater(service.snapshot('missing'), throwsStateError);
    },
  );

  test('explicit host volatile Sessions never initialize schema', () async {
    final volatile = ChatTestStorage(durable: false);
    addTearDown(volatile.close);
    final service = ChatSessionBackend(ChatSessionStore(storage: volatile));
    expect((await service.snapshot('session')).draftRequest, '');
    await service.setDraftRequest('session', '  Volatile draft.\r\n');
    await service.configureSession('session', 'Volatile.', 2);
    expect(
      (await service.appendUserMessage('session', 'Prompt.')).id,
      'entry-0',
    );
    expect((await service.snapshot('session')).instructions, 'Volatile.');
    expect(
      (await service.snapshot('session')).draftRequest,
      '  Volatile draft.\r\n',
    );
    final submitted = await service.submitDraftRequest('session');
    expect(submitted.id, 'entry-1');
    expect(submitted.content, '  Volatile draft.\r\n');
    expect((await service.snapshot('session')).draftRequest, '');
    expect(volatile.durabilityChecks, 1);
    expect(volatile.schemaChecks, 0);
    expect(volatile.transactions, 0);
    expect(volatile.queries, 0);
    await expectLater(service.snapshot('missing'), throwsStateError);
  });

  for (final corruption in <String, String>{
    'budget': 'UPDATE adele_chat_sessions SET max_model_invocations = 0',
    'counter negative': 'UPDATE adele_chat_sessions SET next_entry = -1',
    'counter mismatch': 'UPDATE adele_chat_sessions SET next_entry = 3',
    'role': "UPDATE adele_chat_entries SET role = 'tool'",
    'entry identity': "UPDATE adele_chat_entries SET entry_id = 'entry-9'",
    'sequence gap': 'UPDATE adele_chat_entries SET sequence = 1',
    'negative sequence': 'UPDATE adele_chat_entries SET sequence = -1',
    'blank content': "UPDATE adele_chat_entries SET content = '  '",
    'orphan history': 'DELETE FROM adele_chat_sessions',
    'empty Run identity': "UPDATE adele_chat_entries SET run_id = ''",
    'padded Run identity': "UPDATE adele_chat_entries SET run_id = ' run '",
    'assistant Run association':
        "UPDATE adele_chat_entries SET role = 'assistant', run_id = 'run'",
  }.entries) {
    test(
      'corrupt ${corruption.key} fails explicitly without rewriting data',
      () async {
        await service.appendUserMessage('session', 'Retain.');
        storage.database.execute('PRAGMA ignore_check_constraints = ON');
        storage.database.execute('PRAGMA foreign_keys = OFF');
        storage.database.execute(corruption.value);
        final writes = storage.transactions;
        final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
        await expectLater(
          reloaded.snapshot('session'),
          throwsA(isA<ChatStateCorruption>()),
        );
        expect(storage.transactions, writes);
      },
    );
  }

  test(
    'v1 schema restricts associations to unique user Runs without a core Run foreign key',
    () async {
      await service.appendUserMessage('session', 'First.');
      await service.appendUserMessage('session', 'Second.');
      await service.appendUserMessage('other', 'Other Session.');
      expect(
        storage.database
            .select('SELECT run_id FROM adele_chat_entries')
            .map((row) => row['run_id']),
        [null, null, null],
      );
      storage.database.execute(
        "UPDATE adele_chat_entries SET run_id = 'run' WHERE sequence = 0",
      );
      expect(
        () => storage.database.execute(
          "UPDATE adele_chat_entries SET run_id = 'run' WHERE sequence = 1",
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        () => storage.database.execute(
          "UPDATE adele_chat_entries SET role = 'assistant' WHERE run_id = 'run'",
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        storage.database
            .select('PRAGMA foreign_key_list(adele_chat_entries)')
            .map((row) => row['table']),
        ['adele_chat_sessions'],
      );
    },
  );

  for (final invalid in [42, 'duplicate']) {
    test(
      'hydration rejects ${invalid == 42 ? 'non-string' : 'duplicate'} Run associations even with damaged constraints',
      () async {
        await service.appendUserMessage('session', 'First.');
        await service.appendUserMessage('session', 'Second.');
        storage.database.execute('''
CREATE TABLE corrupt_entries (session_id, sequence, entry_id, role, content, run_id);
INSERT INTO corrupt_entries SELECT * FROM adele_chat_entries;
DROP TABLE adele_chat_entries;
ALTER TABLE corrupt_entries RENAME TO adele_chat_entries;
''');
        storage.database.execute('UPDATE adele_chat_entries SET run_id = ?', [
          invalid,
        ]);
        final writes = storage.transactions;
        final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
        await expectLater(
          reloaded.snapshot('session'),
          throwsA(isA<ChatStateCorruption>()),
        );
        expect(storage.transactions, writes);
        expect(
          storage.database
              .select('SELECT run_id FROM adele_chat_entries')
              .map((row) => row['run_id']),
          [invalid, invalid],
        );
      },
    );
  }

  for (final change in ['configuration', 'counter', 'draft', 'association']) {
    test(
      'stale $change fences association before canonical publication',
      () async {
        await service.appendUserMessage('session', 'Accepted.');
        final staleStore = ChatSessionStore(storage: storage);
        final staleService = ChatSessionBackend(staleStore);
        await staleService.snapshot('session');
        final staleBackend = ChatRemoteOrchestrationBackend(
          sessions: staleStore,
          hostChannel: (_) => throw StateError('No execution expected.'),
        );
        addTearDown(staleBackend.close);
        if (change == 'configuration') {
          await service.configureSession('session', 'Replacement.', 2);
        } else if (change == 'counter') {
          await service.appendUserMessage('session', 'New latest.');
        } else if (change == 'draft') {
          await service.setDraftRequest('session', 'Changed.');
        } else {
          final current = ChatRemoteOrchestrationBackend(
            sessions: store,
            hostChannel: (_) => throw StateError('No execution expected.'),
          );
          addTearDown(current.close);
          final execution = await current.materialize(
            chatStrategyRouteId,
            _session,
            'original-run',
          );
          await current.release(execution);
        }
        final before = storage.database.select(
          'SELECT * FROM adele_chat_entries',
        );
        await expectLater(
          staleBackend.materialize(chatStrategyRouteId, _session, 'stale-run'),
          throwsStateError,
        );
        expect(
          (await staleService.snapshot('session')).entries.single.runId,
          isNull,
        );
        expect(
          storage.database.select('SELECT * FROM adele_chat_entries'),
          before,
        );
        final reloaded = await ChatSessionBackend(
          ChatSessionStore(storage: storage),
        ).snapshot('session');
        expect(
          reloaded.entries.first.runId,
          change == 'association' ? 'original-run' : null,
        );
      },
    );
  }

  test(
    'association charges the full readable row before writing and permits retry',
    () async {
      final content =
          'x' *
          (relationalQueryByteLimit -
              _rowBytes({
                'session_id': 'session',
                'sequence': 0,
                'entry_id': 'entry-0',
                'role': 'user',
                'content': '',
                'run_id': null,
              }));
      await service.appendUserMessage('session', content);
      final backend = ChatRemoteOrchestrationBackend(
        sessions: store,
        hostChannel: (_) => throw StateError('No execution expected.'),
      );
      addTearDown(backend.close);
      final writes = storage.transactions;
      await expectLater(
        backend.materialize(chatStrategyRouteId, _session, 'long-run'),
        throwsStateError,
      );
      expect(storage.transactions, writes);
      expect((await service.snapshot('session')).entries.single.runId, isNull);
      final execution = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'r',
      );
      expect((await service.snapshot('session')).entries.single.runId, 'r');
      final restored = await ChatSessionBackend(
        ChatSessionStore(storage: storage),
      ).snapshot('session');
      expect(restored.entries.single.runId, 'r');
      expect(restored.entries.single.content, content);
      await backend.release(execution);
    },
  );

  test(
    'hydration seeks beyond 1000 entries without OFFSET and preserves exact next ID',
    () async {
      await service.snapshot('session');
      storage.database.execute('BEGIN');
      final insert = storage.database.prepare(
        'INSERT INTO adele_chat_entries VALUES (?, ?, ?, ?, ?, ?)',
      );
      try {
        for (var index = 0; index < 1105; index++) {
          insert.execute([
            'session',
            index,
            'entry-$index',
            index.isEven ? 'user' : 'assistant',
            'Raw $index\r\n',
            null,
          ]);
        }
      } finally {
        insert.close();
      }
      storage.database.execute(
        'UPDATE adele_chat_sessions SET next_entry = 1105',
      );
      storage.database.execute('COMMIT');
      final queries = storage.queries;
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      final snapshot = await reloaded.snapshot('session');
      expect(storage.queries - queries, 1108);
      expect(
        storage.querySql.last,
        'SELECT COUNT(*) AS entry_count FROM adele_chat_entries '
        'WHERE session_id = :session',
      );
      final historyQueries = storage.querySql
          .skip(queries)
          .where((sql) => sql.startsWith('SELECT session_id, sequence'));
      expect(historyQueries, hasLength(1106));
      for (final sql in historyQueries) {
        expect(sql.toUpperCase(), isNot(contains('OFFSET')));
        expect(
          sql,
          contains(
            'WHERE session_id = :session AND sequence = :sequence LIMIT 2',
          ),
        );
      }
      expect(snapshot.entries.length, 1105);
      for (var index = 0; index < 1105; index++) {
        expect(snapshot.entries[index].id, 'entry-$index');
        expect(
          snapshot.entries[index].role,
          index.isEven ? 'user' : 'assistant',
        );
        expect(snapshot.entries[index].content, 'Raw $index\r\n');
      }
      expect(
        (await reloaded.appendUserMessage('session', 'Next.')).id,
        'entry-1105',
      );
    },
  );

  for (final invalid in [null, 42]) {
    test(
      'non-string stored draft $invalid fails hydration without resetting',
      () async {
        await service.setDraftRequest('session', 'Retain.');
        storage.database.execute('PRAGMA foreign_keys = OFF');
        storage.database.execute('''
CREATE TABLE corrupt_sessions (
  session_id, instructions, max_model_invocations, next_entry, draft_request
);
INSERT INTO corrupt_sessions SELECT * FROM adele_chat_sessions;
DROP TABLE adele_chat_sessions;
ALTER TABLE corrupt_sessions RENAME TO adele_chat_sessions;
''');
        storage.database.execute(
          'UPDATE adele_chat_sessions SET draft_request = ?',
          [invalid],
        );
        final writes = storage.transactions;
        final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
        await expectLater(
          reloaded.snapshot('session'),
          throwsA(isA<ChatStateCorruption>()),
        );
        await expectLater(
          reloaded.setDraftRequest('session', ''),
          throwsA(isA<ChatStateCorruption>()),
        );
        expect(storage.transactions, writes);
        expect(
          storage.database
              .select('SELECT draft_request FROM adele_chat_sessions')
              .single['draft_request'],
          invalid,
        );
        expect((await service.snapshot('session')).draftRequest, 'Retain.');
      },
    );
  }

  test(
    '128 accepted 8192-byte messages reload without combined page overflow',
    () async {
      final content = 'x' * 8192;
      for (var index = 0; index < 128; index++) {
        expect(
          (await service.appendUserMessage('session', content)).id,
          'entry-$index',
        );
      }
      final queries = storage.queries;
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      final snapshot = await reloaded.snapshot('session');
      expect(storage.queries - queries, 131);
      expect(snapshot.entries, hasLength(128));
      for (var index = 0; index < snapshot.entries.length; index++) {
        expect(snapshot.entries[index].id, 'entry-$index');
        expect(snapshot.entries[index].role, 'user');
        expect(snapshot.entries[index].content, content);
      }
      expect(
        (await reloaded.appendUserMessage('session', 'Next.')).id,
        'entry-128',
      );
    },
  );

  test(
    'sequence gap before later rows fails instead of publishing a prefix',
    () async {
      for (final content in ['First.', 'Missing.', 'Last.']) {
        await service.appendUserMessage('session', content);
      }
      storage.database.execute(
        'DELETE FROM adele_chat_entries WHERE sequence = 1',
      );
      final writes = storage.transactions;
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      await expectLater(
        reloaded.snapshot('session'),
        throwsA(isA<ChatStateCorruption>()),
      );
      expect(storage.transactions, writes);
      expect(
        storage.database.select(
          'SELECT sequence FROM adele_chat_entries ORDER BY sequence',
        ),
        [
          {'sequence': 0},
          {'sequence': 2},
        ],
      );
    },
  );

  test(
    'hidden sequence 2 with next_entry 1 fails without publishing or filling the gap',
    () async {
      for (final content in ['First.', 'Missing.', 'Last.']) {
        await service.appendUserMessage('session', content);
      }
      storage.database.execute('''
DELETE FROM adele_chat_entries WHERE sequence = 1;
UPDATE adele_chat_sessions SET next_entry = 1;
''');
      final entriesBefore = storage.database.select(
        'SELECT * FROM adele_chat_entries ORDER BY sequence',
      );
      final configurationBefore = storage.database.select(
        'SELECT * FROM adele_chat_sessions',
      );
      final writes = storage.transactions;
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      await expectLater(
        reloaded.snapshot('session'),
        throwsA(isA<ChatStateCorruption>()),
      );
      expect(storage.transactions, writes);
      // The failed generation exposes no cached prefix and cannot append into it.
      await expectLater(
        reloaded.snapshot('session'),
        throwsA(isA<ChatStateCorruption>()),
      );
      await expectLater(
        reloaded.appendUserMessage('session', 'Do not fill the gap.'),
        throwsA(isA<ChatStateCorruption>()),
      );
      expect(storage.transactions, writes);
      expect(
        storage.database.select(
          'SELECT * FROM adele_chat_entries ORDER BY sequence',
        ),
        entriesBefore,
      );
      expect(
        storage.database.select('SELECT * FROM adele_chat_sessions'),
        configurationBefore,
      );
    },
  );

  test(
    'single-row hydration does not skip duplicate sequences in corrupt schema',
    () async {
      await service.appendUserMessage('session', 'Original.');
      storage.database.execute('''
CREATE TABLE corrupt_entries AS SELECT * FROM adele_chat_entries;
DROP TABLE adele_chat_entries;
ALTER TABLE corrupt_entries RENAME TO adele_chat_entries;
INSERT INTO adele_chat_entries SELECT * FROM adele_chat_entries;
''');
      final writes = storage.transactions;
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      await expectLater(
        reloaded.snapshot('session'),
        throwsA(isA<ChatStateCorruption>()),
      );
      expect(storage.transactions, writes);
    },
  );

  for (final configure in [false, true]) {
    for (final text in {
      'ASCII': 'x',
      'escaped': '\\"\n\u0000',
      'multibyte': '\u00e9\u{1f600}',
    }.entries) {
      test(
        '${configure ? 'configuration' : 'user entry'} ${text.key} fits exact encoded limit and rejects one extra byte',
        () async {
          await service.snapshot('session');
          Map<String, Object?> row(String value) => configure
              ? {
                  'session_id': 'session',
                  'instructions': value,
                  'max_model_invocations': 8,
                  'next_entry': 0,
                  'draft_request': '',
                }
              : {
                  'session_id': 'session',
                  'sequence': 0,
                  'entry_id': 'entry-0',
                  'role': 'user',
                  'content': value,
                  'run_id': null,
                };
          final prefix = text.value * 16000;
          final content =
              prefix +
              'x' * (relationalQueryByteLimit - _rowBytes(row(prefix)));
          expect(_rowBytes(row(content)), relationalQueryByteLimit);
          expect(_rowBytes(row('$content!')), relationalQueryByteLimit + 1);
          if (configure) {
            await service.configureSession('session', content, 8);
          } else {
            expect(
              (await service.appendUserMessage('session', content)).id,
              'entry-0',
            );
          }
          final writes = storage.transactions;
          if (configure) {
            await expectLater(
              service.configureSession('session', '$content!', 8),
              throwsStateError,
            );
            await expectLater(
              service.configureSession('session', content, 10),
              throwsStateError,
            );
          } else {
            await expectLater(
              service.appendUserMessage('session', '$content!'),
              throwsStateError,
            );
          }
          expect(storage.transactions, writes);
          for (final reader in [
            service,
            ChatSessionBackend(ChatSessionStore(storage: storage)),
          ]) {
            final unchanged = await reader.snapshot('session');
            expect(unchanged.maxModelInvocations, 8);
            expect(
              unchanged.instructions,
              configure ? content : chatDefaultInstructions,
            );
            expect(unchanged.entries.length, configure ? 0 : 1);
            if (!configure) expect(unchanged.entries.single.content, content);
          }
          // Rejection must release the claim and leave the next occurrence unused.
          await service.configureSession('session', 'Short.', 8);
          expect(
            (await service.appendUserMessage('session', 'Next.')).id,
            configure ? 'entry-0' : 'entry-1',
          );
        },
      );
    }
  }

  test(
    'append revalidates configuration when next counter gains a digit',
    () async {
      for (var index = 0; index < 9; index++) {
        await service.appendUserMessage('session', 'Prompt.');
      }
      final instructions =
          'x' *
          (relationalQueryByteLimit -
              _rowBytes({
                'session_id': 'session',
                'instructions': '',
                'max_model_invocations': 8,
                'next_entry': 9,
                'draft_request': '',
              }));
      await service.configureSession('session', instructions, 8);
      final writes = storage.transactions;
      await expectLater(
        service.appendUserMessage('session', 'Small but unpersistable.'),
        throwsStateError,
      );
      expect(storage.transactions, writes);
      expect((await service.snapshot('session')).entries, hasLength(9));
      final reloaded = await ChatSessionBackend(
        ChatSessionStore(storage: storage),
      ).snapshot('session');
      expect(reloaded.entries, hasLength(9));
      expect(reloaded.instructions, instructions);
      await service.configureSession('session', 'Short.', 8);
      expect(
        (await service.appendUserMessage('session', 'Next.')).id,
        'entry-9',
      );
    },
  );

  test(
    'oversized Session identity rejects default row before insert',
    () async {
      final id = 's' * relationalQueryByteLimit;
      storage.database.execute(
        'INSERT INTO adele_product_sessions VALUES (?)',
        [id],
      );
      await expectLater(service.snapshot(id), throwsStateError);
      expect(storage.transactions, 0);
      expect(
        storage.database.select('SELECT * FROM adele_chat_sessions'),
        isEmpty,
      );
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        isEmpty,
      );
    },
  );

  for (final text in {
    'ASCII': 'x',
    'escaped': '\\"\n\u0000',
    'multibyte': '\u00e9\u{1f600}',
  }.entries) {
    test(
      'draft ${text.key} fits exact row bound, rejects overflow, then submits',
      () async {
        await service.snapshot('session');
        Map<String, Object?> row(String draft) => {
          'session_id': 'session',
          'instructions': chatDefaultInstructions,
          'max_model_invocations': 8,
          'next_entry': 0,
          'draft_request': draft,
        };
        final prefix = text.value * 16000;
        final draft =
            prefix + 'x' * (relationalQueryByteLimit - _rowBytes(row(prefix)));
        expect(_rowBytes(row(draft)), relationalQueryByteLimit);
        expect(_rowBytes(row('$draft!')), relationalQueryByteLimit + 1);
        await service.setDraftRequest('session', draft);
        final writes = storage.transactions;
        final before = storage.database.select(
          'SELECT * FROM adele_chat_sessions',
        );
        await expectLater(
          service.setDraftRequest('session', '$draft!'),
          throwsStateError,
        );
        // Configuration replacement must charge the retained draft as well.
        await expectLater(
          service.configureSession('session', '$chatDefaultInstructions!', 8),
          throwsStateError,
        );
        expect(storage.transactions, writes);
        expect(
          storage.database.select('SELECT * FROM adele_chat_sessions'),
          before,
        );
        for (final reader in [
          service,
          ChatSessionBackend(ChatSessionStore(storage: storage)),
        ]) {
          final snapshot = await reader.snapshot('session');
          expect(snapshot.draftRequest, draft);
          expect(snapshot.instructions, chatDefaultInstructions);
          expect(snapshot.entries, isEmpty);
        }
        final entry = await service.submitDraftRequest('session');
        expect(
          (entry.id, entry.role, entry.content),
          ('entry-0', 'user', draft),
        );
        expect(storage.transactions, writes + 1);
        final after = await ChatSessionBackend(
          ChatSessionStore(storage: storage),
        ).snapshot('session');
        expect(after.draftRequest, '');
        expect(after.entries.single.content, draft);
      },
    );
  }

  test(
    'counter growth charges retained draft but submit validates cleared row',
    () async {
      for (var index = 0; index < 9; index++) {
        await service.appendUserMessage('session', 'Prompt.');
      }
      final draft =
          'x' *
          (relationalQueryByteLimit -
              _rowBytes({
                'session_id': 'session',
                'instructions': chatDefaultInstructions,
                'max_model_invocations': 8,
                'next_entry': 9,
                'draft_request': '',
              }));
      await service.setDraftRequest('session', draft);
      final writes = storage.transactions;
      await expectLater(
        service.appendUserMessage('session', 'Not accepted.'),
        throwsStateError,
      );
      expect(storage.transactions, writes);
      expect((await service.snapshot('session')).draftRequest, draft);
      expect((await service.snapshot('session')).entries, hasLength(9));
      final entry = await service.submitDraftRequest('session');
      expect(entry.id, 'entry-9');
      expect(entry.content, draft);
      final after = await ChatSessionBackend(
        ChatSessionStore(storage: storage),
      ).snapshot('session');
      expect(after.draftRequest, '');
      expect(after.entries, hasLength(10));
    },
  );

  test(
    'oversized stored draft fails without reset or volatile fallback',
    () async {
      await service.setDraftRequest('session', 'Cached draft.');
      final draft = 'x' * relationalQueryByteLimit;
      storage.database.execute(
        'UPDATE adele_chat_sessions SET draft_request = ?',
        [draft],
      );
      final before = storage.database.select(
        'SELECT * FROM adele_chat_sessions',
      );
      final writes = storage.transactions;
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      await expectLater(reloaded.snapshot('session'), throwsStateError);
      await expectLater(
        reloaded.setDraftRequest('session', ''),
        throwsStateError,
      );
      await expectLater(
        reloaded.submitDraftRequest('session'),
        throwsStateError,
      );
      expect(storage.transactions, writes);
      expect(
        storage.database.select('SELECT * FROM adele_chat_sessions'),
        before,
      );
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        isEmpty,
      );
      expect((await service.snapshot('session')).draftRequest, 'Cached draft.');
    },
  );

  for (final hostVolatile in [false, true]) {
    test(
      '${hostVolatile ? 'host-declared' : 'direct'} volatile state retains unlimited messages and configuration',
      () async {
        final volatile = ChatTestStorage(durable: false);
        addTearDown(volatile.close);
        final store = ChatSessionStore(storage: hostVolatile ? volatile : null);
        final service = ChatSessionBackend(store);
        final content = 'x' * relationalQueryByteLimit;
        await service.configureSession('session', content, 8);
        expect(
          (await service.appendUserMessage('session', content)).id,
          'entry-0',
        );
        final snapshot = await service.snapshot('session');
        expect(snapshot.instructions, content);
        expect(snapshot.entries.single.content, content);
        await service.setDraftRequest('session', content);
        expect((await service.snapshot('session')).draftRequest, content);
        expect((await service.submitDraftRequest('session')).id, 'entry-1');
        expect((await service.snapshot('session')).draftRequest, '');
        if (!hostVolatile) {
          final state = store.obtain(SessionId('session'));
          state.instructions = '$content!';
          expect(state.appendUserMessage('$content!').id, 'entry-2');
        }
        expect(volatile.transactions, 0);
        expect(volatile.schemaChecks, 0);
        expect(volatile.queries, 0);
      },
    );
  }

  test(
    'individually oversized history row fails instead of truncating or resetting',
    () async {
      await service.appendUserMessage('session', 'Original.');
      storage.database.execute('UPDATE adele_chat_entries SET content = ?', [
        'x' * relationalQueryByteLimit,
      ]);
      final writes = storage.transactions;
      final reloaded = ChatSessionBackend(ChatSessionStore(storage: storage));
      await expectLater(reloaded.snapshot('session'), throwsStateError);
      await expectLater(
        reloaded.appendUserMessage('session', 'Not accepted.'),
        throwsStateError,
      );
      expect(storage.transactions, writes);
    },
  );
}

int _rowBytes(Map<String, Object?> values) =>
    2 + utf8.encode(jsonEncode({'values': values})).length + 1;

final _session = RemoteOrchestrationSession(
  sessionId: 'session',
  taskId: 'task',
  strategyId: chatStrategyId.value,
);

final _busy = throwsA(
  isA<ChatSessionFailure>().having((e) => e.code, 'code', 'session_busy'),
);

final _invalidContent = throwsA(
  isA<ChatSessionFailure>().having((e) => e.code, 'code', 'invalid_content'),
);
