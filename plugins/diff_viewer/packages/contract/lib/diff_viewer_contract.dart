/// Diff-owned, bounded read-only Unstaged change snapshots.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'diff_viewer_contract.g.dart';

final capabilities.CapabilityKey changeSetSourceCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('adele.diff.change-set-source'),
      majorVersion: 1,
    );

@AdeleValue('diff.changeSetSnapshot')
final class ChangeSetSnapshot {
  ChangeSetSnapshot({required List<ChangedFile> files})
    : files = List<ChangedFile>.unmodifiable(files);

  final List<ChangedFile> files;
}

@AdeleValue('diff.changedFile')
final class ChangedFile {
  ChangedFile({
    required this.relativePath,
    required this.changeKind,
    required this.contentStatus,
    required this.detail,
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
