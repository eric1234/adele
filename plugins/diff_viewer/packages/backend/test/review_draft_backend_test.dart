import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_backend/diff_viewer_backend.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:test/test.dart';

import 'support/review_storage.dart';

void main() {
  late ReviewTestStorage storage;
  late ReviewDraftServiceImpl service;

  setUp(() {
    storage = ReviewTestStorage();
    service = ReviewDraftServiceImpl(storage);
  });
  tearDown(() async {
    await service.close();
    storage.close();
  });

  test(
    'lazy schema guard and fresh snapshots never create draft rows',
    () async {
      expect(storage.schemaChecks, 0);
      expect((await service.snapshot('session')).comments, isEmpty);
      expect((await service.snapshot('session')).comments, isEmpty);
      expect(storage.schemaChecks, 1);
      expect(storage.queries, 2);
      expect(storage.transactions, 0);
      expect(storage.durabilityChecks, 0);
      expect(_databaseState(storage), {
        'sessions': <Object?>[],
        'comments': <Object?>[],
      });
      expect(
        storage.database
            .select('SELECT version FROM test_owner_schema')
            .single['version'],
        2,
      );
      await service.snapshot('other');
      await service.snapshot('session');
      // Only one current scope is retained, not an ever-growing Session map.
      expect(storage.schemaChecks, 3);
      expect(
        storage.modes,
        everyElement(ProjectStorageAccessMode.durableOrTemporary),
      );
    },
  );

  test(
    'concurrent initial reads share the current schema preparation',
    () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.beforeSchema = () {
        if (!entered.isCompleted) entered.complete();
        return gate.future;
      };
      final first = service.snapshot('session');
      final second = service.snapshot('session');
      await entered.future;
      expect(storage.schemaChecks, 1);
      gate.complete();
      expect((await first).comments, isEmpty);
      expect((await second).comments, isEmpty);
      expect(storage.queries, 2);
    },
  );

  test(
    'CRUD preserves duplicate anchors, exact source, ordering and Session isolation',
    () async {
      const text = '  Raw \r\n\t\u0000\u00e9\u{1f600}  ';
      final anchor = _anchor();
      final first = await service.createComment('session', anchor, text);
      final duplicate = await service.createComment('session', anchor, text);
      final other = await service.createComment(
        'other',
        anchor,
        'Other Session.',
      );
      expect((first.id, first.version, first.sequence), ('comment-1', 1, 1));
      expect((duplicate.id, duplicate.sequence), ('comment-2', 2));
      expect(other.id, first.id);
      final snapshot = await service.snapshot('session');
      expect(snapshot.comments.map((comment) => comment.id), [
        'comment-1',
        'comment-2',
      ]);
      final storedAnchor = _anchorFields(storage, first.id);
      final updated = await service.updateComment(
        'session',
        first.id,
        1,
        '  Replacement.\r\n',
      );
      expect(
        (updated.version, updated.sequence, updated.text),
        (2, 1, '  Replacement.\r\n'),
      );
      expect(_anchorFields(storage, first.id), storedAnchor);
      expect(_anchorMap(updated.anchor), _anchorMap(anchor));
      expect(snapshot.comments.first.text, text);
      expect(() => snapshot.comments.clear(), throwsUnsupportedError);
      await service.deleteComment('session', first.id, 2);
      final next = await service.createComment('session', anchor, 'Next.');
      expect((next.id, next.sequence), ('comment-3', 3));
      expect(
        (await service.snapshot(
          'session',
        )).comments.map((comment) => comment.id),
        ['comment-2', 'comment-3'],
      );
      expect(
        (await service.snapshot('other')).comments.single.text,
        'Other Session.',
      );
      await service.deleteComment('session', duplicate.id, 1);
      await service.deleteComment('session', next.id, 1);
      expect((await service.snapshot('session')).comments, isEmpty);
      expect(
        (await service.createComment('session', anchor, 'Not reused.')).id,
        'comment-4',
      );
    },
  );

  test(
    'v1 relational schema references core Sessions, not Environments or Git',
    () async {
      await service.createComment(
        'session',
        _anchor(environment: 'unmaterialized-environment'),
        'Pending.',
      );
      expect(
        storage.database
            .select('PRAGMA foreign_key_list(adele_diff_review_sessions)')
            .single['table'],
        'adele_product_sessions',
      );
      expect(
        storage.database
            .select('PRAGMA foreign_key_list(adele_diff_review_comments)')
            .single['table'],
        'adele_diff_review_sessions',
      );
      storage.database.execute(
        "DELETE FROM adele_product_sessions WHERE id='session'",
      );
      expect(_databaseState(storage), {
        'sessions': <Object?>[],
        'comments': <Object?>[],
      });
      await expectLater(
        service.snapshot('session'),
        _failure('storage_unavailable'),
      );
    },
  );

  test(
    'multiple files, Environments and layers retain distinct anchors',
    () async {
      final originals = <Map<String, Object?>>[];
      for (final environment in ['environment', 'other-environment']) {
        for (final path in ['lib/first.dart', 'lib/second.dart']) {
          for (final layer in ReviewComparisonLayer.values) {
            final anchor = ReviewCommentAnchor(
              environmentId: environment,
              relativePath: path,
              layer: layer,
              side: ReviewComparisonSide.newSide,
              startLine: 1,
              endLine: 1,
              comparisonIdentity: 'original:$environment:$path:${layer.name}',
              sourceExcerpt: 'original line\r\n',
              hunkIndex: 0,
              lineIndex: 0,
            );
            originals.add(_anchorMap(anchor));
            await service.createComment('session', anchor, 'Same comment.');
          }
        }
      }
      final fresh = ReviewDraftServiceImpl(storage);
      addTearDown(fresh.close);
      final saved = await fresh.snapshot('session');
      expect(
        saved.comments.map((comment) => _anchorMap(comment.anchor)),
        originals,
      );
      expect(
        saved.comments.map((comment) => comment.id).toSet(),
        hasLength(12),
      );
      expect(
        saved.comments.map((comment) => comment.sequence),
        List.generate(12, (i) => i + 1),
      );
    },
  );

  test(
    'same-instance mutations serialize and allocate monotonically',
    () async {
      final comments = await Future.wait([
        for (var i = 0; i < 16; i++)
          service.createComment('session', _anchor(), 'Comment $i.'),
      ]);
      expect(
        comments.map((comment) => comment.sequence),
        List.generate(16, (index) => index + 1),
      );
      expect(storage.transactions, 16);
      expect(storage.schemaChecks, 1);
      expect((await service.snapshot('session')).comments, hasLength(16));
    },
  );

  test('pending writes expose only the previous committed snapshot', () async {
    final entered = Completer<void>();
    final gate = Completer<void>();
    storage.beforeTransaction = () async {
      entered.complete();
      await gate.future;
    };
    var completed = false;
    final pending = service
        .createComment('session', _anchor(), 'Accepted.')
        .then((comment) {
          completed = true;
          return comment;
        });
    await entered.future;
    expect(completed, isFalse);
    expect((await service.snapshot('session')).comments, isEmpty);
    expect(_databaseState(storage), {
      'sessions': <Object?>[],
      'comments': <Object?>[],
    });
    gate.complete();
    expect((await pending).id, 'comment-1');
    expect(
      (await service.snapshot('session')).comments.single.text,
      'Accepted.',
    );
  });

  test(
    'failed first insertion rolls back the newly allocated Session counter',
    () async {
      await service.snapshot('session');
      storage.database.execute('''
CREATE TRIGGER reject_first AFTER INSERT ON adele_diff_review_comments
BEGIN SELECT RAISE(ABORT, 'reject first comment'); END;
''');
      await expectLater(
        service.createComment('session', _anchor(), 'Rejected.'),
        _failure('outcome_uncertain'),
      );
      expect(_databaseState(storage), {
        'sessions': <Object?>[],
        'comments': <Object?>[],
      });
      expect((await service.snapshot('session')).comments, isEmpty);
      storage.database.execute('DROP TRIGGER reject_first');
      expect(
        (await service.createComment('session', _anchor(), 'First.')).id,
        'comment-1',
      );
    },
  );

  test(
    'stale versions, deleted IDs and wrong Sessions reject before a transaction',
    () async {
      final first = await service.createComment(
        'session',
        _anchor(),
        'Original.',
      );
      await service.updateComment('session', first.id, 1, 'Current.');
      final before = _databaseState(storage);
      final writes = storage.transactions;
      await expectLater(
        service.updateComment('session', first.id, 1, 'Stale.'),
        _failure('stale_comment'),
      );
      await expectLater(
        service.deleteComment('session', first.id, 1),
        _failure('stale_comment'),
      );
      await expectLater(
        service.deleteComment('other', first.id, 2),
        _failure('stale_comment'),
      );
      await expectLater(
        service.updateComment('session', 'missing', 1, 'Absent.'),
        _failure('stale_comment'),
      );
      expect(storage.transactions, writes);
      expect(_databaseState(storage), before);
      await service.deleteComment('session', first.id, 2);
      await expectLater(
        service.deleteComment('session', first.id, 2),
        _failure('stale_comment'),
      );
    },
  );

  for (final operation in ['create', 'update', 'delete']) {
    test(
      'cross-generation $operation race rejects stale CAS without replay',
      () async {
        PendingReviewComment? prior;
        if (operation != 'create') {
          prior = await service.createComment(
            'session',
            _anchor(),
            'Original.',
          );
        }
        final peer = ReviewDraftServiceImpl(storage);
        addTearDown(peer.close);
        final entered = Completer<void>();
        final gate = Completer<void>();
        storage.beforeTransaction = () async {
          if (!entered.isCompleted) {
            entered.complete();
            await gate.future;
          }
        };
        final writes = storage.transactions;
        final pending = switch (operation) {
          'create' => service.createComment('session', _anchor(), 'Lost race.'),
          'update' => service.updateComment(
            'session',
            prior!.id,
            1,
            'Lost race.',
          ),
          _ => service.deleteComment('session', prior!.id, 1),
        };
        final rejected = expectLater(pending, _failure('outcome_uncertain'));
        await entered.future;
        final winner = operation == 'create'
            ? await peer.createComment('session', _anchor(), 'Winner.')
            : await peer.updateComment('session', prior!.id, 1, 'Winner.');
        gate.complete();
        await rejected;
        expect(storage.transactions - writes, 2);
        final actual = await service.snapshot('session');
        expect(actual.comments.single.text, 'Winner.');
        expect(actual.comments.single.version, winner.version);
        storage.beforeTransaction = null;
        expect(
          (await service.createComment('session', _anchor(), 'Next.')).id,
          'comment-2',
        );
      },
    );
  }

  test(
    'delete winning an edit race cannot resurrect the deleted comment',
    () async {
      final prior = await service.createComment(
        'session',
        _anchor(),
        'Original.',
      );
      final peer = ReviewDraftServiceImpl(storage);
      addTearDown(peer.close);
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.beforeTransaction = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await gate.future;
        }
      };
      final rejected = expectLater(
        service.updateComment('session', prior.id, 1, 'Late.'),
        _failure('outcome_uncertain'),
      );
      await entered.future;
      await peer.deleteComment('session', prior.id, 1);
      gate.complete();
      await rejected;
      expect((await service.snapshot('session')).comments, isEmpty);
    },
  );

  for (final operation in ['create', 'update', 'delete']) {
    test(
      'real SQLite $operation trigger rolls back header and comment atomically',
      () async {
        final prior = await service.createComment(
          'session',
          _anchor(),
          'Original.',
        );
        final before = _databaseState(storage);
        final event = switch (operation) {
          'create' => 'INSERT',
          'update' => 'UPDATE',
          _ => 'DELETE',
        };
        storage.database.execute('''
CREATE TRIGGER reject_comment AFTER $event ON adele_diff_review_comments
BEGIN SELECT RAISE(ABORT, 'failure after changing comment and header'); END;
''');
        final writes = storage.transactions;
        await expectLater(switch (operation) {
          'create' => service.createComment('session', _anchor(), 'Rejected.'),
          'update' => service.updateComment(
            'session',
            prior.id,
            1,
            'Rejected.',
          ),
          _ => service.deleteComment('session', prior.id, 1),
        }, _failure('outcome_uncertain'));
        expect(storage.transactions, writes + 1);
        expect(_databaseState(storage), before);
        expect(
          (await service.snapshot('session')).comments.single.text,
          'Original.',
        );
        storage.database.execute('DROP TRIGGER reject_comment');
        expect(
          (await service.createComment('session', _anchor(), 'Accepted.')).id,
          'comment-2',
        );
      },
    );
  }

  for (final operation in ['create', 'update', 'delete']) {
    test(
      'lost $operation acknowledgement exposes committed SQL only through fresh snapshot',
      () async {
        PendingReviewComment? prior;
        if (operation != 'create') {
          prior = await service.createComment(
            'session',
            _anchor(),
            'Original.',
          );
        }
        final writes = storage.transactions;
        storage.afterCommit = () async =>
            throw StateError('Lost transport acknowledgement.');
        await expectLater(switch (operation) {
          'create' => service.createComment('session', _anchor(), 'Committed.'),
          'update' => service.updateComment(
            'session',
            prior!.id,
            1,
            'Committed.',
          ),
          _ => service.deleteComment('session', prior!.id, 1),
        }, _failure('outcome_uncertain'));
        expect(storage.transactions, writes + 1);
        storage.afterCommit = null;
        for (final reader in [service, ReviewDraftServiceImpl(storage)]) {
          final snapshot = await reader.snapshot('session');
          if (operation == 'delete') {
            expect(snapshot.comments, isEmpty);
          } else {
            expect(snapshot.comments.single.text, 'Committed.');
            expect(
              snapshot.comments.single.version,
              operation == 'update' ? 2 : 1,
            );
          }
        }
        expect(storage.transactions, writes + 1);
        expect(
          (await service.createComment(
            'session',
            _anchor(),
            'Explicit next.',
          )).id,
          'comment-2',
        );
      },
    );
  }

  for (final afterCommit in [false, true]) {
    test(
      'shutdown fences ${afterCommit ? 'committed' : 'admitted'} write and queued mutation success',
      () async {
        final entered = Completer<void>();
        final gate = Completer<void>();
        Future<void> pause() async {
          entered.complete();
          await gate.future;
        }

        if (afterCommit) {
          storage.afterCommit = pause;
        } else {
          storage.beforeTransaction = pause;
        }
        final first = expectLater(
          service.createComment('session', _anchor(), 'Admitted.'),
          _failure('outcome_uncertain'),
        );
        final queued = expectLater(
          service.createComment('session', _anchor(), 'Never admitted.'),
          _failure('backend_closed'),
        );
        await entered.future;
        final closing = service.close();
        gate.complete();
        await Future.wait([first, queued, closing]);
        expect(storage.transactions, 1);
        final snapshot = await ReviewDraftServiceImpl(
          storage,
        ).snapshot('session');
        expect(snapshot.comments.single.text, 'Admitted.');
        await expectLater(
          service.snapshot('session'),
          _failure('backend_closed'),
        );
      },
    );
  }

  test(
    'storage close before admitted SQL never creates a successful draft',
    () async {
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.beforeTransaction = () async {
        entered.complete();
        await gate.future;
      };
      final rejected = expectLater(
        service.createComment('session', _anchor(), 'Not stored.'),
        _failure('outcome_uncertain'),
      );
      await entered.future;
      storage.close();
      gate.complete();
      await rejected;
      await expectLater(
        service.snapshot('session'),
        _failure('storage_unavailable'),
      );
    },
  );

  test('invalid primitives consume neither SQL nor identities', () async {
    for (final text in [
      '',
      '  \t\r\n',
      'x' * (ReviewDraftLimits.maxTextLength + 1),
      '\ud800',
    ]) {
      await expectLater(
        service.createComment('session', _anchor(), text),
        _failure('invalid_request'),
      );
    }
    await expectLater(
      service.snapshot(' session'),
      _failure('invalid_request'),
    );
    await expectLater(
      service.createComment('s' * 257, _anchor(), 'Text.'),
      _failure('invalid_request'),
    );
    await expectLater(
      service.updateComment('session', 'comment-1', 0, 'Text.'),
      _failure('invalid_request'),
    );
    await expectLater(
      service.deleteComment('session', '', 1),
      _failure('invalid_request'),
    );
    expect(storage.schemaChecks, 0);
    expect(storage.transactions, 0);
    expect(
      (await service.createComment('session', _anchor(), 'First.')).id,
      'comment-1',
    );
    final before = _databaseState(storage);
    await expectLater(
      service.updateComment('session', 'comment-1', 1, ' '),
      _failure('invalid_request'),
    );
    expect(_databaseState(storage), before);
  });

  test('missing scopes and storage errors never fall back or retry', () async {
    await expectLater(
      service.snapshot('missing'),
      _failure('storage_unavailable'),
    );
    await expectLater(
      service.createComment('missing', _anchor(), 'Text.'),
      _failure('storage_unavailable'),
    );
    expect(storage.transactions, 0);
    storage.failure = StateError('Unavailable.');
    await expectLater(
      service.createComment('session', _anchor(), 'Text.'),
      _failure('storage_unavailable'),
    );
    expect(storage.transactions, 0);
    storage.failure = null;
    final first = await service.createComment(
      'session',
      _anchor(),
      'Retained.',
    );
    final before = _databaseState(storage);
    storage.failure = const FormatException('Host unavailable.');
    await expectLater(
      service.snapshot('session'),
      _failure('storage_unavailable'),
    );
    await expectLater(
      service.updateComment('session', first.id, 1, 'No fallback.'),
      _failure('storage_unavailable'),
    );
    expect(storage.transactions, 1);
    expect(_databaseState(storage), before);
    storage.failure = null;
    expect(
      (await service.snapshot('session')).comments.single.text,
      'Retained.',
    );
    expect(storage.durabilityChecks, 0);
  });

  test(
    'explicit temporary access retains SQL across generations without durability probing',
    () async {
      final temporary = ReviewTestStorage(durable: false);
      addTearDown(temporary.close);
      final writer = ReviewDraftServiceImpl(temporary);
      await writer.createComment('session', _anchor(), 'Temporary SQL.');
      await writer.close();
      expect(
        (await ReviewDraftServiceImpl(
          temporary,
        ).snapshot('session')).comments.single.text,
        'Temporary SQL.',
      );
      expect(temporary.durabilityChecks, 0);
      expect(
        temporary.modes,
        everyElement(ProjectStorageAccessMode.durableOrTemporary),
      );
    },
  );

  test(
    '128-comment cap and aggregate charge reject before ID allocation',
    () async {
      for (var i = 0; i < ReviewDraftLimits.maxComments; i++) {
        await service.createComment('session', _anchor(), 'Small.');
      }
      final before = _databaseState(storage);
      final writes = storage.transactions;
      await expectLater(
        service.createComment('session', _anchor(), 'Overflow.'),
        _failure('limit_exceeded'),
      );
      expect(storage.transactions, writes);
      expect(_databaseState(storage), before);
      await service.deleteComment('session', 'comment-1', 1);
      expect(
        (await service.createComment('session', _anchor(), 'Replacement.')).id,
        'comment-129',
      );
      expect((await service.snapshot('session')).comments, hasLength(128));
    },
  );

  test(
    'exact total charge boundary rejects edit/create, remains below host response bound',
    () async {
      final anchor = _anchor();
      final comments = <PendingReviewComment>[];
      while (true) {
        final candidate = PendingReviewComment(
          id: 'comment-${comments.length + 1}',
          anchor: anchor,
          text: 'x',
          version: 1,
          sequence: comments.length + 1,
        );
        final available =
            (ReviewDraftLimits.maxSnapshotCharge -
                    reviewDraftSnapshotCharge('session', [
                      ...comments,
                      candidate,
                    ])) ~/
                ReviewDraftLimits.stringCodeUnitCharge +
            1;
        final size = available.clamp(1, ReviewDraftLimits.maxTextLength);
        comments.add(
          await service.createComment('session', anchor, 'x' * size),
        );
        if (available <= ReviewDraftLimits.maxTextLength) break;
      }
      final snapshot = await service.snapshot('session');
      final remaining =
          ReviewDraftLimits.maxSnapshotCharge -
          reviewDraftSnapshotCharge('session', snapshot.comments);
      expect(remaining, inInclusiveRange(0, 5));
      final before = _databaseState(storage);
      final writes = storage.transactions;
      final last = comments.last;
      await expectLater(
        service.updateComment('session', last.id, 1, '${last.text}x'),
        _failure('limit_exceeded'),
      );
      await expectLater(
        service.createComment('session', anchor, 'Too much.'),
        _failure('limit_exceeded'),
      );
      expect(storage.transactions, writes);
      expect(_databaseState(storage), before);
      expect(storage.maximumQueryBytes, lessThan(relationalQueryByteLimit));
      await service.deleteComment('session', comments.first.id, 1);
      expect(
        (await service.createComment(
          'session',
          anchor,
          'Space recovered.',
        )).sequence,
        comments.length + 1,
      );
    },
  );

  test(
    'escaped 128-comment snapshot with maximum identities stays below host byte limit',
    () async {
      final session = '\u0800' * ReviewDraftLimits.maxIdentityLength;
      storage.database.execute(
        'INSERT INTO adele_product_sessions VALUES (?)',
        [session],
      );
      final anchor = ReviewCommentAnchor(
        environmentId: '\u0800' * ReviewDraftLimits.maxIdentityLength,
        relativePath: 'f',
        layer: ReviewComparisonLayer.committed,
        side: ReviewComparisonSide.newSide,
        startLine: ReviewDraftLimits.maxLine,
        endLine: ReviewDraftLimits.maxLine,
        comparisonIdentity: 'x',
        sourceExcerpt: '',
        hunkIndex: ReviewDraftLimits.maxHunkIndex,
        lineIndex: ReviewDraftLimits.maxLineIndex,
      );
      final body = 'x${'\u0000' * 300}';
      for (var index = 0; index < ReviewDraftLimits.maxComments; index++) {
        await service.createComment(session, anchor, body);
      }
      final snapshot = await ReviewDraftServiceImpl(storage).snapshot(session);
      expect(snapshot.comments, hasLength(128));
      expect(
        snapshot.comments.every((comment) => comment.text == body),
        isTrue,
      );
      expect(
        reviewDraftSnapshotCharge(session, snapshot.comments),
        lessThanOrEqualTo(ReviewDraftLimits.maxSnapshotCharge),
      );
      expect(storage.maximumQueryBytes, lessThan(relationalQueryByteLimit));
    },
  );

  test(
    'competing edits cannot exceed the aggregate charge through separate comments',
    () async {
      final first = await service.createComment('session', _anchor(), 'First.');
      final second = await service.createComment(
        'session',
        _anchor(),
        'Second.',
      );
      for (var index = 0; index < 10; index++) {
        await service.createComment(
          'session',
          _anchor(),
          'x' * ReviewDraftLimits.maxTextLength,
        );
      }
      final before = await service.snapshot('session');
      final remaining =
          ReviewDraftLimits.maxSnapshotCharge -
          reviewDraftSnapshotCharge('session', before.comments);
      final growth =
          remaining ~/ ReviewDraftLimits.stringCodeUnitCharge * 3 ~/ 4;
      expect(growth, greaterThan(0));
      final peer = ReviewDraftServiceImpl(storage);
      addTearDown(peer.close);
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.beforeTransaction = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await gate.future;
        }
      };
      final rejected = expectLater(
        service.updateComment(
          'session',
          first.id,
          1,
          '${first.text}${'x' * growth}',
        ),
        _failure('outcome_uncertain'),
      );
      await entered.future;
      await peer.updateComment(
        'session',
        second.id,
        1,
        '${second.text}${'x' * growth}',
      );
      gate.complete();
      await rejected;
      final after = await service.snapshot('session');
      expect(after.comments.first.text, first.text);
      expect(after.comments[1].version, 2);
      expect(
        reviewDraftSnapshotCharge('session', after.comments),
        lessThanOrEqualTo(ReviewDraftLimits.maxSnapshotCharge),
      );
      await expectLater(
        service.updateComment(
          'session',
          first.id,
          1,
          '${first.text}${'x' * growth}',
        ),
        _failure('limit_exceeded'),
      );
    },
  );

  test(
    'concurrent creates at the count cap cannot overfill or allocate twice',
    () async {
      for (var i = 0; i < 127; i++) {
        await service.createComment('session', _anchor(), 'Small.');
      }
      final peer = ReviewDraftServiceImpl(storage);
      addTearDown(peer.close);
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.beforeTransaction = () async {
        if (!entered.isCompleted) {
          entered.complete();
          await gate.future;
        }
      };
      final rejected = expectLater(
        service.createComment('session', _anchor(), 'Loser.'),
        _failure('outcome_uncertain'),
      );
      await entered.future;
      expect(
        (await peer.createComment('session', _anchor(), 'Winner.')).id,
        'comment-128',
      );
      gate.complete();
      await rejected;
      expect((await service.snapshot('session')).comments, hasLength(128));
      expect(
        storage.database
            .select('SELECT next_sequence FROM adele_diff_review_sessions')
            .single['next_sequence'],
        129,
      );
    },
  );

  for (final kind in ['sequence', 'revision', 'version']) {
    test(
      '$kind exhaustion fails explicitly without overflow or writes',
      () async {
        await service.createComment('session', _anchor(), 'Retain.');
        final maximum = ReviewDraftLimits.maxVersion;
        storage.database.execute(
          'UPDATE adele_diff_review_sessions SET revision=?',
          [maximum],
        );
        if (kind == 'sequence') {
          storage.database.execute(
            'UPDATE adele_diff_review_sessions SET next_sequence=?',
            [ReviewDraftLimits.maxSequence + 1],
          );
        }
        if (kind == 'version') {
          storage.database.execute(
            'UPDATE adele_diff_review_comments SET version=?',
            [maximum],
          );
        }
        final before = _databaseState(storage);
        final writes = storage.transactions;
        await expectLater(
          kind == 'version'
              ? service.updateComment(
                  'session',
                  'comment-1',
                  maximum,
                  'Overflow.',
                )
              : service.createComment('session', _anchor(), 'Overflow.'),
          _failure('limit_exceeded'),
        );
        expect(storage.transactions, writes);
        expect(_databaseState(storage), before);
      },
    );
  }

  for (final corruption in <String, String>{
    'negative counter':
        'UPDATE adele_diff_review_sessions SET next_sequence=-1',
    'overflow counter':
        'UPDATE adele_diff_review_sessions SET next_sequence=9223372036854775807',
    'counter behind comment':
        'UPDATE adele_diff_review_sessions SET next_sequence=1',
    'revision': 'UPDATE adele_diff_review_sessions SET revision=0',
    'count': 'UPDATE adele_diff_review_sessions SET comment_count=2',
    'aggregate charge': 'UPDATE adele_diff_review_sessions SET total_charge=0',
    'row charge': 'UPDATE adele_diff_review_comments SET charge=1',
    'identity': "UPDATE adele_diff_review_comments SET comment_id='wrong'",
    'layer': "UPDATE adele_diff_review_comments SET layer='unknown'",
    'side': "UPDATE adele_diff_review_comments SET side='unknown'",
    'line range':
        'UPDATE adele_diff_review_comments SET end_line=start_line+1000',
    'path': "UPDATE adele_diff_review_comments SET relative_path='../escape'",
    'blank text': "UPDATE adele_diff_review_comments SET text=' '",
    'version': 'UPDATE adele_diff_review_comments SET version=0',
    'future version': 'UPDATE adele_diff_review_comments SET version=2',
    'orphan': 'DELETE FROM adele_diff_review_sessions',
  }.entries) {
    test(
      'corrupt ${corruption.key} fails without repair, caching or rewriting',
      () async {
        await service.createComment('session', _anchor(), 'Retain.');
        storage.database.execute('PRAGMA ignore_check_constraints=ON');
        storage.database.execute('PRAGMA foreign_keys=OFF');
        storage.database.execute(corruption.value);
        final before = _databaseState(storage);
        final writes = storage.transactions;
        for (final reader in [service, ReviewDraftServiceImpl(storage)]) {
          await expectLater(
            reader.snapshot('session'),
            _failure('corrupt_state'),
          );
          await expectLater(
            reader.createComment('session', _anchor(), 'Do not repair.'),
            _failure('corrupt_state'),
          );
        }
        expect(storage.transactions, writes);
        expect(_databaseState(storage), before);
      },
    );
  }

  test(
    'damaged schema duplicate rows and non-string bodies fail rather than truncate',
    () async {
      await service.createComment('session', _anchor(), 'Retain.');
      storage.database.execute('''
CREATE TABLE corrupt_comments AS SELECT * FROM adele_diff_review_comments;
DROP TABLE adele_diff_review_comments;
ALTER TABLE corrupt_comments RENAME TO adele_diff_review_comments;
INSERT INTO adele_diff_review_comments SELECT * FROM adele_diff_review_comments;
''');
      final writes = storage.transactions;
      await expectLater(service.snapshot('session'), _failure('corrupt_state'));
      storage.database.execute(
        'DELETE FROM adele_diff_review_comments WHERE rowid=2',
      );
      storage.database.execute(
        'UPDATE adele_diff_review_comments SET text=NULL',
      );
      await expectLater(service.snapshot('session'), _failure('corrupt_state'));
      expect(storage.transactions, writes);
    },
  );

  test(
    'on-disk close and rehydration retains comments, deletions and allocation',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'diff-review-test-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/project.sqlite';
      final firstStorage = ReviewTestStorage(path: path);
      final first = ReviewDraftServiceImpl(firstStorage);
      await first.createComment('session', _anchor(), 'Deleted.');
      await first.createComment('session', _anchor(), 'Retained.');
      await first.deleteComment('session', 'comment-1', 1);
      await first.updateComment(
        'session',
        'comment-2',
        1,
        'Exact retained.\r\n',
      );
      final before = _databaseState(firstStorage);
      await first.close();
      firstStorage.close();
      final reopenedStorage = ReviewTestStorage(path: path);
      addTearDown(reopenedStorage.close);
      final reopened = ReviewDraftServiceImpl(reopenedStorage);
      addTearDown(reopened.close);
      final snapshot = await reopened.snapshot('session');
      expect(
        (
          snapshot.comments.single.id,
          snapshot.comments.single.version,
          snapshot.comments.single.text,
        ),
        ('comment-2', 2, 'Exact retained.\r\n'),
      );
      expect(_databaseState(reopenedStorage), before);
      expect(
        (await reopened.createComment('session', _anchor(), 'Next.')).id,
        'comment-3',
      );
      expect(reopenedStorage.schemaChecks, 1);
    },
  );

  test(
    'diagnostics distinguish cold schema, warm reads and committed mutations',
    () async {
      final timings = <String, int>{};
      Future<T> measure<T>(String name, Future<T> Function() operation) async {
        final watch = Stopwatch()..start();
        final result = await operation();
        timings[name] = watch.elapsedMicroseconds;
        return result;
      }

      await measure('cold_snapshot_us', () => service.snapshot('session'));
      await measure('warm_snapshot_us', () => service.snapshot('session'));
      final comment = await measure(
        'create_us',
        () => service.createComment('session', _anchor(), 'Text.'),
      );
      await measure(
        'update_us',
        () => service.updateComment('session', comment.id, 1, 'Updated.'),
      );
      await measure(
        'delete_us',
        () => service.deleteComment('session', comment.id, 2),
      );
      await measure(
        'rehydrate_us',
        () => ReviewDraftServiceImpl(storage).snapshot('session'),
      );
      expect(storage.schemaChecks, 2);
      expect(storage.queries, 6);
      expect(storage.transactions, 3);
      expect(storage.durabilityChecks, 0);
      print(
        'review_draft_diagnostics ${jsonEncode({...timings, 'schema_checks': storage.schemaChecks, 'queries': storage.queries, 'transactions': storage.transactions, 'max_query_bytes': storage.maximumQueryBytes})}',
      );
    },
  );
}

