/// Diff-owned SQL behind the host's exact-generation Project storage grant.
library;

import 'package:adele_orchestration/session_feedback.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

/// Retains no comments between calls. Only mutations on this instance serialize;
/// database preconditions also fence independently hydrated backend generations.
final class ReviewDraftServiceImpl implements ReviewDraftService {
  ReviewDraftServiceImpl(this._storage);

  final ProjectStorageService _storage;
  static const _access = ProjectStorageAccessMode.durableOrTemporary;
  String? _schemaSession;
  Future<void>? _schemaFuture;
  Future<void> _mutations = Future<void>.value();
  bool _closed = false;

  @override
  Future<ReviewDraftSnapshot> snapshot(String sessionId) async {
    _validate(() => validateReviewDraftIdentity(sessionId, 'sessionId'));
    return (await _load(sessionId)).snapshot;
  }

  @override
  Future<PendingReviewComment> createComment(
    String sessionId,
    ReviewCommentAnchor anchor,
    String text,
  ) => _mutate(() async {
    _validate(() {
      validateReviewDraftIdentity(sessionId, 'sessionId');
      validateReviewCommentText(text);
    });
    final state = await _load(sessionId);
    if (state.nextSequence > ReviewDraftLimits.maxSequence) {
      throw _failure('limit_exceeded', 'Comment identities are exhausted.');
    }
    final comment = PendingReviewComment(
      id: 'comment-${state.nextSequence}',
      anchor: anchor,
      text: text,
      version: 1,
      sequence: state.nextSequence,
    );
    await _commit(
      state,
      [...state.snapshot.comments, comment],
      state.nextSequence + 1,
      RelationalStatement(
        sql: '''INSERT INTO adele_diff_review_comments
          (session_id,comment_id,sequence,version,environment_id,relative_path,
           layer,side,start_line,end_line,comparison_identity,source_excerpt,
           hunk_index,line_index,text,charge)
          VALUES (:session,:id,:sequence,1,:environment,:path,:layer,:side,
                  :start,:end,:comparison,:excerpt,:hunk,:line,:text,:charge)''',
        parameters: {
          ':session': sessionId,
          ':id': comment.id,
          ':sequence': comment.sequence,
          ':environment': anchor.environmentId,
          ':path': anchor.relativePath,
          ':layer': anchor.layer.name,
          ':side': anchor.side.name,
          ':start': anchor.startLine,
          ':end': anchor.endLine,
          ':comparison': anchor.comparisonIdentity,
          ':excerpt': anchor.sourceExcerpt,
          ':hunk': anchor.hunkIndex,
          ':line': anchor.lineIndex,
          ':text': text,
          ':charge': reviewCommentCharge(comment),
        },
        expectedRows: 1,
      ),
    );
    return comment;
  });

  @override
  Future<PendingReviewComment> updateComment(
    String sessionId,
    String commentId,
    int expectedVersion,
    String text,
  ) => _mutate(() async {
    _validateMutation(sessionId, commentId, expectedVersion);
    _validate(() => validateReviewCommentText(text));
    final state = await _load(sessionId);
    final prior = _expectedComment(state, commentId, expectedVersion);
    if (prior.version == ReviewDraftLimits.maxVersion) {
      throw _failure('limit_exceeded', 'Comment versions are exhausted.');
    }
    final comment = PendingReviewComment(
      id: prior.id,
      anchor: prior.anchor,
      text: text,
      version: prior.version + 1,
      sequence: prior.sequence,
    );
    await _commit(
      state,
      [
        for (final value in state.snapshot.comments)
          value.id == commentId ? comment : value,
      ],
      state.nextSequence,
      RelationalStatement(
        sql: '''UPDATE adele_diff_review_comments
          SET text=:text, version=version+1, charge=:charge
          WHERE session_id=:session AND comment_id=:id AND version=:version
            AND version<${ReviewDraftLimits.maxVersion}''',
        parameters: {
          ':session': sessionId,
          ':id': commentId,
          ':version': expectedVersion,
          ':text': text,
          ':charge': reviewCommentCharge(comment),
        },
        expectedRows: 1,
      ),
    );
    return comment;
  });

  @override
  Future<void> deleteComment(
    String sessionId,
    String commentId,
    int expectedVersion,
  ) => _mutate(() async {
    _validateMutation(sessionId, commentId, expectedVersion);
    final state = await _load(sessionId);
    _expectedComment(state, commentId, expectedVersion);
    await _commit(
      state,
      state.snapshot.comments.where((value) => value.id != commentId).toList(),
      state.nextSequence,
      RelationalStatement(
        sql: '''DELETE FROM adele_diff_review_comments
          WHERE session_id=:session AND comment_id=:id AND version=:version''',
        parameters: {
          ':session': sessionId,
          ':id': commentId,
          ':version': expectedVersion,
        },
        expectedRows: 1,
      ),
    );
  });

