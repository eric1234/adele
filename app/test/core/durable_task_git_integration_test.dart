@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';

const _gitPluginId = 'dev.adele.plugin.git-environment';
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
      _gitPluginId:
          'plugins/git_environment/packages/backend/bin/git_environment_backend.dart',
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
          'schemaVersion': 1,
          'environmentId': created.environment.id.value,
          'sourceRelativePath': '',
          'worktreeRelativePath': relativePath,
          'branch': state['branch'],
          'baselineCommit': baseline,
        });
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
        await _git(originalWorktree, [
          'commit',
          '--allow-empty',
          '-m',
          'Task progress',
        ]);
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
