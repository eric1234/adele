@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

const _gitPluginId = 'dev.adele.plugin.git';
const _projectPluginId = 'dev.adele.plugin.local-directory-project';
final _gitProviderId = ProviderId('dev.adele.environment.git-worktree');
final _projectProviderId = ProviderId('dev.adele.project.local-directory');

void main() {
  late Directory installations;
  late File hostArtifact;
  late String dartaotruntime;

  setUpAll(() async {
    final repository = Directory.current.parent;
    final artifacts = await Directory.systemTemp.createTemp(
      'adele-durable-git-backends-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    installations = await Directory('${artifacts.path}/installed').create();
    hostArtifact = File('${artifacts.path}/host.aot');
    final dart = _dartExecutable();
    dartaotruntime = File.fromUri(
      File(dart).parent.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    // Compile once, but start a fresh shared host and both backends per runtime.
    await compileAotSnapshot(
      dartExecutable: dart,
      workingDirectory: repository,
      entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
      artifact: hostArtifact,
      stage: 'durable-git-host',
    );
    for (final entry in const {
      _gitPluginId: 'plugins/git/packages/backend/bin/git_backend.dart',
      _projectPluginId:
          'plugins/local_directory_project/packages/backend/bin/local_directory_project_backend.dart',
    }.entries) {
      final installed = await Directory(
        '${installations.path}/${entry.key}',
      ).create();
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entry.value,
        artifact: File('${installed.path}/backend.aot'),
        stage: 'durable-git-${entry.key}',
      );
      await File(
        '${installed.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': entry.key,
            'version': '1.0.0',
            'displayName': entry.key,
          },
          'components': {
            'backend': {'artifact': 'backend.aot'},
          },
        }),
      );
    }
  });

  Future<AdeleRuntime> start(ProductIdSource ids) async {
    final runtime = AdeleRuntime(ids: ids);
    addTearDown(runtime.close);
    await runtime.plugins.start(
      installationRoot: installations.path,
      dartaotruntimeExecutable: dartaotruntime,
      hostArtifactPath: hostArtifact.path,
      startupArguments: const {},
    );
    expect(runtime.plugins.state, ApplicationPluginState.ready);
    expect(runtime.plugins.failure, isNull);
    expect(runtime.plugins.catalog!.issues, isEmpty);
    expect(runtime.plugins.backends, hasLength(2));
    for (final backend in runtime.plugins.backends) {
      expect(backend.state, InstalledBackendState.active);
      expect(backend.failure, isNull);
      expect(backend.connection!.isClosed, isFalse);
    }
    final git = runtime.registry
        .providersFor(environmentProviderCapability)
        .single;
    expect(git.id, _gitProviderId);
    expect(git.pluginId, _gitPluginId);
    final project = runtime.registry
        .providersFor(projectProviderCapability)
        .single;
    expect(project.id, _projectProviderId);
    expect(project.pluginId, _projectPluginId);
    return runtime;
  }

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
        await _git(originalSource, ['init', '--initial-branch=main']);
        await _git(originalSource, ['add', 'lib/example.dart']);
        await _git(originalSource, ['commit', '-m', 'Fixture baseline']);
        final baseline = (await _git(originalSource, [
          'rev-parse',
          'HEAD',
        ])).trim();

        final original = await start(
          MonotonicProductIdSource(seed: 'durable-git'),
        );
        final project = await original.lifecycle.openProject(
          sourceLocation: originalSource.uri,
          provider: original.lifecycle.resolveProjectProvider(
            _projectProviderId,
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
        expect(created.environment.providerId, _gitProviderId);
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
        final anchor = _anchor(backing, created.environment.id);
        expect(anchor, {
          'environment_id': created.environment.id.value,
          'baseline_commit': baseline,
          'expected_branch_ref': 'refs/heads/${state['branch']}',
        });
        expect(backing.loadProductGraph().sessions, isEmpty);
        expect(original.store.sessionsForTask(created.task.id), isEmpty);
        final strategy = _registerStrategy(original.extensions);
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
          (await _git(originalWorktree, ['rev-parse', 'HEAD'])).trim(),
          baseline,
        );

        // Both branches advance independently; restore must not reset to baseline
        // or replace the retained Task checkout with the current source HEAD.
        final progress = File('${originalWorktree.path}/progress.txt');
        await progress.writeAsString('First Task commit.\n');
        await _git(originalWorktree, ['add', 'progress.txt']);
        await _git(originalWorktree, ['commit', '-m', 'Task progress']);
        await progress.writeAsString('Later Task commit.\n');
        await _git(originalWorktree, ['add', 'progress.txt']);
        await _git(originalWorktree, ['commit', '-m', 'Later Task progress']);
        final taskHead = (await _git(originalWorktree, [
          'rev-parse',
          'HEAD',
        ])).trim();
        await _git(originalSource, [
          'commit',
          '--allow-empty',
          '-m',
          'Source progress',
        ]);
        final sourceHead = (await _git(originalSource, [
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
        final beforeRestart = await _invoke(
          original,
          laterSession,
          (client) => client.snapshotTaskChanges(),
        );
        _expectOriginalBaselineChanges(beforeRestart);
        expect(_anchor(backing, created.environment.id), anchor);
        // The real Git schema rejects identical and conflicting insertions.
        final storage = ProjectStorageHost(
          lifecycle: original.lifecycle,
          owner: PluginId(_gitPluginId),
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
          expect(_anchor(backing, created.environment.id), anchor);
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
        await _git(originalWorktree, ['add', 'lib/example.dart']);
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
        final status = await _git(originalWorktree, [
          'status',
          '--porcelain=v1',
          '-z',
        ]);
        expect(
          status.split('\u0000'),
          containsAll(['MM lib/example.dart', '?? scratch.txt']),
        );
        final diff = await _git(originalWorktree, ['diff', '--binary', 'HEAD']);
        final stagedDiff = await _git(originalWorktree, [
          'diff',
          '--cached',
          '--binary',
        ]);
        final branches = await _git(originalSource, [
          'for-each-ref',
          '--format=%(refname) %(objectname)',
          'refs/heads',
        ]);
        expect(branches.trim().split('\n'), hasLength(2));
        final inventory = await _git(originalSource, [
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
        final gitDirectory = (await _git(originalWorktree, [
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
        await replacementBackends.start(
          installationRoot: installations.path,
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          startupArguments: const {},
        );
        final rematerialized = await original.lifecycle.environmentRuntime
            .materialize(created.environment.id);
        expect(rematerialized.provider, isNot(same(initial.provider)));
        expect(rematerialized.environment.providerState, state);
        expect(_anchor(backing, created.environment.id), anchor);
        _expectOriginalBaselineChanges(
          await _invoke(
            original,
            laterSession,
            (client) => client.snapshotTaskChanges(),
            backends: replacementBackends,
          ),
        );
        expect(_anchor(backing, created.environment.id), anchor);
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
        final beforeOpenInventory = await _git(source, [
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

        final ids = _NoAllocationIds();
        final fresh = await start(ids);
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
          provider: fresh.lifecycle.resolveProjectProvider(_projectProviderId),
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
        expect(_anchor(reopenedBacking, environment.id), anchor);
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
          await _git(source, ['worktree', 'list', '--porcelain', '-z']),
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
        expect(
          await _git(worktree, ['status', '--porcelain=v1', '-z']),
          status,
        );
        expect(await _git(worktree, ['diff', '--binary', 'HEAD']), diff);
        expect(
          await _git(worktree, ['diff', '--cached', '--binary']),
          stagedDiff,
        );
        expect((await _git(worktree, ['rev-parse', 'HEAD'])).trim(), taskHead);
        expect((await _git(source, ['rev-parse', 'HEAD'])).trim(), sourceHead);
        expect(
          (await _git(worktree, [
            'rev-parse',
            '--verify',
            '$baseline^{commit}',
          ])).trim(),
          baseline,
        );
        expect(
          (await _git(worktree, ['symbolic-ref', 'HEAD'])).trim(),
          'refs/heads/${state['branch']}',
        );
        expect(
          (await _git(worktree, ['rev-parse', '--show-toplevel'])).trim(),
          worktree.path,
        );
        expect(
          (await _git(worktree, [
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
          await _git(source, [
            'for-each-ref',
            '--format=%(refname) %(objectname)',
            'refs/heads',
          ]),
          branches,
        );
        expect(
          await _git(source, ['worktree', 'list', '--porcelain', '-z']),
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
          await _git(worktree, ['diff', '--cached', '--binary']),
          stagedDiff,
        );
        expect(
          await fresh.lifecycle.environmentRuntime.materialize(environment.id),
          same(restored),
        );
        expect(ids.calls, 0);
        _expectOriginalBaselineChanges(
          await _invoke(
            fresh,
            reopenedSession,
            (client) => client.snapshotTaskChanges(),
          ),
        );
        expect(_anchor(reopenedBacking, environment.id), anchor);
        await fresh.close();
        expect(
          await _git(source, ['worktree', 'list', '--porcelain', '-z']),
          inventory.replaceAll(originalSource.path, source.path),
        );
        expect(
          await _git(source, [
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

  for (final failure in [
    'missing anchor',
    'wrong branch',
    'unavailable commit',
  ]) {
    test('stock Task comparison fails closed for $failure', () async {
      final source = await _repository('adele-git-anchor-failure-');
      final original = await start(MonotonicProductIdSource(seed: 'anchor'));
      final project = await original.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: original.lifecycle.resolveProjectProvider(_projectProviderId),
      );
      final created = await original.lifecycle.createTask(
        projectId: project.id,
        title: 'Retained anchor failure',
      );
      final backing = original.lifecycle.existingDatabaseForProject(project)!;
      final anchor = _anchor(backing, created.environment.id);
      final baseline = anchor['baseline_commit']! as String;
      final worktree = Directory.fromUri(
        source.uri.resolve(
          created.environment.providerState!['worktreeRelativePath']! as String,
        ),
      );
      await File(
        '${worktree.path}/progress.txt',
      ).writeAsString('Task progress.\n');
      await _git(worktree, ['add', 'progress.txt']);
      await _git(worktree, ['commit', '-m', 'Later Task commit']);
      await _git(source, [
        'commit',
        '--allow-empty',
        '-m',
        'Later source commit',
      ]);
      final session = original.lifecycle.createSession(
        taskId: created.task.id,
        strategyId: _registerStrategy(original.extensions),
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
      final reopened = await start(_NoAllocationIds());
      final reopenedProject = await reopened.lifecycle.openProject(
        sourceLocation: source.uri,
        provider: reopened.lifecycle.resolveProjectProvider(_projectProviderId),
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
        await _git(worktree, ['switch', '-c', 'unexpected-task-branch']);
      } else if (failure == 'unavailable commit') {
        // Remove the exact originally stored loose object, not a guessed HEAD.
        final object = File(
          '${source.path}/.git/objects/${baseline.substring(0, 2)}/${baseline.substring(2)}',
        );
        expect(await object.exists(), isTrue);
        await object.delete();
      }
      final unstaged = await _invoke(
        reopened,
        retainedSession,
        (client) => client.snapshotUnstaged(),
      );
      expect(unstaged.files, isEmpty);
      final uncommitted = await _invoke(
        reopened,
        retainedSession,
        (client) => client.snapshotUncommitted(),
      );
      expect(uncommitted.staged.files, isEmpty);
      expect(uncommitted.unstaged.files, isEmpty);
      await expectLater(
        _invoke(
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

  for (final failCommit in [false, true]) {
    test(
      'actual Git establishment survives externally but SQL ${failCommit ? 'COMMIT' : 'insert'} failure publishes nothing',
      () async {
        final source = await _repository('adele-git-atomic-failure-');
        final fixture = _HeldEstablishmentFixture(
          installations: installations,
          hostArtifact: hostArtifact,
          dartaotruntime: dartaotruntime,
        );
        addTearDown(fixture.close);
        await fixture.start();
        final project = await fixture.open(source);
        final prior = await fixture.create(project);
        final backing = fixture.lifecycle.existingDatabaseForProject(project)!;
        final originalAnchor = _anchor(backing, prior.environment.id);
        final inspection = sqlite3.open(backing.path);
        addTearDown(inspection.close);
        if (failCommit) {
          inspection.execute('''
            CREATE TABLE fixture_deferred (
              environment_id TEXT REFERENCES adele_product_environments(id)
              DEFERRABLE INITIALLY DEFERRED
            );
            CREATE TRIGGER reject_anchor AFTER INSERT ON adele_git_task_anchors
            BEGIN
              INSERT INTO fixture_deferred (environment_id) VALUES ('absent');
            END;
          ''');
        } else {
          inspection.execute('''
            CREATE TRIGGER reject_anchor BEFORE INSERT ON adele_git_task_anchors
            BEGIN SELECT RAISE(ABORT, 'injected anchor insert failure'); END;
          ''');
        }
        final gate = fixture.holdNext();
        final creating = fixture.create(project);
        final rejected = expectLater(
          creating,
          throwsA(
            isA<SqliteException>().having(
              (error) => error.causingStatement,
              'causingStatement',
              failCommit
                  ? equals('COMMIT')
                  : contains('INSERT INTO adele_git_task_anchors'),
            ),
          ),
        );
        await gate.arrived.future;
        final plan = gate.result!['initialState']! as Map;
        expect(plan['inserts'], hasLength(1));
        expect(((plan['inserts']! as List).single as Map)['expectedRows'], 1);
        gate.release.complete();
        await rejected;
        _expectRejected(fixture, project, gate, prior: prior);
        expect(_anchor(backing, prior.environment.id), originalAnchor);
        expect(inspection.select('SELECT * FROM adele_git_task_anchors'), [
          originalAnchor,
        ]);
        expect(inspection.select('SELECT id FROM adele_product_tasks'), [
          {'id': prior.task.id.value},
        ]);
        expect(inspection.select('SELECT id FROM adele_product_environments'), [
          {'id': prior.environment.id.value},
        ]);
        expect(
          inspection.select('SELECT * FROM adele_product_sessions'),
          isEmpty,
        );
        if (failCommit) {
          expect(inspection.select('SELECT * FROM fixture_deferred'), isEmpty);
        }
        expect(backing.autocommit, isTrue);
        await _expectExternalWorktree(source, gate);
        inspection.execute('DROP TRIGGER reject_anchor');
        final retried = await fixture.create(project);
        expect(retried.task.id.value, isNot(gate.context!['taskId']));
        expect(fixture.lifecycle.store.tasksFor(project.id), hasLength(2));
        expect(
          inspection.select('SELECT * FROM adele_git_task_anchors'),
          hasLength(2),
        );
      },
    );
  }

  for (final replace in [false, true]) {
    test(
      'retired actual Git plan cannot enter SQL${replace ? ' through a same-ID replacement' : ''}',
      () async {
        final source = await _repository('adele-git-retired-plan-');
        final fixture = _HeldEstablishmentFixture(
          installations: installations,
          hostArtifact: hostArtifact,
          dartaotruntime: dartaotruntime,
        );
        addTearDown(fixture.close);
        await fixture.start();
        final project = await fixture.open(source);
        final oldBinding = fixture.registry.resolve(
          environmentProviderCapability,
        );
        final gate = fixture.holdNext();
        final creating = fixture.create(project);
        final rejected = expectLater(
          creating,
          throwsA(
            isA<ProviderUnavailable>().having(
              (error) => error.stale,
              'stale',
              isTrue,
            ),
          ),
        );
        await gate.arrived.future;
        expect(gate.result!['initialState'], isA<Map<String, Object?>>());
        final backing = fixture.lifecycle.existingDatabaseForProject(project)!;
        expect(backing.loadProductGraph().tasks, isEmpty);
        await fixture.backends.close();
        if (replace) {
          await fixture.start();
          final freshBinding = fixture.registry.resolve(
            environmentProviderCapability,
          );
          expect(freshBinding.provider.id, oldBinding.provider.id);
          expect(freshBinding.isSameRegistration(oldBinding), isFalse);
        }
        gate.release.complete();
        await rejected;
        _expectRejected(fixture, project, gate);
        expect(backing.loadProductGraph().tasks, isEmpty);
        expect(backing.loadProductGraph().environments, isEmpty);
        expect(
          backing.queryPluginRows(
            "SELECT name FROM sqlite_master WHERE name='adele_git_task_anchors'",
            {},
          ),
          isEmpty,
        );
        expect(
          fixture.establishments,
          1,
          reason: 'Never retry on the replacement.',
        );
        await _expectExternalWorktree(source, gate);
        if (replace) {
          final fresh = await fixture.create(project);
          expect(fixture.establishments, 2);
          expect(fixture.lifecycle.store.tasksFor(project.id), [fresh.task]);
          expect(
            _anchor(backing, fresh.environment.id)['baseline_commit'],
            gate.baseline,
          );
        }
      },
    );
  }
}

Map<String, Object?> _anchor(
  ProjectDatabase database,
  EnvironmentId environment,
) => database
    .queryPluginRows(
      'SELECT * FROM adele_git_task_anchors WHERE environment_id=:environment',
      {':environment': environment.value},
    )
    .single
    .values;

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

OrchestrationStrategyId _registerStrategy(ExtensionRegistry extensions) {
  final id = OrchestrationStrategyId('dev.adele.test.git-lifecycle');
  final registration = extensions.register(
    point: orchestrationStrategyContributions,
    id: ExtensionId(id.value),
    value: OrchestrationStrategyContribution(
      strategyId: id,
      materialize: (_) => throw StateError('No Run is started.'),
    ),
  );
  addTearDown(registration.close);
  return id;
}

Future<T> _invoke<T>(
  AdeleRuntime runtime,
  Session session,
  Future<T> Function(ChangeSetSourceServiceClient) invoke, {
  ApplicationPluginBootstrap? backends,
}) async {
  final plugins = backends ?? runtime.plugins;
  final selection = await CapturedEnvironmentCapabilities(
    environmentRuntime: runtime.lifecycle.environmentRuntime,
    backends: plugins,
    session: session,
  ).resolve(changeSetSourceCapability);
  return invokeEnvironmentCapabilityWithBufferedProcess(
    selection: selection,
    backends: plugins,
    serviceId: changeSetSourceServiceId,
    invoke: (channel) => invoke(ChangeSetSourceServiceClient(channel)),
  );
}

void _expectOriginalBaselineChanges(TaskChangeSetSnapshot snapshot) {
  expect(snapshot.committed.files.single.relativePath, 'progress.txt');
  expect(snapshot.committed.files.single.changeKind, 'added');
  expect(
    snapshot.committed.files.single.hunks.single.lines.single.text,
    'Later Task commit.',
  );
}

Future<Directory> _repository(String prefix) async {
  final source = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => source.delete(recursive: true));
  await File(
    '${source.path}/seed.txt',
  ).writeAsString('Original source commit.\n');
  await _git(source, ['init', '--initial-branch=main', '--object-format=sha1']);
  await _git(source, ['add', 'seed.txt']);
  await _git(source, ['commit', '-m', 'Original source commit']);
  return source;
}

void _expectRejected(
  _HeldEstablishmentFixture fixture,
  Project project,
  _EstablishmentGate gate, {
  TaskCreationResult? prior,
}) {
  final task = TaskId(gate.context!['taskId']! as String);
  final environment = EnvironmentId(gate.context!['environmentId']! as String);
  final store = fixture.lifecycle.store;
  expect(
    store.tasksFor(project.id),
    prior == null ? isEmpty : equals([prior.task]),
  );
  expect(store.task(task), isNull);
  expect(store.environment(environment), isNull);
  expect(store.primaryEnvironmentFor(task), isNull);
  expect(store.sessionsForTask(task), isEmpty);
  expect(
    fixture.lifecycle.environmentRuntime.currentMaterialization(environment),
    isNull,
  );
}

Future<void> _expectExternalWorktree(
  Directory source,
  _EstablishmentGate gate,
) async {
  final state = gate.result!['providerState']! as Map;
  final worktree = Directory.fromUri(
    source.uri.resolve(state['worktreeRelativePath']! as String),
  );
  expect(await worktree.exists(), isTrue);
  expect((await _git(worktree, ['rev-parse', 'HEAD'])).trim(), gate.baseline);
  expect(
    (await _git(worktree, ['symbolic-ref', 'HEAD'])).trim(),
    'refs/heads/${state['branch']}',
  );
  expect(
    await _git(source, ['worktree', 'list', '--porcelain']),
    contains('worktree ${worktree.path}\n'),
  );
}

final class _HeldEstablishmentFixture {
  _HeldEstablishmentFixture({
    required this.installations,
    required this.hostArtifact,
    required this.dartaotruntime,
  }) {
    lifecycle = ProductLifecycleCoordinator(
      store: InMemoryProductStore(),
      registry: registry,
      extensions: extensions,
      ids: MonotonicProductIdSource(seed: 'held-git'),
      providerForBinding: (binding) => GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(
          _EstablishmentChannel(binding.requestChannel, this),
        ),
      ),
      captureEstablishmentOwner: (binding) {
        final owner = backends.backendForProvider(binding)!;
        return EnvironmentEstablishmentOwner(
          pluginId: PluginId(owner.connection!.pluginId),
          validate: () => owner.validateProviderOwnership(binding),
        );
      },
    );
  }

  final Directory installations;
  final File hostArtifact;
  final String dartaotruntime;
  final registry = CapabilityRegistry();
  final extensions = ExtensionRegistry();
  late final ProductLifecycleCoordinator lifecycle;
  late ApplicationPluginBootstrap backends;
  _EstablishmentGate? nextGate;
  final gates = <_EstablishmentGate>[];
  int establishments = 0;

  Future<void> start() async {
    backends = ApplicationPluginBootstrap(
      registry,
      extensions,
      createInfrastructureServices: (connection) =>
          projectStorageServices(lifecycle, connection),
    );
    await backends.start(
      installationRoot: installations.path,
      dartaotruntimeExecutable: dartaotruntime,
      hostArtifactPath: hostArtifact.path,
      startupArguments: const {},
    );
    expect(
      backends.backends.map((backend) => backend.state),
      everyElement(InstalledBackendState.active),
    );
  }

  Future<Project> open(Directory source) => lifecycle.openProject(
    sourceLocation: source.uri,
    provider: lifecycle.resolveProjectProvider(_projectProviderId),
  );

  Future<TaskCreationResult> create(Project project) => lifecycle.createTask(
    projectId: project.id,
    title: 'Actual Git establishment',
  );

  _EstablishmentGate holdNext() {
    final gate = _EstablishmentGate();
    gates.add(gate);
    return nextGate = gate;
  }

  Future<void> close() async {
    for (final gate in gates) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
    await backends.close();
    await lifecycle.close();
  }
}

final class _EstablishmentGate {
  final arrived = Completer<void>();
  final release = Completer<void>();
  Map<String, Object?>? context;
  Map<String, Object?>? result;

  String get baseline =>
      (((result!['initialState']! as Map)['inserts']! as List).single
              as Map)['parameters'][':baseline']
          as String;
}

/// Observe and delay only the already-completed real AOT result, never synthesize
/// provider state, an initial plan, or any comparison implementation.
final class _EstablishmentChannel implements AdeleRequestChannel {
  _EstablishmentChannel(this.delegate, this.fixture);

  final AdeleRequestChannel delegate;
  final _HeldEstablishmentFixture fixture;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    if (method != environmentProviderServiceEstablishId) {
      return delegate.request(method, payload);
    }
    fixture.establishments++;
    final gate = fixture.nextGate;
    fixture.nextGate = null;
    final result = await delegate.request(method, payload);
    if (gate != null) {
      gate.context = Map<String, Object?>.from(payload['context']! as Map);
      gate.result = Map<String, Object?>.from(result! as Map);
      gate.arrived.complete();
      await gate.release.future;
    }
    return result;
  }
}

final class _NoAllocationIds implements ProductIdSource {
  int calls = 0;

  Never _allocate() {
    calls++;
    throw StateError(
      'Reopening durable work must not allocate any product ID.',
    );
  }

  @override
  ProjectId nextProjectId() => _allocate();

  @override
  TaskId nextTaskId() => _allocate();

  @override
  EnvironmentId nextEnvironmentId() => _allocate();

  @override
  SessionId nextSessionId() => _allocate();
}

Future<String> _git(Directory directory, List<String> arguments) async {
  final result = await Process.run('git', [
    '-c',
    'user.name=ADELE Test',
    '-c',
    'user.email=adele-test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    ...arguments,
  ], workingDirectory: directory.path);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString();
}

String _dartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final executable = File.fromUri(
      Directory(flutterRoot).uri.resolve(
        'bin/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ),
    );
    if (executable.existsSync()) return executable.path;
  }
  final executable = File(Platform.resolvedExecutable);
  if (executable.parent.path.endsWith(
    '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin',
  )) {
    return executable.path;
  }
  throw StateError('Unable to locate the Dart SDK executable for AOT tests.');
}
