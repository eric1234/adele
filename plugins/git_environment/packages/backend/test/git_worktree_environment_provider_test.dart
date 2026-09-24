import 'dart:async';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:git_environment_backend/git_environment_backend.dart';
import 'package:test/test.dart';

void main() {
  test('establishes and restores Task-specific Git worktrees', () async {
    final ({Directory container, Directory source}) fixture =
        await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final LiveObjectRegistry<EnvironmentId, WorktreeEnvironment> liveObjects =
        LiveObjectRegistry<EnvironmentId, WorktreeEnvironment>();
    final GitWorktreeEnvironmentProvider generationA =
        GitWorktreeEnvironmentProvider(liveObjects: liveObjects);
    final LocalEnvironment first = _environment(
      fixture.source.uri,
      taskId: 'task-first',
      environmentId: 'environment-\tfirst',
      title: 'Build Parser Support',
    );

    final EnvironmentProviderResult firstResult = await generationA.establish(
      first,
    );
    _expectV2State(first, firstResult.providerState);
    expect(firstResult.providerState['environmentId'], 'environment-\tfirst');
    expect(
      firstResult.providerState['baselineCommit'],
      await _gitOutput(fixture.source, <String>['rev-parse', 'HEAD']),
    );
    final WorktreeEnvironment firstLive = liveObjects.resolve(first.id);
    final String retainedPath = firstLive.root.path;
    expect(retainedPath, isNot(fixture.source.path));
    expect(
      retainedPath,
      _worktreeRoot(fixture.source, firstResult.providerState).path,
    );
    expect(await Directory(retainedPath).exists(), isTrue);
    expect(
      (await generationA.readFile(first.id, 'README.md')).text,
      contains('fixture source'),
    );
    final EnvironmentDirectoryListing listing = await generationA.readDirectory(
      first.id,
      '',
    );
    expect(
      listing.entries.map((EnvironmentDirectoryEntry entry) => entry.name),
      containsAll(<String>['README.md', 'lib']),
    );
    final String branch = await _gitOutput(firstLive.root, <String>[
      'branch',
      '--show-current',
    ]);
    expect(branch, startsWith('adele-build-parser-support-'));

    final LocalEnvironment second = _environment(
      fixture.source.uri,
      taskId: 'task-second',
      environmentId: 'environment-second',
      title: 'Second Environment',
    );
    await generationA.establish(second);
    expect(liveObjects.length, 2);
    expect(liveObjects.resolve(second.id).root.path, isNot(retainedPath));

    await generationA.close();
    expect(liveObjects.length, 0);
    expect(await Directory(retainedPath).exists(), isTrue);

    final Environment durable = Environment(
      id: first.id,
      taskId: first.task.id,
      role: first.role,
      providerId: first.providerId,
      providerState: firstResult.providerState,
    );
    final GitWorktreeEnvironmentProvider generationB =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationB.close);
    final LocalEnvironment renamedTask = LocalEnvironment(
      project: first.task.project,
      task: Task(
        id: first.task.id,
        projectId: first.task.project.id,
        title: 'A Later Task Title',
      ),
      value: durable,
    );

    final Environment copiedState = Environment(
      id: EnvironmentId('environment-copied-state'),
      taskId: first.task.id,
      role: first.role,
      providerId: first.providerId,
      providerState: firstResult.providerState,
    );
    await expectLater(
      generationB.restore(
        LocalEnvironment(
          project: first.task.project,
          task: first.task.value,
          value: copiedState,
        ),
      ),
      throwsA(_failureWithCode('restore_environment_mismatch')),
    );

    final String sourceBranch = await _gitOutput(fixture.source, <String>[
      'branch',
      '--show-current',
    ]);
    final Environment sourceCheckoutState = Environment(
      id: first.id,
      taskId: first.task.id,
      role: first.role,
      providerId: first.providerId,
      providerState: <String, Object?>{
        ...firstResult.providerState,
        'worktreeRelativePath': '.',
        'branch': sourceBranch,
      },
    );
    await expectLater(
      generationB.restore(
        LocalEnvironment(
          project: first.task.project,
          task: first.task.value,
          value: sourceCheckoutState,
        ),
      ),
      throwsA(_failureWithCode('invalid_provider_state')),
    );

    final Environment symbolicBaselineState = Environment(
      id: first.id,
      taskId: first.task.id,
      role: first.role,
      providerId: first.providerId,
      providerState: <String, Object?>{
        ...firstResult.providerState,
        'baselineCommit': 'HEAD',
      },
    );
    await expectLater(
      generationB.restore(
        LocalEnvironment(
          project: first.task.project,
          task: first.task.value,
          value: symbolicBaselineState,
        ),
      ),
      throwsA(_failureWithCode('invalid_provider_state')),
    );

    final EnvironmentProviderResult restored = await generationB.restore(
      renamedTask,
    );

    expect(generationB.liveObjects.resolve(first.id).root.path, retainedPath);
    expect(restored.providerState, firstResult.providerState);
    expect(
      (await generationB.readFile(first.id, 'README.md')).text,
      contains('fixture source'),
    );
    expect(
      await _gitOutput(Directory(retainedPath), <String>[
        'branch',
        '--show-current',
      ]),
      branch,
    );
  });

  test('allocates distinct resources for colliding Environment IDs', () async {
    final ({Directory container, Directory source}) fixture =
        await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final GitWorktreeEnvironmentProvider provider =
        GitWorktreeEnvironmentProvider();
    addTearDown(provider.close);
    final LocalEnvironment first = _environment(
      fixture.source.uri,
      taskId: 'task-collision-first',
      environmentId: 'environment-aaaag2vvb02tcd5ge7aj',
      title: 'Colliding Resources',
    );
    final LocalEnvironment second = _environment(
      fixture.source.uri,
      taskId: 'task-collision-second',
      environmentId: 'environment-aaaa1foa721piuycf72w',
      title: 'Colliding Resources',
    );

    final EnvironmentProviderResult firstResult = await provider.establish(
      first,
    );
    final EnvironmentProviderResult secondResult = await provider.establish(
      second,
    );
    final String firstBranch = firstResult.providerState['branch']! as String;
    final String secondBranch = secondResult.providerState['branch']! as String;
    final String firstPath = _worktreeRoot(
      fixture.source,
      firstResult.providerState,
    ).path;
    final String secondPath = _worktreeRoot(
      fixture.source,
      secondResult.providerState,
    ).path;

    expect(secondBranch, '$firstBranch-2');
    expect(secondPath, '$firstPath-2');
    expect(provider.liveObjects.length, 2);
    expect(provider.liveObjects.resolve(first.id).root.path, firstPath);
    expect(provider.liveObjects.resolve(second.id).root.path, secondPath);
    expect(
      (await provider.readFile(first.id, 'README.md')).text,
      contains('fixture source'),
    );
    expect(
      (await provider.readFile(second.id, 'README.md')).text,
      contains('fixture source'),
    );
  });

  test('restores when a tag has the provider branch name', () async {
    final ({Directory container, Directory source}) fixture =
        await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final GitWorktreeEnvironmentProvider generationA =
        GitWorktreeEnvironmentProvider();
    final LocalEnvironment environment = _environment(
      fixture.source.uri,
      taskId: 'task-branch-tag',
      environmentId: 'environment-branch-tag',
      title: 'Branch Tag Ambiguity',
    );

    final EnvironmentProviderResult established = await generationA.establish(
      environment,
    );
    final WorktreeEnvironment firstLive = generationA.liveObjects.resolve(
      environment.id,
    );
    final String branch = await _gitOutput(firstLive.root, <String>[
      'branch',
      '--show-current',
    ]);
    await _gitOutput(fixture.source, <String>['tag', branch, 'HEAD']);
    expect(
      await _gitOutput(firstLive.root, <String>[
        'symbolic-ref',
        '--quiet',
        '--short',
        'HEAD',
      ]),
      'heads/$branch',
    );
    await generationA.close();
    final Environment durable = Environment(
      id: environment.id,
      taskId: environment.task.id,
      role: environment.role,
      providerId: environment.providerId,
      providerState: established.providerState,
    );
    final GitWorktreeEnvironmentProvider generationB =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationB.close);

    await generationB.restore(
      LocalEnvironment(
        project: environment.task.project,
        task: environment.task.value,
        value: durable,
      ),
    );

    final WorktreeEnvironment restored = generationB.liveObjects.resolve(
      environment.id,
    );
    expect(
      await _gitOutput(restored.root, <String>['branch', '--show-current']),
      branch,
    );
    expect(
      (await generationB.readFile(environment.id, 'README.md')).text,
      contains('fixture source'),
    );
  });

  test(
    'preserves a trailing-space repository path across restore',
    () async {
      final ({Directory container, Directory source}) fixture =
          await _createRepository(sourceDirectoryName: 'repo ');
      addTearDown(() => fixture.container.delete(recursive: true));
      expect(fixture.source.path, endsWith(' '));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-trailing-space',
        environmentId: 'environment-trailing-space',
        title: 'Trailing Space Repository',
      );

      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      _expectV2State(environment, established.providerState);
      expect(
        generationA.liveObjects.resolve(environment.id).root.path,
        _worktreeRoot(fixture.source, established.providerState).path,
      );
      expect(
        (await generationA.readFile(environment.id, 'README.md')).text,
        contains('fixture source'),
      );
      await generationA.close();

      final Environment durable = Environment(
        id: environment.id,
        taskId: environment.task.id,
        role: environment.role,
        providerId: environment.providerId,
        providerState: established.providerState,
      );
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      await generationB.restore(
        LocalEnvironment(
          project: environment.task.project,
          task: environment.task.value,
          value: durable,
        ),
      );

      expect(
        (await generationB.readFile(environment.id, 'README.md')).text,
        contains('fixture source'),
      );
    },
    skip: Platform.isWindows
        ? 'Windows does not support trailing-space directory names.'
        : false,
  );

  test(
    'preserves a trailing-carriage-return repository path across restore',
    () async {
      final ({Directory container, Directory source}) fixture =
          await _createRepository(sourceDirectoryName: 'repo\r');
      addTearDown(() => fixture.container.delete(recursive: true));
      expect(fixture.source.path, endsWith('\r'));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-trailing-carriage-return',
        environmentId: 'environment-trailing-carriage-return',
        title: 'Trailing Carriage Return Repository',
      );

      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      _expectV2State(environment, established.providerState);
      expect(
        generationA.liveObjects.resolve(environment.id).root.path,
        _worktreeRoot(fixture.source, established.providerState).path,
      );
      expect(
        (await generationA.readFile(environment.id, 'README.md')).text,
        contains('fixture source'),
      );
      await generationA.close();

      final Environment durable = Environment(
        id: environment.id,
        taskId: environment.task.id,
        role: environment.role,
        providerId: environment.providerId,
        providerState: established.providerState,
      );
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      await generationB.restore(
        LocalEnvironment(
          project: environment.task.project,
          task: environment.task.value,
          value: durable,
        ),
      );

      expect(
        (await generationB.readFile(environment.id, 'README.md')).text,
        contains('fixture source'),
      );
    },
    skip: Platform.isWindows
        ? 'Windows does not support trailing-carriage-return directory names.'
        : false,
  );

  test('preserves a Project source subdirectory across restore', () async {
    final ({Directory container, Directory source}) fixture =
        await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    await File('${fixture.source.path}/outside.txt').writeAsString('outside');
    final Directory projectSource = Directory(
      '${fixture.source.path}/project-source',
    );
    await projectSource.create();
    await File('${projectSource.path}/inside.txt').writeAsString('inside');
    await _gitOutput(fixture.source, <String>['add', '.']);
    await _gitOutput(fixture.source, <String>[
      'commit',
      '-m',
      'Add scoped Project source',
    ]);
    final GitWorktreeEnvironmentProvider generationA =
        GitWorktreeEnvironmentProvider();
    final LocalEnvironment environment = _environment(
      projectSource.uri,
      taskId: 'task-scoped-source',
      environmentId: 'environment-scoped-source',
      title: 'Scoped source',
    );

    final EnvironmentProviderResult established = await generationA.establish(
      environment,
    );
    final WorktreeEnvironment firstLive = generationA.liveObjects.resolve(
      environment.id,
    );
    _expectV2State(
      environment,
      established.providerState,
      sourceRelativePath: 'project-source',
    );
    final Directory worktreeRoot = _worktreeRoot(
      projectSource,
      established.providerState,
    );
    expect(
      firstLive.root.path,
      '${worktreeRoot.path}${Platform.pathSeparator}project-source',
    );
    expect(
      (await generationA.readFile(environment.id, 'inside.txt')).text,
      'inside',
    );
    await expectLater(
      generationA.readFile(environment.id, 'outside.txt'),
      throwsA(_failureWithCode('not_found')),
    );
    final EnvironmentDirectoryListing listing = await generationA.readDirectory(
      environment.id,
      '',
    );
    expect(
      listing.entries.map((EnvironmentDirectoryEntry entry) => entry.name),
      <String>['inside.txt'],
    );

    await generationA.close();
    final Environment durable = Environment(
      id: environment.id,
      taskId: environment.task.id,
      role: environment.role,
      providerId: environment.providerId,
      providerState: established.providerState,
    );
    final GitWorktreeEnvironmentProvider generationB =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationB.close);
    final LocalEnvironment retained = LocalEnvironment(
      project: environment.task.project,
      task: environment.task.value,
      value: durable,
    );
    await firstLive.root.delete(recursive: true);
    await expectLater(
      generationB.restore(retained),
      throwsA(_failureWithCode('restore_source_scope_missing')),
    );
    expect(await firstLive.root.exists(), isFalse);
    final Link redirectedScope = Link(firstLive.root.path);
    await redirectedScope.create(worktreeRoot.path);
    await expectLater(
      generationB.restore(retained),
      throwsA(_failureWithCode('restore_source_scope_missing')),
    );
    await redirectedScope.delete();

    final Directory outsideScope = Directory(
      '${fixture.container.path}/outside-scope',
    );
    await outsideScope.create();
    await File('${outsideScope.path}/inside.txt').writeAsString('escaped');
    final Link escapedScope = Link(firstLive.root.path);
    await escapedScope.create(outsideScope.path);
    await expectLater(
      generationB.restore(retained),
      throwsA(_failureWithCode('restore_source_scope_missing')),
    );
    await escapedScope.delete();
    await firstLive.root.create();
    await File('${firstLive.root.path}/inside.txt').writeAsString('inside');

    await generationB.restore(retained);

    expect(
      generationB.liveObjects.resolve(environment.id).root.path,
      firstLive.root.path,
    );
    expect(
      (await generationB.readFile(environment.id, 'inside.txt')).text,
      'inside',
    );
    await expectLater(
      generationB.readFile(environment.id, 'outside.txt'),
      throwsA(_failureWithCode('not_found')),
    );
  });

  test('places storage under the canonical selected Project source', () async {
    final fixture = await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final Directory selectedSource = Directory('${fixture.source.path}/lib');
    final Link alias = Link('${fixture.container.path}/source-alias');
    await alias.create(selectedSource.path);
    final LocalEnvironment environment = _environment(
      Directory(alias.path).uri,
      taskId: 'task-canonical',
      environmentId: 'environment-canonical',
      title: 'Canonical source',
    );
    final GitWorktreeEnvironmentProvider generationA =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationA.close);
    final EnvironmentProviderResult established = await generationA.establish(
      environment,
    );
    _expectV2State(
      environment,
      established.providerState,
      sourceRelativePath: 'lib',
    );
    final Directory worktree = _worktreeRoot(
      selectedSource,
      established.providerState,
    );
    expect(
      generationA.liveObjects.resolve(environment.id).root.path,
      '${worktree.path}/lib',
    );
    expect(
      await Directory('${selectedSource.path}/.adele/worktrees').exists(),
      isTrue,
    );
    expect(await Directory('${fixture.source.path}/.adele').exists(), isFalse);
    await generationA.close();
    await alias.delete();
    final GitWorktreeEnvironmentProvider generationB =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationB.close);
    final EnvironmentProviderResult restored = await generationB.restore(
      _retainedEnvironment(
        environment,
        established.providerState,
        sourceLocation: selectedSource.uri,
      ),
    );
    expect(restored.providerState, established.providerState);
    expect(
      (await generationB.readFile(environment.id, 'main.dart')).text,
      'void main() {}\n',
    );
  });

  for (final String scope in <String>['', 'project-source']) {
    test(
      'restores ${scope.isEmpty ? 'root' : 'scoped'} source after a real repository move',
      () async {
        final fixture = await _createRepository();
        addTearDown(() => fixture.container.delete(recursive: true));
        final Directory selectedSource = scope.isEmpty
            ? fixture.source
            : Directory('${fixture.source.path}/$scope');
        if (scope.isNotEmpty) {
          await selectedSource.create();
          await File(
            '${selectedSource.path}/README.md',
          ).writeAsString('scoped source\n');
          await _gitOutput(fixture.source, <String>['add', '.']);
          await _gitOutput(fixture.source, <String>[
            'commit',
            '-m',
            'Add scoped source',
          ]);
        }
        final LocalEnvironment environment = _environment(
          selectedSource.uri,
          taskId: 'task-moved',
          environmentId: 'environment-moved',
          title: 'Moved repository',
        );
        final GitWorktreeEnvironmentProvider generationA =
            GitWorktreeEnvironmentProvider();
        addTearDown(generationA.close);
        final EnvironmentProviderResult established = await generationA
            .establish(environment);
        final Map<String, Object?> state = Map<String, Object?>.of(
          established.providerState,
        );
        _expectV2State(environment, state, sourceRelativePath: scope);
        final Directory oldWorktree = _worktreeRoot(selectedSource, state);
        final Directory oldLiveRoot = generationA.liveObjects
            .resolve(environment.id)
            .root;
        expect(
          oldLiveRoot.path,
          scope.isEmpty ? oldWorktree.path : '${oldWorktree.path}/$scope',
        );
        await _gitOutput(oldWorktree, <String>[
          'commit',
          '--allow-empty',
          '-m',
          'Advance retained branch',
        ]);
        final String retainedHead = await _gitOutput(oldWorktree, <String>[
          'rev-parse',
          'HEAD',
        ]);
        await _gitOutput(fixture.source, <String>[
          'commit',
          '--allow-empty',
          '-m',
          'Advance source branch',
        ]);
        expect(retainedHead, isNot(state['baselineCommit']));
        expect(
          await _gitOutput(fixture.source, <String>['rev-parse', 'HEAD']),
          isNot(state['baselineCommit']),
        );
        await File(
          '${oldLiveRoot.path}/README.md',
        ).writeAsString('retained uncommitted content\n');
        await generationA.createTextFile(
          environment.id,
          'untracked.txt',
          'retained untracked content\n',
        );
        await generationA.close();
        expect(generationA.liveObjects.length, 0);

        final Directory movedRepository = await fixture.source.rename(
          '${fixture.container.path}/moved repository',
        );
        final Directory movedSource = scope.isEmpty
            ? movedRepository
            : Directory('${movedRepository.path}/$scope');
        final Directory movedWorktree = _worktreeRoot(movedSource, state);
        expect(
          await Directory('${movedRepository.path}/.git').exists(),
          isTrue,
        );
        expect(await Directory('${movedSource.path}/.adele').exists(), isTrue);
        expect(await oldWorktree.exists(), isFalse);
        expect(await movedWorktree.exists(), isTrue);
        final String before = await _gitOutput(movedRepository, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]);
        expect(
          before.split('\u0000'),
          contains('worktree ${oldWorktree.path}'),
        );
        expect(
          before.split('\u0000'),
          isNot(contains('worktree ${movedWorktree.path}')),
        );

        final GitWorktreeEnvironmentProvider generationB =
            GitWorktreeEnvironmentProvider();
        addTearDown(generationB.close);
        final LocalEnvironment retained = _retainedEnvironment(
          environment,
          state,
          sourceLocation: movedSource.uri,
        );
        expect(retained.task.project.id, environment.task.project.id);
        expect(
          retained.task.project.sourceLocation,
          isNot(environment.task.project.sourceLocation),
        );
        final EnvironmentProviderResult restored = await generationB.restore(
          retained,
        );
        expect(restored.providerState, state);
        expect(established.providerState, state);
        expect(generationB.liveObjects.length, 1);
        expect(
          generationB.liveObjects.resolve(environment.id).root.path,
          scope.isEmpty ? movedWorktree.path : '${movedWorktree.path}/$scope',
        );
        expect(
          (await generationB.readFile(environment.id, 'README.md')).text,
          'retained uncommitted content\n',
        );
        expect(
          (await generationB.readFile(environment.id, 'untracked.txt')).text,
          'retained untracked content\n',
        );
        expect(
          await _gitOutput(movedWorktree, <String>['symbolic-ref', 'HEAD']),
          'refs/heads/${state['branch']}',
        );
        expect(
          await _gitOutput(movedWorktree, <String>['rev-parse', 'HEAD']),
          retainedHead,
        );
        expect(
          await _gitOutput(movedWorktree, <String>[
            'rev-parse',
            '--verify',
            '${state['baselineCommit']}^{commit}',
          ]),
          state['baselineCommit'],
        );
        final String after = await _gitOutput(movedRepository, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]);
        expect(
          after.split('\u0000'),
          contains('worktree ${movedWorktree.path}'),
        );
        expect(
          after.split('\u0000'),
          isNot(contains('worktree ${oldWorktree.path}')),
        );
        expect(await oldWorktree.exists(), isFalse);
      },
    );
  }

  test('strictly rejects malformed schema v2 provider state', () async {
    final fixture = await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final GitWorktreeEnvironmentProvider generationA =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationA.close);
    final LocalEnvironment environment = _environment(
      fixture.source.uri,
      taskId: 'task-schema',
      environmentId: 'environment-schema',
      title: 'Schema validation',
    );
    final EnvironmentProviderResult established = await generationA.establish(
      environment,
    );
    final Map<String, Object?> state = established.providerState;
    _expectV2State(environment, state);
    await generationA.close();
    final GitWorktreeEnvironmentProvider generationB =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationB.close);
    final Map<String, Map<String, Object?>?> malformed =
        <String, Map<String, Object?>?>{
          'absent state': null,
          'empty state': <String, Object?>{},
          for (final String field in state.keys)
            'missing $field': Map<String, Object?>.of(state)..remove(field),
          for (final String field in state.keys)
            for (final Object? value in <Object?>[
              null,
              true,
              <Object?>[],
              <String, Object?>{},
            ])
              '$field type ${value.runtimeType}': <String, Object?>{
                ...state,
                field: value,
              },
          for (final Object version in <Object>[1, 3, 2.0, '2'])
            'version $version (${version.runtimeType})': <String, Object?>{
              ...state,
              'schemaVersion': version,
            },
          for (final String field in state.keys.where(
            (String field) => field != 'schemaVersion',
          ))
            '$field integer': <String, Object?>{...state, field: 2},
          for (final String field in <String>[
            'environmentId',
            'worktreeRelativePath',
            'branch',
            'baselineCommit',
          ])
            '$field empty': <String, Object?>{...state, field: ''},
          for (final String field in <String>[
            'sourcePath',
            'repositoryPath',
            'commonGitDirectory',
            'worktreePath',
            'unexpected',
          ])
            'extra $field': <String, Object?>{
              ...state,
              field: fixture.source.path,
            },
          for (final String field in <String>[
            'sourceRelativePath',
            'worktreeRelativePath',
          ])
            for (final String path in <String>[
              '/absolute/path',
              'C:/absolute/path',
              r'C:\absolute\path',
              r'\\server\share',
              '..',
              '../outside',
              'inside/../outside',
              '.',
              './inside',
              'inside/./child',
              'inside//child',
              'inside/',
              r'inside\child',
              'inside\u0000child',
            ])
              '$field path $path': <String, Object?>{...state, field: path},
          for (final String path in <String>[
            '.adele',
            '.adele/worktrees',
            '.adele/worktrees/',
            '.adele/worktrees/flat/nested',
            '.adele/other/flat',
            'other/worktrees/flat',
            '.adele/worktrees/../flat',
            '.adele/worktrees/./flat',
            '.adele//worktrees/flat',
            r'.adele\worktrees\flat',
          ])
            'worktree shape $path': <String, Object?>{
              ...state,
              'worktreeRelativePath': path,
            },
          for (final String branch in <String>[
            'HEAD',
            '-option',
            '/branch',
            'branch/',
            'branch//child',
            'branch..name',
            'branch.lock',
            'branch name',
            'branch@{1}',
            r'branch\name',
            'branch:name',
            'branch~name',
            'branch^name',
            'branch?name',
            'branch[name',
            'branch\nname',
          ])
            'branch $branch': <String, Object?>{...state, 'branch': branch},
          for (final String baseline in <String>[
            'HEAD',
            'a' * 39,
            'a' * 41,
            'a' * 63,
            'a' * 65,
            'A' * 40,
            'A' * 64,
            'g' * 40,
            'g' * 64,
            '${'a' * 40}\n',
          ])
            'baseline $baseline': <String, Object?>{
              ...state,
              'baselineCommit': baseline,
            },
        };
    final String inventory = await _gitOutput(fixture.source, <String>[
      'worktree',
      'list',
      '--porcelain',
      '-z',
    ]);
    for (final entry in malformed.entries) {
      await expectLater(
        generationB.restore(_retainedEnvironment(environment, entry.value)),
        throwsA(_failureWithCode('invalid_provider_state')),
        reason: entry.key,
      );
      expect(generationB.liveObjects.length, 0, reason: entry.key);
    }
    expect(
      await _gitOutput(fixture.source, <String>[
        'worktree',
        'list',
        '--porcelain',
        '-z',
      ]),
      inventory,
    );
    expect(
      (await generationB.restore(
        _retainedEnvironment(environment, state),
      )).providerState,
      state,
    );
  });

  test(
    'rejects a changed Project source scope without binding or relocation',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-scope-mismatch',
        environmentId: 'environment-scope-mismatch',
        title: 'Source scope mismatch',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      await generationA.close();
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      await expectLater(
        generationB.restore(
          _retainedEnvironment(
            environment,
            established.providerState,
            sourceLocation: Directory('${fixture.source.path}/lib').uri,
          ),
        ),
        throwsA(_failureWithCode('restore_source_mismatch')),
      );
      expect(generationB.liveObjects.length, 0);
      expect(
        await Directory('${fixture.source.path}/lib/.adele').exists(),
        isFalse,
      );
      expect(
        await _worktreeRoot(fixture.source, established.providerState).exists(),
        isTrue,
      );
    },
  );

  test('does not recreate a missing retained worktree', () async {
    final fixture = await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final GitWorktreeEnvironmentProvider generationA =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationA.close);
    final LocalEnvironment environment = _environment(
      fixture.source.uri,
      taskId: 'task-missing',
      environmentId: 'environment-missing',
      title: 'Missing worktree',
    );
    final EnvironmentProviderResult established = await generationA.establish(
      environment,
    );
    final Directory root = _worktreeRoot(
      fixture.source,
      established.providerState,
    );
    await generationA.close();
    await root.delete(recursive: true);
    final String inventory = await _gitOutput(fixture.source, <String>[
      'worktree',
      'list',
      '--porcelain',
      '-z',
    ]);
    final List<String> branches = await _branchNames(fixture.source);
    final GitWorktreeEnvironmentProvider generationB =
        GitWorktreeEnvironmentProvider();
    addTearDown(generationB.close);
    await expectLater(
      generationB.restore(
        _retainedEnvironment(environment, established.providerState),
      ),
      throwsA(_failureWithCode('restore_worktree_missing')),
    );
    expect(generationB.liveObjects.length, 0);
    expect(await root.exists(), isFalse);
    expect(await _branchNames(fixture.source), branches);
    expect(
      await _gitOutput(fixture.source, <String>[
        'worktree',
        'list',
        '--porcelain',
        '-z',
      ]),
      inventory,
    );
  });

  test(
    'rejects a worktree no longer registered on the retained branch',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-branch-mismatch',
        environmentId: 'environment-branch-mismatch',
        title: 'Branch mismatch',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      final Directory root = _worktreeRoot(
        fixture.source,
        established.providerState,
      );
      await generationA.close();
      await _gitOutput(root, <String>['checkout', '-b', 'replacement-branch']);
      final String inventory = await _gitOutput(fixture.source, <String>[
        'worktree',
        'list',
        '--porcelain',
        '-z',
      ]);
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      await expectLater(
        generationB.restore(
          _retainedEnvironment(environment, established.providerState),
        ),
        throwsA(_failureWithCode('restore_branch_mismatch')),
      );
      expect(generationB.liveObjects.length, 0);
      expect(
        await _gitOutput(root, <String>['branch', '--show-current']),
        'replacement-branch',
      );
      expect(
        await _gitOutput(fixture.source, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]),
        inventory,
      );
    },
  );

  test(
    'accepts full lower-hex baseline syntax but rejects unavailable commits',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-baseline',
        environmentId: 'environment-baseline',
        title: 'Missing baseline',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      await generationA.close();
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      for (final int length in <int>[40, 64]) {
        await expectLater(
          generationB.restore(
            _retainedEnvironment(environment, <String, Object?>{
              ...established.providerState,
              'baselineCommit': 'f' * length,
            }),
          ),
          throwsA(_failureWithCode('restore_baseline_missing')),
        );
        expect(generationB.liveObjects.length, 0);
      }
    },
  );

  test(
    'rejects a retained path linked to a different common repository',
    () async {
      final fixture = await _createRepository();
      final foreign = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      addTearDown(() => foreign.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-foreign',
        environmentId: 'environment-foreign',
        title: 'Different repository',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      final Directory root = _worktreeRoot(
        fixture.source,
        established.providerState,
      );
      await generationA.close();
      await root.delete(recursive: true);
      await _gitOutput(foreign.source, <String>[
        'worktree',
        'add',
        '-b',
        established.providerState['branch']! as String,
        root.path,
      ]);
      final String inventory = await _gitOutput(fixture.source, <String>[
        'worktree',
        'list',
        '--porcelain',
        '-z',
      ]);
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      await expectLater(
        generationB.restore(
          _retainedEnvironment(environment, established.providerState),
        ),
        throwsA(_failureWithCode('restore_worktree_mismatch')),
      );
      expect(generationB.liveObjects.length, 0);
      expect(
        await _gitOutput(fixture.source, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]),
        inventory,
      );
      expect(
        await _gitOutput(root, <String>['rev-parse', '--git-common-dir']),
        '${foreign.source.path}/.git',
      );
    },
  );

  test(
    'repair preflight does not repoint another same-repository branch',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-repair-alias',
        environmentId: 'environment-repair-alias',
        title: 'Repair alias',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      final Directory oldRoot = _worktreeRoot(
        fixture.source,
        established.providerState,
      );
      await generationA.close();
      final Directory moved = await fixture.source.rename(
        '${fixture.container.path}/moved',
      );
      final Directory expectedRoot = _worktreeRoot(
        moved,
        established.providerState,
      );
      final File candidateGitfile = File('${expectedRoot.path}/.git');
      final String retainedMarker = await candidateGitfile.readAsString();
      final Directory sibling = Directory('${fixture.container.path}/branch-b');
      await _gitOutput(moved, <String>[
        'worktree',
        'add',
        '-b',
        'branch-b',
        sibling.path,
      ]);
      final String siblingMarker = await File(
        '${sibling.path}/.git',
      ).readAsString();
      final String siblingMetadata = await _gitOutput(moved, <String>[
        'rev-parse',
        '--resolve-git-dir',
        '${sibling.path}/.git',
      ]);
      expect(
        await _gitOutput(sibling, <String>['rev-parse', 'HEAD']),
        established.providerState['baselineCommit'],
      );
      await candidateGitfile.writeAsString(siblingMarker);
      final String inventory = await _gitInventory(moved);
      expect(await oldRoot.exists(), isFalse);
      expect(inventory.split('\u0000'), contains('worktree ${oldRoot.path}'));

      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      final LocalEnvironment retained = _retainedEnvironment(
        environment,
        established.providerState,
        sourceLocation: moved.uri,
      );
      await expectLater(
        generationB.restore(retained),
        throwsA(_failureWithCode('restore_worktree_mismatch')),
      );
      expect(generationB.liveObjects.length, 0);
      expect(await _gitInventory(moved), inventory);
      expect(await candidateGitfile.readAsString(), siblingMarker);
      expect(await File('${sibling.path}/.git').readAsString(), siblingMarker);
      expect(
        await _gitOutput(moved, <String>[
          'rev-parse',
          '--resolve-git-dir',
          '${sibling.path}/.git',
        ]),
        siblingMetadata,
      );
      expect(
        await _gitOutput(sibling, <String>['symbolic-ref', 'HEAD']),
        'refs/heads/branch-b',
      );

      await candidateGitfile.writeAsString(retainedMarker);
      expect(
        (await generationB.restore(retained)).providerState,
        established.providerState,
      );
      expect(
        await _gitOutput(sibling, <String>['symbolic-ref', 'HEAD']),
        'refs/heads/branch-b',
      );
    },
  );

  test(
    'repair preflight rejects foreign metadata without loading malformed foreign config',
    () async {
      final fixture = await _createRepository();
      final foreign = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      addTearDown(() => foreign.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-repair-foreign',
        environmentId: 'environment-repair-foreign',
        title: 'Foreign repair metadata',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      final Directory oldRoot = _worktreeRoot(
        fixture.source,
        established.providerState,
      );
      await generationA.close();
      final Directory moved = await fixture.source.rename(
        '${fixture.container.path}/moved',
      );
      final Directory expectedRoot = _worktreeRoot(
        moved,
        established.providerState,
      );
      final Directory foreignCheckout = Directory(
        '${foreign.container.path}/linked',
      );
      await _gitOutput(foreign.source, <String>[
        'worktree',
        'add',
        '-b',
        'foreign-branch',
        foreignCheckout.path,
      ]);
      final String marker = await File(
        '${foreignCheckout.path}/.git',
      ).readAsString();
      final File candidateGitfile = File('${expectedRoot.path}/.git');
      await candidateGitfile.writeAsString(marker);
      final String metadata = await _gitOutput(moved, <String>[
        'rev-parse',
        '--resolve-git-dir',
        candidateGitfile.path,
      ]);
      final String inventory = await _gitInventory(moved);
      final String foreignInventory = await _gitInventory(foreign.source);
      final File foreignConfig = File('${foreign.source.path}/.git/config');
      final String validConfig = await foreignConfig.readAsString();
      final String brokenConfig = '$validConfig\n[invalid section\n';
      await foreignConfig.writeAsString(brokenConfig);
      final ProcessResult foreignProbe = await Process.run('git', <String>[
        '-C',
        foreignCheckout.path,
        'rev-parse',
        '--git-common-dir',
      ]);
      expect(foreignProbe.exitCode, isNot(0));
      expect(
        await _gitOutput(moved, <String>[
          'rev-parse',
          '--resolve-git-dir',
          candidateGitfile.path,
        ]),
        metadata,
      );
      expect(await oldRoot.exists(), isFalse);
      expect(inventory.split('\u0000'), contains('worktree ${oldRoot.path}'));

      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      await expectLater(
        generationB.restore(
          _retainedEnvironment(
            environment,
            established.providerState,
            sourceLocation: moved.uri,
          ),
        ),
        throwsA(_failureWithCode('restore_worktree_mismatch')),
      );
      expect(generationB.liveObjects.length, 0);
      expect(await candidateGitfile.readAsString(), marker);
      expect(await File('${foreignCheckout.path}/.git').readAsString(), marker);
      expect(await foreignConfig.readAsString(), brokenConfig);
      expect(
        await _gitOutput(moved, <String>[
          'rev-parse',
          '--resolve-git-dir',
          candidateGitfile.path,
        ]),
        metadata,
      );
      expect(await _gitInventory(moved), inventory);
      await foreignConfig.writeAsString(validConfig);
      expect(await _gitInventory(foreign.source), foreignInventory);
      expect(
        await _gitOutput(foreignCheckout, <String>['symbolic-ref', 'HEAD']),
        'refs/heads/foreign-branch',
      );
    },
  );

  for (final String replacement in <String>[
    'foreign checkout',
    'checkout symlink',
    'gitfile symlink',
  ]) {
    test(
      'repair preflight preserves another registration reused by a $replacement',
      () async {
        final fixture = await _createRepository();
        final foreign = await _createRepository();
        addTearDown(() => fixture.container.delete(recursive: true));
        addTearDown(() => foreign.container.delete(recursive: true));
        final GitWorktreeEnvironmentProvider generationA =
            GitWorktreeEnvironmentProvider();
        addTearDown(generationA.close);
        final LocalEnvironment environment = _environment(
          fixture.source.uri,
          taskId: 'task-repair-sibling',
          environmentId: 'environment-repair-sibling',
          title: 'Repair sibling',
        );
        final EnvironmentProviderResult established = await generationA
            .establish(environment);
        final Directory oldRoot = _worktreeRoot(
          fixture.source,
          established.providerState,
        );
        final Directory sibling = Directory(
          '${fixture.container.path}/other-registration',
        );
        await _gitOutput(fixture.source, <String>[
          'worktree',
          'add',
          '-b',
          'other-branch',
          sibling.path,
        ]);
        await generationA.close();
        final Directory moved = await fixture.source.rename(
          '${fixture.container.path}/moved',
        );
        final Directory expectedRoot = _worktreeRoot(
          moved,
          established.providerState,
        );
        final File candidateGitfile = File('${expectedRoot.path}/.git');
        final String candidateMarker = await candidateGitfile.readAsString();
        if (replacement != 'gitfile symlink') {
          await sibling.rename('${fixture.container.path}/saved-sibling');
        }
        final Directory foreignCheckout = replacement == 'foreign checkout'
            ? sibling
            : Directory('${foreign.container.path}/linked');
        await _gitOutput(foreign.source, <String>[
          'worktree',
          'add',
          '-b',
          'foreign-branch',
          foreignCheckout.path,
        ]);
        if (replacement == 'checkout symlink') {
          await Link(sibling.path).create(foreignCheckout.path);
        } else if (replacement == 'gitfile symlink') {
          await File('${sibling.path}/.git').delete();
          await Link(
            '${sibling.path}/.git',
          ).create('${foreignCheckout.path}/.git');
        }
        final String foreignMarker = await File(
          '${foreignCheckout.path}/.git',
        ).readAsString();
        final String foreignMetadata = await _gitOutput(moved, <String>[
          'rev-parse',
          '--resolve-git-dir',
          '${foreignCheckout.path}/.git',
        ]);
        final String inventory = await _gitInventory(moved);
        final String foreignInventory = await _gitInventory(foreign.source);
        expect(await oldRoot.exists(), isFalse);
        expect(
          inventory.split('\u0000'),
          containsAll(<String>[
            'worktree ${oldRoot.path}',
            'worktree ${sibling.path}',
          ]),
        );

        final GitWorktreeEnvironmentProvider generationB =
            GitWorktreeEnvironmentProvider();
        addTearDown(generationB.close);
        await expectLater(
          generationB.restore(
            _retainedEnvironment(
              environment,
              established.providerState,
              sourceLocation: moved.uri,
            ),
          ),
          throwsA(_failureWithCode('restore_worktree_mismatch')),
        );
        expect(generationB.liveObjects.length, 0);
        expect(await candidateGitfile.readAsString(), candidateMarker);
        expect(
          await File('${foreignCheckout.path}/.git').readAsString(),
          foreignMarker,
        );
        expect(
          await File('${sibling.path}/.git').readAsString(),
          foreignMarker,
        );
        expect(await _gitInventory(moved), inventory);
        expect(await _gitInventory(foreign.source), foreignInventory);
        expect(
          await _gitOutput(moved, <String>[
            'rev-parse',
            '--resolve-git-dir',
            '${foreignCheckout.path}/.git',
          ]),
          foreignMetadata,
        );
        if (replacement == 'checkout symlink') {
          expect(await Link(sibling.path).target(), foreignCheckout.path);
        } else if (replacement == 'gitfile symlink') {
          expect(
            await Link('${sibling.path}/.git').target(),
            '${foreignCheckout.path}/.git',
          );
        }
      },
    );
  }

  for (final String siblingKind in <String>[
    'branch',
    'detached',
    'ambiguous detached',
  ]) {
    test('repair preflight handles live $siblingKind siblings', () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      await _gitOutput(fixture.source, <String>['checkout', '--detach']);
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-repair-live',
        environmentId: 'environment-repair-live',
        title: 'Repair with live sibling',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      final Directory oldRoot = _worktreeRoot(
        fixture.source,
        established.providerState,
      );
      await generationA.close();
      final Directory moved = await fixture.source.rename(
        '${fixture.container.path}/moved',
      );
      final Directory expectedRoot = _worktreeRoot(
        moved,
        established.providerState,
      );
      final File candidateGitfile = File('${expectedRoot.path}/.git');
      final String candidateMarker = await candidateGitfile.readAsString();
      final Directory sibling = Directory(
        '${fixture.container.path}/live-sibling',
      );
      await _gitOutput(moved, <String>[
        'worktree',
        'add',
        if (siblingKind == 'branch') ...<String>['-b', 'live-sibling'] else
          '--detach',
        sibling.path,
      ]);
      if (siblingKind == 'ambiguous detached') {
        await _gitOutput(moved, <String>[
          'worktree',
          'add',
          '--detach',
          '${fixture.container.path}/duplicate-sibling',
        ]);
      }
      final String siblingMarker = await File(
        '${sibling.path}/.git',
      ).readAsString();
      final String siblingMetadata = await _gitOutput(moved, <String>[
        'rev-parse',
        '--resolve-git-dir',
        '${sibling.path}/.git',
      ]);
      final String inventory = await _gitInventory(moved);
      final String siblingRegistration = inventory
          .split('\u0000\u0000')
          .singleWhere(
            (String entry) =>
                entry.startsWith('worktree ${sibling.path}\u0000'),
          );
      await File(
        '${sibling.path}/README.md',
      ).writeAsString('uncommitted sibling content');
      expect(await oldRoot.exists(), isFalse);
      expect(inventory.split('\u0000'), contains('worktree ${oldRoot.path}'));

      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      final LocalEnvironment retained = _retainedEnvironment(
        environment,
        established.providerState,
        sourceLocation: moved.uri,
      );
      if (siblingKind == 'ambiguous detached') {
        await expectLater(
          generationB.restore(retained),
          throwsA(_failureWithCode('restore_worktree_conflict')),
        );
        expect(generationB.liveObjects.length, 0);
        expect(await _gitInventory(moved), inventory);
        expect(await candidateGitfile.readAsString(), candidateMarker);
      } else {
        expect(
          (await generationB.restore(retained)).providerState,
          established.providerState,
        );
        expect(
          generationB.liveObjects.resolve(environment.id).root.path,
          expectedRoot.path,
        );
        expect(
          (await generationB.readFile(environment.id, 'README.md')).text,
          'fixture source\n',
        );
        final String after = await _gitInventory(moved);
        expect(
          after.split('\u0000'),
          contains('worktree ${expectedRoot.path}'),
        );
        expect(
          after.split('\u0000'),
          isNot(contains('worktree ${oldRoot.path}')),
        );
        expect(after.split('\u0000\u0000'), contains(siblingRegistration));
      }
      expect(await File('${sibling.path}/.git').readAsString(), siblingMarker);
      expect(
        await File('${sibling.path}/README.md').readAsString(),
        'uncommitted sibling content',
      );
      expect(
        await _gitOutput(moved, <String>[
          'rev-parse',
          '--resolve-git-dir',
          '${sibling.path}/.git',
        ]),
        siblingMetadata,
      );
      expect(
        await _gitOutput(sibling, <String>[
          'rev-parse',
          '--symbolic-full-name',
          'HEAD',
        ]),
        siblingKind == 'branch' ? 'refs/heads/live-sibling' : 'HEAD',
      );
    });
  }

  test(
    'rejects a copied repository while the old registered worktree exists',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-copy',
        environmentId: 'environment-copy',
        title: 'Copy conflict',
      );
      final EnvironmentProviderResult established = await generationA.establish(
        environment,
      );
      final Directory original = _worktreeRoot(
        fixture.source,
        established.providerState,
      );
      await generationA.close();
      final Directory copiedSource = Directory(
        '${fixture.container.path}/copied-source',
      );
      await _copyDirectory(fixture.source, copiedSource);
      final Directory copied = _worktreeRoot(
        copiedSource,
        established.providerState,
      );
      final String inventory = await _gitOutput(copiedSource, <String>[
        'worktree',
        'list',
        '--porcelain',
        '-z',
      ]);
      expect(inventory.split('\u0000'), contains('worktree ${original.path}'));
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      await expectLater(
        generationB.restore(
          _retainedEnvironment(
            environment,
            established.providerState,
            sourceLocation: copiedSource.uri,
          ),
        ),
        throwsA(_failureWithCode('restore_worktree_conflict')),
      );
      expect(generationB.liveObjects.length, 0);
      expect(await original.exists(), isTrue);
      expect(await copied.exists(), isTrue);
      expect(
        await File('${copied.path}/.git').readAsString(),
        await File('${original.path}/.git').readAsString(),
      );
      expect(
        await _gitOutput(copiedSource, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]),
        inventory,
      );
    },
  );

  for (final String component in <String>['.adele', '.adele/worktrees']) {
    for (final String kind in <String>[
      'internal symlink',
      'escaping symlink',
      'file',
    ]) {
      test('creation rejects $kind at storage $component', () async {
        final fixture = await _createRepository();
        addTearDown(() => fixture.container.delete(recursive: true));
        final String path = '${fixture.source.path}/$component';
        await Directory(path).parent.create(recursive: true);
        final Directory target = Directory(
          kind == 'internal symlink'
              ? '${fixture.source.path}/redirected-storage'
              : '${fixture.container.path}/outside-storage',
        );
        await target.create();
        if (kind == 'file') {
          await File(path).writeAsString('do not replace');
        } else {
          await Link(path).create(target.path);
        }
        final List<String> branches = await _branchNames(fixture.source);
        final GitWorktreeEnvironmentProvider provider =
            GitWorktreeEnvironmentProvider();
        addTearDown(provider.close);
        await expectLater(
          provider.establish(
            _environment(
              fixture.source.uri,
              taskId: 'task-storage',
              environmentId: 'environment-storage',
              title: 'Storage confinement',
            ),
          ),
          throwsA(_failureWithCode('invalid_worktree_storage')),
        );
        expect(provider.liveObjects.length, 0);
        expect(await _branchNames(fixture.source), branches);
        expect(await target.list().toList(), isEmpty);
        if (kind == 'file') {
          expect(await File(path).readAsString(), 'do not replace');
        }
      });
    }
  }

  for (final String component in <String>[
    '.adele',
    '.adele/worktrees',
    'root',
  ]) {
    for (final String kind in <String>[
      'internal symlink',
      'escaping symlink',
      'file',
    ]) {
      test('restore rejects $kind at storage $component', () async {
        final fixture = await _createRepository();
        addTearDown(() => fixture.container.delete(recursive: true));
        final GitWorktreeEnvironmentProvider generationA =
            GitWorktreeEnvironmentProvider();
        addTearDown(generationA.close);
        final LocalEnvironment environment = _environment(
          fixture.source.uri,
          taskId: 'task-storage',
          environmentId: 'environment-storage',
          title: 'Storage confinement',
        );
        final EnvironmentProviderResult established = await generationA
            .establish(environment);
        await generationA.close();
        final Directory storage = component == 'root'
            ? _worktreeRoot(fixture.source, established.providerState)
            : Directory('${fixture.source.path}/$component');
        final Directory target = await storage.rename(
          kind == 'internal symlink'
              ? '${fixture.source.path}/redirected-storage'
              : '${fixture.container.path}/outside-storage',
        );
        if (kind == 'file') {
          await File(storage.path).writeAsString('do not replace');
        } else {
          await Link(storage.path).create(target.path);
        }
        final String inventory = await _gitOutput(fixture.source, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]);
        final GitWorktreeEnvironmentProvider generationB =
            GitWorktreeEnvironmentProvider();
        addTearDown(generationB.close);
        await expectLater(
          generationB.restore(
            _retainedEnvironment(environment, established.providerState),
          ),
          throwsA(_failureWithCode('invalid_worktree_storage')),
        );
        expect(generationB.liveObjects.length, 0);
        expect(await target.exists(), isTrue);
        expect(
          await _gitOutput(fixture.source, <String>[
            'worktree',
            'list',
            '--porcelain',
            '-z',
          ]),
          inventory,
        );
        if (kind == 'file') {
          expect(await File(storage.path).readAsString(), 'do not replace');
        }
      });
    }
  }

  test(
    'creation skips a symbolic-link worktree name without following it',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final GitWorktreeEnvironmentProvider generationA =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationA.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-root-alias',
        environmentId: 'environment-root-alias',
        title: 'Root alias',
      );
      final EnvironmentProviderResult first = await generationA.establish(
        environment,
      );
      await generationA.close();
      final Directory root = _worktreeRoot(fixture.source, first.providerState);
      await _gitOutput(fixture.source, <String>[
        'worktree',
        'remove',
        root.path,
      ]);
      await _gitOutput(fixture.source, <String>[
        'branch',
        '-D',
        first.providerState['branch']! as String,
      ]);
      final Directory outside = Directory('${fixture.container.path}/outside')
        ..createSync();
      await Link(root.path).create(outside.path);
      final GitWorktreeEnvironmentProvider generationB =
          GitWorktreeEnvironmentProvider();
      addTearDown(generationB.close);
      final EnvironmentProviderResult second = await generationB.establish(
        environment,
      );
      expect(
        _worktreeRoot(fixture.source, second.providerState).path,
        '${root.path}-2',
      );
      expect(
        await FileSystemEntity.type(root.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(await outside.list().toList(), isEmpty);
    },
  );

  test(
    'uses a flat branch and removes its branch after checkout failure',
    () async {
      final ({Directory container, Directory source}) fixture =
          await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      await File(
        '${fixture.source.path}/.gitattributes',
      ).writeAsString('required.txt filter=adele-required\n');
      await File(
        '${fixture.source.path}/required.txt',
      ).writeAsString('filtered content\n');
      await _gitOutput(fixture.source, <String>['add', '.']);
      await _gitOutput(fixture.source, <String>[
        'commit',
        '-m',
        'Add required filter fixture',
      ]);
      await _gitOutput(fixture.source, <String>['branch', 'adele', 'HEAD']);
      await _gitOutput(fixture.source, <String>[
        'config',
        'filter.adele-required.clean',
        'cat',
      ]);
      await _gitOutput(fixture.source, <String>[
        'config',
        'filter.adele-required.smudge',
        'false',
      ]);
      await _gitOutput(fixture.source, <String>[
        'config',
        'filter.adele-required.required',
        'true',
      ]);
      final GitWorktreeEnvironmentProvider provider =
          GitWorktreeEnvironmentProvider();
      addTearDown(provider.close);
      final LocalEnvironment environment = _environment(
        fixture.source.uri,
        taskId: 'task-checkout-failure',
        environmentId: 'environment-checkout-failure',
        title: 'Checkout Failure',
      );

      await expectLater(
        provider.establish(environment),
        throwsA(_failureWithCode('worktree_establishment_failed')),
      );
      final List<String> afterFailure = await _branchNames(fixture.source);
      expect(afterFailure, contains('adele'));
      expect(
        afterFailure.where(
          (String branch) => branch.startsWith('adele-checkout-failure-'),
        ),
        isEmpty,
      );

      await _gitOutput(fixture.source, <String>[
        'config',
        'filter.adele-required.smudge',
        'cat',
      ]);
      await provider.establish(environment);
      final WorktreeEnvironment live = provider.liveObjects.resolve(
        environment.id,
      );
      final String branch = await _gitOutput(live.root, <String>[
        'branch',
        '--show-current',
      ]);
      expect(branch, startsWith('adele-checkout-failure-'));
      expect(await _branchNames(fixture.source), contains('adele'));
      expect(
        (await provider.readFile(environment.id, 'required.txt')).text,
        contains('filtered content'),
      );
    },
  );

  test('rejects unsupported and unusable Project sources clearly', () async {
    final Directory nonGit = await Directory.systemTemp.createTemp(
      'adele-git-environment-non-git-',
    );
    addTearDown(() => nonGit.delete(recursive: true));
    final GitWorktreeEnvironmentProvider provider =
        GitWorktreeEnvironmentProvider();
    addTearDown(provider.close);

    await expectLater(
      provider.establish(
        _environment(
          const _RelativeFileUri(),
          taskId: 'task-relative-file',
          environmentId: 'environment-relative-file',
          title: 'Relative file source',
        ),
      ),
      throwsA(_failureWithCode('invalid_source_uri')),
    );
    await expectLater(
      provider.establish(
        _environment(
          Uri.parse('https://example.com/repository.git'),
          taskId: 'task-https',
          environmentId: 'environment-https',
          title: 'Remote source',
        ),
      ),
      throwsA(_failureWithCode('unsupported_source_scheme')),
    );
    await expectLater(
      provider.establish(
        _environment(
          nonGit.uri,
          taskId: 'task-non-git',
          environmentId: 'environment-non-git',
          title: 'Non Git source',
        ),
      ),
      throwsA(_failureWithCode('invalid_git_source')),
    );
  });

  test('serves bounded confined file and directory reads', () async {
    final ({Directory container, Directory source}) fixture =
        await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final GitWorktreeEnvironmentProvider provider =
        GitWorktreeEnvironmentProvider();
    addTearDown(provider.close);
    final LocalEnvironment environment = _environment(
      fixture.source.uri,
      taskId: 'task-filesystem',
      environmentId: 'environment-filesystem',
      title: 'Filesystem checks',
    );
    await provider.establish(environment);
    final Directory root = provider.liveObjects.resolve(environment.id).root;
    await File('${root.path}/zeta.txt').writeAsString('zeta');
    await File('${root.path}/alpha.txt').writeAsString('alpha');
    await Directory('${root.path}/nested').create();
    await File('${root.path}/nested/inside.txt').writeAsString('inside');
    await Link(
      '${root.path}/inside-link.txt',
    ).create('${root.path}/nested/inside.txt');
    final File outside = File('${fixture.container.path}/outside.txt');
    await outside.writeAsString('outside');
    await Link('${root.path}/outside-link.txt').create(outside.path);
    final Directory outsideDirectory = Directory(
      '${fixture.container.path}/outside-directory',
    );
    await outsideDirectory.create();
    await Link(
      '${root.path}/outside-directory-link',
    ).create(outsideDirectory.path);
    await File('${root.path}/invalid.bin').writeAsBytes(<int>[0xff]);
    await File(
      '${root.path}/large.txt',
    ).writeAsBytes(List<int>.filled(maximumEnvironmentFileBytes + 1, 0x61));
    if (!Platform.isWindows) {
      await File(
        '${root.path}/literal\\name.txt',
      ).writeAsString('literal backslash');
      await File('${root.path}/C:notes.txt').writeAsString('drive-shaped name');
    }

    expect(
      (await provider.readFile(environment.id, 'nested/./inside.txt')).text,
      'inside',
    );
    await expectLater(
      provider.readFile(environment.id, 'inside-link.txt'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    await expectLater(
      provider.readFile(environment.id, '../outside.txt'),
      throwsA(_failureWithCode('invalid_path')),
    );
    await expectLater(
      provider.readFile(environment.id, outside.absolute.path),
      throwsA(_failureWithCode('invalid_path')),
    );
    await expectLater(
      provider.readFile(environment.id, 'outside-link.txt'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    await expectLater(
      provider.readDirectory(environment.id, 'outside-directory-link'),
      throwsA(_failureWithCode('outside_root')),
    );
    await expectLater(
      provider.readFile(environment.id, 'invalid.bin'),
      throwsA(_failureWithCode('invalid_utf8')),
    );
    await expectLater(
      provider.readFile(environment.id, 'large.txt'),
      throwsA(_failureWithCode('file_too_large')),
    );

    final EnvironmentDirectoryListing listing = await provider.readDirectory(
      environment.id,
      '',
    );
    final List<String> names = listing.entries
        .map((EnvironmentDirectoryEntry entry) => entry.name)
        .toList();
    expect(names, orderedEquals(<String>[...names]..sort()));
    expect(
      listing.entries
          .singleWhere(
            (EnvironmentDirectoryEntry entry) => entry.name == 'nested',
          )
          .kind,
      EnvironmentDirectoryEntryKind.directory,
    );
    expect(
      listing.entries
          .singleWhere(
            (EnvironmentDirectoryEntry entry) =>
                entry.name == 'inside-link.txt',
          )
          .kind,
      EnvironmentDirectoryEntryKind.other,
    );
    if (!Platform.isWindows) {
      final EnvironmentDirectoryEntry backslashEntry = listing.entries
          .singleWhere(
            (EnvironmentDirectoryEntry entry) =>
                entry.name == 'literal\\name.txt',
          );
      expect(backslashEntry.relativePath, 'literal\\name.txt');
      expect(
        (await provider.readFile(
          environment.id,
          backslashEntry.relativePath,
        )).text,
        'literal backslash',
      );
      final EnvironmentDirectoryEntry driveShapedEntry = listing.entries
          .singleWhere(
            (EnvironmentDirectoryEntry entry) => entry.name == 'C:notes.txt',
          );
      expect(driveShapedEntry.relativePath, 'C:notes.txt');
      expect(
        (await provider.readFile(
          environment.id,
          driveShapedEntry.relativePath,
        )).text,
        'drive-shaped name',
      );
    }

    final Directory many = Directory('${root.path}/many');
    await many.create();
    for (int index = 0; index <= maximumEnvironmentDirectoryEntries; index++) {
      await File('${many.path}/$index').writeAsString('');
    }
    await expectLater(
      provider.readDirectory(environment.id, 'many'),
      throwsA(_failureWithCode('directory_too_large')),
    );
  });

  test('conditionally replaces existing text files by revision', () async {
    final ({Directory container, Directory source}) fixture =
        await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final GitWorktreeEnvironmentProvider provider =
        GitWorktreeEnvironmentProvider();
    addTearDown(provider.close);
    final LocalEnvironment environment = _environment(
      fixture.source.uri,
      taskId: 'task-conditional-replacement',
      environmentId: 'environment-conditional-replacement',
      title: 'Conditional replacement',
    );
    await provider.establish(environment);
    final Directory root = provider.liveObjects.resolve(environment.id).root;

    final EnvironmentTextFile first = await provider.readFile(
      environment.id,
      'README.md',
    );
    final EnvironmentTextFileReplacement replaced = await provider
        .replaceExistingTextFile(
          environment.id,
          'README.md',
          'replacement\n',
          first.revision,
        );
    final EnvironmentTextFile second = await provider.readFile(
      environment.id,
      'README.md',
    );
    expect(second.text, 'replacement\n');
    expect(replaced.revision, second.revision);
    expect(second.revision, isNot(first.revision));

    await File('${root.path}/README.md').writeAsString('external change\n');
    await expectLater(
      provider.replaceExistingTextFile(
        environment.id,
        'README.md',
        'stale replacement\n',
        second.revision,
      ),
      throwsA(_failureWithCode('revision_conflict')),
    );
    expect(
      await File('${root.path}/README.md').readAsString(),
      'external change\n',
    );
  });

  test('creates new bounded UTF-8 files under existing directories', () async {
    final ({Directory container, Directory source}) fixture =
        await _createRepository();
    addTearDown(() => fixture.container.delete(recursive: true));
    final GitWorktreeEnvironmentProvider provider =
        GitWorktreeEnvironmentProvider();
    addTearDown(provider.close);
    final LocalEnvironment environment = _environment(
      fixture.source.uri,
      taskId: 'task-create-file',
      environmentId: 'environment-create-file',
      title: 'Create files',
    );
    await provider.establish(environment);
    final Directory root = provider.liveObjects.resolve(environment.id).root;

    final EnvironmentTextFileCreation creation = await provider.createTextFile(
      environment.id,
      'lib/new-file.txt',
      'created \u{1f642}\n',
    );
    final EnvironmentTextFile created = await provider.readFile(
      environment.id,
      'lib/new-file.txt',
    );
    final EnvironmentTextFileCreation emptyCreation = await provider
        .createTextFile(environment.id, 'lib/empty.txt', '');
    final EnvironmentTextFile empty = await provider.readFile(
      environment.id,
      'lib/empty.txt',
    );

    expect(created.text, 'created \u{1f642}\n');
    expect(created.sizeBytes, 13);
    expect(created.revision, creation.revision);
    expect(empty.text, isEmpty);
    expect(empty.sizeBytes, 0);
    expect(empty.revision, emptyCreation.revision);
    expect(
      await root
          .list(recursive: true)
          .where(
            (FileSystemEntity entity) =>
                _entityName(entity.path).startsWith('.adele-creation-'),
          )
          .toList(),
      isEmpty,
    );
  });

  test('create never replaces existing or indirect paths', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-create-guards-',
    );
    addTearDown(() => container.delete(recursive: true));
    final Directory root = Directory('${container.path}/root');
    await root.create();
    final File existing = File('${root.path}/existing.txt');
    await existing.writeAsString('existing');
    final Directory existingDirectory = Directory('${root.path}/directory');
    await existingDirectory.create();
    final File parentFile = File('${root.path}/parent-file');
    await parentFile.writeAsString('parent');
    final File outside = File('${container.path}/outside.txt');
    await outside.writeAsString('outside');
    final Link terminalAlias = Link('${root.path}/terminal-alias.txt');
    await terminalAlias.create(outside.path);
    final Directory realDirectory = Directory('${root.path}/real-directory');
    await realDirectory.create();
    final Link parentAlias = Link('${root.path}/parent-alias');
    await parentAlias.create(realDirectory.path);
    final WorktreeEnvironment environment = WorktreeEnvironment(root);

    await expectLater(
      environment.createTextFile('existing.txt', 'replacement'),
      throwsA(_failureWithCode(environmentFileAlreadyExistsCode)),
    );
    await expectLater(
      environment.createTextFile('directory', 'replacement'),
      throwsA(_failureWithCode(environmentFileAlreadyExistsCode)),
    );
    await expectLater(
      environment.createTextFile('terminal-alias.txt', 'replacement'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    await expectLater(
      environment.createTextFile('missing/new.txt', 'created'),
      throwsA(_failureWithCode('not_found')),
    );
    await expectLater(
      environment.createTextFile('parent-file/new.txt', 'created'),
      throwsA(_failureWithCode('not_directory')),
    );
    await expectLater(
      environment.createTextFile('parent-alias/new.txt', 'created'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    await expectLater(
      environment.createTextFile('../outside.txt', 'escaped'),
      throwsA(_failureWithCode('invalid_path')),
    );
    await expectLater(
      environment.createTextFile(
        'oversized.txt',
        'a' * (maximumEnvironmentFileBytes + 1),
      ),
      throwsA(_failureWithCode('file_too_large')),
    );

    expect(await existing.readAsString(), 'existing');
    expect(await outside.readAsString(), 'outside');
    expect(await Directory('${root.path}/missing').exists(), isFalse);
    expect(await File('${root.path}/oversized.txt').exists(), isFalse);
    expect(
      await FileSystemEntity.type(terminalAlias.path, followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test('serializes duplicate create without allowing overwrite', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-create-concurrency-',
    );
    addTearDown(() => root.delete(recursive: true));
    final WorktreeEnvironment environment = WorktreeEnvironment(root);

    final List<Object> outcomes = await Future.wait<Object>(<Future<Object>>[
      environment
          .createTextFile('target.txt', 'creation A')
          .then<Object>((EnvironmentTextFileCreation value) => value)
          .catchError((Object error) => error),
      environment
          .createTextFile('target.txt', 'creation B')
          .then<Object>((EnvironmentTextFileCreation value) => value)
          .catchError((Object error) => error),
    ]);

    expect(outcomes.whereType<EnvironmentTextFileCreation>(), hasLength(1));
    expect(
      outcomes.whereType<EnvironmentFailure>().single.code,
      environmentFileAlreadyExistsCode,
    );
    expect(
      await File('${root.path}/target.txt').readAsString(),
      anyOf('creation A', 'creation B'),
    );
  });

  test('conditionally deletes only direct current UTF-8 files', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-delete-',
    );
    addTearDown(() => container.delete(recursive: true));
    final Directory root = Directory('${container.path}/root');
    await root.create();
    final WorktreeEnvironment environment = WorktreeEnvironment(root);
    final File deleted = File('${root.path}/deleted.txt');
    await deleted.writeAsString('delete me');
    final String deletedRevision = (await environment.readFile(
      'deleted.txt',
    )).revision;

    await environment.deleteExistingTextFile('deleted.txt', deletedRevision);

    expect(await deleted.exists(), isFalse);
    await expectLater(
      environment.readFile('deleted.txt'),
      throwsA(_failureWithCode('not_found')),
    );

    final File stale = File('${root.path}/stale.txt');
    await stale.writeAsString('observed');
    final String staleRevision = (await environment.readFile(
      'stale.txt',
    )).revision;
    await stale.writeAsString('external change');
    await expectLater(
      environment.deleteExistingTextFile('stale.txt', staleRevision),
      throwsA(_failureWithCode(environmentRevisionConflictCode)),
    );
    expect(await stale.readAsString(), 'external change');

    final Directory directory = Directory('${root.path}/directory');
    await directory.create();
    await expectLater(
      environment.deleteExistingTextFile('directory', 'opaque'),
      throwsA(_failureWithCode('not_regular_file')),
    );
    await expectLater(
      environment.deleteExistingTextFile('missing.txt', 'opaque'),
      throwsA(_failureWithCode('not_found')),
    );

    final File aliasTarget = File('${root.path}/alias-target.txt');
    await aliasTarget.writeAsString('alias target');
    final Link alias = Link('${root.path}/alias.txt');
    await alias.create(aliasTarget.path);
    await expectLater(
      environment.deleteExistingTextFile('alias.txt', 'opaque'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    expect(await aliasTarget.readAsString(), 'alias target');
    expect(
      await FileSystemEntity.type(alias.path, followLinks: false),
      FileSystemEntityType.link,
    );

    final Directory realDirectory = Directory('${root.path}/real-directory');
    await realDirectory.create();
    final File nestedTarget = File('${realDirectory.path}/target.txt');
    await nestedTarget.writeAsString('nested target');
    final Link parentAlias = Link('${root.path}/parent-alias');
    await parentAlias.create(realDirectory.path);
    await expectLater(
      environment.deleteExistingTextFile('parent-alias/target.txt', 'opaque'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    expect(await nestedTarget.readAsString(), 'nested target');

    final File oversized = File('${root.path}/oversized.txt');
    await oversized.writeAsBytes(
      List<int>.filled(maximumEnvironmentFileBytes + 1, 0x61),
    );
    await expectLater(
      environment.deleteExistingTextFile('oversized.txt', 'opaque'),
      throwsA(_failureWithCode('file_too_large')),
    );
    expect(await oversized.exists(), isTrue);
    await expectLater(
      environment.deleteExistingTextFile('../outside.txt', 'opaque'),
      throwsA(_failureWithCode('invalid_path')),
    );
  });

  test('serializes duplicate and cross-kind mutations', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-mutation-coordination-',
    );
    addTearDown(() => root.delete(recursive: true));
    final WorktreeEnvironment environment = WorktreeEnvironment(root);
    final File duplicateDelete = File('${root.path}/duplicate-delete.txt');
    await duplicateDelete.writeAsString('delete once');
    final String deleteRevision = (await environment.readFile(
      'duplicate-delete.txt',
    )).revision;

    final List<Object?> deleteOutcomes =
        await Future.wait<Object?>(<Future<Object?>>[
          environment
              .deleteExistingTextFile('duplicate-delete.txt', deleteRevision)
              .then<Object?>((_) => null)
              .catchError((Object error) => error),
          environment
              .deleteExistingTextFile('duplicate-delete.txt', deleteRevision)
              .then<Object?>((_) => null)
              .catchError((Object error) => error),
        ]);
    expect(
      deleteOutcomes.where((Object? value) => value == null),
      hasLength(1),
    );
    expect(
      deleteOutcomes.whereType<EnvironmentFailure>().single.code,
      'not_found',
    );

    const String emptyRevision =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    final Future<EnvironmentTextFileCreation> create = environment
        .createTextFile('create-delete.txt', '');
    final Future<void> delete = environment.deleteExistingTextFile(
      'create-delete.txt',
      emptyRevision,
    );
    await create;
    await delete;
    expect(await File('${root.path}/create-delete.txt').exists(), isFalse);

    final File replaceDelete = File('${root.path}/replace-delete.txt');
    await replaceDelete.writeAsString('initial');
    final String replacementRevision = (await environment.readFile(
      'replace-delete.txt',
    )).revision;
    final Future<EnvironmentTextFileReplacement> replacement = environment
        .replaceExistingTextFile(
          'replace-delete.txt',
          'replacement',
          replacementRevision,
        );
    final Future<void> staleDelete = environment.deleteExistingTextFile(
      'replace-delete.txt',
      replacementRevision,
    );
    await replacement;
    await expectLater(
      staleDelete,
      throwsA(_failureWithCode(environmentRevisionConflictCode)),
    );
    expect(await replaceDelete.readAsString(), 'replacement');
  });

  test('serializes concurrent conditional replacements', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-concurrency-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File file = File('${root.path}/target.txt');
    await file.writeAsString('initial');
    final WorktreeEnvironment environment = WorktreeEnvironment(root);
    final String revision = (await environment.readFile('target.txt')).revision;

    final List<Object> outcomes = await Future.wait<Object>(<Future<Object>>[
      environment
          .replaceExistingTextFile('target.txt', 'replacement A', revision)
          .then<Object>((EnvironmentTextFileReplacement value) => value)
          .catchError((Object error) => error),
      environment
          .replaceExistingTextFile('target.txt', 'replacement B', revision)
          .then<Object>((EnvironmentTextFileReplacement value) => value)
          .catchError((Object error) => error),
    ]);

    expect(outcomes.whereType<EnvironmentTextFileReplacement>(), hasLength(1));
    expect(
      outcomes.whereType<EnvironmentFailure>().single.code,
      'revision_conflict',
    );
    final String finalText = await file.readAsString();
    expect(finalText, anyOf('replacement A', 'replacement B'));
    final EnvironmentTextFileReplacement winner = outcomes
        .whereType<EnvironmentTextFileReplacement>()
        .single;
    expect(
      (await environment.readFile('target.txt')).revision,
      winner.revision,
    );
  });

  test('rejects terminal symbolic-link file aliases', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-terminal-alias-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File file = File('${root.path}/target.txt');
    await file.writeAsString('initial');
    final Link alias = Link('${root.path}/target-alias.txt');
    await alias.create(file.path);
    final WorktreeEnvironment environment = WorktreeEnvironment(root);
    final String revision = (await environment.readFile('target.txt')).revision;

    await expectLater(
      environment.readFile('target-alias.txt'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    await expectLater(
      environment.replaceExistingTextFile(
        'target-alias.txt',
        'replacement',
        revision,
      ),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    expect(await file.readAsString(), 'initial');
    expect(
      await FileSystemEntity.type(alias.path, followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test('rejects symbolic-link parent aliases', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-parent-alias-',
    );
    addTearDown(() => root.delete(recursive: true));
    final Directory realDirectory = Directory('${root.path}/real-directory');
    await realDirectory.create();
    final File file = File('${realDirectory.path}/target.txt');
    await file.writeAsString('initial');
    final Link aliasDirectory = Link('${root.path}/alias-directory');
    await aliasDirectory.create(realDirectory.path);
    final WorktreeEnvironment environment = WorktreeEnvironment(root);
    final String revision = (await environment.readFile(
      'real-directory/target.txt',
    )).revision;

    await expectLater(
      environment.readFile('alias-directory/target.txt'),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    await expectLater(
      environment.replaceExistingTextFile(
        'alias-directory/target.txt',
        'replacement',
        revision,
      ),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    expect(await file.readAsString(), 'initial');
    expect(
      await FileSystemEntity.type(aliasDirectory.path, followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test(
    'staged replacement preserves POSIX file permissions',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'adele-worktree-environment-permissions-',
      );
      addTearDown(() => root.delete(recursive: true));
      final File file = File('${root.path}/executable.sh');
      await file.writeAsString('#!/bin/sh\nexit 0\n');
      final int permissions = int.parse('751', radix: 8);
      final ProcessResult chmod = await Process.run('chmod', <String>[
        permissions.toRadixString(8),
        file.path,
      ]);
      expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
      final WorktreeEnvironment environment = WorktreeEnvironment(root);
      final String revision = (await environment.readFile(
        'executable.sh',
      )).revision;

      await environment.replaceExistingTextFile(
        'executable.sh',
        '#!/bin/sh\nexit 1\n',
        revision,
      );

      expect((await file.stat()).mode & 0x1ff, permissions);
      expect(await file.readAsString(), '#!/bin/sh\nexit 1\n');
      expect(
        await root
            .list()
            .where(
              (FileSystemEntity entity) =>
                  _entityName(entity.path).startsWith('.adele-replacement-'),
            )
            .toList(),
        isEmpty,
      );
    },
    skip: Platform.isWindows
        ? 'Windows does not expose POSIX permission bits.'
        : false,
  );

  test('confines and bounds conditional replacement', () async {
    final Directory container = await Directory.systemTemp.createTemp(
      'adele-worktree-environment-mutation-',
    );
    addTearDown(() => container.delete(recursive: true));
    final Directory root = Directory('${container.path}/root');
    await root.create();
    final File target = File('${root.path}/target.txt');
    await target.writeAsString('inside');
    final File outside = File('${container.path}/outside.txt');
    await outside.writeAsString('outside');
    await Link('${root.path}/outside-link.txt').create(outside.path);
    final WorktreeEnvironment environment = WorktreeEnvironment(root);
    final String revision = (await environment.readFile('target.txt')).revision;

    await expectLater(
      environment.replaceExistingTextFile(
        '../outside.txt',
        'escaped',
        revision,
      ),
      throwsA(_failureWithCode('invalid_path')),
    );
    await expectLater(
      environment.replaceExistingTextFile(
        'outside-link.txt',
        'escaped',
        'opaque',
      ),
      throwsA(_failureWithCode('path_alias_unsupported')),
    );
    await expectLater(
      environment.replaceExistingTextFile('missing.txt', 'created', 'opaque'),
      throwsA(_failureWithCode('not_found')),
    );
    await expectLater(
      environment.replaceExistingTextFile(
        'target.txt',
        'a' * (maximumEnvironmentFileBytes + 1),
        revision,
      ),
      throwsA(_failureWithCode('file_too_large')),
    );

    expect(await outside.readAsString(), 'outside');
    expect(await target.readAsString(), 'inside');
    expect(await File('${root.path}/missing.txt').exists(), isFalse);
  });

  test(
    'streams direct argv stdout stderr ordering and nonzero exits',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();

      final List<EnvironmentProcessEvent> stdoutEvents = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['stdout']),
          )
          .toList();
      final List<EnvironmentProcessOutput> stdoutOutput = _outputs(
        stdoutEvents,
      );
      expect(
        stdoutOutput
            .where(
              (EnvironmentProcessOutput output) =>
                  output.stream == EnvironmentProcessOutputStream.stdout,
            )
            .map((EnvironmentProcessOutput output) => output.text)
            .join(),
        'stdout-one|stdout-two',
      );
      expect(stdoutOutput, hasLength(greaterThanOrEqualTo(2)));
      expect(stdoutEvents.last.kind, EnvironmentProcessEventKind.completed);
      expect(_completion(stdoutEvents).exitCode, 0);

      final List<EnvironmentProcessEvent> interleaved = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['interleaved']),
          )
          .toList();
      expect(
        _outputs(interleaved).map(
          (EnvironmentProcessOutput output) =>
              '${output.stream.name}:${output.text}',
        ),
        <String>[
          'stdout:out-one|',
          'stderr:err-one|',
          'stdout:out-two|',
          'stderr:err-two',
        ],
      );

      const String literal = r'spaces ; $(not-run) * [literal]';
      final List<EnvironmentProcessEvent> literalEvents = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['literal', literal]),
          )
          .toList();
      expect(_outputText(literalEvents).trim(), literal);

      final List<EnvironmentProcessEvent> nonzero = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['exit', '23']),
          )
          .toList();
      expect(
        _completion(nonzero).termination,
        EnvironmentProcessTermination.exited,
      );
      expect(_completion(nonzero).exitCode, 23);

      await expectLater(
        fixture.provider.runForegroundProcess(
          fixture.environment.id,
          EnvironmentForegroundProcessRequest(
            program: 'adele-executable-that-does-not-exist',
            arguments: const <String>[],
            relativeWorkingDirectory: '',
            timeoutSeconds: 5,
          ),
        ),
        emitsError(_failureWithCode('process_executable_not_found')),
      );
      final File notExecutable = File(
        '${fixture.container.path}/not-executable',
      );
      await notExecutable.writeAsString('#!/bin/sh\nexit 0\n');
      await expectLater(
        fixture.provider.runForegroundProcess(
          fixture.environment.id,
          EnvironmentForegroundProcessRequest(
            program: notExecutable.path,
            arguments: const <String>[],
            relativeWorkingDirectory: '',
            timeoutSeconds: 5,
          ),
        ),
        emitsError(_failureWithCode('process_start_failed')),
      );
    },
    skip: !Platform.isLinux ? 'Foreground execution is Linux-only.' : false,
  );

  test(
    'uses effective executable access instead of aggregate mode bits',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();
      final File ownerDenied = File(
        '${fixture.container.path}/owner-denied-executable',
      );
      await ownerDenied.writeAsString('#!/bin/sh\nprintf unexpected\n');
      final ProcessResult chmod = await Process.run('chmod', <String>[
        '001',
        ownerDenied.path,
      ]);
      expect(chmod.exitCode, 0, reason: chmod.stderr.toString());

      await expectLater(
        fixture.provider.runForegroundProcess(
          fixture.environment.id,
          EnvironmentForegroundProcessRequest(
            program: ownerDenied.path,
            arguments: const <String>[],
            relativeWorkingDirectory: '',
            timeoutSeconds: 5,
          ),
        ),
        emitsError(_failureWithCode('process_start_failed')),
      );

      final List<EnvironmentProcessEvent> executable = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['stdout']),
          )
          .toList();
      expect(_completion(executable).exitCode, 0);
    },
    skip: !Platform.isLinux
        ? 'Foreground execution is Linux-only.'
        : _runningAsRoot
        ? 'Root effective-execute semantics differ.'
        : false,
  );

  test(
    'confines root nested and symbolic-link process working directories',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();
      final Directory root = fixture.provider.liveObjects
          .resolve(fixture.environment.id)
          .root;
      final Directory nested = Directory('${root.path}/nested-process')
        ..createSync();
      final Link insideAlias = Link('${root.path}/inside-directory-link')
        ..createSync(nested.path);
      final Directory outside = Directory(
        '${fixture.container.path}/outside-process',
      )..createSync();
      final Link outsideAlias = Link('${root.path}/outside-directory-link')
        ..createSync(outside.path);

      Future<String> cwd(String relativeWorkingDirectory) async => _outputText(
        await fixture.provider
            .runForegroundProcess(
              fixture.environment.id,
              fixture.request(<String>[
                'cwd',
              ], relativeWorkingDirectory: relativeWorkingDirectory),
            )
            .toList(),
      ).trim();

      expect(await cwd(''), root.path);
      expect(await cwd('./nested-process//'), nested.path);
      expect(await cwd('inside-directory-link'), nested.path);

      final File marker = File('${fixture.container.path}/spawned.txt');
      for (final ({String path, String code}) invalid
          in <({String path, String code})>[
            (path: '..', code: 'invalid_path'),
            (path: root.absolute.path, code: 'invalid_path'),
            (path: 'outside-directory-link', code: 'outside_root'),
          ]) {
        await expectLater(
          fixture.provider.runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>[
              'spawn-marker',
              marker.path,
            ], relativeWorkingDirectory: invalid.path),
          ),
          emitsError(_failureWithCode(invalid.code)),
        );
      }
      expect(await marker.exists(), isFalse);
      expect(await insideAlias.exists(), isTrue);
      expect(await outsideAlias.exists(), isTrue);
    },
    skip: !Platform.isLinux ? 'Foreground execution is Linux-only.' : false,
  );

  test(
    'times out and terminates the owned process tree',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();

      // A native fixture avoids spending the one-second execution timeout on
      // Dart JIT startup. The leader reaps its child after the group receives TERM.
      final List<EnvironmentProcessEvent> events = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            EnvironmentForegroundProcessRequest(
              program: '/bin/sh',
              arguments: [
                '-c',
                r'''sleep 300 & child=$!; trap 'wait "$child"; exit 0' TERM; printf 'owned:%s:%s\n' "$$" "$child"; wait "$child"''',
              ],
              relativeWorkingDirectory: '',
              timeoutSeconds: 1,
            ),
          )
          .toList();

      final match = RegExp(
        r'owned:(\d+):(\d+)\n',
      ).firstMatch(_outputText(events));
      expect(match, isNotNull);
      final pids = [int.parse(match![1]!), int.parse(match[2]!)];
      addTearDown(() {
        for (final pid in pids) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      });
      expect(
        _completion(events).termination,
        EnvironmentProcessTermination.timedOut,
      );
      expect(_completion(events).exitCode, isNull);
      for (final pid in pids) {
        expect(await Directory('/proc/$pid').exists(), isFalse);
      }
      pids.clear();
    },
    skip: !Platform.isLinux ? 'Foreground execution is Linux-only.' : false,
  );

  test(
    'stream cancellation terminates the owned process tree',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();
      final File sentinel = File(
        '${fixture.container.path}/cancellation-sentinel',
      );
      final Completer<void> started = Completer<void>();
      late final StreamSubscription<EnvironmentProcessEvent> subscription;
      subscription = fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['sentinel-parent', sentinel.path]),
          )
          .listen((EnvironmentProcessEvent event) {
            if (event.output?.text.contains('started') ?? false) {
              started.complete();
            }
          });

      await started.future;
      await subscription.cancel();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await sentinel.exists(), isFalse);
    },
    skip: !Platform.isLinux ? 'Foreground execution is Linux-only.' : false,
  );

  test(
    'bounds each decoded output stream and replaces malformed UTF-8',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();
      final List<EnvironmentProcessEvent> bounded = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['bounded-output']),
          )
          .toList();
      final String stdoutText = _outputText(
        bounded,
        stream: EnvironmentProcessOutputStream.stdout,
      );
      final String stderrText = _outputText(
        bounded,
        stream: EnvironmentProcessOutputStream.stderr,
      );

      expect(stdoutText.length, 1024 * 1024);
      expect(stderrText.length, 1024 * 1024);
      expect(stdoutText, startsWith('H'));
      expect(stdoutText, endsWith('T'));
      expect(stderrText, startsWith('E'));
      expect(stderrText, endsWith('R'));
      expect(_completion(bounded).stdoutTruncated, isTrue);
      expect(_completion(bounded).stderrTruncated, isTrue);
      expect(_completion(bounded).exitCode, 0);

      final List<EnvironmentProcessEvent> malformed = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['malformed-output']),
          )
          .toList();
      expect(_outputText(malformed), '\ufffda');
      expect(_completion(malformed).stdoutTruncated, isFalse);

      final List<EnvironmentProcessEvent> nulOutput = await fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['nul-output']),
          )
          .toList();
      expect(_outputText(nulOutput), '\u0000a');
      expect(_completion(nulOutput).exitCode, 0);
    },
    skip: !Platform.isLinux ? 'Foreground execution is Linux-only.' : false,
  );

  test(
    'provider close terminates active foreground process trees',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();
      final File sentinel = File('${fixture.container.path}/close-sentinel');
      final Completer<void> started = Completer<void>();
      final Completer<void> streamDone = Completer<void>();
      fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['sentinel-parent', sentinel.path]),
          )
          .listen((EnvironmentProcessEvent event) {
            if (event.output?.text.contains('started') ?? false) {
              started.complete();
            }
          }, onDone: streamDone.complete);

      await started.future;
      await fixture.provider.close();
      await streamDone.future;
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await sentinel.exists(), isFalse);
      expect(fixture.provider.liveObjects.length, 0);
    },
    skip: !Platform.isLinux ? 'Foreground execution is Linux-only.' : false,
  );

  test(
    'provider close is independent of a paused stream consumer',
    () async {
      final _ProcessFixture fixture = await _createProcessFixture();
      final Completer<void> firstOutput = Completer<void>();
      late final StreamSubscription<EnvironmentProcessEvent> subscription;
      subscription = fixture.provider
          .runForegroundProcess(
            fixture.environment.id,
            fixture.request(<String>['stdout']),
          )
          .listen((EnvironmentProcessEvent event) {
            if (!firstOutput.isCompleted && event.output != null) {
              subscription.pause();
              firstOutput.complete();
            }
          });

      await firstOutput.future;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await fixture.provider.close().timeout(const Duration(seconds: 2));
      await subscription.cancel();
    },
    skip: !Platform.isLinux ? 'Foreground execution is Linux-only.' : false,
  );
}