  @override
  Future<ReviewPreparationResult> prepareReview(
    String sessionId,
    int expectedRevision,
  ) => _mutate(() async {
    _validate(() {
      validateReviewDraftIdentity(sessionId, 'sessionId');
      if (expectedRevision < 0 ||
          expectedRevision > ReviewDraftLimits.maxVersion) {
        throw ArgumentError('Invalid draft revision.');
      }
    });
    final state = await _load(
      sessionId,
      access: ProjectStorageAccessMode.durable,
    );
    if (state.revision != expectedRevision) {
      return ReviewPreparationResult(
        submission: null,
        rejectionCode: 'stale_draft',
      );
    }
    final current = state.snapshot.currentReview;
    if (current != null && current.status != ReviewSubmissionStatus.scheduled) {
      return ReviewPreparationResult(
        submission: null,
        rejectionCode: 'review_conflict',
      );
    }
    if (state.snapshot.comments.isEmpty) {
      return ReviewPreparationResult(
        submission: null,
        rejectionCode: 'empty_review',
      );
    }
    // Preparation and acceptance each consume one draft revision. Attempt and
    // scheduling metadata do not, so finalization can never exhaust its budget.
    if (state.revision > ReviewDraftLimits.maxVersion - 2 ||
        state.nextSubmission > ReviewDraftLimits.maxSequence) {
      return ReviewPreparationResult(
        submission: null,
        rejectionCode: 'counter_exhausted',
      );
    }
    final submissionId = 'review-${state.nextSubmission}';
    final String payload;
    try {
      payload = encodeSessionFeedbackSubmission(
        _submission(submissionId, state.snapshot.comments),
      );
    } on SessionFeedbackFailure catch (error) {
      if (error.code == 'submission_too_large') {
        return ReviewPreparationResult(
          submission: null,
          rejectionCode: 'submission_too_large',
        );
      }
      throw _failure(
        'invalid_request',
        'The complete pending review cannot be submitted within the feedback bounds.',
      );
    }
    final prepared = PreparedReviewSubmission(
      sessionId: sessionId,
      submissionId: submissionId,
      canonicalPayload: payload,
      status: ReviewSubmissionStatus.prepared,
      commentCount: state.snapshot.comments.length,
      schedulingAttempt: 0,
      occurrenceId: null,
      runId: null,
    );
    await _writeReview(sessionId, [
      RelationalStatement(
        sql:
            '''UPDATE adele_diff_review_sessions SET revision=revision+1
          WHERE session_id=:session AND revision=:revision
            AND next_sequence=:next AND comment_count=:count AND total_charge=:charge
            AND revision<=${ReviewDraftLimits.maxVersion - 2}
            AND NOT EXISTS (SELECT 1 FROM adele_diff_review_handoffs
              WHERE session_id=:session AND status!='scheduled')''',
        parameters: {
          ':session': sessionId,
          ':revision': state.revision,
          ':next': state.nextSequence,
          ':count': state.snapshot.comments.length,
          ':charge': state.charge,
        },
        expectedRows: 1,
      ),
      if (state.nextSubmission == 1)
        RelationalStatement(
          sql: '''INSERT INTO adele_diff_review_allocators
            (session_id,next_submission) VALUES (:session,2)''',
          parameters: {':session': sessionId},
          expectedRows: 1,
        )
      else
        RelationalStatement(
          sql: '''UPDATE adele_diff_review_allocators
            SET next_submission=next_submission+1
            WHERE session_id=:session AND next_submission=:next
              AND next_submission<=${ReviewDraftLimits.maxSequence}''',
          parameters: {':session': sessionId, ':next': state.nextSubmission},
          expectedRows: 1,
        ),
      // Retain one current row. Only a positively scheduled predecessor is pruned.
      RelationalStatement(
        sql: '''DELETE FROM adele_diff_review_handoffs
          WHERE session_id=:session AND submission_id=:id AND status='scheduled' ''',
        parameters: {':session': sessionId, ':id': current?.submissionId},
        expectedRows: current == null ? 0 : 1,
      ),
      RelationalStatement(
        sql: '''INSERT INTO adele_diff_review_handoffs
          (session_id,submission_id,submission_sequence,prepared_revision,
           canonical_payload,status,comment_count,scheduling_attempt,occurrence_id,run_id)
          VALUES (:session,:id,:sequence,:revision,:payload,'prepared',:count,0,NULL,NULL)''',
        parameters: {
          ':session': sessionId,
          ':id': submissionId,
          ':sequence': state.nextSubmission,
          ':revision': state.revision + 1,
          ':payload': payload,
          ':count': prepared.commentCount,
        },
        expectedRows: 1,
      ),
    ]);
    return ReviewPreparationResult(submission: prepared, rejectionCode: null);
  });

  @override
  Future<PreparedReviewSubmission?> readReview(String sessionId) async {
    _validate(() => validateReviewDraftIdentity(sessionId, 'sessionId'));
    return (await _readReview(sessionId))?.value;
  }

  @override
  Future<PreparedReviewSubmission> markDeliveryAttempted(
    String sessionId,
    String submissionId,
  ) => _mutate(() async {
    final stored = await _expectedReview(sessionId, submissionId);
    if (stored.value.status != ReviewSubmissionStatus.prepared) {
      throw _failure(
        'review_conflict',
        'Delivery was already attempted. Reconcile the original review.',
      );
    }
    return _transition(stored, ReviewSubmissionStatus.deliveryPending);
  });

