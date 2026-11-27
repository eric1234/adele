@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../../app/test/support/prepared_durable_git.dart';

void main() {
  final suite = PreparedDurableGit(
    Directory.current.parent.parent.parent.parent,
  );
  setUpAll(suite.prepare);

  for (final failure in [
    'missing anchor',
    'wrong branch',
    'unavailable commit',
  ]) {
    test('stock Task comparison fails closed for $failure', () async {
      final source = await createGitRepository('adele-git-anchor-failure-');
      final original = await suite.start(
        MonotonicProductIdSource(seed: 'anchor'),
      );
      final project = await original.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: original.lifecycle.resolveProjectProvider(
          localDirectoryProviderId,
        ),
      );
      final created = await original.lifecycle.createTask(
        projectId: project.id,
        title: 'Retained anchor failure',
      );
      final backing = original.lifecycle.existingDatabaseForProject(project)!;
      final anchor = gitAnchor(backing, created.environment.id);
      final baseline = anchor['baseline_commit']! as String;
      final worktree = Directory.fromUri(
        source.uri.resolve(
          created.environment.providerState!['worktreeRelativePath']! as String,
        ),
      );
      await File(
        '${worktree.path}/progress.txt',
      ).writeAsString('Task progress.\n');
      await git(worktree, ['add', 'progress.txt']);
      await git(worktree, ['commit', '-m', 'Later Task commit']);
      await git(source, [
        'commit',
        '--allow-empty',
        '-m',
        'Later source commit',
      ]);
      final session = original.lifecycle.createSession(
        taskId: created.task.id,
        strategyId: registerGitTestStrategy(original.extensions),
      );
      if (failure == 'missing anchor') {
        backing.executePluginTransaction([
          RelationalStatement(
            sql: 'DELETE FROM adele_git_task_anchors WHERE environment_id=:id',
            parameters: {':id': created.environment.id.value},
            expectedRows: 1,
          ),
        ]);
      }
      await original.close();
      final reopened = await suite.start(NoAllocationIds());
      final reopenedProject = await reopened.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: reopened.lifecycle.resolveProjectProvider(
          localDirectoryProviderId,
        ),
      );
      final restored = await reopened.lifecycle.environmentRuntime.materialize(
        created.environment.id,
      );
      expect(
        restored.environment.providerState,
        created.environment.providerState,
      );
      expect(
        (await restored.provider.readFile(
          created.environment.id,
          'progress.txt',
        )).text,
        'Task progress.\n',
      );
      final reopenedBacking = reopened.lifecycle.existingDatabaseForProject(
        reopenedProject,
      )!;
      final retainedSession = reopened.store.session(session.id)!;
      if (failure == 'wrong branch') {
        await git(worktree, ['switch', '-c', 'unexpected-task-branch']);
      } else if (failure == 'unavailable commit') {
        // Remove the exact originally stored loose object, not a guessed HEAD.
        final object = File(
          '${source.path}/.git/objects/${baseline.substring(0, 2)}/${baseline.substring(2)}',
        );
        expect(await object.exists(), isTrue);
        await object.delete();
      }
      final unstaged = await invokeChangeSet(
        reopened,
        retainedSession,
        (client) => client.snapshotUnstaged(),
      );
      expect(unstaged.files, isEmpty);
      final uncommitted = await invokeChangeSet(
        reopened,
        retainedSession,
        (client) => client.snapshotUncommitted(),
      );
      expect(uncommitted.staged.files, isEmpty);
      expect(uncommitted.unstaged.files, isEmpty);
      await expectLater(
        invokeChangeSet(
          reopened,
          retainedSession,
          (client) => client.snapshotTaskChanges(),
        ),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            failure == 'wrong branch'
                ? 'unexpected_branch'
                : 'baseline_unavailable',
          ),
        ),
      );
      expect(
        reopenedBacking
            .queryPluginRows('SELECT * FROM adele_git_task_anchors', {})
            .map((row) => row.values),
        failure == 'missing anchor' ? isEmpty : equals([anchor]),
      );
      expect(
        reopened.store.environment(created.environment.id)!.providerState,
        isNot(contains('baselineCommit')),
      );
    });
  }
}
