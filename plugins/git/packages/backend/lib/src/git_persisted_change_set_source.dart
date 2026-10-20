import 'dart:async';

import 'package:adele_environment/adele_environment.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

import 'git_portable_unstaged_snapshot.dart';
import 'git_task_anchor_store.dart';

/// Portable Diff adapter; neither SQL nor product identity enters Git comparison.
/// Construct per invocation using its process grant and the backend generation's
/// infrastructure-backed store. Used by the stock ChangeSetSource dispatcher.
final class GitPersistedChangeSetSourceService
    implements ChangeSetSourceService {
  GitPersistedChangeSetSourceService({
    required this.processes,
    required this.anchors,
    this.limits = const GitPortableUnstagedLimits(),
  }) : _plain = GitPortableUnstagedSnapshotService(
         processes: processes,
         limits: limits,
       );

  final AuthorizedEnvironmentBufferedProcessService processes;
  final GitTaskAnchorStore anchors;
  final GitPortableUnstagedLimits limits;
  final GitPortableUnstagedSnapshotService _plain;

  @override
  Future<ChangeSetSnapshot> snapshotUnstaged() => _plain.snapshotUnstaged();

  @override
  Future<UncommittedChangeSetSnapshot> snapshotUncommitted() =>
      _plain.snapshotUncommitted();

  @override
  Future<TaskChangeSetSnapshot> snapshotTaskChanges() async {
    // Include identity, schema, SQL and final validation in the same deadline.
    final bounded = _TaskProcesses(processes, limits.operationTimeout);
    Future<TaskChangeSetSnapshot> snapshot() async {
      final identity = await bounded.capturedIdentity();
      final anchor = await anchors.read(
        identity,
        checkActive: bounded.checkOpen,
      );
      bounded.checkOpen();
      final result = await GitPortableUnstagedSnapshotService(
        processes: bounded,
        limits: limits,
        taskAnchor: anchor,
      ).snapshotTaskChanges();
      bounded.checkOpen();
      final retained = await anchors.read(
        identity,
        checkActive: bounded.checkOpen,
      );
      bounded.checkOpen();
      if (retained.baselineCommit != anchor.baselineCommit ||
          retained.expectedBranchRef != anchor.expectedBranchRef) {
        throw ChangeSetFailure(
          code: 'baseline_changed',
          message: 'The retained Git baseline changed during the snapshot.',
          details: const {},
        );
      }
      final current = await bounded.capturedIdentity();
      if (current.sessionId != identity.sessionId ||
          current.environmentId != identity.environmentId) {
        throw ChangeSetFailure(
          code: 'baseline_association_mismatch',
          message: 'The captured Environment identity changed.',
          details: const {},
        );
      }
      return result;
    }

    try {
      return await snapshot().timeout(limits.operationTimeout);
    } on TimeoutException {
      throw _timeout();
    } on EnvironmentFailure catch (error) {
      throw ChangeSetFailure(
        code: 'environment_process_failed',
        message: 'The selected Environment could not complete a Task snapshot.',
        details: {'environmentCode': error.code},
      );
    } finally {
      // A late SQL response or unary process cannot start more work or publish.
      bounded.closed = true;
    }
  }
}

final class _TaskProcesses
    implements AuthorizedEnvironmentBufferedProcessService {
  _TaskProcesses(this.delegate, this.timeout);

  final AuthorizedEnvironmentBufferedProcessService delegate;
  final Duration timeout;
  final Stopwatch watch = Stopwatch()..start();
  bool closed = false;

  void checkOpen() {
    if (closed || watch.elapsed >= timeout) throw _timeout();
  }

  @override
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async {
    checkOpen();
    final result = await delegate.capturedIdentity();
    checkOpen();
    return result;
  }

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    checkOpen();
    final result = await delegate.runBufferedProcess(request);
    checkOpen();
    return result;
  }
}

ChangeSetFailure _timeout() => ChangeSetFailure(
  code: 'operation_timeout',
  message: 'The change snapshot exceeded its deadline.',
  details: const {},
);