List<EnvironmentProcessOutput> _outputs(List<EnvironmentProcessEvent> events) =>
    events
        .where(
          (EnvironmentProcessEvent event) =>
              event.kind == EnvironmentProcessEventKind.output,
        )
        .map((EnvironmentProcessEvent event) => event.output!)
        .toList();

String _outputText(
  List<EnvironmentProcessEvent> events, {
  EnvironmentProcessOutputStream? stream,
}) => _outputs(events)
    .where(
      (EnvironmentProcessOutput output) =>
          stream == null || output.stream == stream,
    )
    .map((EnvironmentProcessOutput output) => output.text)
    .join();

EnvironmentProcessCompleted _completion(List<EnvironmentProcessEvent> events) =>
    events
        .singleWhere(
          (EnvironmentProcessEvent event) =>
              event.kind == EnvironmentProcessEventKind.completed,
        )
        .completed!;

final class _ProcessFixture {
  const _ProcessFixture({
    required this.container,
    required this.provider,
    required this.environment,
    required this.helper,
  });

  final Directory container;
  final GitWorktreeEnvironmentProvider provider;
  final LocalEnvironment environment;
  final File helper;

  EnvironmentForegroundProcessRequest request(
    List<String> arguments, {
    String relativeWorkingDirectory = '',
    int timeoutSeconds = 5,
  }) => EnvironmentForegroundProcessRequest(
    program: Platform.resolvedExecutable,
    arguments: <String>[helper.path, ...arguments],
    relativeWorkingDirectory: relativeWorkingDirectory,
    timeoutSeconds: timeoutSeconds,
  );
}

