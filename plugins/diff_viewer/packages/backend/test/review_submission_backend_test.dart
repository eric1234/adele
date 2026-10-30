import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_orchestration/session_feedback.dart';
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

  Future<PreparedReviewSubmission> prepare() async {
    await service.createComment('session', _anchor(), 'Original.');
    return _prepared(
      service.prepareReview(
        'session',
        (await service.snapshot('session')).revision,
      ),
    );
  }

  Future<PreparedReviewSubmission> accept() async {
    final review = await prepare();
    await service.markDeliveryAttempted('session', review.submissionId);
    return service.confirmAcceptance(
      'session',
      review.submissionId,
      'session',
      'entry-1',
    );
  }

  test(
    'all saved scopes map explicitly to one immutable canonical submission',
    () async {
      const text = '  Review\r\n\t\u0000\u00e9\u{1f600}  ';
      for (final layer in ReviewComparisonLayer.values) {
        for (final side in ReviewComparisonSide.values) {
          await service.createComment(
            'session',
            _anchor(layer: layer, side: side),
            text,
          );
        }
      }
      await service.updateComment('session', 'comment-2', 1, 'Edited.\r\n');
      await service.deleteComment('session', 'comment-3', 1);
      await service.createComment('other', _anchor(), 'Other Session.');
      final snapshot = await service.snapshot('session');
      expect(snapshot.revision, 8);
      final review = await _prepared(
        service.prepareReview('session', snapshot.revision),
      );
      expect(
        (
          review.submissionId,
          review.status,
          review.commentCount,
          review.schedulingAttempt,
        ),
        ('review-1', ReviewSubmissionStatus.prepared, 5, 0),
      );
      final submission = decodeSessionFeedbackSubmission(
        review.canonicalPayload,
      );
      expect(
        encodeSessionFeedbackSubmission(submission),
        review.canonicalPayload,
      );
      expect(submission.kind, SessionFeedbackKind.codeReview);
      expect(submission.comments.map((c) => c.id), [
        'comment-1',
        'comment-2',
        'comment-4',
        'comment-5',
        'comment-6',
      ]);
      for (var index = 0; index < snapshot.comments.length; index++) {
        final original = snapshot.comments[index];
        final frozen = submission.comments[index];
        expect(
          (frozen.id, frozen.sequence, frozen.version, frozen.text),
          (original.id, original.sequence, original.version, original.text),
        );
        expect(
          (
            frozen.anchor.environmentId,
            frozen.anchor.relativePath,
            frozen.anchor.layer.name,
            frozen.anchor.side.name,
            frozen.anchor.startLine,
            frozen.anchor.endLine,
            frozen.anchor.comparisonIdentity,
            frozen.anchor.sourceExcerpt,
            frozen.anchor.hunkIndex,
            frozen.anchor.lineIndex,
          ),
          (
            original.anchor.environmentId,
            original.anchor.relativePath,
            original.anchor.layer.name,
            original.anchor.side.name,
            original.anchor.startLine,
            original.anchor.endLine,
            original.anchor.comparisonIdentity,
            original.anchor.sourceExcerpt,
            original.anchor.hunkIndex,
            original.anchor.lineIndex,
          ),
        );
      }
      final after = await service.snapshot('session');
      expect(after.revision, snapshot.revision + 1);
      expect(after.currentReview!.submissionId, review.submissionId);
      expect(after.comments, hasLength(5));
      expect(
        (await service.snapshot('other')).comments.single.text,
        'Other Session.',
      );
      expect(
        (await service.readReview('session'))!.canonicalPayload,
        review.canonicalPayload,
      );
      expect(await service.readReview('other'), isNull);
    },
  );

  test(
    'empty, stale and oversized preparation leave every SQL row unchanged',
    () async {
      await service.snapshot('session');
      var before = _state(storage);
      await expectLater(
        service.prepareReview('session', 0),
        completion(_rejection('empty_review')),
      );
      expect(_state(storage), before);
      await service.createComment('session', _anchor(), 'Original.');
      before = _state(storage);
      await expectLater(
        service.prepareReview('session', 0),
        completion(_rejection('stale_draft')),
      );
      await expectLater(
        service.prepareReview('session', -1),
        _failure('invalid_request'),
      );
      expect(_state(storage), before);
      for (var index = 0; index < 3; index++) {
        await service.createComment(
          'session',
          _anchor(),
          'x${'\u0000' * 8191}',
        );
      }
      final snapshot = await service.snapshot('session');
      expect(
        reviewDraftSnapshotCharge('session', snapshot.comments),
        lessThan(ReviewDraftLimits.maxSnapshotCharge),
      );
      before = _state(storage);
      final writes = storage.transactions;
      await expectLater(
        service.prepareReview('session', snapshot.revision),
        completion(_rejection('submission_too_large')),
      );
      expect(storage.transactions, writes);
      expect(_state(storage), before);
      expect(await service.readReview('session'), isNull);
      for (final comment in snapshot.comments.skip(1)) {
        await service.deleteComment('session', comment.id, comment.version);
      }
      expect(
        (await _prepared(
          service.prepareReview(
            'session',
            (await service.snapshot('session')).revision,
          ),
        )).submissionId,
        'review-1',
      );
    },
  );

  test(
    'UTF-8 payload bytes, not only character count, enforce feedback bound',
    () async {
      for (var index = 0; index < 6; index++) {
        await service.createComment('session', _anchor(), '\u0800' * 8192);
      }
      final before = _state(storage);
      await expectLater(
        service.prepareReview('session', 6),
        completion(_rejection('submission_too_large')),
      );
      expect(_state(storage), before);
    },
  );

  test(
    'temporary SQL supports drafts but never a successful review handoff',
    () async {
      final temporary = ReviewTestStorage(durable: false);
      addTearDown(temporary.close);
      final writer = ReviewDraftServiceImpl(temporary);
      addTearDown(writer.close);
      await writer.createComment('session', _anchor(), 'Temporary draft.');
      final before = _state(temporary);
      await expectLater(
        writer.prepareReview('session', 1),
        _failure('storage_unavailable'),
      );
      await expectLater(
        writer.readReview('session'),
        _failure('storage_unavailable'),
      );
      expect(_state(temporary), before);
      expect(temporary.transactions, 1);
      expect(temporary.modes, contains(ProjectStorageAccessMode.durable));
    },
  );

  test(
    'exact 128 KiB plus one rejection retains the complete editable draft',
    () async {
      final baseText = 'x${'\u0000' * 7000}';
      for (final session in ['other', 'session']) {
        for (var index = 0; index < 3; index++) {
          await service.createComment(session, _anchor(), baseText);
        }
      }
      // Calibrate with the actual public canonical encoder, not a fixture codec.
      // Session is not part of the payload; both batches have the same identities.
      final baseline = await _prepared(service.prepareReview('other', 3));
      final baselineBytes = utf8.encode(baseline.canonicalPayload).length;
      final growth =
          SessionFeedbackLimits.maxSubmissionBytes + 1 - baselineBytes;
      expect(growth, greaterThan(0));
      final escapedPadding = (growth - 1) ~/ 6;
      final asciiPadding = (growth - 1) % 6 + 1;
      final tooLargeText =
          '$baseText${'\u0000' * escapedPadding}${'x' * asciiPadding}';
      expect(
        tooLargeText.length,
        lessThanOrEqualTo(ReviewDraftLimits.maxTextLength),
      );
      expect(
        baselineBytes + escapedPadding * 6 + asciiPadding,
        SessionFeedbackLimits.maxSubmissionBytes + 1,
      );
      final updated = await service.updateComment(
        'session',
        'comment-3',
        1,
        tooLargeText,
      );
      final snapshot = await service.snapshot('session');
      final before = _state(storage);
      final writes = storage.transactions;
      final rejected = await service.prepareReview(
        'session',
        snapshot.revision,
      );
      expect(rejected, _rejection('submission_too_large'));
      expect(storage.transactions, writes);
      expect(_state(storage), before);
      expect(await service.readReview('session'), isNull);
      final unchanged = await service.snapshot('session');
      expect(unchanged.revision, snapshot.revision);
      expect(unchanged.currentReview, isNull);
      expect(unchanged.comments, hasLength(3));
      expect(unchanged.comments.last.text, tooLargeText);
      expect(unchanged.comments.last.version, updated.version);

      // Removing one ASCII byte leaves exactly 128 KiB. Both version counters
      // remain one digit, so this edit changes only one encoded payload byte.
      await service.updateComment(
        'session',
        updated.id,
        updated.version,
        tooLargeText.substring(0, tooLargeText.length - 1),
      );
      final accepted = await _prepared(
        service.prepareReview(
          'session',
          (await service.snapshot('session')).revision,
        ),
      );
      expect(
        utf8.encode(accepted.canonicalPayload).length,
        SessionFeedbackLimits.maxSubmissionBytes,
      );
      expect(accepted.submissionId, 'review-1');
      expect(
        decodeSessionFeedbackSubmission(accepted.canonicalPayload).comments,
        hasLength(3),
      );
    },
  );

  for (final stage in ['schema', 'read']) {
    test(
      'preparation $stage failure throws rather than reporting definite rejection',
      () async {
        await service.createComment('session', _anchor(), 'Retain.');
        final before = _state(storage);
        final writes = storage.transactions;
        final fresh = ReviewDraftServiceImpl(storage);
        addTearDown(fresh.close);
        if (stage == 'schema') {
          storage.beforeSchema = () async =>
              throw StateError('Schema acknowledgement unavailable.');
        } else {
          storage.beforeQuery = () async =>
              throw StateError('Read acknowledgement unavailable.');
        }
        await expectLater(
          fresh.prepareReview('session', 1),
          _failure('storage_unavailable'),
        );
        expect(storage.transactions, writes);
        expect(_state(storage), before);
      },
    );
  }

  test(
    'CREATE-only migration retains existing v1 draft header and comments',
    () async {
      await service.createComment('session', _anchor(), 'Existing v1.');
      storage.database.execute('DROP TABLE adele_diff_review_handoffs');
      storage.database.execute('DROP TABLE adele_diff_review_allocators');
      storage.database.execute('UPDATE test_owner_schema SET version=1');
      final fresh = ReviewDraftServiceImpl(storage);
      addTearDown(fresh.close);
      expect(
        (await fresh.snapshot('session')).comments.single.text,
        'Existing v1.',
      );
      expect(
        (await _prepared(fresh.prepareReview('session', 1))).submissionId,
        'review-1',
      );
      expect(
        storage.database
            .select('SELECT version FROM test_owner_schema')
            .single['version'],
        2,
      );
    },
  );

  for (final status in [
    ReviewSubmissionStatus.prepared,
    ReviewSubmissionStatus.deliveryPending,
  ]) {
    test(
      '$status freezes CRUD and second prepare across backend generations',
      () async {
        final review = await prepare();
        if (status == ReviewSubmissionStatus.deliveryPending) {
          await service.markDeliveryAttempted('session', review.submissionId);
        }
        final peer = ReviewDraftServiceImpl(storage);
        addTearDown(peer.close);
        final before = _state(storage);
        for (final writer in [service, peer]) {
          await expectLater(
            writer.createComment('session', _anchor(), 'Blocked.'),
            _failure('draft_frozen'),
          );
          await expectLater(
            writer.updateComment('session', 'comment-1', 1, 'Blocked.'),
            _failure('draft_frozen'),
          );
          await expectLater(
            writer.deleteComment('session', 'comment-1', 1),
            _failure('draft_frozen'),
          );
          await expectLater(
            writer.prepareReview('session', 2),
            completion(_rejection('review_conflict')),
          );
        }
        expect(_state(storage), before);
        await peer.createComment('other', _anchor(), 'Independent.');
      },
    );
  }

  for (final competing in ['prepare', 'create', 'update', 'delete']) {
    test(
      'concurrent $competing loses to preparation SQL CAS without replay',
      () async {
        await service.createComment('session', _anchor(), 'Original.');
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
        final Future<Object?> pending = switch (competing) {
          'prepare' => service.prepareReview('session', 1),
          'create' => service.createComment('session', _anchor(), 'Late.'),
          'update' => service.updateComment('session', 'comment-1', 1, 'Late.'),
          _ => service.deleteComment('session', 'comment-1', 1),
        };
        final rejected = expectLater(pending, _failure('outcome_uncertain'));
        await entered.future;
        final winner = await _prepared(peer.prepareReview('session', 1));
        final committed = _state(storage);
        gate.complete();
        await rejected;
        expect(_state(storage), committed);
        expect(
          (await service.readReview('session'))!.canonicalPayload,
          winner.canonicalPayload,
        );
        expect(
          (await service.snapshot('session')).comments.single.text,
          'Original.',
        );
        expect(
          storage.database
              .select(
                'SELECT next_submission FROM adele_diff_review_allocators',
              )
              .single['next_submission'],
          2,
        );
      },
    );
  }

  test(
    'concurrent edit winning before prepare cannot freeze a stale batch',
    () async {
      await service.createComment('session', _anchor(), 'Original.');
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
        service.prepareReview('session', 1),
        _failure('outcome_uncertain'),
      );
      await entered.future;
      await peer.updateComment('session', 'comment-1', 1, 'New revision.');
      gate.complete();
      await rejected;
      expect(await service.readReview('session'), isNull);
      expect(
        (await service.snapshot('session')).comments.single.text,
        'New revision.',
      );
      expect(
        storage.database.select('SELECT * FROM adele_diff_review_allocators'),
        isEmpty,
      );
    },
  );

  test(
    'confirmed receipt atomically clears only original versions and preserves allocator',
    () async {
      final review = await prepare();
      await expectLater(
        service.confirmAcceptance(
          'session',
          review.submissionId,
          'session',
          'entry-1',
        ),
        _failure('review_conflict'),
      );
      await service.markDeliveryAttempted('session', review.submissionId);
      await expectLater(
        service.markDeliveryAttempted('session', review.submissionId),
        _failure('review_conflict'),
      );
      final before = _state(storage);
      for (final (session, id, receiptSession) in [
        ('session', review.submissionId, 'other'),
        ('session', 'different-review', 'session'),
        ('other', review.submissionId, 'other'),
      ]) {
        await expectLater(
          service.confirmAcceptance(session, id, receiptSession, 'entry-1'),
          _failure('review_conflict'),
        );
      }
      expect(_state(storage), before);
      final accepted = await service.confirmAcceptance(
        'session',
        review.submissionId,
        'session',
        'entry-1',
      );
      expect(
        (accepted.status, accepted.occurrenceId),
        (ReviewSubmissionStatus.accepted, 'entry-1'),
      );
      expect((await service.snapshot('session')).comments, isEmpty);
      expect((await service.snapshot('session')).revision, 3);
      final next = await service.createComment(
        'session',
        _anchor(),
        'Next pending.',
      );
      expect(next.id, 'comment-2');
      final current = _state(storage);
      expect(
        (await service.confirmAcceptance(
          'session',
          review.submissionId,
          'session',
          'entry-1',
        )).canonicalPayload,
        review.canonicalPayload,
      );
      await expectLater(
        service.confirmAcceptance(
          'session',
          review.submissionId,
          'session',
          'different-entry',
        ),
        _failure('review_conflict'),
      );
      await expectLater(
        service.prepareReview('session', 4),
        completion(_rejection('review_conflict')),
      );
      expect(_state(storage), current);
      expect((await service.snapshot('session')).comments.single.id, next.id);
    },
  );

  test(
    'finalization SQL predicates reject changed original versions atomically',
    () async {
      final review = await prepare();
      await service.markDeliveryAttempted('session', review.submissionId);
      storage.beforeTransaction = () async {
        storage.beforeTransaction = null;
        storage.database.execute(
          'UPDATE adele_diff_review_comments SET version=2',
        );
      };
      await expectLater(
        service.confirmAcceptance(
          'session',
          review.submissionId,
          'session',
          'entry-1',
        ),
        _failure('outcome_uncertain'),
      );
      expect(
        storage.database
            .select('SELECT version FROM adele_diff_review_comments')
            .single['version'],
        2,
      );
      expect(
        storage.database
            .select('SELECT revision FROM adele_diff_review_sessions')
            .single['revision'],
        2,
      );
      expect(
        (await service.readReview('session'))!.status,
        ReviewSubmissionStatus.deliveryPending,
      );
    },
  );

  test(
    'scheduling marker, receipt, Run and attempt are strict and idempotent',
    () async {
      final review = await accept();
      await expectLater(
        service.confirmRunScheduled(
          'session',
          review.submissionId,
          'entry-1',
          1,
          'run-1',
        ),
        _failure('review_conflict'),
      );
      final pending = await service.markSchedulingAttempted(
        'session',
        review.submissionId,
        'entry-1',
      );
      expect(
        (pending.status, pending.schedulingAttempt),
        (ReviewSubmissionStatus.schedulingPending, 1),
      );
      await expectLater(
        service.markSchedulingAttempted(
          'session',
          review.submissionId,
          'entry-1',
        ),
        _failure('review_conflict'),
      );
      await expectLater(
        service.confirmRunScheduled(
          'session',
          review.submissionId,
          'wrong-entry',
          1,
          'run-1',
        ),
        _failure('review_conflict'),
      );
      final reset = await service.confirmRunNotStarted(
        'session',
        review.submissionId,
        'entry-1',
        1,
      );
      expect(reset.status, ReviewSubmissionStatus.accepted);
      expect(
        (await service.confirmRunNotStarted(
          'session',
          review.submissionId,
          'entry-1',
          1,
        )).schedulingAttempt,
        1,
      );
      final retry = await service.markSchedulingAttempted(
        'session',
        review.submissionId,
        'entry-1',
      );
      expect(retry.schedulingAttempt, 2);
      final before = _state(storage);
      await expectLater(
        service.confirmRunNotStarted(
          'session',
          review.submissionId,
          'entry-1',
          1,
        ),
        _failure('review_conflict'),
      );
      await expectLater(
        service.confirmRunScheduled(
          'session',
          review.submissionId,
          'entry-1',
          1,
          'old-run',
        ),
        _failure('review_conflict'),
      );
      expect(_state(storage), before);
      final scheduled = await service.confirmRunScheduled(
        'session',
        review.submissionId,
        'entry-1',
        2,
        'run-2',
      );
      expect(
        (scheduled.status, scheduled.runId),
        (ReviewSubmissionStatus.scheduled, 'run-2'),
      );
      final committed = _state(storage);
      expect(
        (await service.confirmRunScheduled(
          'session',
          review.submissionId,
          'entry-1',
          2,
          'run-2',
        )).runId,
        'run-2',
      );
      await expectLater(
        service.confirmRunScheduled(
          'session',
          review.submissionId,
          'entry-1',
          2,
          'other-run',
        ),
        _failure('review_conflict'),
      );
      await expectLater(
        service.confirmRunNotStarted(
          'session',
          review.submissionId,
          'entry-1',
          2,
        ),
        _failure('review_conflict'),
      );
      expect(_state(storage), committed);
    },
  );

  test(
    'cross-generation delayed reset cannot erase a newer scheduling attempt',
    () async {
      final review = await accept();
      await service.markSchedulingAttempted(
        'session',
        review.submissionId,
        'entry-1',
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
        service.confirmRunNotStarted(
          'session',
          review.submissionId,
          'entry-1',
          1,
        ),
        _failure('outcome_uncertain'),
      );
      await entered.future;
      await peer.confirmRunNotStarted(
        'session',
        review.submissionId,
        'entry-1',
        1,
      );
      await peer.markSchedulingAttempted(
        'session',
        review.submissionId,
        'entry-1',
      );
      gate.complete();
      await rejected;
      final current = (await peer.readReview('session'))!;
      expect(
        (current.status, current.schedulingAttempt),
        (ReviewSubmissionStatus.schedulingPending, 2),
      );
    },
  );

  test(
    'one current row is pruned only after scheduled, identities never reused',
    () async {
      for (var index = 1; index <= 4; index++) {
        final review = await accept();
        expect(review.submissionId, 'review-$index');
        await service.markSchedulingAttempted(
          'session',
          review.submissionId,
          'entry-1',
        );
        await service.confirmRunScheduled(
          'session',
          review.submissionId,
          'entry-1',
          1,
          'run-$index',
        );
        expect(
          storage.database.select('SELECT * FROM adele_diff_review_handoffs'),
          hasLength(1),
        );
        expect(
          storage.database
              .select(
                'SELECT next_submission FROM adele_diff_review_allocators',
              )
              .single['next_submission'],
          index + 1,
        );
      }
      // Even removal of retained completed data cannot reset the separate allocator.
      storage.database.execute('DELETE FROM adele_diff_review_handoffs');
      final next = await prepare();
      expect(next.submissionId, 'review-5');
      expect(
        decodeSessionFeedbackSubmission(
          next.canonicalPayload,
        ).comments.single.id,
        'comment-5',
      );
    },
  );

  for (final operation in [
    'prepare',
    'delivery',
    'acceptance',
    'scheduling',
    'scheduled',
    'notStarted',
  ]) {
    for (final lostAck in [false, true]) {
      test(
        '$operation ${lostAck ? 'lost acknowledgement retains commit' : 'SQL failure rolls back whole transition'}',
        () async {
          await service.createComment('session', _anchor(), 'Original.');
          if (operation != 'prepare') {
            await _prepared(service.prepareReview('session', 1));
          }
          if (!['prepare', 'delivery'].contains(operation)) {
            await service.markDeliveryAttempted('session', 'review-1');
          }
          if (['scheduling', 'scheduled', 'notStarted'].contains(operation)) {
            await service.confirmAcceptance(
              'session',
              'review-1',
              'session',
              'entry-1',
            );
          }
          if (['scheduled', 'notStarted'].contains(operation)) {
            await service.markSchedulingAttempted(
              'session',
              'review-1',
              'entry-1',
            );
          }
          final before = _state(storage);
          final writes = storage.transactions;
          if (lostAck) {
            storage.afterCommit = () async =>
                throw StateError('Lost acknowledgement.');
          } else {
            final event = operation == 'prepare' ? 'INSERT' : 'UPDATE';
            storage.database.execute(
              '''CREATE TRIGGER reject_handoff AFTER $event ON adele_diff_review_handoffs
            BEGIN SELECT RAISE(ABORT, 'after all transition writes'); END;''',
            );
          }
          await expectLater(switch (operation) {
            'prepare' => service.prepareReview('session', 1),
            'delivery' => service.markDeliveryAttempted('session', 'review-1'),
            'acceptance' => service.confirmAcceptance(
              'session',
              'review-1',
              'session',
              'entry-1',
            ),
            'scheduling' => service.markSchedulingAttempted(
              'session',
              'review-1',
              'entry-1',
            ),
            'scheduled' => service.confirmRunScheduled(
              'session',
              'review-1',
              'entry-1',
              1,
              'run-1',
            ),
            _ => service.confirmRunNotStarted(
              'session',
              'review-1',
              'entry-1',
              1,
            ),
          }, _failure('outcome_uncertain'));
          expect(storage.transactions, writes + 1);
          storage.afterCommit = null;
          if (!lostAck) {
            expect(_state(storage), before);
          } else {
            expect(_state(storage), isNot(before));
            final fresh = ReviewDraftServiceImpl(storage);
            addTearDown(fresh.close);
            final restored = (await fresh.readReview('session'))!;
            expect(restored.status, switch (operation) {
              'prepare' => ReviewSubmissionStatus.prepared,
              'delivery' => ReviewSubmissionStatus.deliveryPending,
              'acceptance' || 'notStarted' => ReviewSubmissionStatus.accepted,
              'scheduling' => ReviewSubmissionStatus.schedulingPending,
              _ => ReviewSubmissionStatus.scheduled,
            });
            expect(
              (await fresh.snapshot('session')).comments.length,
              ['prepare', 'delivery'].contains(operation) ? 1 : 0,
            );
          }
          expect(storage.transactions, writes + 1);
        },
      );
    }
  }

  test(
    'prepare reserves finalization revision budget at exact maximum',
    () async {
      await service.createComment('session', _anchor(), 'Original.');
      final max = ReviewDraftLimits.maxVersion;
      storage.database.execute(
        'UPDATE adele_diff_review_sessions SET revision=?',
        [max - 1],
      );
      final before = _state(storage);
      await expectLater(
        service.prepareReview('session', max - 1),
        completion(_rejection('counter_exhausted')),
      );
      expect(_state(storage), before);
      storage.database.execute(
        'UPDATE adele_diff_review_sessions SET revision=?',
        [max - 2],
      );
      await _prepared(service.prepareReview('session', max - 2));
      await service.markDeliveryAttempted('session', 'review-1');
      await service.confirmAcceptance(
        'session',
        'review-1',
        'session',
        'entry-1',
      );
      expect((await service.snapshot('session')).revision, max);
      await service.markSchedulingAttempted('session', 'review-1', 'entry-1');
      await service.confirmRunScheduled(
        'session',
        'review-1',
        'entry-1',
        1,
        'run-1',
      );
    },
  );

  test(
    'exhausted submission and scheduling counters reject unchanged',
    () async {
      await service.createComment('session', _anchor(), 'Original.');
      storage.database.execute(
        'INSERT INTO adele_diff_review_allocators VALUES (?,?)',
        ['session', ReviewDraftLimits.maxSequence + 1],
      );
      var before = _state(storage);
      await expectLater(
        service.prepareReview('session', 1),
        completion(_rejection('counter_exhausted')),
      );
      expect(_state(storage), before);
      storage.database.execute('DELETE FROM adele_diff_review_allocators');
      await _prepared(service.prepareReview('session', 1));
      await service.markDeliveryAttempted('session', 'review-1');
      await service.confirmAcceptance(
        'session',
        'review-1',
        'session',
        'entry-1',
      );
      storage.database.execute(
        'UPDATE adele_diff_review_handoffs SET scheduling_attempt=?',
        [ReviewDraftLimits.maxSequence],
      );
      before = _state(storage);
      await expectLater(
        service.markSchedulingAttempted('session', 'review-1', 'entry-1'),
        _failure('limit_exceeded'),
      );
      expect(_state(storage), before);
    },
  );

  for (final corrupt in [
    "UPDATE adele_diff_review_handoffs SET canonical_payload=canonical_payload || ' '",
    "UPDATE adele_diff_review_handoffs SET submission_id='wrong'",
    'UPDATE adele_diff_review_handoffs SET comment_count=2',
    "UPDATE adele_diff_review_handoffs SET status='scheduled'",
    'UPDATE adele_diff_review_handoffs SET scheduling_attempt=-1',
    'UPDATE adele_diff_review_allocators SET next_submission=1',
  ]) {
    test('invalid retained handoff fails closed: $corrupt', () async {
      await prepare();
      storage.database.execute('PRAGMA ignore_check_constraints=ON');
      storage.database.execute(corrupt);
      final before = _state(storage);
      await expectLater(
        service.readReview('session'),
        _failure('corrupt_state'),
      );
      await expectLater(
        service.markDeliveryAttempted('session', 'review-1'),
        _failure('corrupt_state'),
      );
      expect(_state(storage), before);
    });
  }

  for (final status in ReviewSubmissionStatus.values) {
    test(
      'on-disk reopen retains $status without replay or inferred rollback',
      () async {
        final directory = Directory.systemTemp.createTempSync('diff-handoff-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final path = '${directory.path}/project.sqlite';
        final firstStorage = ReviewTestStorage(path: path);
        final first = ReviewDraftServiceImpl(firstStorage);
        await first.createComment('session', _anchor(), 'Persisted.');
        final original = await _prepared(first.prepareReview('session', 1));
        if (status.index >= ReviewSubmissionStatus.deliveryPending.index) {
          await first.markDeliveryAttempted('session', original.submissionId);
        }
        if (status.index >= ReviewSubmissionStatus.accepted.index) {
          await first.confirmAcceptance(
            'session',
            original.submissionId,
            'session',
            'entry-1',
          );
          await first.createComment('session', _anchor(), 'New pending.');
        }
        if (status.index >= ReviewSubmissionStatus.schedulingPending.index) {
          await first.markSchedulingAttempted(
            'session',
            original.submissionId,
            'entry-1',
          );
        }
        if (status == ReviewSubmissionStatus.scheduled) {
          await first.confirmRunScheduled(
            'session',
            original.submissionId,
            'entry-1',
            1,
            'run-1',
          );
        }
        final before = _state(firstStorage);
        await first.close();
        firstStorage.close();
        final reopenedStorage = ReviewTestStorage(path: path);
        addTearDown(reopenedStorage.close);
        final reopened = ReviewDraftServiceImpl(reopenedStorage);
        addTearDown(reopened.close);
        final review = (await reopened.readReview('session'))!;
        expect(review.status, status);
        expect(review.canonicalPayload, original.canonicalPayload);
        expect(_state(reopenedStorage), before);
        expect(reopenedStorage.transactions, 0);
        expect(
          (await reopened.snapshot('session')).comments.single.text,
          status.index >= ReviewSubmissionStatus.accepted.index
              ? 'New pending.'
              : 'Persisted.',
        );
        if (status == ReviewSubmissionStatus.schedulingPending) {
          await expectLater(
            reopened.markSchedulingAttempted(
              'session',
              review.submissionId,
              'entry-1',
            ),
            _failure('review_conflict'),
          );
          expect((await reopened.readReview('session'))!.runId, isNull);
        }
      },
    );
  }

  test(
    'shutdown after prepare commit fences success but retains frozen SQL',
    () async {
      await service.createComment('session', _anchor(), 'Original.');
      final entered = Completer<void>();
      final gate = Completer<void>();
      storage.afterCommit = () async {
        entered.complete();
        await gate.future;
      };
      final rejected = expectLater(
        service.prepareReview('session', 1),
        _failure('outcome_uncertain'),
      );
      await entered.future;
      final closing = service.close();
      gate.complete();
      await Future.wait([rejected, closing]);
      final fresh = ReviewDraftServiceImpl(storage);
      addTearDown(fresh.close);
      expect(
        (await fresh.readReview('session'))!.status,
        ReviewSubmissionStatus.prepared,
      );
      await expectLater(
        fresh.createComment('session', _anchor(), 'Blocked.'),
        _failure('draft_frozen'),
      );
    },
  );

  test(
    'full 128-comment snapshot reads summary without multiplying payload',
    () async {
      for (var index = 0; index < 128; index++) {
        await service.createComment('session', _anchor(), 'x${'\u0000' * 80}');
      }
      final review = await _prepared(service.prepareReview('session', 128));
      expect(
        utf8.encode(review.canonicalPayload).length,
        lessThanOrEqualTo(SessionFeedbackLimits.maxSubmissionBytes),
      );
      final snapshot = await service.snapshot('session');
      expect(snapshot.comments, hasLength(128));
      expect(snapshot.currentReview!.commentCount, 128);
      expect(storage.querySql.last, isNot(contains('canonical_payload')));
      expect(storage.maximumQueryBytes, lessThan(relationalQueryByteLimit));
      expect(
        (await service.readReview('session'))!.canonicalPayload,
        review.canonicalPayload,
      );
    },
  );
}

