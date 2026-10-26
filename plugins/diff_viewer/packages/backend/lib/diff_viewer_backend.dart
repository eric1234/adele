/// Diff-owned SQL behind the host's exact-generation Project storage grant.
library;

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

  Future<_StoredDraft> _load(String sessionId) async {
    _requireOpen();
    if (_schemaSession != sessionId) {
      _schemaSession = sessionId;
      _schemaFuture = null;
    }
    final Future<void> schema;
    try {
      schema = _schemaFuture ??= _storage.ensureSchemaForSession(sessionId, [
        _schemaSql,
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
          c.source_excerpt,c.hunk_index,c.line_index,c.text,c.charge
          FROM (SELECT :session AS session_id) requested
          LEFT JOIN adele_diff_review_sessions s ON s.session_id=requested.session_id
          LEFT JOIN adele_diff_review_comments c ON c.session_id=requested.session_id
          ORDER BY c.sequence LIMIT ${ReviewDraftLimits.maxComments + 1}''',
        {':session': sessionId},
        _access,
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
          ReviewDraftSnapshot(sessionId: sessionId, comments: const []),
          nextSequence: 1,
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
      final comments = <PendingReviewComment>[];
      var actualCharge = 0;
      for (final result in rows) {
        final row = result.values;
        for (final key in [
          'state_session',
          'next_sequence',
          'revision',
          'comment_count',
          'total_charge',
        ]) {
          if (row[key] != first[key]) {
            throw const FormatException('Inconsistent Session header.');
          }
        }
        if (row['comment_session'] == null) {
          if (rows.length != 1 ||
              count != 0 ||
              row.entries.any(
                (entry) =>
                    ![
                      'state_session',
                      'next_sequence',
                      'revision',
                      'comment_count',
                      'total_charge',
                    ].contains(entry.key) &&
                    entry.value != null,
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
        ReviewDraftSnapshot(sessionId: sessionId, comments: comments),
        nextSequence: next,
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
    required this.revision,
    required this.charge,
  });

  final ReviewDraftSnapshot snapshot;
  final int nextSequence;
  final int revision;
  final int charge;
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('Invalid stored integer.');
  }
  return value;
}

ReviewDraftFailure _failure(String code, String message) =>
    ReviewDraftFailure(code: code, message: message);

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