Future<_ProcessFixture> _createProcessFixture() async {
  final ({Directory container, Directory source}) repository =
      await _createRepository();
  addTearDown(() => repository.container.delete(recursive: true));
  final GitWorktreeEnvironmentProvider provider =
      GitWorktreeEnvironmentProvider();
  addTearDown(provider.close);
  final LocalEnvironment environment = _environment(
    repository.source.uri,
    taskId: 'task-process',
    environmentId: 'environment-process',
    title: 'Foreground process',
  );
  await provider.establish(environment);
  final File helper = File('${repository.container.path}/process_helper.dart');
  await helper.writeAsString(r'''
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  switch (arguments.first) {
    case 'stdout':
      stdout.write('stdout-one|');
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      stdout.write('stdout-two');
      await stdout.flush();
      return;
    case 'interleaved':
      stdout.write('out-one|');
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      stderr.write('err-one|');
      await stderr.flush();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      stdout.write('out-two|');
      await stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      stderr.write('err-two');
      await stderr.flush();
      return;
    case 'literal':
      stdout.writeln(arguments[1]);
      await stdout.flush();
      return;
    case 'exit':
      exit(int.parse(arguments[1]));
    case 'cwd':
      stdout.writeln(Directory.current.resolveSymbolicLinksSync());
      await stdout.flush();
      return;
    case 'spawn-marker':
      await File(arguments[1]).writeAsString('spawned');
      return;
    case 'sentinel-parent':
      await Process.start(Platform.resolvedExecutable, <String>[
        Platform.script.toFilePath(),
        'sentinel-child',
        arguments[1],
      ]);
      stdout.write('started');
      await stdout.flush();
      await Future<void>.delayed(const Duration(seconds: 20));
      return;
    case 'sentinel-child':
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await File(arguments[1]).writeAsString('survived');
      return;
    case 'bounded-output':
      stdout.write('H' * 600000);
      stdout.write('M' * 600000);
      stdout.write('T' * 600000);
      stderr.write('E' * 600000);
      stderr.write('D' * 600000);
      stderr.write('R' * 600000);
      await Future.wait<void>(<Future<void>>[stdout.flush(), stderr.flush()]);
      return;
    case 'malformed-output':
      stdout.add(<int>[0xff, 0x61]);
      await stdout.flush();
      return;
    case 'nul-output':
      stdout.add(<int>[0x00, 0x61]);
      await stdout.flush();
      return;
    default:
      throw ArgumentError.value(arguments.first);
  }
}
''');
  return _ProcessFixture(
    container: repository.container,
    provider: provider,
    environment: environment,
    helper: helper,
  );
}