  @override
  Future<PreparedReviewSubmission> confirmAcceptance(
    String sessionId,
    String submissionId,
    String receiptSessionId,
    String occurrenceId,
  ) => _mutate(() async {
    _validate(() {
      validateReviewDraftIdentity(receiptSessionId, 'receiptSessionId');
      validateReviewDraftIdentity(occurrenceId, 'occurrenceId');
    });
    if (receiptSessionId != sessionId) {
      throw _failure(
        'review_conflict',
        'The receipt belongs to a different Session.',
      );
    }
    final stored = await _expectedReview(sessionId, submissionId);
    final review = stored.value;
    if (review.occurrenceId != null) {
      if (review.occurrenceId != occurrenceId) {
        throw _failure(
          'review_conflict',
          'The accepted occurrence cannot be replaced.',
        );
      }
      return review;
    }
    if (review.status != ReviewSubmissionStatus.deliveryPending) {
      throw _failure(
        'review_conflict',
        'Delivery must be marked before acceptance.',
      );
    }
    final state = await _load(
      sessionId,
      access: ProjectStorageAccessMode.durable,
    );
    if (state.snapshot.currentReview?.submissionId != submissionId ||
        state.snapshot.currentReview?.status != review.status) {
      throw _failure(
        'review_conflict',
        'The review changed while confirming acceptance. Read its current state.',
      );
    }
    final String currentPayload;
    try {
      currentPayload = encodeSessionFeedbackSubmission(
        _submission(submissionId, state.snapshot.comments),
      );
    } on SessionFeedbackFailure {
      throw _failure(
        'corrupt_state',
        'The frozen pending comments are invalid.',
      );
    }
    if (state.revision != stored.preparedRevision ||
        currentPayload != review.canonicalPayload) {
      throw _failure(
        'corrupt_state',
        'The frozen review no longer matches its pending comments.',
      );
    }
    final submission = decodeSessionFeedbackSubmission(review.canonicalPayload);
    await _writeReview(sessionId, [
      RelationalStatement(
        sql: '''UPDATE adele_diff_review_sessions
          SET revision=revision+1,comment_count=0,total_charge=0
          WHERE session_id=:session AND revision=:revision
            AND comment_count=:count AND total_charge=:charge
            AND revision<${ReviewDraftLimits.maxVersion}''',
        parameters: {
          ':session': sessionId,
          ':revision': stored.preparedRevision,
          ':count': review.commentCount,
          ':charge': state.charge,
        },
        expectedRows: 1,
      ),
      for (final comment in submission.comments)
        RelationalStatement(
          sql: '''DELETE FROM adele_diff_review_comments
            WHERE session_id=:session AND comment_id=:id AND version=:version
              AND sequence=:sequence''',
          parameters: {
            ':session': sessionId,
            ':id': comment.id,
            ':version': comment.version,
            ':sequence': comment.sequence,
          },
          expectedRows: 1,
        ),
      _reviewUpdate(
        stored,
        ReviewSubmissionStatus.accepted,
        occurrenceId: occurrenceId,
      ),
    ]);
    return _reviewValue(
      review,
      ReviewSubmissionStatus.accepted,
      occurrenceId: occurrenceId,
    );
  });

  @override
  Future<PreparedReviewSubmission> markSchedulingAttempted(
    String sessionId,
    String submissionId,
    String occurrenceId,
  ) => _mutate(() async {
    final stored = await _expectedReview(
      sessionId,
      submissionId,
      occurrenceId: occurrenceId,
    );
    if (stored.value.status != ReviewSubmissionStatus.accepted) {
      throw _failure(
        'review_conflict',
        'Scheduling was already attempted. Reconcile the original occurrence.',
      );
    }
    if (stored.value.schedulingAttempt == ReviewDraftLimits.maxSequence) {
      throw _failure(
        'limit_exceeded',
        'Review scheduling attempts are exhausted.',
      );
    }
    return _transition(
      stored,
      ReviewSubmissionStatus.schedulingPending,
      schedulingAttempt: stored.value.schedulingAttempt + 1,
    );
  });

  @override
  Future<PreparedReviewSubmission> confirmRunScheduled(
    String sessionId,
    String submissionId,
    String occurrenceId,
    int expectedAttempt,
    String runId,
  ) => _mutate(() async {
    _validate(() => validateReviewDraftIdentity(runId, 'runId'));
    final stored = await _expectedReview(
      sessionId,
      submissionId,
      occurrenceId: occurrenceId,
      expectedAttempt: expectedAttempt,
    );
    if (stored.value.runId != null) {
      if (stored.value.runId != runId) {
        throw _failure(
          'review_conflict',
          'The scheduled Run cannot be replaced.',
        );
      }
      return stored.value;
    }
    if (stored.value.status != ReviewSubmissionStatus.schedulingPending) {
      throw _failure(
        'review_conflict',
        'Scheduling must be marked before recording a Run.',
      );
    }
    return _transition(stored, ReviewSubmissionStatus.scheduled, runId: runId);
  });

  @override
  Future<PreparedReviewSubmission> confirmRunNotStarted(
    String sessionId,
    String submissionId,
    String occurrenceId,
    int expectedAttempt,
  ) => _mutate(() async {
    final stored = await _expectedReview(
      sessionId,
      submissionId,
      occurrenceId: occurrenceId,
      expectedAttempt: expectedAttempt,
    );
    if (stored.value.status == ReviewSubmissionStatus.accepted) {
      return stored.value;
    }
    if (stored.value.status != ReviewSubmissionStatus.schedulingPending) {
      throw _failure(
        'review_conflict',
        'The scheduling attempt cannot be reset.',
      );
    }
    return _transition(stored, ReviewSubmissionStatus.accepted);
  });

