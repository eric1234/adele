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
      environmentId: 'environment-first',
      title: 'Build Parser Support',
    );

    final EnvironmentProviderResult firstResult = await generationA.establish(
      first,
    );
    expect(
      firstResult.providerState['baselineCommit'],
      await _gitOutput(fixture.source, <String>['rev-parse', 'HEAD']),
    );
    final WorktreeEnvironment firstLive = liveObjects.resolve(first.id);
    final String retainedPath = firstLive.root.path;
    expect(retainedPath, isNot(fixture.source.path));
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
    expect(branch, startsWith('adele/build-parser-support-'));

    final LocalEnvironment second = _environment(
      fixture.source.uri,
      taskId: 'task-second',
      environmentId: 'environment-second',
      title: 'Second Environment',
    );
    await generationA.establish(second);
    expect(liveObjects.length, 2);
    expect(liveObjects.resolve(second.id).root.path, isNot(retainedPath));

    generationA.close();
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
        'worktreePath': fixture.source.path,
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
      throwsA(_failureWithCode('restore_worktree_mismatch')),
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

    expect(
      (await provider.readFile(environment.id, 'nested/./inside.txt')).text,
      'inside',
    );
    expect(
      (await provider.readFile(environment.id, 'inside-link.txt')).text,
      'inside',
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
      throwsA(_failureWithCode('outside_root')),
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
}

Matcher _failureWithCode(String code) => isA<EnvironmentFailure>().having(
  (EnvironmentFailure failure) => failure.code,
  'code',
  code,
);

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

Future<({Directory container, Directory source})> _createRepository() async {
  final Directory container = await Directory.systemTemp.createTemp(
    'adele-git-environment-',
  );
  final Directory source = Directory('${container.path}/source');
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
