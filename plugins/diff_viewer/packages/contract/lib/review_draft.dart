/// Diff-owned pending review comments, independent of review approval authority.
library;

import 'package:adele_contract/adele_contract.dart';

part 'review_draft.g.dart';

/// Public bounds use UTF-16 code units, not Unicode scalars or UTF-8 bytes.
abstract final class ReviewDraftLimits {
  static const maxComments = 128;
  static const maxTextLength = 8192;
  static const maxExcerptLength = 4096;
  static const maxPathLength = 4096;
  static const maxComparisonIdentityLength = 256;
  static const maxIdentityLength = 256;
  static const maxLine = 2147483647;
  static const maxLineRange = 1000;
  static const maxHunkIndex = 8191;
  static const maxLineIndex = 65535;
  static const maxVersion = 2147483647;
  static const maxSequence = 2147483647;
  static const maxSnapshotCharge = 512 * 1024;

  /// Fixed structural allowance, including generated JSON keys and numbers.
  static const snapshotOverhead = 256;
  static const commentOverhead = 512;
  static const stringCodeUnitCharge = 6;
}

enum ReviewComparisonLayer { unstaged, staged, committed }

enum ReviewComparisonSide { oldSide, newSide }

/// Attempted states survive lost replies; absence of evidence is not rollback.
enum ReviewSubmissionStatus {
  prepared,
  deliveryPending,
  accepted,
  schedulingPending,
  scheduled,
}

@AdeleValue('diff.reviewSubmissionSummary')
final class ReviewSubmissionSummary {
  ReviewSubmissionSummary({
    required this.submissionId,
    required this.status,
    required this.commentCount,
    required this.schedulingAttempt,
    required this.occurrenceId,
    required this.runId,
  }) {
    validateReviewDraftIdentity(submissionId, 'submissionId');
    if (commentCount < 1 || commentCount > ReviewDraftLimits.maxComments) {
      throw ArgumentError('Invalid prepared review count.');
    }
    if (occurrenceId != null) {
      validateReviewDraftIdentity(occurrenceId!, 'occurrenceId');
    }
    if (runId != null) validateReviewDraftIdentity(runId!, 'runId');
    final accepted =
        status == ReviewSubmissionStatus.accepted ||
        status == ReviewSubmissionStatus.schedulingPending ||
        status == ReviewSubmissionStatus.scheduled;
    if (accepted != (occurrenceId != null) ||
        (status == ReviewSubmissionStatus.scheduled) != (runId != null)) {
      throw ArgumentError('Invalid prepared review state.');
    }
    if (schedulingAttempt < 0 ||
        schedulingAttempt > ReviewDraftLimits.maxSequence ||
        (!accepted && schedulingAttempt != 0) ||
        ((status == ReviewSubmissionStatus.schedulingPending ||
                status == ReviewSubmissionStatus.scheduled) &&
            schedulingAttempt == 0)) {
      throw ArgumentError('Invalid scheduling attempt.');
    }
  }

  final String submissionId;
  final ReviewSubmissionStatus status;
  final int commentCount;
  final int schedulingAttempt;
  final String? occurrenceId;
  final String? runId;
}

/// Local transport envelope for the public SessionFeedback canonical codec.
/// The backend owns payload validation; consumers forward the exact string.
@AdeleValue('diff.preparedReviewSubmission')
final class PreparedReviewSubmission {
  PreparedReviewSubmission({
    required this.sessionId,
    required this.submissionId,
    required this.canonicalPayload,
    required this.status,
    required this.commentCount,
    required this.schedulingAttempt,
    required this.occurrenceId,
    required this.runId,
  }) {
    validateReviewDraftIdentity(sessionId, 'sessionId');
    ReviewSubmissionSummary(
      submissionId: submissionId,
      status: status,
      commentCount: commentCount,
      schedulingAttempt: schedulingAttempt,
      occurrenceId: occurrenceId,
      runId: runId,
    );
    if (canonicalPayload.isEmpty) {
      throw ArgumentError('Missing prepared review payload.');
    }
  }

