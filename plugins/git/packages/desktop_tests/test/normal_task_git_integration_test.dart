@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../../../app/test/support/git_worktree_fixture.dart';
import '../../../../../app/test/support/prepared_normal_task_git.dart';

void main() {
  final suite = PreparedNormalTaskGit(
    Directory.current.parent.parent.parent.parent,
  );
  setUpAll(suite.prepare);

  late NormalTaskGitCase fixture;
  late AdeleRuntime runtime;
  setUp(() async {
    fixture = await suite.createCase();
    runtime = fixture.runtime;
  });

  for (final bool dirty in [false, true]) {
    test(
      'discovered backends establish a Task and preserve ${dirty ? 'dirty' : 'clean'} nested source',
      () async {
        final Directory repository = Directory(
          '${fixture.container.path}/repo',
        );
        final Directory source = Directory(
          '${repository.path}/packages/source',
        );
        await Directory('${source.path}/lib').create(recursive: true);
        final File sourceFile = File('${source.path}/lib/example.dart');
        const String baselineText = 'const answer = 42;\n';
        await sourceFile.writeAsString(baselineText);
        await File(
          '${repository.path}/outside.txt',
        ).writeAsString('Outside Project scope.\n');
        await git(repository, ['init', '--initial-branch=main']);
        await git(repository, ['add', '.']);
        await git(repository, ['commit', '-m', 'Fixture baseline']);
        final String baseline = (await git(repository, [
          'rev-parse',
          'HEAD',
        ])).trim();
        if (dirty) {
          await sourceFile.writeAsString('const answer = 43;\n');
          await git(repository, ['add', 'packages/source/lib/example.dart']);
          await sourceFile.writeAsString('const answer = 44;\n');
          await File(
            '${source.path}/scratch.txt',
          ).writeAsString('Untracked source.\n');
        }
        final String sourceText = await sourceFile.readAsString();
        final String status = await git(repository, [
          'status',
          '--porcelain=v1',
          '-z',
        ]);
        final String diff = await git(repository, ['diff', '--binary', 'HEAD']);
        final String staged = await git(repository, [
          'diff',
          '--cached',
          '--binary',
        ]);
        expect(status.isNotEmpty, dirty);
        final Project project = runtime.lifecycle.createProject(source.uri);
        expect(runtime.store.project(project.id), same(project));
        expect(project.sourceLocation, source.uri);
        expect(runtime.store.tasksFor(project.id), isEmpty);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );

        await fixture.installBackends();
        await fixture.start();
        fixture.expectBothActive();
        expect(runtime.plugins.backends, hasLength(2));
        expect(runtime.store.tasksFor(project.id), isEmpty);
        final ProviderDescriptor descriptor = runtime.registry
            .providersFor(environmentProviderCapability)
            .single;
        final TaskCreationResult created = await runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'Normal nested Task',
        );
        expect(runtime.store.project(project.id), same(project));
        expect(runtime.store.task(created.task.id), same(created.task));
        expect(runtime.store.tasksFor(project.id).single, same(created.task));
        expect(created.task.projectId, project.id);
        expect(created.task.title, 'Normal nested Task');
        expect(runtime.store.sessionsForTask(created.task.id), isEmpty);
        // Establishment, not a later Session/storage read, created this backing.
        final database = runtime.lifecycle.existingDatabaseForProject(project)!;
        final temporaryBacking = File(database.path);
        expect(await temporaryBacking.exists(), isTrue);
        expect(database.path, isNot(startsWith(source.path)));
        expect(await File('${source.path}/.adele/data.db').exists(), isFalse);
        expect(
          runtime.lifecycle.databaseForEnvironment(created.environment.id),
          isNull,
        );
        expect(database.loadProductGraph().sessions, isEmpty);
        expect(
          database
              .queryPluginRows('SELECT * FROM adele_git_task_anchors', {})
              .map((row) => row.values),
          [
            {
              'environment_id': created.environment.id.value,
              'baseline_commit': baseline,
              'expected_branch_ref':
                  'refs/heads/${created.environment.providerState!['branch']}',
            },
          ],
        );
        expect(
          runtime.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(
          runtime.store.primaryEnvironmentFor(created.task.id),
          same(created.environment),
        );
        expect(created.environment.taskId, created.task.id);
        expect(created.environment.role, EnvironmentRole.primary);
        expect(created.environment.providerId, descriptor.id);
        expect(created.environment.providerState, isNotEmpty);
        final EnvironmentMaterialization materialization = await runtime
            .lifecycle
            .environmentRuntime
            .materialize(created.environment.id);
        expect(materialization.environment, same(created.environment));
        expect(
          materialization,
          same(
            runtime.lifecycle.environmentRuntime.currentMaterialization(
              created.environment.id,
            ),
          ),
        );
        expect(materialization.provider, isA<GeneratedEnvironmentProvider>());
        expect(materialization.providerDescriptor, same(descriptor));
        expect(materialization.validateBinding, returnsNormally);

        // Inspect provider-owned state only to corroborate the real Git fixture.
        final Map<String, Object?> state = created.environment.providerState!;
        final Directory worktree = Directory(
          gitWorktreeFixturePath(project, created.environment),
        );
        final String commonDirectory = (await git(repository, [
          'rev-parse',
          '--path-format=absolute',
          '--git-common-dir',
        ])).trim();
        expect(await worktree.exists(), isTrue);
        expect(await File('${worktree.path}/.git').exists(), isTrue);
        expect(
          worktree.parent.path,
          '${await source.resolveSymbolicLinks()}${Platform.pathSeparator}'
          '.adele${Platform.pathSeparator}worktrees',
        );
        final String relativePath = state['worktreeRelativePath']! as String;
        expect(relativePath, matches(r'^\.adele/worktrees/[^/]+$'));
        expect(state, <String, Object?>{
          'schemaVersion': 2,
          'environmentId': created.environment.id.value,
          'sourceRelativePath': 'packages/source',
          'worktreeRelativePath': relativePath,
          'branch': state['branch'],
        });
        expect(
          (await git(worktree, ['rev-parse', '--show-toplevel'])).trim(),
          worktree.path,
        );
        expect((await git(worktree, ['rev-parse', 'HEAD'])).trim(), baseline);
        expect(
          (await git(worktree, [
            'rev-parse',
            '--path-format=absolute',
            '--git-common-dir',
          ])).trim(),
          commonDirectory,
        );
        expect(
          (await git(worktree, ['branch', '--show-current'])).trim(),
          state['branch'],
        );
        expect(
          await git(repository, ['worktree', 'list', '--porcelain']),
          contains('worktree ${worktree.path}\n'),
        );
        expect(await git(worktree, ['status', '--porcelain=v1']), isEmpty);
        final EnvironmentTextFile read = await materialization.provider
            .readFile(created.environment.id, 'lib/example.dart');
        expect(read.text, baselineText);
        expect(read.relativePath, 'lib/example.dart');
        expect(read.revision, isNotEmpty);
        final EnvironmentDirectoryListing listing = await materialization
            .provider
            .readDirectory(created.environment.id, '');
        expect(listing.entries.map((entry) => entry.name), ['lib']);
        await expectLater(
          materialization.provider.readFile(
            created.environment.id,
            'outside.txt',
          ),
          throwsA(
            isA<EnvironmentFailure>().having(
              (failure) => failure.code,
              'code',
              'not_found',
            ),
          ),
        );
        expect(await sourceFile.readAsString(), sourceText);
        // Provider storage is deliberately unignored; only that new entry is
        // allowed alongside the exact pre-existing source/index changes.
        final List<String> expectedStatus = <String>[
          ...status.split('\u0000').where((entry) => entry.isNotEmpty),
          '?? packages/source/.adele/',
        ];
        expect(
          (await git(repository, [
            'status',
            '--porcelain=v1',
            '-z',
          ])).split('\u0000').where((entry) => entry.isNotEmpty),
          unorderedEquals(expectedStatus),
        );
        expect(await git(repository, ['diff', '--binary', 'HEAD']), diff);
        expect(await git(repository, ['diff', '--cached', '--binary']), staged);

        final Future<void> closing = runtime.close();
        expect(runtime.close(), same(closing));
        await closing;
        expect(await temporaryBacking.exists(), isFalse);
        expect(await temporaryBacking.parent.exists(), isFalse);
        expect(runtime.close(), same(closing));
        expect(runtime.plugins.state, ApplicationPluginState.closed);
        expect(runtime.plugins.failure, isNull);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(materialization.validateBinding, throwsA(staleProvider));
        await expectLater(
          materialization.provider.readFile(
            created.environment.id,
            'lib/example.dart',
          ),
          throwsA(isA<PluginConnectionClosed>()),
        );
        expect(runtime.store.task(created.task.id), same(created.task));
        expect(runtime.store.sessionsForTask(created.task.id), isEmpty);
        expect(
          runtime.store.environment(created.environment.id),
          same(created.environment),
        );
        expect(await worktree.exists(), isTrue);
        expect(
          await File(
            '${worktree.path}/packages/source/lib/example.dart',
          ).readAsString(),
          baselineText,
        );
        expect((await git(worktree, ['rev-parse', 'HEAD'])).trim(), baseline);
        expect(
          await git(repository, ['worktree', 'list', '--porcelain']),
          contains('worktree ${worktree.path}\n'),
        );
        expect((await git(repository, ['rev-parse', 'HEAD'])).trim(), baseline);
        expect(
          (await git(repository, ['branch', '--show-current'])).trim(),
          'main',
        );
        expect(await sourceFile.readAsString(), sourceText);
        expect(
          (await git(repository, [
            'status',
            '--porcelain=v1',
            '-z',
          ])).split('\u0000').where((entry) => entry.isNotEmpty),
          unorderedEquals(expectedStatus),
        );
        expect(await git(repository, ['diff', '--binary', 'HEAD']), diff);
        expect(await git(repository, ['diff', '--cached', '--binary']), staged);
        if (dirty) {
          expect(
            await File('${source.path}/scratch.txt').readAsString(),
            'Untracked source.\n',
          );
        }
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }

  test(
    'prepared Git buffered facet uses canonical materializations without process grants',
    () async {
      final repository = Directory('${fixture.container.path}/buffered-repo');
      final source = Directory('${repository.path}/packages/source');
      await Directory('${source.path}/data').create(recursive: true);
      await File('${source.path}/data/seed.txt').writeAsString('Baseline\n');
      await git(repository, [
        'init',
        '--initial-branch=main',
        '--object-format=sha1',
      ]);
      await git(repository, ['add', '.']);
      await git(repository, ['commit', '-m', 'Buffered fixture baseline']);
      final project = runtime.lifecycle.createProject(source.uri);
      await fixture.installBackends();
      await fixture.start();
      fixture.expectBothActive();
      final materializations = <EnvironmentMaterialization>[];
      final roots = <Directory>[];
      for (final title in [
        'First binary Environment',
        'Second binary Environment',
      ]) {
        final created = await runtime.lifecycle.createTask(
          projectId: project.id,
          title: title,
        );
        final materialization = await runtime.lifecycle.environmentRuntime
            .materialize(created.environment.id);
        expect(materialization.environment, same(created.environment));
        expect(
          runtime.store.environment(created.environment.id),
          same(materialization.environment),
        );
        expect(materialization.provider, isA<GeneratedEnvironmentProvider>());
        expect(
          materialization.provider,
          isA<EnvironmentBufferedProcessProvider>(),
        );
        expect(materialization.validateBinding, returnsNormally);
        expect(runtime.store.sessionsForTask(created.task.id), isEmpty);
        materializations.add(materialization);
        roots.add(
          Directory(gitWorktreeFixturePath(project, created.environment)),
        );
      }
      expect(
        materializations[0].environment.id,
        isNot(materializations[1].environment.id),
      );
      expect(roots[0].path, isNot(roots[1].path));
      final sourceHead = await git(repository, ['rev-parse', 'HEAD']);
      final sourceDiff = await git(repository, ['diff', '--binary', 'HEAD']);
      final sourceStatus = await git(repository, [
        'status',
        '--porcelain=v1',
        '-z',
      ]);
      final child =
          '${suite.repositoryRoot.path}/plugins/git/'
          'packages/backend/test/fixtures/buffered_process_child.dart';
      const binary = [0, 255, 128, 192, 175, 13, 10, 27, 91, 50, 74, 1, 9, 127];

      await Future.wait([
        for (var i = 0; i < materializations.length; i++)
          (() async {
            final materialization = materializations[i];
            final provider =
                materialization.provider as EnvironmentBufferedProcessProvider;
            final id = materialization.environment.id;
            final data = Directory('${roots[i].path}/packages/source/data');
            final paths = [
              'line\nbreak.txt',
              'space name.txt',
              '${id.value}.txt',
            ]..sort();
            for (final path in paths) {
              await File('${data.path}/$path').writeAsBytes(binary);
            }
            await git(data, ['add', '--', ...paths]);
            final index = File(
              (await git(data, [
                'rev-parse',
                '--path-format=absolute',
                '--git-path',
                'index',
              ])).trim(),
            );
            final indexBefore = await index.readAsBytes();
            final refsBefore = await git(data, ['show-ref']);
            Future<EnvironmentBufferedProcessResult> run(
              String program,
              List<String> arguments, {
              List<int> input = const [],
            }) {
              materialization.validateBinding();
              return provider.runBufferedProcess(
                id,
                EnvironmentBufferedProcessRequest(
                  program: program,
                  arguments: arguments,
                  relativeWorkingDirectory: 'data',
                  timeoutSeconds: 10,
                  stdinBase64: encodeEnvironmentProcessBytes(
                    input,
                    maximumBytes: environmentBufferedProcessStdinLimit,
                  ),
                ),
              );
            }

            final echoed = await run(suite.sdk.dart, [
              child,
              'echo',
              '17',
            ], input: binary);
            expect(echoed.exitCode, 17);
            expect(
              decodeEnvironmentProcessBytes(
                echoed.stdoutBase64,
                maximumBytes: environmentBufferedProcessStdoutLimit,
              ),
              binary,
            );
            expect(
              decodeEnvironmentProcessBytes(
                echoed.stderrBase64,
                maximumBytes: environmentBufferedProcessStderrLimit,
              ),
              [0, 255, 128, 13, 10, 27, 91, 50, 74],
            );
            final identity = await run('git', [
              'rev-parse',
              '--show-toplevel',
              '--show-prefix',
            ]);
            expect(identity.exitCode, 0);
            expect(
              base64Decode(identity.stdoutBase64),
              utf8.encode('${roots[i].path}\npackages/source/data/\n'),
            );
            expect(identity.stderrBase64, isEmpty);
            final names = await run('git', ['ls-files', '--cached', '-z']);
            expect(names.exitCode, 0);
            expect(names.stderrBase64, isEmpty);
            final expectedPaths = [...paths, 'seed.txt']..sort();
            expect(
              base64Decode(names.stdoutBase64),
              utf8.encode('${expectedPaths.join('\x00')}\x00'),
            );
            final hash = await run('git', [
              'hash-object',
              '--stdin',
            ], input: binary);
            expect(hash.exitCode, 0);
            // SHA-1 of the raw Git blob header plus the fourteen fixture bytes.
            expect(
              base64Decode(hash.stdoutBase64),
              ascii.encode('4fe223bb065d3f5a71b410ad26afa5c536483f07\n'),
            );
            expect(hash.stderrBase64, isEmpty);
            final diagnostic = await run('git', [
              'rev-parse',
              '--verify',
              'refs/heads/adele-missing-ref',
            ]);
            expect(diagnostic.exitCode, 128);
            expect(diagnostic.stdoutBase64, isEmpty);
            expect(base64Decode(diagnostic.stderrBase64), isNotEmpty);
            expect(await index.readAsBytes(), indexBefore);
            expect(await git(data, ['show-ref']), refsBefore);
            for (final path in paths) {
              expect(await File('${data.path}/$path').readAsBytes(), binary);
            }
          })(),
      ]);
      expect(await git(repository, ['rev-parse', 'HEAD']), sourceHead);
      expect(await git(repository, ['diff', '--binary', 'HEAD']), sourceDiff);
      expect(
        await git(repository, ['status', '--porcelain=v1', '-z']),
        sourceStatus,
      );
      await runtime.close();
      for (final materialization in materializations) {
        expect(materialization.validateBinding, throwsA(staleProvider));
        final provider =
            materialization.provider as EnvironmentBufferedProcessProvider;
        await expectLater(
          provider.runBufferedProcess(
            materialization.environment.id,
            EnvironmentBufferedProcessRequest(
              program: suite.sdk.dart,
              arguments: [child, 'empty'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
              stdinBase64: '',
            ),
          ),
          throwsA(isA<PluginConnectionClosed>()),
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
    skip: !Platform.isLinux ? 'Buffered Git processes require Linux.' : false,
  );

  test(
    'discovered Git rejects non-Git Project without Task publication',
    () async {
      final Directory source = await Directory(
        '${fixture.container.path}/not-git',
      ).create();
      await File(
        '${source.path}/source.txt',
      ).writeAsString('Not a repository.\n');
      final Project project = runtime.lifecycle.createProject(source.uri);
      await fixture.installBackends();
      await fixture.start();
      fixture.expectBothActive();
      await expectLater(
        runtime.lifecycle.createTask(
          projectId: project.id,
          title: 'Reject non-Git source',
        ),
        throwsA(
          isA<EnvironmentFailure>().having(
            (failure) => failure.code,
            'code',
            'invalid_git_source',
          ),
        ),
      );
      expect(runtime.store.project(project.id), same(project));
      expect(runtime.store.tasksFor(project.id), isEmpty);
      expect(runtime.store.task(TaskId('task-normal-1')), isNull);
      expect(
        runtime.store.environment(EnvironmentId('environment-normal-1')),
        isNull,
      );
      expect(
        runtime.store.primaryEnvironmentFor(TaskId('task-normal-1')),
        isNull,
      );
      expect(
        runtime.lifecycle.environmentRuntime.currentMaterialization(
          EnvironmentId('environment-normal-1'),
        ),
        isNull,
      );
      expect(
        await File('${source.path}/source.txt').readAsString(),
        'Not a repository.\n',
      );
      expect(await Directory('${source.path}/.git').exists(), isFalse);
      fixture.expectBothActive();
    },
  );
}
