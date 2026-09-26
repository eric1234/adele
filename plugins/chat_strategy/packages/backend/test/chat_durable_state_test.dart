import 'dart:async';
import 'dart:convert';

import 'package:adele_orchestration/adele_orchestration.dart';
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
    },
  );

  for (final configure in [false, true]) {
    test(
      '${configure ? 'configuration' : 'user append'} commits before publication and response',
      () async {
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
        gate.complete();
        await completed;
        final after = await peer.snapshot('session');
        expect(
          after.instructions,
          configure ? 'Both fields.' : before.instructions,
        );
        expect(after.maxModelInvocations, configure ? 2 : 8);
        expect(after.entries.length, configure ? 0 : 1);
        final reloaded = await ChatSessionBackend(
          ChatSessionStore(storage: storage),
        ).snapshot('session');
        expect(reloaded.instructions, after.instructions);
        expect(reloaded.maxModelInvocations, after.maxModelInvocations);
        expect(
          reloaded.entries.map((e) => e.id),
          after.entries.map((e) => e.id),
        );
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

  for (final change in ['configuration', 'counter']) {
    test(
      'stale generation $change preconditions reject config and append',
      () async {
        await service.snapshot('session');
        final stale = ChatSessionBackend(ChatSessionStore(storage: storage));
        await stale.snapshot('session');
        if (change == 'configuration') {
          await service.configureSession('session', 'New configuration.', 2);
        } else {
          await service.appendUserMessage('session', 'New occurrence.');
        }
        await expectLater(
          stale.configureSession('session', 'Stale.', 4),
          throwsStateError,
        );
        await expectLater(
          stale.appendUserMessage('session', 'Stale.'),
          throwsStateError,
        );
        final unchanged = await stale.snapshot('session');
        expect(unchanged.instructions, chatDefaultInstructions);
        expect(unchanged.maxModelInvocations, 8);
        expect(unchanged.entries, isEmpty);
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
    await service.configureSession('session', 'Volatile.', 2);
    expect(
      (await service.appendUserMessage('session', 'Prompt.')).id,
      'entry-0',
    );
    expect((await service.snapshot('session')).instructions, 'Volatile.');
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
    'hydration seeks beyond 1000 entries without OFFSET and preserves exact next ID',
    () async {
      await service.snapshot('session');
      storage.database.execute('BEGIN');
      final insert = storage.database.prepare(
        'INSERT INTO adele_chat_entries VALUES (?, ?, ?, ?, ?)',
      );
      try {
        for (var index = 0; index < 1105; index++) {
          insert.execute([
            'session',
            index,
            'entry-$index',
            index.isEven ? 'user' : 'assistant',
            'Raw $index\r\n',
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
                }
              : {
                  'session_id': 'session',
                  'sequence': 0,
                  'entry_id': 'entry-0',
                  'role': 'user',
                  'content': value,
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
        if (!hostVolatile) {
          final state = store.obtain(SessionId('session'));
          state.instructions = '$content!';
          expect(state.appendUserMessage('$content!').id, 'entry-1');
        }
        expect(volatile.transactions, 0);
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

final _busy = throwsA(
  isA<ChatSessionFailure>().having((e) => e.code, 'code', 'session_busy'),
);
