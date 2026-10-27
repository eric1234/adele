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
    required List<PendingReviewComment> comments,
  }) : comments = List<PendingReviewComment>.unmodifiable(comments) {
    validateReviewDraftIdentity(sessionId, 'sessionId');
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
  final List<PendingReviewComment> comments;
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
}

/// `invalid_request` rejects invalid data; `stale_comment` requires a fresh
/// snapshot after a missing comment or version mismatch. `limit_exceeded`,
/// `corrupt_state`, `storage_unavailable`, and `backend_closed` remain explicit.
/// `outcome_uncertain` never establishes rollback: read a fresh snapshot rather
/// than replaying a mutation whose acknowledgement was lost.
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