  Future<_StoredReview> _expectedReview(
    String sessionId,
    String submissionId, {
    String? occurrenceId,
    int? expectedAttempt,
  }) async {
    _validate(() {
      validateReviewDraftIdentity(sessionId, 'sessionId');
      validateReviewDraftIdentity(submissionId, 'submissionId');
      if (occurrenceId != null) {
        validateReviewDraftIdentity(occurrenceId, 'occurrenceId');
      }
      if (expectedAttempt != null &&
          (expectedAttempt < 1 ||
              expectedAttempt > ReviewDraftLimits.maxSequence)) {
        throw ArgumentError('Invalid scheduling attempt.');
      }
    });
    final stored = await _readReview(sessionId);
    if (stored == null ||
        stored.value.submissionId != submissionId ||
        (occurrenceId != null && stored.value.occurrenceId != occurrenceId) ||
        (expectedAttempt != null &&
            stored.value.schedulingAttempt != expectedAttempt)) {
      throw _failure(
        'review_conflict',
        'The current review or accepted occurrence does not match.',
      );
    }
    return stored;
  }

  Future<PreparedReviewSubmission> _transition(
    _StoredReview stored,
    ReviewSubmissionStatus status, {
    String? runId,
    int? schedulingAttempt,
  }) async {
    await _writeReview(stored.value.sessionId, [
      _reviewUpdate(
        stored,
        status,
        runId: runId,
        schedulingAttempt: schedulingAttempt,
      ),
    ]);
    return _reviewValue(
      stored.value,
      status,
      runId: runId,
      schedulingAttempt: schedulingAttempt,
    );
  }

  RelationalStatement _reviewUpdate(
    _StoredReview stored,
    ReviewSubmissionStatus status, {
    String? occurrenceId,
    String? runId,
    int? schedulingAttempt,
  }) => RelationalStatement(
    sql: '''UPDATE adele_diff_review_handoffs
      SET status=:status,occurrence_id=:occurrence,run_id=:run,scheduling_attempt=:attempt
      WHERE session_id=:session AND submission_id=:id AND status=:oldStatus
        AND scheduling_attempt=:oldAttempt
        AND occurrence_id IS :oldOccurrence AND run_id IS :oldRun''',
    parameters: {
      ':session': stored.value.sessionId,
      ':id': stored.value.submissionId,
      ':status': status.name,
      ':occurrence': occurrenceId ?? stored.value.occurrenceId,
      ':run': runId ?? stored.value.runId,
      ':oldStatus': stored.value.status.name,
      ':oldOccurrence': stored.value.occurrenceId,
      ':oldRun': stored.value.runId,
      ':attempt': schedulingAttempt ?? stored.value.schedulingAttempt,
      ':oldAttempt': stored.value.schedulingAttempt,
    },
    expectedRows: 1,
  );

  Future<void> _writeReview(
    String sessionId,
    List<RelationalStatement> statements,
  ) async {
    _requireOpen();
    try {
      await _storage.transactionForSession(
        sessionId,
        statements,
        ProjectStorageAccessMode.durable,
      );
    } on Object {
      throw _failure(
        'outcome_uncertain',
        'The review write was not acknowledged. Read the original handoff before another action.',
      );
    }
  }

