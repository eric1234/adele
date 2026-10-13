/// Diff-owned change snapshots and explicit revision-bound review operations.
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
    required this.reviewRevision,
  }) : files = List<ChangedFile>.unmodifiable(files);

  final List<ChangedFile> files;

  /// Opaque provider revision for this exact reviewable layer, never authority.
  /// Null means review is unavailable, including committed history.
  final String? reviewRevision;
}

@AdeleValue('diff.changedFile')
final class ChangedFile {
  ChangedFile({
    required this.relativePath,
    required this.changeKind,
    required this.contentStatus,
    required this.detail,
    required this.reviewEligible,
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
  final List<DiffHunk> hunks;

  /// Provider evidence that this complete file can participate in review.
  /// Consumers must still require a layer revision and separate review access.
  final bool reviewEligible;
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

@AdeleValue('diff.reviewSelection')
final class ReviewSelection {
  const ReviewSelection({
    required this.expectedRevision,
    required this.granularity,
    required this.relativePath,
    required this.hunkIndex,
  });

  /// The unchanged revision of the displayed layer, not a caller-selected root.
  final String expectedRevision;

  /// hunk, file, or layer. Providers reject any other value before effects.
  final String granularity;

  /// Required for hunk/file; null for layer. Never an absolute path.
  final String? relativePath;

  /// Zero-based displayed hunk index for hunk; null for file/layer.
  final int? hunkIndex;
}

@AdeleValue('diff.reviewApprovalResult')
final class ReviewApprovalResult {
  const ReviewApprovalResult({required this.status});

  /// applied, stale, or ineligible. Unknown statuses must not imply success.
  final String status;
}

@AdeleService('diff.reviewApproval')
abstract interface class ReviewApprovalService {
  /// Approves exactly the selected unstaged change, conditional on its revision.
  /// Invalid combinations and unsupported selections produce no partial effects.
  @AdeleMethod('approve')
  Future<ReviewApprovalResult> approve(ReviewSelection selection);

  /// Removes approval from exactly the selected staged change without rewriting
  /// working content. Environment authority comes only from contextual admission.
  @AdeleMethod('unapprove')
  Future<ReviewApprovalResult> unapprove(ReviewSelection selection);
}

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