ReviewCommentAnchor _anchor({String environment = 'environment'}) =>
    ReviewCommentAnchor(
      environmentId: environment,
      relativePath: 'lib/ raw\t\n\u00e9.dart',
      layer: ReviewComparisonLayer.staged,
      side: ReviewComparisonSide.oldSide,
      startLine: 3,
      endLine: 4,
      comparisonIdentity: 'opaque-comparison-not-approval',
      sourceExcerpt: '  Source\r\n\t\u0000\u00e9\u{1f600}  ',
      hunkIndex: 2,
      lineIndex: 5,
    );

Matcher _failure(String code) => throwsA(
  isA<ReviewDraftFailure>().having((error) => error.code, 'code', code),
);

Map<String, Object?> _databaseState(ReviewTestStorage storage) => {
  'sessions': [
    for (final row in storage.database.select(
      'SELECT * FROM adele_diff_review_sessions ORDER BY session_id',
    ))
      Map<String, Object?>.from(row),
  ],
  'comments': [
    for (final row in storage.database.select(
      'SELECT * FROM adele_diff_review_comments ORDER BY session_id,sequence',
    ))
      Map<String, Object?>.from(row),
  ],
};

Map<String, Object?> _anchorFields(ReviewTestStorage storage, String id) =>
    Map<String, Object?>.from(
      storage.database
          .select(
            '''
SELECT environment_id,relative_path,layer,side,start_line,end_line,
       comparison_identity,source_excerpt,hunk_index,line_index
FROM adele_diff_review_comments WHERE session_id='session' AND comment_id=?
''',
            [id],
          )
          .single,
    );

Map<String, Object?> _anchorMap(ReviewCommentAnchor anchor) => {
  'environment': anchor.environmentId,
  'path': anchor.relativePath,
  'layer': anchor.layer,
  'side': anchor.side,
  'start': anchor.startLine,
  'end': anchor.endLine,
  'comparison': anchor.comparisonIdentity,
  'excerpt': anchor.sourceExcerpt,
  'hunk': anchor.hunkIndex,
  'line': anchor.lineIndex,
};