  void _requireEditable(_StoredDraft state) {
    final status = state.snapshot.currentReview?.status;
    if (status == ReviewSubmissionStatus.prepared ||
        status == ReviewSubmissionStatus.deliveryPending) {
      throw _failure(
        'draft_frozen',
        'Pending comments are frozen until acceptance is confirmed.',
      );
    }
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _mutations.then((_) async {
      _requireOpen();
      final value = await action();
      if (_closed) {
        throw _failure(
          'outcome_uncertain',
          'The backend closed before the write could be confirmed. Reload the draft.',
        );
      }
      return value;
    });
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _commit(
    _StoredDraft state,
    List<PendingReviewComment> comments,
    int nextSequence,
    RelationalStatement change,
  ) async {
    final sessionId = state.snapshot.sessionId;
    _requireEditable(state);
    final emptyCharge = reviewDraftSnapshotCharge(sessionId, const []);
    final charge = reviewDraftSnapshotCharge(sessionId, comments) - emptyCharge;
    if (comments.length > ReviewDraftLimits.maxComments ||
        charge + emptyCharge > ReviewDraftLimits.maxSnapshotCharge ||
        state.revision == ReviewDraftLimits.maxVersion) {
      throw _failure(
        'limit_exceeded',
        'The pending review draft limit was reached.',
      );
    }
    final header = state.revision == 0
        ? RelationalStatement(
            sql: '''INSERT INTO adele_diff_review_sessions
              (session_id,next_sequence,revision,comment_count,total_charge)
              SELECT :session,:next,1,:count,:charge
              WHERE :count<=${ReviewDraftLimits.maxComments} AND :charge<=:limit''',
            parameters: {
              ':session': sessionId,
              ':next': nextSequence,
              ':count': comments.length,
              ':charge': charge,
              ':limit': ReviewDraftLimits.maxSnapshotCharge - emptyCharge,
            },
            expectedRows: 1,
          )
        : RelationalStatement(
            sql:
                '''UPDATE adele_diff_review_sessions
              SET next_sequence=:next,revision=revision+1,
                  comment_count=:count,total_charge=:charge
              WHERE session_id=:session AND revision=:revision
                AND next_sequence=:oldNext AND comment_count=:oldCount
                AND total_charge=:oldCharge
                AND NOT EXISTS (SELECT 1 FROM adele_diff_review_handoffs
                  WHERE session_id=:session AND status IN ('prepared','deliveryPending'))
                AND revision<${ReviewDraftLimits.maxVersion}
                AND :count BETWEEN 0 AND ${ReviewDraftLimits.maxComments}
                AND :charge BETWEEN 0 AND :limit''',
            parameters: {
              ':session': sessionId,
              ':revision': state.revision,
              ':oldNext': state.nextSequence,
              ':oldCount': state.snapshot.comments.length,
              ':oldCharge': state.charge,
              ':next': nextSequence,
              ':count': comments.length,
              ':charge': charge,
              ':limit': ReviewDraftLimits.maxSnapshotCharge - emptyCharge,
            },
            expectedRows: 1,
          );
    _requireOpen();
    try {
      await _storage.transactionForSession(sessionId, [
        header,
        change,
      ], _access);
    } on Object {
      // A transport exception cannot prove rollback, even for an expectedRows
      // conflict. Never retry or reinterpret a subsequent read as acknowledgement.
      throw _failure(
        'outcome_uncertain',
        'The write was not acknowledged. Reload the draft before another change.',
      );
    }
  }

  Future<void> _ensureSchema(String sessionId) async {
    _requireOpen();
    if (_schemaSession != sessionId) {
      _schemaSession = sessionId;
      _schemaFuture = null;
    }
    final Future<void> schema;
    try {
      schema = _schemaFuture ??= _storage.ensureSchemaForSession(sessionId, [
        _schemaSql,
        _handoffSchemaSql,
      ], _access);
      await schema;
    } on Object {
      if (_schemaSession == sessionId) _schemaFuture = null;
      _requireOpen();
      throw _failure(
        'storage_unavailable',
        'Review draft storage is unavailable.',
      );
    }
    _requireOpen();
  }

  Future<_StoredReview?> _readReview(String sessionId) async {
    await _ensureSchema(sessionId);
    final List<RelationalRow> rows;
    try {
      rows = await _storage.queryForSession(
        sessionId,
        '''SELECT h.*,
        a.next_submission,s.revision FROM adele_diff_review_handoffs h
        LEFT JOIN adele_diff_review_allocators a ON a.session_id=h.session_id
        LEFT JOIN adele_diff_review_sessions s ON s.session_id=h.session_id
        WHERE h.session_id=:session LIMIT 2''',
        {':session': sessionId},
        ProjectStorageAccessMode.durable,
      );
    } on Object {
      _requireOpen();
      throw _failure(
        'storage_unavailable',
        'Durable review handoff storage could not be read.',
      );
    }
    _requireOpen();
    if (rows.isEmpty) return null;
    try {
      if (rows.length != 1) {
        throw const FormatException('Duplicate review handoff.');
      }
      final row = rows.single.values;
      final summary = _reviewSummary(row, row['comment_count']);
      final preparedRevision = _integer(
        row['prepared_revision'],
        2,
        ReviewDraftLimits.maxVersion - 1,
      );
      final revision = _integer(
        row['revision'],
        preparedRevision,
        ReviewDraftLimits.maxVersion,
      );
      final sequence = _integer(
        row['submission_sequence'],
        1,
        ReviewDraftLimits.maxSequence,
      );
      if (row['session_id'] != sessionId ||
          row['next_submission'] != sequence + 1 ||
          summary.submissionId != 'review-$sequence' ||
          (_frozen(summary.status)
              ? revision != preparedRevision
              : revision <= preparedRevision)) {
        throw const FormatException('Invalid review counters.');
      }
      final payload = row['canonical_payload']! as String;
      final submission = decodeSessionFeedbackSubmission(payload);
      if (submission.submissionId != summary.submissionId ||
          submission.comments.length != summary.commentCount ||
          encodeSessionFeedbackSubmission(submission) != payload) {
        throw const FormatException('Invalid canonical review payload.');
      }
      return _StoredReview(
        PreparedReviewSubmission(
          sessionId: sessionId,
          submissionId: summary.submissionId,
          canonicalPayload: payload,
          status: summary.status,
          commentCount: summary.commentCount,
          schedulingAttempt: summary.schedulingAttempt,
          occurrenceId: summary.occurrenceId,
          runId: summary.runId,
        ),
        preparedRevision,
      );
    } on Object {
      throw _failure('corrupt_state', 'Stored review handoff data is invalid.');
    }
  }

  Future<_StoredDraft> _load(
    String sessionId, {
    ProjectStorageAccessMode access = _access,
  }) async {
    await _ensureSchema(sessionId);
    final List<RelationalRow> rows;
    try {
      // A single SQL snapshot keeps header counters and every comment coherent.
      // The extra row detects overflow rather than returning a truncated prefix.
      rows = await _storage.queryForSession(
        sessionId,
        '''SELECT s.session_id AS state_session,s.next_sequence,s.revision,
          s.comment_count,s.total_charge,c.session_id AS comment_session,
          c.comment_id,c.sequence,c.version,c.environment_id,c.relative_path,
          c.layer,c.side,c.start_line,c.end_line,c.comparison_identity,
          c.source_excerpt,c.hunk_index,c.line_index,c.text,c.charge,
          a.next_submission,h.submission_id,h.submission_sequence,
          h.prepared_revision,h.status,h.comment_count AS review_count,
          h.occurrence_id,h.run_id,h.scheduling_attempt
          FROM (SELECT :session AS session_id) requested
          LEFT JOIN adele_diff_review_sessions s ON s.session_id=requested.session_id
          LEFT JOIN adele_diff_review_comments c ON c.session_id=requested.session_id
          LEFT JOIN adele_diff_review_allocators a ON a.session_id=requested.session_id
          LEFT JOIN adele_diff_review_handoffs h ON h.session_id=requested.session_id
          ORDER BY c.sequence LIMIT ${ReviewDraftLimits.maxComments + 1}''',
        {':session': sessionId},
        access,
      );
    } on Object {
      _requireOpen();
      throw _failure(
        'storage_unavailable',
        'Review draft storage could not be read.',
      );
    }
    _requireOpen();
    try {
      if (rows.isEmpty || rows.length > ReviewDraftLimits.maxComments) {
        throw const FormatException('Invalid comment extent.');
      }
      final first = rows.first.values;
      if (first['state_session'] == null) {
        if (rows.length != 1 || first.values.any((value) => value != null)) {
          throw const FormatException('Orphan review comments.');
        }
        return _StoredDraft(
          ReviewDraftSnapshot(
            sessionId: sessionId,
            revision: 0,
            comments: const [],
            currentReview: null,
          ),
          nextSequence: 1,
          nextSubmission: 1,
          revision: 0,
          charge: 0,
        );
      }
      final next = _integer(
        first['next_sequence'],
        2,
        ReviewDraftLimits.maxSequence + 1,
      );
      final revision = _integer(
        first['revision'],
        1,
        ReviewDraftLimits.maxVersion,
      );
      final count = _integer(
        first['comment_count'],
        0,
        ReviewDraftLimits.maxComments,
      );
      final charge = _integer(
        first['total_charge'],
        0,
        ReviewDraftLimits.maxSnapshotCharge,
      );
      if (first['state_session'] != sessionId || revision < next - 1) {
        throw const FormatException('Invalid Session counters.');
      }
      final nextSubmission = first['next_submission'] == null
          ? 1
          : _integer(
              first['next_submission'],
              2,
              ReviewDraftLimits.maxSequence + 1,
            );
      ReviewSubmissionSummary? review;
      if (first['submission_id'] != null) {
        review = _reviewSummary(first, first['review_count']);
        final sequence = _integer(
          first['submission_sequence'],
          1,
          ReviewDraftLimits.maxSequence,
        );
        final preparedRevision = _integer(
          first['prepared_revision'],
          2,
          ReviewDraftLimits.maxVersion - 1,
        );
        if (nextSubmission != sequence + 1 ||
            review.submissionId != 'review-$sequence' ||
            preparedRevision > revision ||
            (!_frozen(review.status) && preparedRevision == revision) ||
            (_frozen(review.status) &&
                (preparedRevision != revision ||
                    review.commentCount != count))) {
          throw const FormatException('Invalid handoff counters.');
        }
      } else if ([
        'submission_sequence',
        'prepared_revision',
        'status',
        'review_count',
        'occurrence_id',
        'run_id',
        'scheduling_attempt',
      ].any((key) => first[key] != null)) {
        throw const FormatException('Invalid empty handoff.');
      }
      final comments = <PendingReviewComment>[];
      var actualCharge = 0;
      for (final result in rows) {
        final row = result.values;
        for (final key in _headerColumns) {
          if (row[key] != first[key]) {
            throw const FormatException('Inconsistent Session header.');
          }
        }
        if (row['comment_session'] == null) {
          if (rows.length != 1 ||
              count != 0 ||
              row.entries.any(
                (entry) =>
                    !_headerColumns.contains(entry.key) && entry.value != null,
              )) {
            throw const FormatException('Invalid empty draft.');
          }
          continue;
        }
        final comment = PendingReviewComment(
          id: row['comment_id']! as String,
          sequence: row['sequence']! as int,
          version: row['version']! as int,
          text: row['text']! as String,
          anchor: ReviewCommentAnchor(
            environmentId: row['environment_id']! as String,
            relativePath: row['relative_path']! as String,
            layer: ReviewComparisonLayer.values.byName(row['layer']! as String),
            side: ReviewComparisonSide.values.byName(row['side']! as String),
            startLine: row['start_line']! as int,
            endLine: row['end_line']! as int,
            comparisonIdentity: row['comparison_identity']! as String,
            sourceExcerpt: row['source_excerpt']! as String,
            hunkIndex: row['hunk_index']! as int,
            lineIndex: row['line_index']! as int,
          ),
        );
        final commentCharge = reviewCommentCharge(comment);
        if (row['comment_session'] != sessionId ||
            comment.sequence >= next ||
            comment.version > revision ||
            comment.id != 'comment-${comment.sequence}' ||
            row['charge'] != commentCharge) {
          throw const FormatException(
            'Invalid stored comment identity or charge.',
          );
        }
        actualCharge += commentCharge;
        comments.add(comment);
      }
      if (comments.length != count || actualCharge != charge) {
        throw const FormatException('Invalid aggregate draft counters.');
      }
      return _StoredDraft(
        ReviewDraftSnapshot(
          sessionId: sessionId,
          revision: revision,
          comments: comments,
          currentReview: review,
        ),
        nextSequence: next,
        nextSubmission: nextSubmission,
        revision: revision,
        charge: charge,
      );
    } on Object {
      throw _failure('corrupt_state', 'Stored review draft data is invalid.');
    }
  }

  PendingReviewComment _expectedComment(
    _StoredDraft state,
    String id,
    int version,
  ) {
    for (final comment in state.snapshot.comments) {
      if (comment.id == id && comment.version == version) return comment;
    }
    throw _failure(
      'stale_comment',
      'The comment was changed or deleted. Reload the draft.',
    );
  }

  void _validateMutation(String sessionId, String commentId, int version) =>
      _validate(() {
        validateReviewDraftIdentity(sessionId, 'sessionId');
        validateReviewDraftIdentity(commentId, 'commentId');
        validateReviewCommentVersion(version);
      });

  void _validate(void Function() validate) {
    _requireOpen();
    try {
      validate();
    } on ArgumentError {
      throw _failure('invalid_request', 'Invalid review draft request.');
    }
  }

  void _requireOpen() {
    if (_closed) {
      throw _failure('backend_closed', 'The review draft backend is closed.');
    }
  }

  /// Fences immediately; the entrypoint also closes reverse calls to settle any
  /// pending host requests. A replacement must reconcile through a fresh snapshot.
  Future<void> close() {
    _closed = true;
    _schemaSession = null;
    _schemaFuture = null;
    return _mutations;
  }
}

final class _StoredDraft {
  const _StoredDraft(
    this.snapshot, {
    required this.nextSequence,
    required this.nextSubmission,
    required this.revision,
    required this.charge,
  });

