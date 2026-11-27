@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../test/support/prepared_durable_git.dart';

void main() {
  final suite = PreparedDurableGit(Directory.current.parent);
  setUpAll(suite.prepare);

  for (final move in [false, true]) {
    test(
      'durable Git Task survives ${move ? 'whole-Project move' : 'same-directory restart'} with lazy restoration',
      () async {
        final container = await Directory.systemTemp.createTemp(
          'adele-durable-git-project-',
        );
        addTearDown(() => container.delete(recursive: true));
        final originalSource = Directory('${container.path}/project');
        await Directory('${originalSource.path}/lib').create(recursive: true);
        const baselineText = 'const answer = 42;\n';
        const stagedText = 'const answer = 43;\n';
        const dirtyText = 'const answer = 44;\n';
        const untrackedText = 'Retained untracked Task work.\n';
        await File(
          '${originalSource.path}/lib/example.dart',
        ).writeAsString(baselineText);
        await git(originalSource, ['init', '--initial-branch=main']);
        await git(originalSource, ['add', 'lib/example.dart']);
        await git(originalSource, ['commit', '-m', 'Fixture baseline']);
        final baseline = (await git(originalSource, [
          'rev-parse',
          'HEAD',
        ])).trim();

        final original = await suite.start(
          MonotonicProductIdSource(seed: 'durable-git'),
        );
        final project = await original.lifecycle.openProject(
          sourceLocation: originalSource.uri,
          provider: original.lifecycle.resolveProjectProvider(
            localDirectoryProviderId,
          ),
        );
        expect(original.store.project(project.id), same(project));
        expect(project.sourceLocation, originalSource.uri);
        expect(original.store.tasksFor(project.id), isEmpty);
        final created = await original.lifecycle.createTask(
          projectId: project.id,
          title: 'Durable Git Task with retained work',
        );
        expect(created.task.projectId, project.id);
        expect(created.environment.taskId, created.task.id);
        expect(created.environment.role, EnvironmentRole.primary);
        expect(created.environment.providerId, gitProviderId);
        final state = created.environment.providerState!;
        final relativePath = state['worktreeRelativePath']! as String;
        expect(relativePath, matches(r'^\.adele/worktrees/[^/]+$'));
        expect(state, {
          'schemaVersion': 2,
          'environmentId': created.environment.id.value,
          'sourceRelativePath': '',
          'worktreeRelativePath': relativePath,
          'branch': state['branch'],
        });
        final backing = original.lifecycle.existingDatabaseForProject(project)!;
        expect(backing.path, '${originalSource.path}/.adele/data.db');
        final anchor = gitAnchor(backing, created.environment.id);
        expect(anchor, {
          'environment_id': created.environment.id.value,
          'baseline_commit': baseline,
          'expected_branch_ref': 'refs/heads/${state['branch']}',
        });
        expect(backing.loadProductGraph().sessions, isEmpty);
        expect(original.store.sessionsForTask(created.task.id), isEmpty);
        final strategy = registerGitTestStrategy(original.extensions);
        final firstSession = original.lifecycle.createSession(
          taskId: created.task.id,
          strategyId: strategy,
        );
        final originalWorktree = Directory.fromUri(
          originalSource.uri.resolve(relativePath),
        );
        final initial = await original.lifecycle.environmentRuntime.materialize(
          created.environment.id,
        );
        expect(initial.environment, same(created.environment));
        expect(initial.provider, isA<GeneratedEnvironmentProvider>());
        expect(initial.validateBinding, returnsNormally);
        expect(
          (await git(originalWorktree, ['rev-parse', 'HEAD'])).trim(),
          baseline,
        );

        // Both branches advance independently; restore must not reset to baseline
        // or replace the retained Task checkout with the current source HEAD.
        final progress = File('${originalWorktree.path}/progress.txt');
        await progress.writeAsString('First Task commit.\n');
        await git(originalWorktree, ['add', 'progress.txt']);
        await git(originalWorktree, ['commit', '-m', 'Task progress']);
        await progress.writeAsString('Later Task commit.\n');
        await git(originalWorktree, ['add', 'progress.txt']);
        await git(originalWorktree, ['commit', '-m', 'Later Task progress']);
        final taskHead = (await git(originalWorktree, [
          'rev-parse',
          'HEAD',
        ])).trim();
        await git(originalSource, [
          'commit',
          '--allow-empty',
          '-m',
          'Source progress',
        ]);
        final sourceHead = (await git(originalSource, [
          'rev-parse',
          'HEAD',
        ])).trim();
        expect(taskHead, isNot(baseline));
        expect(sourceHead, isNot(baseline));
        expect(taskHead, isNot(sourceHead));
        final laterSession = original.lifecycle.createSession(
          taskId: created.task.id,
          strategyId: strategy,
        );
        expect(laterSession.id, isNot(firstSession.id));
        expect(
          original.lifecycle.databaseForSession(laterSession.id),
          same(backing),
        );
        expect(_anchorForSession(backing, laterSession.id), anchor);
        final beforeRestart = await invokeChangeSet(
          original,
          laterSession,
          (client) => client.snapshotTaskChanges(),
        );
        _expectOriginalBaselineChanges(beforeRestart);
        expect(gitAnchor(backing, created.environment.id), anchor);
        // The real Git schema rejects identical and conflicting insertions.
        final storage = ProjectStorageHost(
          lifecycle: original.lifecycle,
          owner: PluginId(gitPluginId),
          validateAccess: () {},
        );
        for (final duplicate in [baseline, sourceHead]) {
          await expectLater(
            storage.transactionForEnvironment(created.environment.id.value, [
              RelationalStatement(
                sql: '''INSERT INTO adele_git_task_anchors
                (environment_id, baseline_commit, expected_branch_ref)
                VALUES (:environment, :baseline, :branch)''',
                parameters: {
                  ':environment': created.environment.id.value,
                  ':baseline': duplicate,
                  ':branch': anchor['expected_branch_ref'],
                },
                expectedRows: 1,
              ),
            ], ProjectStorageAccessMode.durable),
            throwsA(isA<SqliteException>()),
          );
          expect(gitAnchor(backing, created.environment.id), anchor);
        }
        final initialRead = await initial.provider.readFile(
          created.environment.id,
          'lib/example.dart',
        );
        expect(initialRead.text, baselineText);
        final staged = await initial.provider.replaceExistingTextFile(
          created.environment.id,
          'lib/example.dart',
          stagedText,
          initialRead.revision,
        );
        await git(originalWorktree, ['add', 'lib/example.dart']);
        await initial.provider.replaceExistingTextFile(
          created.environment.id,
          'lib/example.dart',
          dirtyText,
          staged.revision,
        );
        await initial.provider.createTextFile(
          created.environment.id,
          'scratch.txt',
          untrackedText,
        );
        final status = await git(originalWorktree, [
          'status',
          '--porcelain=v1',
          '-z',
        ]);
        expect(
          status.split('\u0000'),
          containsAll(['MM lib/example.dart', '?? scratch.txt']),
        );
        final diff = await git(originalWorktree, ['diff', '--binary', 'HEAD']);
        final stagedDiff = await git(originalWorktree, [
          'diff',
          '--cached',
          '--binary',
        ]);
        final branches = await git(originalSource, [
          'for-each-ref',
          '--format=%(refname) %(objectname)',
          'refs/heads',
        ]);
        expect(branches.trim().split('\n'), hasLength(2));
        final inventory = await git(originalSource, [
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]);
        expect(
          inventory
              .split('\u0000')
              .where((line) => line.startsWith('worktree ')),
          hasLength(2),
        );
        final gitDirectory = (await git(originalWorktree, [
          'rev-parse',
          '--path-format=absolute',
          '--git-dir',
        ])).trim();
        final markerBytes = await File(
          '${originalWorktree.path}/.git',
        ).readAsBytes();
        expect(utf8.decode(markerBytes), 'gitdir: $gitDirectory\n');

        // Replace both actual AOT generations while retaining this open Project.
        await original.plugins.close();
        final replacementBackends = ApplicationPluginBootstrap(
          original.registry,
          original.extensions,
          createInfrastructureServices: (connection) =>
              projectStorageServices(original.lifecycle, connection),
        );
        addTearDown(replacementBackends.close);
        await suite.startBackends(replacementBackends);
        final rematerialized = await original.lifecycle.environmentRuntime
            .materialize(created.environment.id);
        expect(rematerialized.provider, isNot(same(initial.provider)));
        expect(rematerialized.environment.providerState, state);
        expect(gitAnchor(backing, created.environment.id), anchor);
        _expectOriginalBaselineChanges(
          await invokeChangeSet(
            original,
            laterSession,
            (client) => client.snapshotTaskChanges(),
            backends: replacementBackends,
          ),
        );
        expect(gitAnchor(backing, created.environment.id), anchor);
        await replacementBackends.close();
        await original.close();
        expect(original.plugins.state, ApplicationPluginState.closed);
        expect(original.plugins.host!.isClosed, isTrue);
        for (final backend in original.plugins.backends) {
          expect(backend.connection!.isClosed, isTrue);
        }
        expect(initial.validateBinding, throwsA(isA<ProviderUnavailable>()));
        final database = File('${originalSource.path}/.adele/data.db');
        expect(await database.exists(), isTrue);
        expect(
          String.fromCharCodes((await database.readAsBytes()).take(16)),
          'SQLite format 3\u0000',
        );

        final source = move
            ? await originalSource.rename('${container.path}/moved project')
            : originalSource;
        final worktree = Directory.fromUri(source.uri.resolve(relativePath));
        expect(await Directory('${source.path}/.git').exists(), isTrue);
        expect(await File('${source.path}/.adele/data.db').exists(), isTrue);
        expect(await worktree.exists(), isTrue);
        if (move) {
          expect(await originalSource.exists(), isFalse);
          expect(await originalWorktree.exists(), isFalse);
        }
        final marker = File('${worktree.path}/.git');
        expect(await marker.readAsBytes(), markerBytes);
        final beforeOpenInventory = await git(source, [
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]);
        expect(
          beforeOpenInventory.split('\u0000'),
          contains('worktree ${originalWorktree.path}'),
        );
        if (move) {
          expect(
            beforeOpenInventory.split('\u0000'),
            isNot(contains('worktree ${worktree.path}')),
          );
        }

        final ids = NoAllocationIds();
        final fresh = await suite.start(ids);
        expect(fresh.store, isNot(same(original.store)));
        expect(fresh.registry, isNot(same(original.registry)));
        expect(fresh.plugins.host, isNot(same(original.plugins.host)));
        for (final backend in fresh.plugins.backends) {
          expect(
            backend.connection,
            isNot(
              same(
                original.plugins.backends
                    .singleWhere(
                      (old) =>
                          old.installation.metadata.id ==
                          backend.installation.metadata.id,
                    )
                    .connection,
              ),
            ),
          );
        }
        expect(fresh.store.project(project.id), isNull);
        expect(fresh.store.tasksFor(project.id), isEmpty);
        expect(fresh.store.task(created.task.id), isNull);
        expect(fresh.store.environment(created.environment.id), isNull);
        expect(
          fresh.lifecycle.environmentRuntime.currentMaterialization(
            created.environment.id,
          ),
          isNull,
        );

        final reopened = await fresh.lifecycle.openProject(
          sourceLocation: source.uri,
          provider: fresh.lifecycle.resolveProjectProvider(
            localDirectoryProviderId,
          ),
        );
        expect(reopened, isNot(same(project)));
        expect(reopened.id, project.id);
        expect(reopened.sourceLocation, source.uri);
        expect(fresh.store.project(project.id), same(reopened));
        final task = fresh.store.tasksFor(reopened.id).single;
        expect(task, isNot(same(created.task)));
        expect(task.id, created.task.id);
        expect(task.title, created.task.title);
        expect(task.projectId, reopened.id);
        expect(fresh.store.task(task.id), same(task));
        final environment = fresh.store.environment(created.environment.id)!;
        expect(environment, isNot(same(created.environment)));
        expect(environment.id, created.environment.id);
        expect(environment.taskId, task.id);
        expect(environment.role, created.environment.role);
        expect(environment.providerId, created.environment.providerId);
        expect(environment.providerState, state);
        expect(fresh.store.primaryEnvironmentFor(task.id), same(environment));
        final reopenedBacking = fresh.lifecycle.existingDatabaseForProject(
          reopened,
        )!;
        expect(gitAnchor(reopenedBacking, environment.id), anchor);
        final reopenedSession = fresh.store.session(laterSession.id)!;
        expect(reopenedSession, isNot(same(laterSession)));
        expect(_anchorForSession(reopenedBacking, reopenedSession.id), anchor);
        expect(
          fresh.store.sessionsForTask(task.id).map((session) => session.id),
          [firstSession.id, laterSession.id],
        );
        expect(
          fresh.registry.providersFor(environmentProviderCapability).single.id,
          environment.providerId,
        );
        expect(
          fresh.lifecycle.environmentRuntime.currentMaterialization(
            environment.id,
          ),
          isNull,
        );
        expect(ids.calls, 0);
        // Opening loads SQLite only, even with Git registered and stale absolute
        // metadata after a move. Repair belongs to explicit materialization.
        expect(await marker.readAsBytes(), markerBytes);
        expect(
          await git(source, ['worktree', 'list', '--porcelain', '-z']),
          beforeOpenInventory,
        );

        final restored = await fresh.lifecycle.environmentRuntime.materialize(
          environment.id,
        );
        expect(
          restored,
          same(
            fresh.lifecycle.environmentRuntime.currentMaterialization(
              environment.id,
            ),
          ),
        );
        expect(restored.provider, isA<GeneratedEnvironmentProvider>());
        expect(restored.provider, isNot(same(initial.provider)));
        expect(
          restored.providerDescriptor,
          isNot(same(initial.providerDescriptor)),
        );
        expect(restored.providerDescriptor.id, environment.providerId);
        expect(restored.validateBinding, returnsNormally);
        expect(restored.environment.id, environment.id);
        expect(restored.environment.taskId, task.id);
        expect(restored.environment.role, environment.role);
        expect(restored.environment.providerId, environment.providerId);
        expect(restored.environment.providerState, state);
        expect(
          fresh.store.environment(environment.id),
          same(restored.environment),
        );
        expect(
          fresh.store.primaryEnvironmentFor(task.id),
          same(restored.environment),
        );
        expect(ids.calls, 0);

        final dirtyRead = await restored.provider.readFile(
          environment.id,
          'lib/example.dart',
        );
        expect(dirtyRead.text, dirtyText);
        expect(
          (await restored.provider.readFile(
            environment.id,
            'scratch.txt',
          )).text,
          untrackedText,
        );
        expect(await git(worktree, ['status', '--porcelain=v1', '-z']), status);
        expect(await git(worktree, ['diff', '--binary', 'HEAD']), diff);
        expect(
          await git(worktree, ['diff', '--cached', '--binary']),
          stagedDiff,
        );
        expect((await git(worktree, ['rev-parse', 'HEAD'])).trim(), taskHead);
        expect((await git(source, ['rev-parse', 'HEAD'])).trim(), sourceHead);
        expect(
          (await git(worktree, [
            'rev-parse',
            '--verify',
            '$baseline^{commit}',
          ])).trim(),
          baseline,
        );
        expect(
          (await git(worktree, ['symbolic-ref', 'HEAD'])).trim(),
          'refs/heads/${state['branch']}',
        );
        expect(
          (await git(worktree, ['rev-parse', '--show-toplevel'])).trim(),
          worktree.path,
        );
        expect(
          (await git(worktree, [
            'rev-parse',
            '--path-format=absolute',
            '--git-dir',
          ])).trim(),
          gitDirectory.replaceAll(originalSource.path, source.path),
        );
        expect(
          await marker.readAsBytes(),
          move ? isNot(equals(markerBytes)) : equals(markerBytes),
        );
        expect(
          await git(source, [
            'for-each-ref',
            '--format=%(refname) %(objectname)',
            'refs/heads',
          ]),
          branches,
        );
        expect(
          await git(source, ['worktree', 'list', '--porcelain', '-z']),
          inventory.replaceAll(originalSource.path, source.path),
        );

        const resumedText = 'const answer = 45;\n';
        final replacement = await restored.provider.replaceExistingTextFile(
          environment.id,
          'lib/example.dart',
          resumedText,
          dirtyRead.revision,
        );
        final resumedRead = await restored.provider.readFile(
          environment.id,
          'lib/example.dart',
        );
        expect(resumedRead.text, resumedText);
        expect(resumedRead.revision, replacement.revision);
        expect(
          await File('${worktree.path}/lib/example.dart').readAsString(),
          resumedText,
        );
        expect(
          await File('${worktree.path}/scratch.txt').readAsString(),
          untrackedText,
        );
        expect(
          await File('${source.path}/lib/example.dart').readAsString(),
          baselineText,
        );
        expect(
          await git(worktree, ['diff', '--cached', '--binary']),
          stagedDiff,
        );
        expect(
          await fresh.lifecycle.environmentRuntime.materialize(environment.id),
          same(restored),
        );
        expect(ids.calls, 0);
        _expectOriginalBaselineChanges(
          await invokeChangeSet(
            fresh,
            reopenedSession,
            (client) => client.snapshotTaskChanges(),
          ),
        );
        expect(gitAnchor(reopenedBacking, environment.id), anchor);
        await fresh.close();
        expect(
          await git(source, ['worktree', 'list', '--porcelain', '-z']),
          inventory.replaceAll(originalSource.path, source.path),
        );
        expect(
          await git(source, [
            'for-each-ref',
            '--format=%(refname) %(objectname)',
            'refs/heads',
          ]),
          branches,
        );
        if (move) expect(await originalSource.exists(), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Map<String, Object?> _anchorForSession(
  ProjectDatabase database,
  SessionId session,
) => database
    .queryPluginRows(
      '''SELECT g.* FROM adele_product_session_environment_authority a
      JOIN adele_git_task_anchors g ON g.environment_id=a.environment_id
      WHERE a.session_id=:session''',
      {':session': session.value},
    )
    .single
    .values;

void _expectOriginalBaselineChanges(TaskChangeSetSnapshot snapshot) {
  expect(snapshot.committed.files.single.relativePath, 'progress.txt');
  expect(snapshot.committed.files.single.changeKind, 'added');
  expect(
    snapshot.committed.files.single.hunks.single.lines.single.text,
    'Later Task commit.',
  );
}
