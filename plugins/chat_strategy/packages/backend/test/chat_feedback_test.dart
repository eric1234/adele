import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_product/adele_product.dart' show TaskId;
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:test/test.dart';

import 'support/chat_storage.dart';

void main() {
  late ChatTestStorage storage;
  late ChatSessionStore store;
  late ChatSessionBackend chat;
  late ChatSessionFeedbackService feedback;
  late ChatFeedbackInspectionBackend inspection;

  setUp(() {
    storage = ChatTestStorage();
    store = ChatSessionStore(storage: storage);
    chat = ChatSessionBackend(store);
    feedback = ChatSessionFeedbackService(store);
    inspection = ChatFeedbackInspectionBackend(storage);
  });
  tearDown(() async {
    await feedback.close();
    storage.close();
  });

  Future<SessionFeedbackReceipt> accept(
    SessionFeedbackSubmission submission, {
    String session = 'session',
  }) => feedback.accept(chatStrategyRouteId, session, submission);

  Future<SessionFeedbackRecord?> lookup(
    String submissionId, {
    String session = 'session',
  }) => feedback.lookup(chatStrategyRouteId, session, submissionId);

  ChatRemoteOrchestrationBackend guardedBackend(ChatSessionStore sessions) {
    final backend = ChatRemoteOrchestrationBackend(
      sessions: sessions,
      maxModelInvocations: 8,
      hostChannel: (_) => throw StateError('No execution expected.'),
    );
    addTearDown(backend.close);
    return backend;
  }

  test(
    'metadata is durable relationship data, never inferred from prose',
    () async {
      final submission = _submission();
      final content = renderChatSessionFeedback(submission);
      await chat.appendUserMessage('session', content);
      await chat.setDraftRequest('session', '  Retained draft\r\n');
      final receipt = await accept(submission);
      await chat.appendUserMessage('session', content);
      final reopened = ChatSessionBackend(ChatSessionStore(storage: storage));
      final queries = storage.queries;
      for (final reader in [chat, reopened]) {
        final snapshot = await reader.snapshot('session');
        expect(snapshot.entries.map((entry) => entry.id), [
          'entry-0',
          'entry-1',
          'entry-2',
        ]);
        expect(snapshot.entries.map((entry) => entry.content), [
          content,
          content,
          content,
        ]);
        expect(snapshot.entries.map((entry) => entry.runId), [
          null,
          null,
          null,
        ]);
        expect(snapshot.draftRequest, '  Retained draft\r\n');
        expect(snapshot.entries.first.feedback, isNull);
        expect(snapshot.entries.last.feedback, isNull);
        final metadata = snapshot.entries[1].feedback!;
        expect(metadata.kind, ChatFeedbackKind.codeReview);
        expect(metadata.submissionId, receipt.submissionId);
        expect(metadata.commentCount, submission.comments.length);
      }
      final hydrationQueries = storage.querySql.skip(queries);
      expect(
        hydrationQueries.any((sql) => sql.contains('json_array_length')),
        isTrue,
      );
      expect(
        hydrationQueries.any((sql) => sql.contains('f.canonical_payload')),
        isFalse,
      );
      for (final occurrence in ['entry-0', 'entry-2', 'entry-99']) {
        await expectLater(
          inspection.readAcceptedFeedback('session', occurrence),
          _inspectionFailure('not_found'),
        );
      }
      _expectInspected(
        await inspection.readAcceptedFeedback('session', receipt.occurrenceId),
        submission,
        occurrenceId: receipt.occurrenceId,
      );
    },
  );

  test(
    'Inspection is read-only before acceptance, while claimed and after reopen',
    () async {
      await expectLater(
        inspection.readAcceptedFeedback('session', 'entry-0'),
        _inspectionFailure('unavailable'),
      );
      expect(storage.schemaChecks, 0);
      expect(storage.transactions, 0);
      expect(
        storage.database.select(
          "SELECT name FROM sqlite_master WHERE name LIKE 'adele_chat_%'",
        ),
        isEmpty,
      );
      final submission = _submission();
      final receipt = await accept(submission);
      final before = await chat.snapshot('session');
      final writes = storage.transactions;
      final schemas = storage.schemaChecks;
      _expectInspected(
        await inspection.readAcceptedFeedback('session', receipt.occurrenceId),
        submission,
      );
      expect(storage.transactions, writes);
      expect(storage.schemaChecks, schemas);
      final backend = guardedBackend(store);
      final execution = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'later-run',
        RemoteExpectedSessionFeedback.fromLocal(receipt),
      );
      final associated = (await chat.snapshot('session')).entries.single;
      expect(associated.content, before.entries.single.content);
      expect(associated.feedback!.submissionId, receipt.submissionId);
      final associatedWrites = storage.transactions;
      _expectInspected(
        await inspection.readAcceptedFeedback('session', receipt.occurrenceId),
        submission,
        runId: 'later-run',
      );
      await backend.release(execution);
      final reopened = ChatSessionBackend(ChatSessionStore(storage: storage));
      final restored = (await reopened.snapshot('session')).entries.single;
      expect(restored.feedback!.commentCount, 3);
      expect(restored.feedback!.submissionId, receipt.submissionId);
      expect(restored.runId, 'later-run');
      _expectInspected(
        await ChatFeedbackInspectionBackend(
          storage,
        ).readAcceptedFeedback('session', receipt.occurrenceId),
        submission,
        runId: 'later-run',
      );
      expect(storage.transactions, associatedWrites);
    },
  );

  test(
    'Inspection request, missing Session and storage failures are safe',
    () async {
      for (final (sessionId, occurrenceId) in [
        ('', 'entry-0'),
        (' session', 'entry-0'),
        ('session', ''),
        ('session', 'bad\u0000id'),
        ('session', 'x' * 257),
      ]) {
        await expectLater(
          inspection.readAcceptedFeedback(sessionId, occurrenceId),
          _inspectionFailure('invalid_request'),
        );
      }
      expect(storage.durabilityChecks, 0);
      await expectLater(
        inspection.readAcceptedFeedback('missing', 'entry-0'),
        _inspectionFailure('unavailable'),
      );
      final volatile = ChatTestStorage(durable: false);
      addTearDown(volatile.close);
      for (final unavailable in [
        ChatFeedbackInspectionBackend(null),
        ChatFeedbackInspectionBackend(volatile),
      ]) {
        await expectLater(
          unavailable.readAcceptedFeedback('session', 'entry-0'),
          _inspectionFailure('unavailable'),
        );
      }
      expect(volatile.schemaChecks, 0);
      expect(volatile.transactions, 0);
      expect(volatile.queries, 0);
      await accept(_submission());
      storage.failure = StateError('Secret SQL details and private text.');
      await expectLater(
        inspection.readAcceptedFeedback('session', 'entry-0'),
        _inspectionFailure('unavailable'),
      );
    },
  );

  for (final (name, sql) in [
    (
      'malformed JSON',
      "UPDATE adele_chat_feedback_submissions SET canonical_payload = '{broken'",
    ),
    (
      'invalid structured payload',
      "UPDATE adele_chat_feedback_submissions SET canonical_payload = '{}'",
    ),
    (
      'noncanonical payload',
      "UPDATE adele_chat_feedback_submissions SET canonical_payload = canonical_payload || ' '",
    ),
    (
      'submission identity',
      "UPDATE adele_chat_feedback_submissions SET submission_id = 'changed'",
    ),
    (
      'canonical content',
      "UPDATE adele_chat_entries SET content = 'Changed canonical content.'",
    ),
    (
      'assistant relationship',
      "UPDATE adele_chat_entries SET role = 'assistant'",
    ),
    ('canonical sequence', 'UPDATE adele_chat_entries SET sequence = 5'),
    ('canonical counter', 'UPDATE adele_chat_sessions SET next_entry = 0'),
    ('invalid Run', "UPDATE adele_chat_entries SET run_id = ' invalid '"),
    (
      'orphan relationship',
      'PRAGMA foreign_keys = OFF; DELETE FROM adele_chat_entries;',
    ),
    (
      'missing Chat Session',
      'PRAGMA foreign_keys = OFF; DELETE FROM adele_chat_sessions;',
    ),
    (
      'duplicate relationship',
      '''
PRAGMA foreign_keys = OFF;
CREATE TABLE broken_feedback AS SELECT * FROM adele_chat_feedback_submissions;
DROP TABLE adele_chat_feedback_submissions;
ALTER TABLE broken_feedback RENAME TO adele_chat_feedback_submissions;
INSERT INTO adele_chat_feedback_submissions SELECT * FROM adele_chat_feedback_submissions;
''',
    ),
  ]) {
    test('Inspection rejects $name without writes or cache refresh', () async {
      await accept(_submission());
      final cached = (await chat.snapshot('session')).entries.single;
      storage.database.execute(sql);
      final writes = storage.transactions;
      final schemas = storage.schemaChecks;
      await expectLater(
        inspection.readAcceptedFeedback('session', 'entry-0'),
        _inspectionFailure('corrupt'),
      );
      expect(storage.transactions, writes);
      expect(storage.schemaChecks, schemas);
      expect((await chat.snapshot('session')).entries.single, same(cached));
    });
  }

  for (final sql in [
    "UPDATE adele_chat_feedback_submissions SET canonical_payload = '{broken'",
    "UPDATE adele_chat_feedback_submissions SET canonical_payload = '{}'",
    "UPDATE adele_chat_feedback_submissions SET canonical_payload = json_set(canonical_payload, '\$.kind', 'unknown')",
    "UPDATE adele_chat_feedback_submissions SET canonical_payload = json_set(canonical_payload, '\$.comments', json('[]'))",
    "UPDATE adele_chat_feedback_submissions SET submission_id = 'changed'",
    "UPDATE adele_chat_entries SET role = 'assistant'",
    "PRAGMA foreign_keys = OFF; UPDATE adele_chat_feedback_submissions SET entry_id = 'missing';",
  ]) {
    test('hydration rejects invalid narrow metadata: $sql', () async {
      await accept(_submission());
      storage.database.execute(sql);
      final writes = storage.transactions;
      await expectLater(
        ChatSessionBackend(
          ChatSessionStore(storage: storage),
        ).snapshot('session'),
        throwsA(isA<ChatStateCorruption>()),
      );
      expect(storage.transactions, writes);
    });
  }

  test(
    '128 KiB canonical feedback is fully readable through both generated transports',
    () async {
      final storageDispatcher = ProjectStorageServiceDispatcher(storage);
      addTearDown(storageDispatcher.close);
      final client = ProjectStorageServiceClient(
        _DirectChannel(storageDispatcher),
      );
      final remoteStore = ChatSessionStore(storage: client);
      final acceptance = ChatSessionFeedbackService(remoteStore);
      addTearDown(acceptance.close);
      final dispatcher = ChatFeedbackInspectionServiceDispatcher(
        ChatFeedbackInspectionBackend(client),
      );
      addTearDown(dispatcher.close);
      final inspector = ChatFeedbackInspectionServiceClient(
        _DirectChannel(dispatcher),
      );
      final comments = List.generate(
        32,
        (index) => _comment(index + 1, text: 'a'),
      );
      SessionFeedbackSubmission submission() => SessionFeedbackSubmission(
        submissionId: 'review',
        kind: SessionFeedbackKind.codeReview,
        comments: comments,
      );
      var remaining =
          SessionFeedbackLimits.maxSubmissionBytes -
          utf8.encode(encodeSessionFeedbackSubmission(submission())).length;
      for (var index = 0; index < comments.length; index++) {
        final count = remaining < SessionFeedbackLimits.maxTextLength - 1
            ? remaining
            : SessionFeedbackLimits.maxTextLength - 1;
        comments[index] = _comment(index + 1, text: 'a${'x' * count}');
        remaining -= count;
      }
      expect(remaining, 0);
      final value = submission();
      expect(
        utf8.encode(encodeSessionFeedbackSubmission(value)).length,
        128 * 1024,
      );
      await acceptance.accept(chatStrategyRouteId, 'session', value);
      final writes = storage.transactions;
      final schemas = storage.schemaChecks;
      final inspected = await inspector.readAcceptedFeedback(
        'session',
        'entry-0',
      );
      _expectInspected(inspected, value);
      expect(storage.transactions, writes);
      expect(storage.schemaChecks, schemas);
      final restored = await ChatSessionBackend(
        ChatSessionStore(storage: client),
      ).snapshot('session');
      expect(restored.entries.single.feedback!.commentCount, 32);
      expect(restored.entries.single.content, renderChatSessionFeedback(value));
    },
  );

  test(
    'expected feedback retains durable association without starting',
    () async {
      final receipt = await accept(_submission());
      final backend = guardedBackend(store);
      final expected = RemoteExpectedSessionFeedback.fromLocal(receipt);
      final execution = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'accepted-run',
        expected,
      );
      expect((await lookup('review'))!.runId, 'accepted-run');
      expect(_identity(await accept(_submission())), _identity(receipt));
      await backend.release(execution);

      // Repeating the exact Run association is allowed, never another Run.
      final repeated = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'accepted-run',
        expected,
      );
      await backend.release(repeated);
      final reopenedStore = ChatSessionStore(storage: storage);
      final reopened = guardedBackend(reopenedStore);
      final durable = await ChatSessionFeedbackService(
        reopenedStore,
      ).lookup(chatStrategyRouteId, 'session', 'review');
      expect(durable!.runId, 'accepted-run');
      await expectLater(
        reopened.materialize(
          chatStrategyRouteId,
          _session,
          'duplicate',
          expected,
        ),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect((await lookup('review'))!.runId, 'accepted-run');
      expect((await chat.snapshot('session')).entries, hasLength(1));
    },
  );

  for (final laterFeedback in [false, true]) {
    test(
      'superseded feedback never associates later input ($laterFeedback)',
      () async {
        final receipt = await accept(_submission());
        if (laterFeedback) {
          await accept(_submission(id: 'later'));
        } else {
          await chat.appendUserMessage('session', 'Unrelated later input.');
        }
        final backend = guardedBackend(store);
        final writes = storage.transactions;
        await expectLater(
          backend.materialize(
            chatStrategyRouteId,
            _session,
            'must-not-associate',
            RemoteExpectedSessionFeedback.fromLocal(receipt),
          ),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(storage.transactions, writes);
        expect((await lookup('review'))!.runId, isNull);
        expect((await chat.snapshot('session')).entries.map((e) => e.runId), [
          null,
          null,
        ]);
        // The normal null-input path is unchanged and can use the latest input.
        final ordinary = await backend.materialize(
          chatStrategyRouteId,
          _session,
          'ordinary-run',
          null,
        );
        expect(
          (await chat.snapshot('session')).entries.last.runId,
          'ordinary-run',
        );
        expect((await lookup('review'))!.runId, isNull);
        await backend.release(ordinary);
      },
    );
  }

  test(
    'expected receipt must identify its exact accepted submission',
    () async {
      await accept(_submission());
      final backend = guardedBackend(store);
      for (final expected in [
        RemoteExpectedSessionFeedback(
          submissionId: 'absent',
          occurrenceId: 'entry-0',
        ),
        RemoteExpectedSessionFeedback(
          submissionId: 'review',
          occurrenceId: 'entry-1',
        ),
      ]) {
        await expectLater(
          backend.materialize(
            chatStrategyRouteId,
            _session,
            'wrong-run',
            expected,
          ),
          throwsA(isA<InvalidRunOperation>()),
        );
      }
      expect((await lookup('review'))!.runId, isNull);
      await chat.appendUserMessage('session', 'Claim released.');
    },
  );

  test(
    'cross-generation supersession races fail the atomic association CAS',
    () async {
      final receipt = await accept(_submission());
      final backend = guardedBackend(store);
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.beforeTransaction = () {
        entered.complete();
        return gate.future;
      };
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final materializing = backend.materialize(
        chatStrategyRouteId,
        _session,
        'stale-run',
        RemoteExpectedSessionFeedback.fromLocal(receipt),
      );
      final rejected = expectLater(materializing, throwsStateError);
      await entered.future;
      storage.beforeTransaction = null;
      await ChatSessionBackend(
        ChatSessionStore(storage: storage),
      ).appendUserMessage('session', 'Won before the association transaction.');
      gate.complete();
      await rejected;
      expect((await lookup('review'))!.runId, isNull);
      expect((await chat.snapshot('session')).entries.map((e) => e.runId), [
        null,
        null,
      ]);
    },
  );

  test(
    'lost association acknowledgement refreshes cache and forbids another Run',
    () async {
      final receipt = await accept(_submission());
      final backend = guardedBackend(store);
      final entered = Completer<void>();
      final acknowledgement = Completer<void>();
      addTearDown(() {
        storage.afterCommit = null;
        if (!acknowledgement.isCompleted) acknowledgement.complete();
      });
      storage.afterCommit = () {
        entered.complete();
        return acknowledgement.future;
      };
      final materializing = backend.materialize(
        chatStrategyRouteId,
        _session,
        'committed-run',
        RemoteExpectedSessionFeedback.fromLocal(receipt),
      );
      final rejected = expectLater(materializing, throwsStateError);
      await entered.future;
      expect((await lookup('review'))!.runId, 'committed-run');
      expect((await chat.snapshot('session')).entries.single.runId, isNull);
      acknowledgement.completeError(
        StateError('Lost association acknowledgement.'),
      );
      await rejected;
      storage.afterCommit = null;
      expect(
        (await chat.snapshot('session')).entries.single.runId,
        'committed-run',
      );
      await expectLater(
        backend.materialize(
          chatStrategyRouteId,
          _session,
          'must-not-retry',
          RemoteExpectedSessionFeedback.fromLocal(receipt),
        ),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect((await lookup('review'))!.runId, 'committed-run');
    },
  );

  test(
    'native strategy target retains feedback independently of Run budgets',
    () async {
      final session = Session(
        id: SessionId('session'),
        taskId: TaskId('task'),
        strategyId: chatStrategyId,
      );
      final plugin = ChatStrategyPlugin(
        sessions: store,
        maxModelInvocations: 1,
      );
      final target = plugin.contribution.feedbackTarget!(session);
      final receipt = await target.accept(_submission());
      expect(_identity(receipt), ('review', 'session', 'entry-0'));
      expect(
        _identity((await target.lookup('review'))!.receipt),
        _identity(receipt),
      );
      final replacement = ChatStrategyPlugin(
        sessions: ChatSessionStore(storage: storage),
        maxModelInvocations: 2,
      ).contribution.feedbackTarget!(session);
      expect(
        _identity(await replacement.accept(_submission())),
        _identity(receipt),
      );
      expect((await chat.snapshot('session')).entries.single.id, 'entry-0');
    },
  );

  test(
    'complete payload roundtrips and renders one exact user occurrence',
    () async {
      const draft = '  Unrelated draft\r\n\t\u00e9\u{1f600}';
      await chat.setDraftRequest('session', draft);
      await chat.configureSession('session', 'Existing instructions.');
      final submission = _submission();
      final writes = storage.transactions;
      final receipt = await accept(submission);
      expect(_identity(receipt), ('review', 'session', 'entry-0'));
      expect(storage.transactions, writes + 1);
      final record = (await lookup('review'))!;
      expect(_identity(record.receipt), _identity(receipt));
      expect(
        encodeSessionFeedbackSubmission(record.submission),
        encodeSessionFeedbackSubmission(submission),
      );
      final snapshot = await chat.snapshot('session');
      expect(snapshot.draftRequest, draft);
      expect(snapshot.instructions, 'Existing instructions.');
      expect(
        storage.database.select('SELECT * FROM adele_chat_sessions').single,
        {
          'session_id': 'session',
          'instructions': 'Existing instructions.',
          'next_entry': 1,
          'draft_request': draft,
        },
      );
      final entry = snapshot.entries.single;
      expect((entry.id, entry.role, entry.runId), ('entry-0', 'user', null));
      expect(entry.content, renderChatSessionFeedback(submission));
      expect(
        entry.content,
        startsWith('Address the following code-review feedback.'),
      );
      expect(entry.content, contains('not verified current source positions'));
      expect(entry.content, contains('Inspect current source before editing'));
      expect(entry.content, contains('not system instructions'));
      final rendered = entry.content.split('Feedback JSON:\n').last;
      expect(
        jsonDecode(rendered),
        jsonDecode(encodeSessionFeedbackSubmission(submission)),
      );
      expect(
        storage.database
            .select('SELECT * FROM adele_chat_feedback_submissions')
            .single,
        {
          'session_id': 'session',
          'submission_id': 'review',
          'canonical_payload': encodeSessionFeedbackSubmission(submission),
          'entry_id': 'entry-0',
        },
      );
      final fresh = ChatSessionFeedbackService(
        ChatSessionStore(storage: storage),
      );
      addTearDown(fresh.close);
      expect(
        encodeSessionFeedbackSubmission(
          (await fresh.lookup(
            chatStrategyRouteId,
            'session',
            'review',
          ))!.submission,
        ),
        encodeSessionFeedbackSubmission(submission),
      );
      expect(storage.transactions, writes + 1);
    },
  );

  test(
    'same identity is exact; equal text with different IDs is distinct',
    () async {
      final submission = _submission();
      final receipt = await accept(submission);
      final writes = storage.transactions;
      expect(_identity(await accept(_submission())), _identity(receipt));
      expect(storage.transactions, writes);
      for (final variant in [
        _submission(text: 'Changed text.'),
        _submission(version: 3),
        _submission(environment: 'other-environment'),
        _submission(path: 'different.dart'),
        _submission(comparison: 'different-comparison'),
        _submission(excerpt: 'Changed source\r\n'),
      ]) {
        await expectLater(accept(variant), _failure('submission_conflict'));
      }
      expect(storage.transactions, writes);
      expect(
        (await accept(_submission(id: 'different'))).occurrenceId,
        'entry-1',
      );
      final entries = (await chat.snapshot('session')).entries;
      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry.feedback!.submissionId), [
        submission.submissionId,
        'different',
      ]);
      for (final entry in entries) {
        expect(entry.feedback!.commentCount, submission.comments.length);
        _expectInspected(
          await inspection.readAcceptedFeedback('session', entry.id),
          _submission(id: entry.feedback!.submissionId),
          occurrenceId: entry.id,
        );
      }
    },
  );

  test(
    'same-store concurrent duplicates coalesce only while in flight',
    () async {
      await chat.snapshot('session');
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.beforeTransaction = () {
        entered.complete();
        return gate.future;
      };
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final writes = storage.transactions;
      final first = accept(_submission());
      await entered.future;
      final duplicate = ChatSessionFeedbackService(
        store,
      ).accept(chatStrategyRouteId, 'session', _submission());
      final conflict = expectLater(
        accept(_submission(text: 'Conflicting.')),
        _failure('submission_conflict'),
      );
      expect((await chat.snapshot('session')).entries, isEmpty);
      expect(await lookup('review'), isNull);
      await expectLater(
        accept(_submission(id: 'new')),
        _failure('session_busy'),
      );
      await expectLater(
        chat.appendUserMessage('session', 'Ordinary.'),
        throwsA(isA<ChatSessionFailure>()),
      );
      gate.complete();
      final receipts = await Future.wait([first, duplicate]);
      await conflict;
      expect(_identity(receipts.first), _identity(receipts.last));
      expect(storage.transactions, writes + 1);
      storage.beforeTransaction = null;
      storage.failure = StateError('Read unavailable, not a cached receipt.');
      await expectLater(accept(_submission()), _failure('storage_failure'));
      await expectLater(lookup('review'), _failure('storage_failure'));
    },
  );

  for (final fresh in [false, true]) {
    test(
      'independent ${fresh ? 'fresh' : 'loaded'} stores accept one concurrent occurrence',
      () async {
        final otherStore = ChatSessionStore(storage: storage);
        final other = ChatSessionFeedbackService(otherStore);
        addTearDown(other.close);
        if (!fresh) {
          await chat.snapshot('session');
          await otherStore.load(SessionId('session'));
        }
        final receipts = await Future.wait([
          accept(_submission()),
          other.accept(chatStrategyRouteId, 'session', _submission()),
        ]);
        expect(_identity(receipts.first), _identity(receipts.last));
        expect(
          storage.database.select('SELECT * FROM adele_chat_entries'),
          hasLength(1),
        );
        expect(
          storage.database.select(
            'SELECT * FROM adele_chat_feedback_submissions',
          ),
          hasLength(1),
        );
        expect(
          storage.database
              .select('SELECT next_entry FROM adele_chat_sessions')
              .single['next_entry'],
          1,
        );
        expect(
          (await ChatSessionBackend(otherStore).snapshot('session')).entries,
          hasLength(1),
        );
        expect((await chat.snapshot('session')).entries, hasLength(1));
      },
    );
  }

  test(
    'SQL CAS reconciles independent conflicting identity without replay',
    () async {
      await chat.snapshot('session');
      final otherStore = ChatSessionStore(storage: storage);
      final other = ChatSessionFeedbackService(otherStore);
      addTearDown(other.close);
      await otherStore.load(SessionId('session'));
      final gate = Completer<void>();
      final entered = Completer<void>();
      var calls = 0;
      storage.beforeTransaction = () {
        if (++calls == 2) entered.complete();
        return gate.future;
      };
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final first = accept(_submission());
      final second = other.accept(
        chatStrategyRouteId,
        'session',
        _submission(text: 'Different.'),
      );
      final rejected = expectLater(second, _failure('submission_conflict'));
      await entered.future;
      gate.complete();
      expect((await first).occurrenceId, 'entry-0');
      await rejected;
      expect(calls, 2);
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        hasLength(1),
      );
    },
  );

  test(
    'stale counter/configuration/draft CAS never overwrites or replays',
    () async {
      await chat.setDraftRequest('session', 'Original.');
      final staleStore = ChatSessionStore(storage: storage);
      final stale = ChatSessionFeedbackService(staleStore);
      addTearDown(stale.close);
      await staleStore.load(SessionId('session'));
      await chat.configureSession('session', 'New instructions.');
      await chat.setDraftRequest('session', 'New draft.');
      await chat.appendUserMessage('session', 'Independent accepted input.');
      final writes = storage.transactions;
      await expectLater(
        stale.accept(chatStrategyRouteId, 'session', _submission()),
        _failure('storage_failure'),
      );
      expect(storage.transactions, writes + 1);
      expect(await lookup('review'), isNull);
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        hasLength(1),
      );
      final snapshot = await ChatSessionBackend(staleStore).snapshot('session');
      expect(snapshot.instructions, 'New instructions.');
      expect(snapshot.draftRequest, 'New draft.');
      expect(snapshot.entries.single.content, 'Independent accepted input.');
    },
  );

  test(
    'accepted lookup refreshes stale history without losing unrelated entries',
    () async {
      await chat.snapshot('session');
      final staleStore = ChatSessionStore(storage: storage);
      final stale = ChatSessionFeedbackService(staleStore);
      addTearDown(stale.close);
      final state = await staleStore.load(SessionId('session'));
      await chat.appendUserMessage('session', 'Earlier.');
      await accept(_submission());
      await chat.appendUserMessage('session', 'Later.');
      expect(state.snapshot().entries, isEmpty);
      expect(
        (await stale.lookup(
          chatStrategyRouteId,
          'session',
          'review',
        ))!.receipt.occurrenceId,
        'entry-1',
      );
      expect(await staleStore.load(SessionId('session')), same(state));
      expect(state.snapshot().entries.map((e) => e.id), [
        'entry-0',
        'entry-1',
        'entry-2',
      ]);
      expect(
        (await ChatSessionBackend(
          staleStore,
        ).appendUserMessage('session', 'Next.')).id,
        'entry-3',
      );
    },
  );

  test(
    'accepted duplicate and lookup stay readable while execution owns claim',
    () async {
      final receipt = await accept(_submission());
      final backend = ChatRemoteOrchestrationBackend(
        sessions: store,
        maxModelInvocations: 8,
        hostChannel: (_) => throw StateError('No execution expected.'),
      );
      addTearDown(backend.close);
      final execution = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'run',
        null,
      );
      final writes = storage.transactions;
      expect(_identity((await lookup('review'))!.receipt), _identity(receipt));
      expect(_identity(await accept(_submission())), _identity(receipt));
      await expectLater(
        accept(_submission(id: 'new')),
        _failure('session_busy'),
      );
      await expectLater(
        accept(_submission(text: 'Different.')),
        _failure('submission_conflict'),
      );
      await expectLater(
        chat.setDraftRequest('session', 'Blocked.'),
        throwsA(isA<ChatSessionFailure>()),
      );
      expect(storage.transactions, writes);
      expect((await chat.snapshot('session')).entries.single.runId, 'run');
      await backend.release(execution);
      expect(
        (await accept(_submission(id: 'after-release'))).occurrenceId,
        'entry-1',
      );
    },
  );

  test(
    'active stale cache is not replaced; idle load refreshes before next run',
    () async {
      await chat.snapshot('session');
      final backend = ChatRemoteOrchestrationBackend(
        sessions: store,
        maxModelInvocations: 8,
        hostChannel: (_) => throw StateError('No execution expected.'),
      );
      addTearDown(backend.close);
      final state = await store.load(SessionId('session'));
      final execution = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'old-run',
        null,
      );
      final independent = ChatSessionFeedbackService(
        ChatSessionStore(storage: storage),
      );
      addTearDown(independent.close);
      await independent.accept(chatStrategyRouteId, 'session', _submission());
      expect((await lookup('review'))!.receipt.occurrenceId, 'entry-0');
      expect(state.snapshot().entries, isEmpty);
      await expectLater(
        accept(_submission(id: 'blocked')),
        _failure('session_busy'),
      );
      await backend.release(execution);
      final next = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'new-run',
        null,
      );
      expect(state.snapshot().entries.single.runId, 'new-run');
      await backend.release(next);
    },
  );

  test(
    'receipt insert rollback is atomic and does not publish or consume ID',
    () async {
      await chat.setDraftRequest('session', 'Retained.');
      final state = await store.load(SessionId('session'));
      storage.database.execute('''
CREATE TRIGGER reject_feedback AFTER INSERT ON adele_chat_feedback_submissions
BEGIN SELECT RAISE(ABORT, 'private SQL failure'); END;
''');
      final writes = storage.transactions;
      await expectLater(accept(_submission()), _failure('outcome_uncertain'));
      expect(storage.transactions, writes + 1);
      expect(state.snapshot().entries, isEmpty);
      expect(state.draftRequest, 'Retained.');
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
      expect(
        storage.database.select(
          'SELECT * FROM adele_chat_feedback_submissions',
        ),
        isEmpty,
      );
      expect(await lookup('review'), isNull);
      expect(storage.transactions, writes + 1);
      storage.database.execute('DROP TRIGGER reject_feedback');
      expect((await accept(_submission())).occurrenceId, 'entry-0');
    },
  );

  test(
    'lost acknowledgement after commit is uncertain; explicit lookup recovers',
    () async {
      await chat.setDraftRequest('session', 'Retained.');
      final state = await store.load(SessionId('session'));
      final writes = storage.transactions;
      storage.afterCommit = () async => throw StateError('Private lost ACK.');
      await expectLater(accept(_submission()), _failure('outcome_uncertain'));
      expect(storage.transactions, writes + 1);
      expect(state.snapshot().entries, isEmpty);
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        hasLength(1),
      );
      expect(
        storage.database.select(
          'SELECT * FROM adele_chat_feedback_submissions',
        ),
        hasLength(1),
      );
      storage.afterCommit = null;
      final record = (await lookup('review'))!;
      expect(record.receipt.occurrenceId, 'entry-0');
      expect(state.snapshot().entries.single.id, 'entry-0');
      expect(state.draftRequest, 'Retained.');
      expect(_identity(await accept(_submission())), _identity(record.receipt));
      final fresh = ChatSessionFeedbackService(
        ChatSessionStore(storage: storage),
      );
      addTearDown(fresh.close);
      expect(
        _identity(
          await fresh.accept(chatStrategyRouteId, 'session', _submission()),
        ),
        _identity(record.receipt),
      );
      expect(storage.transactions, writes + 1);
    },
  );

  for (final operation in [
    'materialize',
    'append',
    'setDraft',
    'submitDraft',
    'configure',
  ]) {
    test('uncertain ACK fences an already-loaded $operation claim', () async {
      await chat.setDraftRequest('session', 'Unrelated draft.');
      final state = await store.load(SessionId('session'));
      final backend = ChatRemoteOrchestrationBackend(
        sessions: store,
        maxModelInvocations: 8,
        hostChannel: (_) => throw StateError('No execution expected.'),
      );
      addTearDown(backend.close);
      final committed = Completer<void>();
      final ack = Completer<void>();
      storage.afterCommit = () {
        committed.complete();
        return ack.future;
      };
      final rejected = expectLater(
        accept(_submission()),
        _failure('outcome_uncertain'),
      );
      await committed.future;
      final writes = storage.transactions;
      expect(state.snapshot().entries, isEmpty);
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        hasLength(1),
      );
      // load() still sees the held acceptance claim and returns its completed
      // cached Future. The write error flags it stale before this continuation
      // attempts to acquire a new claim. No sleep or scheduling guess is needed.
      ack.completeError(StateError('Lost acknowledgement.'));
      final Future<Object?> racing = switch (operation) {
        'materialize' => backend.materialize(
          chatStrategyRouteId,
          _session,
          'racing-run',
          null,
        ),
        'append' => chat.appendUserMessage('session', 'Must not append.'),
        'setDraft' => chat.setDraftRequest('session', 'Must not replace.'),
        'submitDraft' => chat.submitDraftRequest('session'),
        'configure' => chat.configureSession('session', 'Must not configure.'),
        _ => throw StateError('Unknown operation.'),
      };
      await expectLater(racing, throwsStateError);
      await rejected;
      expect(storage.transactions, writes);
      expect(state.snapshot().entries, isEmpty);
      expect(state.draftRequest, 'Unrelated draft.');
      storage.afterCommit = null;
      expect((await lookup('review'))!.receipt.occurrenceId, 'entry-0');
      expect(state.snapshot().entries.single.id, 'entry-0');
      expect(storage.transactions, writes);
      final execution = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'explicit-run',
        null,
      );
      expect(state.snapshot().entries.single.runId, 'explicit-run');
      await backend.release(execution);
    });
  }

  for (final active in [false, true]) {
    test(
      'conflicting accepted read refreshes ${active ? 'after active claim release' : 'idle stale history'}',
      () async {
        final state = await store.load(SessionId('session'));
        final backend = ChatRemoteOrchestrationBackend(
          sessions: store,
          maxModelInvocations: 8,
          hostChannel: (_) => throw StateError('No execution expected.'),
        );
        addTearDown(backend.close);
        final oldExecution = active
            ? await backend.materialize(
                chatStrategyRouteId,
                _session,
                'old-run',
                null,
              )
            : null;
        final independent = ChatSessionFeedbackService(
          ChatSessionStore(storage: storage),
        );
        addTearDown(independent.close);
        await independent.accept(chatStrategyRouteId, 'session', _submission());
        expect(state.snapshot().entries, isEmpty);
        final writes = storage.transactions;
        await expectLater(
          accept(_submission(text: 'Conflicting feedback.')),
          _failure('submission_conflict'),
        );
        expect(storage.transactions, writes);
        if (oldExecution != null) {
          expect(state.snapshot().entries, isEmpty);
          await backend.release(oldExecution);
        } else {
          expect(state.snapshot().entries.single.id, 'entry-0');
        }
        final next = await backend.materialize(
          chatStrategyRouteId,
          _session,
          'next-run',
          null,
        );
        expect(state.snapshot().entries.single.runId, 'next-run');
        await backend.release(next);
        expect(
          storage.database.select('SELECT * FROM adele_chat_entries'),
          hasLength(1),
        );
      },
    );
  }

  for (final loseAck in [false, true]) {
    test(
      'close drains admitted ${loseAck ? 'uncertain' : 'successful'} acceptance',
      () async {
        await chat.snapshot('session');
        final gate = Completer<void>();
        final entered = Completer<void>();
        storage.afterCommit = () async {
          entered.complete();
          await gate.future;
          if (loseAck) throw StateError('Lost ACK during shutdown.');
        };
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final accepting = accept(_submission());
        final result = expectLater(
          accepting,
          loseAck ? _failure('outcome_uncertain') : completes,
        );
        await entered.future;
        var closed = false;
        final closing = feedback.close().then((_) => closed = true);
        await expectLater(lookup('review'), _failure('stale_target'));
        await expectLater(
          accept(_submission(id: 'new')),
          _failure('stale_target'),
        );
        expect(closed, isFalse);
        expect((await chat.snapshot('session')).entries, isEmpty);
        gate.complete();
        await result;
        await closing;
        storage.afterCommit = null;
        final fresh = ChatSessionFeedbackService(
          ChatSessionStore(storage: storage),
        );
        addTearDown(fresh.close);
        expect(
          (await fresh.lookup(
            chatStrategyRouteId,
            'session',
            'review',
          ))!.receipt.occurrenceId,
          'entry-0',
        );
      },
    );
  }

  test(
    'Sessions and Projects independently scope identical submission IDs',
    () async {
      final first = await accept(_submission());
      final second = await accept(
        _submission(text: 'Other Session.'),
        session: 'other',
      );
      expect(_identity(first), ('review', 'session', 'entry-0'));
      expect(_identity(second), ('review', 'other', 'entry-0'));
      final project = ChatTestStorage();
      addTearDown(project.close);
      final other = ChatSessionFeedbackService(
        ChatSessionStore(storage: project),
      );
      addTearDown(other.close);
      expect(
        await other.lookup(chatStrategyRouteId, 'session', 'review'),
        isNull,
      );
      await other.accept(
        chatStrategyRouteId,
        'session',
        _submission(text: 'Other Project.'),
      );
      expect(
        (await lookup('review'))!.submission.comments.first.text,
        _submission().comments.first.text,
      );
      expect(
        (await other.lookup(
          chatStrategyRouteId,
          'session',
          'review',
        ))!.submission.comments.first.text,
        'Other Project.',
      );
    },
  );

  test(
    'ordinary append and draft submission retain original semantics',
    () async {
      await chat.setDraftRequest('session', '  Draft\r\n');
      await accept(_submission());
      final ordinary = await chat.appendUserMessage(
        'session',
        'Unchanged ordinary.',
      );
      expect(
        (ordinary.id, ordinary.content),
        ('entry-1', 'Unchanged ordinary.'),
      );
      final draft = await chat.submitDraftRequest('session');
      expect((draft.id, draft.content), ('entry-2', '  Draft\r\n'));
      expect((await chat.snapshot('session')).draftRequest, '');
      expect(
        storage.database.select(
          'SELECT * FROM adele_chat_feedback_submissions',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'bounded escaped payload and complete SQL rows remain readable',
    () async {
      final comments = <SessionFeedbackComment>[];
      for (var index = 1; index <= 16; index++) {
        final candidate = _comment(
          index,
          text: '\u0000\r\n\\"\u00e9\u{1f600}' * 400,
        );
        try {
          SessionFeedbackSubmission(
            submissionId: 'bounded',
            kind: SessionFeedbackKind.codeReview,
            comments: [...comments, candidate],
          );
          comments.add(candidate);
        } on SessionFeedbackFailure catch (error) {
          expect(error.code, 'submission_too_large');
          break;
        }
      }
      final submission = SessionFeedbackSubmission(
        submissionId: 'bounded',
        kind: SessionFeedbackKind.codeReview,
        comments: comments,
      );
      expect(
        utf8.encode(encodeSessionFeedbackSubmission(submission)).length,
        greaterThan(100 * 1024),
      );
      expect(
        utf8.encode(renderChatSessionFeedback(submission)).length,
        lessThanOrEqualTo(SessionFeedbackLimits.maxModelContentBytes),
      );
      await accept(submission);
      expect(
        encodeSessionFeedbackSubmission((await lookup('bounded'))!.submission),
        encodeSessionFeedbackSubmission(submission),
      );
    },
  );

  test(
    'counter growth row overflow is rejected before the acceptance write',
    () async {
      for (var index = 0; index < 9; index++) {
        await chat.appendUserMessage('session', 'Earlier.');
      }
      final emptyBytes =
          3 +
          utf8
              .encode(
                jsonEncode({
                  'values': {
                    'session_id': 'session',
                    'instructions': chatDefaultInstructions,
                    'next_entry': 9,
                    'draft_request': '',
                  },
                }),
              )
              .length;
      await chat.setDraftRequest(
        'session',
        'x' * (relationalQueryByteLimit - emptyBytes),
      );
      final writes = storage.transactions;
      await expectLater(
        accept(_submission()),
        _failure('submission_too_large'),
      );
      expect(storage.transactions, writes);
      expect(await lookup('review'), isNull);
      expect(
        storage.database.select('SELECT * FROM adele_chat_entries'),
        hasLength(9),
      );
    },
  );

  test(
    'read failures, missing baseline and corrupt payload are never absence',
    () async {
      await accept(_submission());
      storage.failure = StateError('Secret SQL error.');
      await expectLater(lookup('unknown'), _failure('storage_failure'));
      await expectLater(lookup('review'), _failure('storage_failure'));
      storage.failure = null;
      storage.database.execute(
        "UPDATE adele_chat_feedback_submissions SET canonical_payload = '{}' ",
      );
      await expectLater(lookup('review'), _failure('storage_failure'));
      storage.database.execute('DROP TABLE adele_chat_feedback_submissions');
      await expectLater(lookup('review'), _failure('storage_failure'));
      await expectLater(accept(_submission()), _failure('storage_failure'));
    },
  );

  test(
    'linked occurrence corruption fails even while a Run claim is active',
    () async {
      await accept(_submission());
      final backend = ChatRemoteOrchestrationBackend(
        sessions: store,
        maxModelInvocations: 8,
        hostChannel: (_) => throw StateError('No execution expected.'),
      );
      addTearDown(backend.close);
      final execution = await backend.materialize(
        chatStrategyRouteId,
        _session,
        'run',
        null,
      );
      storage.database.execute(
        "UPDATE adele_chat_entries SET run_id = ' invalid ' ",
      );
      await expectLater(lookup('review'), _failure('storage_failure'));
      storage.database.execute(
        "UPDATE adele_chat_entries SET run_id = 'run', content = 'Altered.' ",
      );
      await expectLater(lookup('review'), _failure('storage_failure'));
      await backend.release(execution);
    },
  );

  test(
    'invalid routes/identities and volatile storage fail without occurrence',
    () async {
      await expectLater(
        feedback.accept('wrong', 'session', _submission()),
        _failure('stale_target'),
      );
      await expectLater(
        feedback.accept(chatStrategyRouteId, ' session', _submission()),
        _failure('invalid_submission'),
      );
      await expectLater(lookup(' bad'), _failure('invalid_submission'));
      await expectLater(
        feedback.accept(
          chatStrategyRouteId,
          'x' * (SessionFeedbackLimits.maxIdentityLength + 1),
          _submission(),
        ),
        _failure('invalid_submission'),
      );
      expect(storage.transactions, 0);
      final volatile = ChatTestStorage(durable: false);
      addTearDown(volatile.close);
      final volatileStore = ChatSessionStore(storage: volatile);
      final target = ChatSessionFeedbackService(volatileStore);
      addTearDown(target.close);
      await expectLater(
        target.accept(chatStrategyRouteId, 'session', _submission()),
        _failure('storage_failure'),
      );
      expect(
        (await ChatSessionBackend(volatileStore).snapshot('session')).entries,
        isEmpty,
      );
      expect(volatile.transactions, 0);
      expect(volatile.schemaChecks, 0);
    },
  );
}

final _session = RemoteOrchestrationSession(
  sessionId: 'session',
  taskId: 'task',
  strategyId: chatStrategyId.value,
);

SessionFeedbackSubmission _submission({
  String id = 'review',
  String text = '  Fix "quoted" text\r\n\t\u00e9\u{1f600}  ',
  int version = 2,
  String environment = 'environment',
  String path = 'lib/a "file"\n.dart',
  String comparison = 'comparison-1',
  String excerpt = '  old();\r\nnew("\\");\r\n\u00e9\u{1f600}',
}) => SessionFeedbackSubmission(
  submissionId: id,
  kind: SessionFeedbackKind.codeReview,
  comments: [
    _comment(
      1,
      text: text,
      version: version,
      environment: environment,
      path: path,
      comparison: comparison,
      excerpt: excerpt,
    ),
    _comment(
      3,
      text: 'Second comment.',
      layer: SessionFeedbackComparisonLayer.staged,
    ),
    _comment(
      8,
      text: 'Third comment.',
      layer: SessionFeedbackComparisonLayer.committed,
    ),
  ],
);

SessionFeedbackComment _comment(
  int sequence, {
  required String text,
  int version = 1,
  String environment = 'environment',
  String path = 'lib/source.dart',
  String comparison = 'comparison',
  String excerpt = 'source\r\n',
  SessionFeedbackComparisonLayer layer =
      SessionFeedbackComparisonLayer.unstaged,
}) => SessionFeedbackComment(
  id: 'comment-$sequence',
  anchor: SessionFeedbackAnchor(
    environmentId: environment,
    relativePath: path,
    layer: layer,
    side: sequence == 1
        ? SessionFeedbackComparisonSide.oldSide
        : SessionFeedbackComparisonSide.newSide,
    startLine: 4,
    endLine: 7,
    comparisonIdentity: comparison,
    sourceExcerpt: excerpt,
    hunkIndex: 2,
    lineIndex: 3,
  ),
  text: text,
  version: version,
  sequence: sequence,
);

(String, String, String) _identity(SessionFeedbackReceipt receipt) =>
    (receipt.submissionId, receipt.sessionId, receipt.occurrenceId);

Matcher _failure(String code) => throwsA(
  isA<SessionFeedbackFailure>()
      .having((error) => error.code, 'code', code)
      .having((error) => error.message, 'safe message', isNot(contains('SQL')))
      .having((error) => error.details, 'details', isEmpty),
);

Matcher _inspectionFailure(String code) => throwsA(
  isA<ChatFeedbackInspectionFailure>()
      .having((error) => error.code, 'code', code)
      .having((error) => error.message, 'safe message', isNot(contains('SQL')))
      .having((error) => error.details, 'details', isEmpty),
);

void _expectInspected(
  ChatAcceptedFeedback actual,
  SessionFeedbackSubmission expected, {
  String occurrenceId = 'entry-0',
  String? runId,
}) {
  expect(actual.sessionId, 'session');
  expect(actual.occurrenceId, occurrenceId);
  expect(actual.submissionId, expected.submissionId);
  expect(actual.kind.name, expected.kind.name);
  expect(actual.runId, runId);
  expect(actual.comments.length, expected.comments.length);
  for (var index = 0; index < expected.comments.length; index++) {
    final a = actual.comments[index];
    final e = expected.comments[index];
    expect(
      (a.id, a.text, a.version, a.sequence),
      (e.id, e.text, e.version, e.sequence),
    );
    expect(
      (
        a.anchor.environmentId,
        a.anchor.relativePath,
        a.anchor.layer.name,
        a.anchor.side.name,
      ),
      (
        e.anchor.environmentId,
        e.anchor.relativePath,
        e.anchor.layer.name,
        e.anchor.side.name,
      ),
    );
    expect(
      (
        a.anchor.startLine,
        a.anchor.endLine,
        a.anchor.comparisonIdentity,
        a.anchor.sourceExcerpt,
        a.anchor.hunkIndex,
        a.anchor.lineIndex,
      ),
      (
        e.anchor.startLine,
        e.anchor.endLine,
        e.anchor.comparisonIdentity,
        e.anchor.sourceExcerpt,
        e.anchor.hunkIndex,
        e.anchor.lineIndex,
      ),
    );
  }
}

final class _DirectChannel implements AdeleRequestChannel {
  _DirectChannel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  int nextRequest = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': nextRequest++,
      'method': method,
      'payload': payload,
    });
    if (response['ok'] != true) {
      throw StateError('Generated transport failed: ${response['error']}');
    }
    return response['payload'];
  }
}
