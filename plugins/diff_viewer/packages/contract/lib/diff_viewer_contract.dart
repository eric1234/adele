/// Diff-owned, bounded change snapshots and revision-bound review operations.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'diff_viewer_contract.g.dart';

final capabilities.CapabilityKey changeSetSourceCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('adele.diff.change-set-source'),
      majorVersion: 1,
    );

final capabilities.CapabilityKey reviewApprovalCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('adele.diff.review-approval'),
      majorVersion: 1,
    );

@AdeleValue('diff.taskChangeSetSnapshot')
final class TaskChangeSetSnapshot {
  const TaskChangeSetSnapshot({
    required this.committed,
    required this.uncommitted,
  });

  final ChangeSetSnapshot committed;
  final UncommittedChangeSetSnapshot uncommitted;
}

@AdeleValue('diff.uncommittedChangeSetSnapshot')
final class UncommittedChangeSetSnapshot {
  UncommittedChangeSetSnapshot({
    required this.staged,
    required this.unstaged,
    required List<ChangedFile> conflicts,
  }) : conflicts = List<ChangedFile>.unmodifiable(conflicts);

  final ChangeSetSnapshot staged;
  final ChangeSetSnapshot unstaged;
  final List<ChangedFile> conflicts;
}

@AdeleValue('diff.changeSetSnapshot')
final class ChangeSetSnapshot {
  ChangeSetSnapshot({
    required List<ChangedFile> files,
    required this.layerReviewRevision,
  }) : files = List<ChangedFile>.unmodifiable(files);

  final List<ChangedFile> files;

  /// Opaque provider revision for the complete displayed layer, not authority.
  /// Null means whole-layer review is unavailable, independently of file review.
  final String? layerReviewRevision;
}

@AdeleValue('diff.changedFile')
final class ChangedFile {
  ChangedFile({
    required this.relativePath,
    required this.changeKind,
    required this.contentStatus,
    required this.detail,
    required this.reviewRevision,
    required this.fileReviewRevision,
    required List<DiffHunk> hunks,
  }) : hunks = List<DiffHunk>.unmodifiable(hunks);

  final String relativePath;

  /// added, modified, deleted, conflicted, typeChanged, or unsupported.
  /// unsupported can mean change state was not safely inspectable, not a
  /// confirmed modification. Such entries remain visible with an explicit detail.
  final String changeKind;

  /// text, binary, unsupported, oversized, or conflicted.
  final String contentStatus;
  final String? detail;

  /// Opaque provider revision for selecting a hunk from this exact file snapshot.
  /// Null means this entry has no supported individual hunk action.
  final String? reviewRevision;

  /// Opaque provider revision for the complete displayed file change.
  /// Null means complete-file review is unavailable, independently of hunk review.
  final String? fileReviewRevision;
  final List<DiffHunk> hunks;
}

@AdeleValue('diff.hunk')
final class DiffHunk {
  DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required List<DiffLine> lines,
  }) : lines = List<DiffLine>.unmodifiable(lines);

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<DiffLine> lines;
}

@AdeleValue('diff.line')
final class DiffLine {
  const DiffLine({
    required this.kind,
    required this.text,
    required this.noNewline,
  });

  /// context, addition, or deletion.
  final String kind;
  final String text;
  final bool noNewline;
}

/// Identifies one displayed hunk without carrying patch data or authority.
@AdeleValue('diff.reviewHunkSelection')
final class ReviewHunkSelection {
  ReviewHunkSelection({
    required this.relativePath,
    required this.hunkIndex,
    required this.expectedRevision,
  }) {
    _validateReviewSelection(relativePath, expectedRevision);
    if (hunkIndex < 0 || hunkIndex > 8191) {
      throw ArgumentError.value(hunkIndex, 'hunkIndex', 'Invalid hunk index.');
    }
  }

  /// Slash-separated relative path, at most 4096 UTF-16 code units, with no
  /// empty, '.', '..', or '.git' components and no NUL. Providers may reject
  /// additional unsupported names, including tabs or newlines.
  final String relativePath;

  /// Zero-based index in the selected file's hunks, from 0 through 8191.
  final int hunkIndex;

  /// Nonempty opaque revision, at most 256 printable ASCII characters.
  final String expectedRevision;
}