Matcher _failureWithCode(String code) => isA<EnvironmentFailure>().having(
  (EnvironmentFailure failure) => failure.code,
  'code',
  code,
);

final bool _runningAsRoot =
    Platform.isLinux &&
    Process.runSync('id', const <String>['-u']).stdout.toString().trim() == '0';

void _expectV2State(
  LocalEnvironment environment,
  Map<String, Object?> state, {
  String sourceRelativePath = '',
}) {
  expect(
    state.keys,
    unorderedEquals(<String>[
      'schemaVersion',
      'environmentId',
      'sourceRelativePath',
      'worktreeRelativePath',
      'branch',
      'baselineCommit',
    ]),
  );
  expect(state['schemaVersion'], allOf(isA<int>(), 2));
  expect(state['environmentId'], environment.id.value);
  expect(state['sourceRelativePath'], sourceRelativePath);
  expect(
    state['worktreeRelativePath'],
    matches(r'^\.adele/worktrees/[a-z0-9-]+$'),
  );
  expect(state['branch'], isA<String>());
  expect(state['baselineCommit'], matches(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$'));
}

Directory _worktreeRoot(Directory projectSource, Map<String, Object?> state) =>
    Directory(
      <String>[
        projectSource.path,
        ...(state['worktreeRelativePath']! as String).split('/'),
      ].join(Platform.pathSeparator),
    );

LocalEnvironment _retainedEnvironment(
  LocalEnvironment original,
  Map<String, Object?>? state, {
  Uri? sourceLocation,
}) => LocalEnvironment(
  project: Project(
    id: original.task.project.id,
    sourceLocation: sourceLocation ?? original.task.project.sourceLocation,
  ),
  task: original.task.value,
  value: Environment(
    id: original.id,
    taskId: original.task.id,
    role: original.role,
    providerId: original.providerId,
    providerState: state,
  ),
);

Future<void> _copyDirectory(Directory source, Directory target) async {
  await target.create();
  await for (final FileSystemEntity entity in source.list(followLinks: false)) {
    final String destination =
        '${target.path}${Platform.pathSeparator}${_entityName(entity.path)}';
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(destination));
    } else if (entity is File) {
      await entity.copy(destination);
    } else if (entity is Link) {
      await Link(destination).create(await entity.target());
    }
  }
}