  final String sessionId;
  final String submissionId;
  final String canonicalPayload;
  final ReviewSubmissionStatus status;
  final int commentCount;
  final int schedulingAttempt;
  final String? occurrenceId;
  final String? runId;
}

/// A confirmed preparation or a definite rejection before any handoff write.
/// Storage and uncertain mutation failures remain exceptions, never rejections.
@AdeleValue('diff.reviewPreparationResult')
final class ReviewPreparationResult {
  ReviewPreparationResult({
    required this.submission,
    required this.rejectionCode,
  }) {
    if ((submission == null) == (rejectionCode == null) ||
        (rejectionCode != null &&
            !const [
              'stale_draft',
              'empty_review',
              'submission_too_large',
              'review_conflict',
              'counter_exhausted',
            ].contains(rejectionCode))) {
      throw ArgumentError('Invalid review preparation result.');
    }
  }

  final PreparedReviewSubmission? submission;
  final String? rejectionCode;
}

/// Immutable captured source data, never approval or Environment authority.
/// Coordinates describe the original displayed comparison, not a live lookup.
@AdeleValue('diff.reviewCommentAnchor')
final class ReviewCommentAnchor {
  ReviewCommentAnchor({
    required this.environmentId,
    required this.relativePath,
    required this.layer,
    required this.side,
    required this.startLine,
    required this.endLine,
    required this.comparisonIdentity,
    required this.sourceExcerpt,
    required this.hunkIndex,
    required this.lineIndex,
  }) {
    validateReviewDraftIdentity(environmentId, 'environmentId');
    _validateReviewUnicode(relativePath, 'relativePath');
    if (relativePath.isEmpty ||
        relativePath.length > ReviewDraftLimits.maxPathLength ||
        relativePath.contains('\u0000') ||
        relativePath.contains('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(relativePath) ||
        relativePath
            .split('/')
            .any(
              (part) =>
                  part.isEmpty || part == '.' || part == '..' || part == '.git',
            )) {
      throw ArgumentError.value(relativePath, 'relativePath', 'Invalid path.');
    }
    if (comparisonIdentity.trim().isEmpty ||
        comparisonIdentity.length >
            ReviewDraftLimits.maxComparisonIdentityLength ||
        comparisonIdentity.codeUnits.any(
          (unit) => unit < 0x20 || unit > 0x7e,
        )) {
      throw ArgumentError.value(
        comparisonIdentity,
        'comparisonIdentity',
        'Invalid comparison identity.',
      );
    }
    _validateReviewUnicode(sourceExcerpt, 'sourceExcerpt');
    if (sourceExcerpt.length > ReviewDraftLimits.maxExcerptLength) {
      throw ArgumentError.value(
        sourceExcerpt,
        'sourceExcerpt',
        'Excerpt too long.',
      );
    }
    if (startLine < 1 ||
        endLine < startLine ||
        endLine > ReviewDraftLimits.maxLine ||
        endLine - startLine + 1 > ReviewDraftLimits.maxLineRange) {
      throw ArgumentError('Invalid review comment line range.');
    }
    if (hunkIndex < 0 || hunkIndex > ReviewDraftLimits.maxHunkIndex) {
      throw ArgumentError.value(hunkIndex, 'hunkIndex', 'Invalid hunk index.');
    }
    if (lineIndex < 0 || lineIndex > ReviewDraftLimits.maxLineIndex) {
      throw ArgumentError.value(lineIndex, 'lineIndex', 'Invalid line index.');
    }
  }

  final String environmentId;

  /// Canonical slash-separated relative path retained exactly, without trimming
  /// or normalization. No empty, dot, parent, or `.git` component, NUL, backslash,
  /// absolute path, or drive-qualified path is accepted.
  final String relativePath;
  final ReviewComparisonLayer layer;
  final ReviewComparisonSide side;

  /// Inclusive, positive line range on [side] of the captured comparison.
  final int startLine;
  final int endLine;

  /// Opaque nonblank printable ASCII source identity, not an approval revision.
  final String comparisonIdentity;

  /// Exact captured source, including Unicode, line endings, and whitespace.
  final String sourceExcerpt;

  /// Zero-based hunk and line coordinates in the captured display.
  final int hunkIndex;
  final int lineIndex;
}

@AdeleValue('diff.pendingReviewComment')
final class PendingReviewComment {
  PendingReviewComment({
    required this.id,
    required this.anchor,
    required this.text,
    required this.version,
    required this.sequence,
  }) {
    validateReviewDraftIdentity(id, 'id');
    validateReviewCommentText(text);
    validateReviewCommentVersion(version);
    if (sequence < 1 || sequence > ReviewDraftLimits.maxSequence) {
      throw ArgumentError.value(
        sequence,
        'sequence',
        'Invalid creation sequence.',
      );
    }
  }