  final ReviewDraftSnapshot snapshot;
  final int nextSequence;
  final int nextSubmission;
  final int revision;
  final int charge;
}

final class _StoredReview {
  const _StoredReview(this.value, this.preparedRevision);

  final PreparedReviewSubmission value;
  final int preparedRevision;
}

const _headerColumns = [
  'state_session',
  'next_sequence',
  'revision',
  'comment_count',
  'total_charge',
  'next_submission',
  'submission_id',
  'submission_sequence',
  'prepared_revision',
  'status',
  'review_count',
  'occurrence_id',
  'run_id',
  'scheduling_attempt',
];

bool _frozen(ReviewSubmissionStatus status) =>
    status == ReviewSubmissionStatus.prepared ||
    status == ReviewSubmissionStatus.deliveryPending;

ReviewSubmissionSummary _reviewSummary(
  Map<String, Object?> row,
  Object? count,
) => ReviewSubmissionSummary(
  submissionId: row['submission_id']! as String,
  status: ReviewSubmissionStatus.values.byName(row['status']! as String),
  commentCount: _integer(count, 1, ReviewDraftLimits.maxComments),
  schedulingAttempt: _integer(
    row['scheduling_attempt'],
    0,
    ReviewDraftLimits.maxSequence,
  ),
  occurrenceId: row['occurrence_id'] as String?,
  runId: row['run_id'] as String?,
);

PreparedReviewSubmission _reviewValue(
  PreparedReviewSubmission review,
  ReviewSubmissionStatus status, {
  String? occurrenceId,
  String? runId,
  int? schedulingAttempt,
}) => PreparedReviewSubmission(
  sessionId: review.sessionId,
  submissionId: review.submissionId,
  canonicalPayload: review.canonicalPayload,
  status: status,
  commentCount: review.commentCount,
  schedulingAttempt: schedulingAttempt ?? review.schedulingAttempt,
  occurrenceId: occurrenceId ?? review.occurrenceId,
  runId: runId ?? review.runId,
);

SessionFeedbackSubmission _submission(
  String submissionId,
  List<PendingReviewComment> comments,
) => SessionFeedbackSubmission(
  submissionId: submissionId,
  kind: SessionFeedbackKind.codeReview,
  comments: [
    for (final comment in comments)
      SessionFeedbackComment(
        id: comment.id,
        text: comment.text,
        version: comment.version,
        sequence: comment.sequence,
        anchor: SessionFeedbackAnchor(
          environmentId: comment.anchor.environmentId,
          relativePath: comment.anchor.relativePath,
          layer: switch (comment.anchor.layer) {
            ReviewComparisonLayer.unstaged =>
              SessionFeedbackComparisonLayer.unstaged,
            ReviewComparisonLayer.staged =>
              SessionFeedbackComparisonLayer.staged,
            ReviewComparisonLayer.committed =>
              SessionFeedbackComparisonLayer.committed,
          },
          side: switch (comment.anchor.side) {
            ReviewComparisonSide.oldSide =>
              SessionFeedbackComparisonSide.oldSide,
            ReviewComparisonSide.newSide =>
              SessionFeedbackComparisonSide.newSide,
          },
          startLine: comment.anchor.startLine,
          endLine: comment.anchor.endLine,
          comparisonIdentity: comment.anchor.comparisonIdentity,
          sourceExcerpt: comment.anchor.sourceExcerpt,
          hunkIndex: comment.anchor.hunkIndex,
          lineIndex: comment.anchor.lineIndex,
        ),
      ),
  ],
);

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('Invalid stored integer.');
  }
  return value;
}