LocalEnvironment _environment(
  Uri sourceLocation, {
  required String taskId,
  required String environmentId,
  required String title,
}) {
  final Project project = Project(
    id: ProjectId('project-$taskId'),
    sourceLocation: sourceLocation,
  );
  final Task task = Task(
    id: TaskId(taskId),
    projectId: project.id,
    title: title,
  );
  return LocalEnvironment(
    project: project,
    task: task,
    value: Environment(
      id: EnvironmentId(environmentId),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: ProviderId(gitWorktreeEnvironmentProviderId),
      providerState: null,
    ),
  );
}

Future<({Directory container, Directory source})> _createRepository({
  String sourceDirectoryName = 'source',
}) async {
  final Directory container = await Directory.systemTemp.createTemp(
    'adele-git-environment-',
  );
  final Directory source = Directory(
    '${container.path}${Platform.pathSeparator}$sourceDirectoryName',
  );
  await source.create();
  await _gitOutput(source, <String>['init']);
  await _gitOutput(source, <String>['config', 'user.name', 'ADELE Test']);
  await _gitOutput(source, <String>[
    'config',
    'user.email',
    'adele@example.invalid',
  ]);
  await Directory('${source.path}/lib').create();
  await File('${source.path}/README.md').writeAsString('fixture source\n');
  await File('${source.path}/lib/main.dart').writeAsString('void main() {}\n');
  await _gitOutput(source, <String>['add', '.']);
  await _gitOutput(source, <String>['commit', '-m', 'Initial fixture']);
  return (container: container, source: source);
}

Future<String> _gitOutput(Directory directory, List<String> arguments) async {
  final ProcessResult result = await Process.run('git', <String>[
    '-C',
    directory.path,
    ...arguments,
  ]);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString().trim();
}

Future<String> _gitInventory(Directory repository) =>
    _gitOutput(repository, <String>['worktree', 'list', '--porcelain', '-z']);

Future<List<String>> _branchNames(Directory repository) async =>
    (await _gitOutput(repository, <String>[
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads',
    ])).split('\n').where((String branch) => branch.isNotEmpty).toList();

String _entityName(String path) => path.split(Platform.pathSeparator).last;

// `Uri.parse('file:relative/repository')` canonicalizes to a root URI before
// the provider receives it. This fixture exercises a genuinely relative
// decoded file path without adding a production test seam.
final class _RelativeFileUri implements Uri {
  const _RelativeFileUri();

  @override
  bool get hasScheme => true;

  @override
  String get path => 'relative/repository';

  @override
  String get scheme => 'file';

  @override
  String toFilePath({bool? windows}) => 'relative/repository';

  @override
  String toString() => 'file:relative/repository';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