  final String id;
  final ReviewCommentAnchor anchor;
  final String text;

  /// Positive optimistic concurrency version; an update never changes [anchor].
  final int version;

  /// Session-local monotonic creation order, retained across updates and deletes.
  /// Gaps are valid; deleted sequence values must not be reused.
  final int sequence;
}

@AdeleValue('diff.reviewDraftSnapshot')
final class ReviewDraftSnapshot {
  ReviewDraftSnapshot({
    required this.sessionId,
    required this.revision,
    required List<PendingReviewComment> comments,
    required this.currentReview,
  }) : comments = List<PendingReviewComment>.unmodifiable(comments) {
    validateReviewDraftIdentity(sessionId, 'sessionId');
    if (revision < 0 || revision > ReviewDraftLimits.maxVersion) {
      throw ArgumentError('Invalid authoritative draft revision.');
    }
    if (this.comments.length > ReviewDraftLimits.maxComments) {
      throw ArgumentError('Too many pending review comments.');
    }
    final ids = <String>{};
    var previousSequence = 0;
    for (final comment in this.comments) {
      if (!ids.add(comment.id)) {
        throw ArgumentError('Duplicate pending review comment ID.');
      }
      if (comment.sequence <= previousSequence) {
        throw ArgumentError('Review comments must be in creation order.');
      }
      previousSequence = comment.sequence;
    }
    if (reviewDraftSnapshotCharge(sessionId, this.comments) >
        ReviewDraftLimits.maxSnapshotCharge) {
      throw ArgumentError('Review draft snapshot exceeds its total charge.');
    }
  }

  final String sessionId;

  /// Authoritative SQL revision, never inferred from locally patched comments.
  final int revision;
  final List<PendingReviewComment> comments;
  final ReviewSubmissionSummary? currentReview;
}

/// Conservative size charge, not a second wire codec. Six bytes per UTF-16 code
/// unit bounds JSON escaping; fixed overhead bounds keys, enums, and numbers.
int reviewCommentCharge(PendingReviewComment comment) =>
    ReviewDraftLimits.commentOverhead +
    ReviewDraftLimits.stringCodeUnitCharge *
        (comment.id.length +
            comment.text.length +
            comment.anchor.environmentId.length +
            comment.anchor.relativePath.length +
            comment.anchor.comparisonIdentity.length +
            comment.anchor.sourceExcerpt.length +
            comment.anchor.layer.name.length +
            comment.anchor.side.name.length);

int reviewDraftSnapshotCharge(
  String sessionId,
  Iterable<PendingReviewComment> comments,
) =>
    ReviewDraftLimits.snapshotOverhead +
    ReviewDraftLimits.stringCodeUnitCharge * sessionId.length +
    comments.fold(
      0,
      (charge, comment) => charge + reviewCommentCharge(comment),
    );

/// Validates Session, Environment, and comment identities without normalizing.
void validateReviewDraftIdentity(String value, String name) {
  _validateReviewUnicode(value, name);
  if (value.isEmpty ||
      value.length > ReviewDraftLimits.maxIdentityLength ||
      value.trim() != value ||
      value.codeUnits.any(
        (unit) => unit < 0x20 || (unit >= 0x7f && unit <= 0x9f),
      )) {
    throw ArgumentError.value(value, name, 'Invalid review draft identity.');
  }
}

/// Validates exact text; accepted Unicode, CRLF and whitespace are not changed.
void validateReviewCommentText(String text) {
  _validateReviewUnicode(text, 'text');
  if (text.trim().isEmpty || text.length > ReviewDraftLimits.maxTextLength) {
    throw ArgumentError.value(text, 'text', 'Invalid review comment text.');
  }
}

void validateReviewCommentVersion(int version) {
  if (version < 1 || version > ReviewDraftLimits.maxVersion) {
    throw ArgumentError.value(version, 'version', 'Invalid comment version.');
  }
}

void _validateReviewUnicode(String value, String name) {
  if (value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    throw ArgumentError.value(value, name, 'Malformed Unicode.');
  }
}

/// Session-addressed draft storage, not a Git/Environment mutation capability.
@AdeleService('diff.reviewDraft')
abstract interface class ReviewDraftService {
  @AdeleMethod('snapshot')
  Future<ReviewDraftSnapshot> snapshot(String sessionId);