ReviewDraftFailure _failure(String code, String message) =>
    ReviewDraftFailure(code: code, message: message);

final _handoffSchemaSql =
    '''
CREATE TABLE adele_diff_review_allocators (
  session_id TEXT PRIMARY KEY REFERENCES adele_diff_review_sessions(session_id) ON DELETE CASCADE,
  next_submission INTEGER NOT NULL CHECK(typeof(next_submission)='integer' AND next_submission BETWEEN 2 AND ${ReviewDraftLimits.maxSequence + 1})
);
CREATE TABLE adele_diff_review_handoffs (
  session_id TEXT PRIMARY KEY REFERENCES adele_diff_review_allocators(session_id) ON DELETE CASCADE,
  submission_id TEXT NOT NULL CHECK(submission_id='review-' || submission_sequence),
  submission_sequence INTEGER NOT NULL CHECK(typeof(submission_sequence)='integer' AND submission_sequence BETWEEN 1 AND ${ReviewDraftLimits.maxSequence}),
  prepared_revision INTEGER NOT NULL CHECK(typeof(prepared_revision)='integer' AND prepared_revision BETWEEN 2 AND ${ReviewDraftLimits.maxVersion - 1}),
  canonical_payload TEXT NOT NULL CHECK(length(CAST(canonical_payload AS BLOB)) BETWEEN 1 AND ${SessionFeedbackLimits.maxSubmissionBytes}),
  status TEXT NOT NULL CHECK(status IN ('prepared','deliveryPending','accepted','schedulingPending','scheduled')),
  comment_count INTEGER NOT NULL CHECK(typeof(comment_count)='integer' AND comment_count BETWEEN 1 AND ${ReviewDraftLimits.maxComments}),
  scheduling_attempt INTEGER NOT NULL CHECK(typeof(scheduling_attempt)='integer' AND scheduling_attempt BETWEEN 0 AND ${ReviewDraftLimits.maxSequence}),
  occurrence_id TEXT,
  run_id TEXT,
  CHECK((status IN ('prepared','deliveryPending') AND occurrence_id IS NULL AND run_id IS NULL AND scheduling_attempt=0) OR
        (status IN ('accepted','schedulingPending') AND occurrence_id IS NOT NULL AND run_id IS NULL) OR
        (status='scheduled' AND occurrence_id IS NOT NULL AND run_id IS NOT NULL)),
  CHECK(status NOT IN ('schedulingPending','scheduled') OR scheduling_attempt>0)
);
''';