/// Identifies a complete displayed file change, never patch data or authority.
@AdeleValue('diff.reviewFileSelection')
final class ReviewFileSelection {
  ReviewFileSelection({
    required this.relativePath,
    required this.expectedRevision,
  }) {
    _validateReviewSelection(relativePath, expectedRevision);
  }

  /// Same bounded relative path rules as an individual hunk selection.
  final String relativePath;

  /// The provider's complete-file revision, not an individual hunk revision.
  final String expectedRevision;
}

/// Selects the complete displayed layer without paths, actions, or authority.
@AdeleValue('diff.reviewLayerSelection')
final class ReviewLayerSelection {
  ReviewLayerSelection({required this.expectedRevision}) {
    _validateReviewRevision(expectedRevision);
  }

  /// Nonempty opaque layer revision, at most 256 printable ASCII characters.
  final String expectedRevision;
}

void _validateReviewSelection(String relativePath, String expectedRevision) {
  if (relativePath.isEmpty ||
      relativePath.length > 4096 ||
      relativePath.contains('\u0000') ||
      relativePath
          .split('/')
          .any(
            (part) =>
                part.isEmpty || part == '.' || part == '..' || part == '.git',
          )) {
    throw ArgumentError.value(relativePath, 'relativePath', 'Invalid path.');
  }
  _validateReviewRevision(expectedRevision);
}

void _validateReviewRevision(String expectedRevision) {
  if (expectedRevision.isEmpty ||
      expectedRevision.length > 256 ||
      expectedRevision.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    throw ArgumentError.value(
      expectedRevision,
      'expectedRevision',
      'Invalid revision.',
    );
  }
}

@AdeleService('diff.changeSetSource')
abstract interface class ChangeSetSourceService {
  /// Captured Environment authority is supplied by the host, never by arguments.
  @AdeleMethod('snapshotUnstaged')
  Future<ChangeSetSnapshot> snapshotUnstaged();

  /// Separate staged and unstaged layers, not a net working-tree diff.
  @AdeleMethod('snapshotUncommitted')
  Future<UncommittedChangeSetSnapshot> snapshotUncommitted();

  /// Committed Task/branch changes and the separate uncommitted layers.
  @AdeleMethod('snapshotTaskChanges')
  Future<TaskChangeSetSnapshot> snapshotTaskChanges();
}

/// Review mutation is a separate capability from read-only change inspection.
/// The host supplies captured Environment authority, never request arguments.
@AdeleService('diff.reviewApprovalHandler')
abstract interface class ReviewApprovalHandlerService {
  @AdeleMethod('approveHunk')
  Future<void> approveHunk(ReviewHunkSelection selection);

  @AdeleMethod('unapproveHunk')
  Future<void> unapproveHunk(ReviewHunkSelection selection);

  @AdeleMethod('approveFile')
  Future<void> approveFile(ReviewFileSelection selection);

  @AdeleMethod('unapproveFile')
  Future<void> unapproveFile(ReviewFileSelection selection);

  /// Approves the complete provider-certified Unstaged layer in one operation.
  @AdeleMethod('approveAllUnstaged')
  Future<void> approveAllUnstaged(ReviewLayerSelection selection);

  /// Unapproves the complete provider-certified Staged layer in one operation.
  @AdeleMethod('unapproveAllStaged')
  Future<void> unapproveAllStaged(ReviewLayerSelection selection);
}

@AdeleFailure('diff.changeSetFailure')
final class ChangeSetFailure implements Exception {
  const ChangeSetFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ChangeSetFailure($code): $message';
}

/// Stable codes before any mutation: `invalid_selection` (invalid bounds or
/// fields), `stale_selection` (revision changed), `unsupported_target` (target
/// cannot be reviewed), `hunk_unavailable` (selected hunk is absent),
/// `inspection_failed` (preflight inspection failed), and `operation_timeout`
/// (deadline expired before mutation).
///
/// `mutation_failed` means a nonzero mutation exit with a verified unchanged index.
/// `outcome_uncertain` means a write was attempted but its outcome is unconfirmed;
/// a fresh snapshot is required before another selection, not a blind retry.
@AdeleFailure('diff.reviewApprovalFailure')
final class ReviewApprovalFailure implements Exception {
  const ReviewApprovalFailure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ReviewApprovalFailure($code): $message';
}