ReviewCommentAnchor _anchor({
  ReviewComparisonLayer layer = ReviewComparisonLayer.staged,
  ReviewComparisonSide side = ReviewComparisonSide.oldSide,
}) => ReviewCommentAnchor(
  environmentId: 'environment-${layer.name}',
  relativePath: 'lib/ raw\t\u00e9.dart',
  layer: layer,
  side: side,
  startLine: 3,
  endLine: 4,
  comparisonIdentity: 'original-${layer.name}-${side.name}',
  sourceExcerpt: ' exact\r\n\t\u0000\u{1f600} ',
  hunkIndex: 2,
  lineIndex: 5,
);

Matcher _failure(String code) => throwsA(
  isA<ReviewDraftFailure>().having((error) => error.code, 'code', code),
);

Matcher _rejection(String code) => isA<ReviewPreparationResult>()
    .having((result) => result.submission, 'submission', isNull)
    .having((result) => result.rejectionCode, 'rejectionCode', code);

Future<PreparedReviewSubmission> _prepared(
  Future<ReviewPreparationResult> pending,
) async {
  final result = await pending;
  expect(result.rejectionCode, isNull);
  expect(result.submission, isNotNull);
  return result.submission!;
}

Map<String, Object?> _state(ReviewTestStorage storage) => {
  for (final table in ['sessions', 'comments', 'allocators', 'handoffs'])
    table: [
      for (final row in storage.database.select(
        'SELECT * FROM adele_diff_review_$table ORDER BY session_id',
      ))
        Map<String, Object?>.from(row),
    ],
};