final _schemaSql =
    '''
CREATE TABLE adele_diff_review_sessions (
  session_id TEXT PRIMARY KEY REFERENCES adele_product_sessions(id) ON DELETE CASCADE,
  next_sequence INTEGER NOT NULL CHECK(typeof(next_sequence)='integer' AND next_sequence BETWEEN 2 AND ${ReviewDraftLimits.maxSequence + 1}),
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND ${ReviewDraftLimits.maxVersion} AND revision>=next_sequence-1),
  comment_count INTEGER NOT NULL CHECK(typeof(comment_count)='integer' AND comment_count BETWEEN 0 AND ${ReviewDraftLimits.maxComments}),
  total_charge INTEGER NOT NULL CHECK(typeof(total_charge)='integer' AND total_charge BETWEEN 0 AND ${ReviewDraftLimits.maxSnapshotCharge})
);
CREATE TABLE adele_diff_review_comments (
  session_id TEXT NOT NULL REFERENCES adele_diff_review_sessions(session_id) ON DELETE CASCADE,
  comment_id TEXT NOT NULL CHECK(comment_id='comment-' || sequence),
  sequence INTEGER NOT NULL CHECK(typeof(sequence)='integer' AND sequence BETWEEN 1 AND ${ReviewDraftLimits.maxSequence}),
  version INTEGER NOT NULL CHECK(typeof(version)='integer' AND version BETWEEN 1 AND ${ReviewDraftLimits.maxVersion}),
  environment_id TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  layer TEXT NOT NULL CHECK(layer IN ('unstaged','staged','committed')),
  side TEXT NOT NULL CHECK(side IN ('oldSide','newSide')),
  start_line INTEGER NOT NULL CHECK(typeof(start_line)='integer' AND start_line BETWEEN 1 AND ${ReviewDraftLimits.maxLine}),
  end_line INTEGER NOT NULL CHECK(typeof(end_line)='integer' AND end_line BETWEEN start_line AND ${ReviewDraftLimits.maxLine} AND end_line-start_line<${ReviewDraftLimits.maxLineRange}),
  comparison_identity TEXT NOT NULL,
  source_excerpt TEXT NOT NULL,
  hunk_index INTEGER NOT NULL CHECK(typeof(hunk_index)='integer' AND hunk_index BETWEEN 0 AND ${ReviewDraftLimits.maxHunkIndex}),
  line_index INTEGER NOT NULL CHECK(typeof(line_index)='integer' AND line_index BETWEEN 0 AND ${ReviewDraftLimits.maxLineIndex}),
  text TEXT NOT NULL,
  charge INTEGER NOT NULL CHECK(typeof(charge)='integer' AND charge BETWEEN 1 AND ${ReviewDraftLimits.maxSnapshotCharge}),
  PRIMARY KEY (session_id,comment_id),
  UNIQUE (session_id,sequence)
);
''';
