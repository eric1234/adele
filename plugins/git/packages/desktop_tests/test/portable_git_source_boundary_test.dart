@TestOn('linux')
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'independent A and semantic B/C preserve implementation boundaries',
    () async {
      final root = Directory.current.parent.parent.parent.parent;
      final a = await File(
        '${root.path}/app/test/fixtures/portable_git_environment.dart.txt',
      ).readAsString();
      final b = await File(
        '${root.path}/app/test/fixtures/portable_git_callable.dart.txt',
      ).readAsString();
      final c = await File(
        '${root.path}/app/test/fixtures/portable_git_frontend.dart.txt',
      ).readAsString();
      expect(a, contains('Process.start('));
      expect(a, isNot(contains('git_backend')));
      expect(a, isNot(contains('diff_viewer_contract')));
      expect(b, contains('GitPortableUnstagedSnapshotService('));
      expect(
        b,
        contains('GitPortableReviewApprovalService(processes: processes)'),
      );
      expect(b, contains('ReviewApprovalHandlerServiceDispatcher('));
      expect(b, contains("state.checkpoint('after:\$method')"));
      expect(b, contains('processes: processes,'));
      expect(b, contains('taskAnchor: taskAnchor,'));
      expect(b, contains("state.options['taskAnchor']"));
      expect(b, contains('GitPersistedChangeSetSourceService('));
      expect(b, contains('ProjectStorageServiceClient('));
      expect(b, contains('state.hostRequests.bindInfrastructure('));
      expect(b, isNot(contains('.enrollForEnvironment(')));
      expect(
        b.indexOf('GitTaskComparisonAnchor('),
        lessThan(b.indexOf('createDispatcher:')),
      );
      expect(b, contains('return await snapshots.snapshotUncommitted();'));
      expect(b, contains('return await snapshots.snapshotTaskChanges();'));
      expect(b, contains('AuthorizedEnvironmentBufferedProcessServiceClient('));
      for (final source in [b, c]) {
        expect(source, isNot(contains("import 'dart:io'")));
        expect(source, isNot(contains('Process.start')));
        expect(source, isNot(contains('package:adele_desktop')));
        expect(source, isNot(contains('package:plugin_runtime')));
        expect(source, isNot(contains('GitWorktree')));
      }
      expect(c, contains('ChangeSetSourceServiceClient('));
      expect(c, contains('ReviewApprovalHandlerServiceClient('));
      expect(c, contains('ReviewHunkSelection('));
      expect(c, contains('file.reviewRevision'));
      expect(c, contains('ReviewFileSelection('));
      expect(c, contains('file.fileReviewRevision'));
      expect(c, contains('typed.approveFile(file)'));
      expect(c, contains('typed.unapproveFile(file)'));
      expect(c, contains('ReviewLayerSelection('));
      expect(c, contains('expectedRevision: layer.layerReviewRevision!'));
      expect(c, contains('typed.approveAllUnstaged(layer)'));
      expect(c, contains('typed.unapproveAllStaged(layer)'));
      expect(
        b,
        contains(
          'Future<void> approveAllUnstaged(ReviewLayerSelection selection)',
        ),
      );
      expect(
        b,
        contains(
          'Future<void> unapproveAllStaged(ReviewLayerSelection selection)',
        ),
      );
      expect(
        c,
        contains('final UncommittedChangeSetSnapshot value = result[1];'),
      );
      expect(c, contains('renderFiles(value.staged.files)'));
      expect(c, contains('renderFiles(value.unstaged.files)'));
      expect(c, contains('renderFiles(value.conflicts)'));
      expect(c, contains('final TaskChangeSetSnapshot value = result[1];'));
      expect(c, contains('renderFiles(value.committed.files)'));
      expect(c, contains('renderFiles(value.uncommitted.staged.files)'));
      expect(c, contains('renderFiles(value.uncommitted.unstaged.files)'));
      expect(c, contains('renderFiles(value.uncommitted.conflicts)'));
      expect(c, isNot(contains('baselineCommit')));
      expect(c, isNot(contains('expectedBranchRef')));
      expect(c, isNot(contains('taskAnchor')));
      expect(c, isNot(contains('package:adele_environment')));
      expect(c, isNot(contains('package:adele_project_storage')));
      expect(c, isNot(contains('capturedIdentity')));
      expect(c, isNot(contains('EnvironmentBufferedProcessRequest')));
      expect(c, isNot(contains('runBufferedProcess')));
      expect(c, isNot(contains('package:git_backend')));
    },
  );
}