  @AdeleMethod('createComment')
  Future<PendingReviewComment> createComment(
    String sessionId,
    ReviewCommentAnchor anchor,
    String text,
  );

  @AdeleMethod('updateComment')
  Future<PendingReviewComment> updateComment(
    String sessionId,
    String commentId,
    int expectedVersion,
    String text,
  );

  @AdeleMethod('deleteComment')
  Future<void> deleteComment(
    String sessionId,
    String commentId,
    int expectedVersion,
  );

  /// Freezes every saved pending comment, not a caller-selected scope or subset.
  @AdeleMethod('prepareReview')
  Future<ReviewPreparationResult> prepareReview(
    String sessionId,
    int expectedRevision,
  );

  @AdeleMethod('readReview')
  Future<PreparedReviewSubmission?> readReview(String sessionId);

  /// One admission only. A repeated marker does not authorize another dispatch.
  @AdeleMethod('markDeliveryAttempted')
  Future<PreparedReviewSubmission> markDeliveryAttempted(
    String sessionId,
    String submissionId,
  );

  /// Records a confirmed public receipt and removes exact frozen versions.
  @AdeleMethod('confirmAcceptance')
  Future<PreparedReviewSubmission> confirmAcceptance(
    String sessionId,
    String submissionId,
    String receiptSessionId,
    String occurrenceId,
  );

  @AdeleMethod('markSchedulingAttempted')
  Future<PreparedReviewSubmission> markSchedulingAttempted(
    String sessionId,
    String submissionId,
    String occurrenceId,
  );

  @AdeleMethod('confirmRunScheduled')
  Future<PreparedReviewSubmission> confirmRunScheduled(
    String sessionId,
    String submissionId,
    String occurrenceId,
    int expectedAttempt,
    String runId,
  );

  /// Only positive host evidence of pre-start rejection permits this transition.
  /// A missing association, failed read or lost reply never establishes it.
  @AdeleMethod('confirmRunNotStarted')
  Future<PreparedReviewSubmission> confirmRunNotStarted(
    String sessionId,
    String submissionId,
    String occurrenceId,
    int expectedAttempt,
  );
}

/// `invalid_request` rejects invalid data; `stale_comment` requires a fresh
/// snapshot after a missing comment or version mismatch. `limit_exceeded`,
/// `corrupt_state`, `storage_unavailable`, and `backend_closed` remain explicit.
/// `outcome_uncertain` never establishes rollback: read a fresh snapshot rather
/// than replaying a mutation whose acknowledgement was lost.
/// `draft_frozen` rejects CRUD before confirmed acceptance. `review_conflict`
/// rejects mismatched receipt/Run or repeated attempt admission. Definite
/// preparation rejections use [ReviewPreparationResult], not thrown failures.
/// Handoffs require durable storage, never temporary success.
@AdeleFailure('diff.reviewDraftFailure')
final class ReviewDraftFailure implements Exception {
  const ReviewDraftFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ReviewDraftFailure($code): $message';
}
