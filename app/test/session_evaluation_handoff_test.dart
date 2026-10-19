import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../tool/development_git_baseline.dart';
import '../tool/session_evaluation_handoff.dart';

void main() {
  late Directory temporary;
  late Directory source;
  final createdAt = DateTime.parse('2026-10-12T23:14:01+03:00');

  setUp(() {
    final directory = Directory.systemTemp.createTempSync('adele-handoff-');
    temporary = Directory(directory.resolveSymbolicLinksSync());
    source = Directory('${temporary.path}/source')..createSync();
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  void expectUnavailable(SessionEvaluationHandoff handoff, String reason) {
    expect(handoff.worktreeRoot, isNull);
    expect(handoff.selectedSourceDirectory, isNull);
    expect(handoff.sourceRelativePath, isNull);
    expect(handoff.baselineCommit, isNull);
    expect(handoff.branch, isNull);
    final readme = handoff.readme(createdAt);
    expect(readme, contains('Worktree metadata unavailable: $reason'));
    expect(readme, contains('evidence.json'));
    expect(readme, isNot(contains('git -C')));
  }

  test('captures exact canonical primary graph without live resources', () {
    final fixture = _Fixture(source);
    final handoff = fixture.capture();
    expect(handoff.project, same(fixture.project));
    expect(handoff.task, same(fixture.task));
    expect(handoff.session, same(fixture.session));
    expect(handoff.environment, same(fixture.environment));
    expect(handoff.worktreeRoot, fixture.worktree.path);
    expect(handoff.selectedSourceDirectory, fixture.worktree.path);
    expect(handoff.sourceRelativePath, '');
    expect(handoff.baselineCommit, 'a' * 40);
    expect(handoff.branch, 'adele-primary');
    expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
    // The direct marker is deliberately not a real Git registration. Capture
    // validates only the documented filesystem preflight, never invokes Git.
    expect(File('${source.path}/.git/HEAD').existsSync(), isFalse);
  });

  test('uses exact nonprimary association and nested selected scope', () {
    final fixture = _Fixture(source, additional: true, scope: 'nested/project');
    final handoff = fixture.capture();
    expect(handoff.environment, same(fixture.environment));
    expect(handoff.environment.role, EnvironmentRole.additional);
    expect(
      fixture.store.primaryEnvironmentFor(fixture.task.id),
      isNot(same(handoff.environment)),
    );
    expect(handoff.worktreeRoot, fixture.worktree.path);
    expect(
      handoff.selectedSourceDirectory,
      '${fixture.worktree.path}/nested/project',
    );
    expect(handoff.sourceRelativePath, 'nested/project');
    expect(handoff.baselineCommit, 'b' * 64);
    expect(handoff.branch, 'adele-additional');
    final readme = handoff.readme(createdAt);
    for (final value in [
      '2026-10-12T20:14:01.000Z',
      fixture.project.id.value,
      fixture.task.id.value,
      fixture.task.title,
      fixture.session.id.value,
      fixture.session.strategyId.value,
      fixture.environment.id.value,
      fixture.environment.providerId.value,
      'Worktree root: `${jsonEncode(fixture.worktree.path)}`',
      'Source-relative scope: `"nested/project"`',
      'Selected source directory: `${jsonEncode(handoff.selectedSourceDirectory)}`',
      'Retained baseline commit: `"${'b' * 64}"`',
      'Retained branch: `"adele-additional"`',
      "-- ':(top,literal)nested/project'",
    ]) {
      expect(readme, contains(value));
    }
  });

  test('does not replace unavailable nonprimary metadata with primary', () {
    final fixture = _Fixture(
      source,
      additional: true,
      providerId: 'test.environment',
    );
    expectUnavailable(fixture.capture(), 'unsupported Environment provider.');
    expect(fixture.capture().environment, same(fixture.environment));
    expect(
      fixture.store.primaryEnvironmentFor(fixture.task.id)!.providerId.value,
      'dev.adele.environment.git-worktree',
    );
  });

  test('missing backing stays absent; diagnostics never allocate storage', () {
    final fixture = _Fixture(source, backing: false);
    expect(
      fixture.lifecycle.existingDatabaseForProject(fixture.project),
      isNull,
    );
    expectUnavailable(
      fixture.capture(),
      'retained Git SQL baseline is unavailable or invalid.',
    );
    expect(
      fixture.lifecycle.existingDatabaseForProject(fixture.project),
      isNull,
    );
  });

  test(
    'temporary backing diagnostics are read-only and require exact SQL evidence',
    () {
      for (final sql in <String?>[
        null,
        "UPDATE adele_git_task_anchors SET expected_branch_ref='refs/heads/other' WHERE environment_id='additional'",
        "UPDATE adele_product_session_environment_authority SET environment_id='primary'",
        "UPDATE adele_product_environments SET task_id='other-task' WHERE id='additional'",
        "UPDATE adele_product_tasks SET project_id='other-project'",
        "DELETE FROM adele_git_task_anchors WHERE environment_id='additional'",
        "UPDATE adele_schema_versions SET version=2 WHERE owner_id='dev.adele.plugin.git'",
        "DELETE FROM adele_schema_versions WHERE owner_id='dev.adele.plugin.git'",
        'DROP TABLE adele_git_task_anchors',
      ]) {
        final fixture = _Fixture(source, additional: true);
        final database = sqlite3.open(fixture.database.path);
        addTearDown(database.close);
        List<Object?> snapshot() => [
          for (final table in database.select(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
          ))
            database
                .select('SELECT * FROM ${table['name']}')
                .map((row) => Map.of(row))
                .toList(),
        ];
        if (sql != null) database.execute(sql);
        final before = snapshot();
        if (sql == null) {
          expect(fixture.capture().baselineCommit, 'b' * 64);
        } else {
          expectUnavailable(
            fixture.capture(),
            'retained Git SQL baseline is unavailable or invalid.',
          );
        }
        expect(snapshot(), before);
      }
    },
  );

  test('invalid SQL baselines never fall back to provider state or HEAD', () {
    final fixture = _Fixture(source);
    for (final value in <Object?>[
      null,
      '',
      'HEAD',
      'abcdef',
      'a' * 39,
      'a' * 41,
      'a' * 63,
      'a' * 65,
      'g' * 40,
      'A' * 40,
      '${'a' * 40}\n',
      '${'a' * 40}\x7f',
    ]) {
      fixture.setBaseline(value);
      expectUnavailable(
        fixture.capture(),
        'retained Git SQL baseline is unavailable or invalid.',
      );
    }
    fixture.replaceState({
      ...fixture.environment.providerState!,
      'baselineCommit': 'a' * 40,
    });
    expectUnavailable(
      fixture.capture(),
      'invalid or unsupported stock Git v2 state.',
    );
  });

  test('SQL helper rejects a fabricated Environment and unrelated Session', () {
    final fixture = _Fixture(source, additional: true);
    final fabricated = Environment(
      id: fixture.environment.id,
      taskId: fixture.task.id,
      role: fixture.environment.role,
      providerId: fixture.environment.providerId,
      providerState: fixture.environment.providerState,
    );
    expect(
      () => developmentGitBaselineCommit(
        fixture.lifecycle,
        fabricated,
        branch: 'adele-additional',
        session: fixture.session,
      ),
      throwsArgumentError,
    );
    expect(
      () => developmentGitBaselineCommit(
        fixture.lifecycle,
        fixture.store.primaryEnvironmentFor(fixture.task.id)!,
        branch: 'adele-primary',
        session: fixture.session,
      ),
      throwsArgumentError,
    );
  });

  test('rejects a valid existing scope unrelated to the Project source', () {
    final fixture = _Fixture(source, scope: 'nested/project');
    Directory('${fixture.worktree.path}/unrelated').createSync();
    for (final scope in ['unrelated', '', 'nested']) {
      fixture.replaceState({
        ...fixture.environment.providerState!,
        'sourceRelativePath': scope,
      });
      expectUnavailable(
        fixture.capture(),
        'retained source scope does not match the Project.',
      );
    }
  });

  test('uses the nearest Project checkout marker rather than an ancestor', () {
    final fixture = _Fixture(source, scope: 'nested/project');
    File('${source.path}/nested/.git').writeAsStringSync('gitdir: unused\n');
    expectUnavailable(
      fixture.capture(),
      'retained source scope does not match the Project.',
    );
    fixture.replaceState({
      ...fixture.environment.providerState!,
      'sourceRelativePath': 'project',
    });
    Directory('${fixture.worktree.path}/project').createSync();
    expect(fixture.capture().sourceRelativePath, 'project');
  });

  test('rejects absent or symlinked Project checkout markers', () {
    final fixture = _Fixture(source, scope: 'nested/project');
    Directory('${source.path}/.git').deleteSync();
    expectUnavailable(fixture.capture(), 'Project checkout marker is missing.');
    final target = Directory('${temporary.path}/metadata')..createSync();
    Link('${source.path}/.git').createSync(target.path);
    expectUnavailable(fixture.capture(), 'Project checkout marker is unsafe.');
  });

  test('rejects fabricated, unpublished, and unrelated Session objects', () {
    final fixture = _Fixture(source);
    final unrelated = _Fixture(source);
    for (final session in [
      Session(
        id: fixture.session.id,
        taskId: fixture.session.taskId,
        strategyId: fixture.session.strategyId,
      ),
      Session(
        id: fixture.session.id,
        taskId: TaskId('other-task'),
        strategyId: fixture.session.strategyId,
      ),
      Session(
        id: SessionId('unpublished'),
        taskId: fixture.session.taskId,
        strategyId: fixture.session.strategyId,
      ),
      unrelated.session,
    ]) {
      expect(
        () => SessionEvaluationHandoff.capture(fixture.lifecycle, session),
        throwsArgumentError,
      );
    }
    expect(
      () => SessionEvaluationHandoff.capture(
        unrelated.lifecycle,
        fixture.session,
      ),
      throwsArgumentError,
    );
  });

  test('capture retains metadata even after store replacement and FS loss', () {
    final fixture = _Fixture(source);
    final handoff = fixture.capture();
    fixture.replaceState({
      ...fixture.environment.providerState!,
      'branch': 'adele-later',
    });
    fixture.database.executePluginTransaction([
      RelationalStatement(
        sql: 'UPDATE adele_git_task_anchors SET expected_branch_ref=:branch',
        parameters: {':branch': 'refs/heads/adele-later'},
        expectedRows: 1,
      ),
    ]);
    fixture.worktree.deleteSync(recursive: true);
    expect(handoff.environment, same(fixture.environment));
    expect(handoff.baselineCommit, 'a' * 40);
    expect(handoff.branch, 'adele-primary');
    expect(handoff.readme(createdAt), contains('adele-primary'));
    expect(handoff.readme(createdAt), isNot(contains('adele-later')));
    expectUnavailable(
      fixture.capture(),
      'worktree/source directories are missing or unsafe.',
    );
  });

  test('requires every v2 key and rejects extra or renamed keys', () {
    final fixture = _Fixture(source);
    final state = fixture.environment.providerState!;
    for (final key in state.keys) {
      fixture.replaceState({...state}..remove(key));
      expectUnavailable(
        fixture.capture(),
        'invalid or unsupported stock Git v2 state.',
      );
    }
    fixture.replaceState({...state, 'extra': 'value'});
    expectUnavailable(
      fixture.capture(),
      'invalid or unsupported stock Git v2 state.',
    );
    fixture.replaceState(
      {...state, 'schema_version': 2}..remove('schemaVersion'),
    );
    expectUnavailable(
      fixture.capture(),
      'invalid or unsupported stock Git v2 state.',
    );
  });

  final invalidState = <String, List<Object?>>{
    'schemaVersion': [null, '2', 2.0, 0, 1, true, [], <String, Object?>{}],
    'environmentId': [
      null,
      1,
      '',
      'additional',
      'primary\n',
      [],
      <String, Object?>{},
    ],
    'sourceRelativePath': [
      null,
      1,
      false,
      [],
      <String, Object?>{},
      '/',
      '/absolute',
      'trailing/',
      'double//slash',
      '.',
      '..',
      './child',
      '../child',
      'a/../b',
      'a/./b',
      r'a\b',
      'file:source',
      'C:/source',
      'line\nbreak',
      'tab\tname',
      'nul\x00name',
      'del\x7fname',
    ],
    'worktreeRelativePath': [
      null,
      1,
      false,
      [],
      <String, Object?>{},
      '',
      '.adele/worktrees',
      '.adele/worktrees/',
      '.adele/worktrees/.',
      '.adele/worktrees/..',
      '.adele/worktrees/../outside',
      '.adele/worktrees/name/child',
      '.adele/worktrees/Upper',
      '.adele/worktrees/-prefix',
      '.adele/worktrees/under_score',
      '.adele/worktrees/space name',
      '.adele/worktrees/name\n',
      '.adele/worktrees/name\x00',
      '.adele/worktrees/name\x7f',
      '/.adele/worktrees/name',
      '../.adele/worktrees/name',
      './.adele/worktrees/name',
      'other/worktrees/name',
      'file:.adele/worktrees/name',
      r'.adele\worktrees\name',
    ],
    'branch': [
      null,
      1,
      false,
      [],
      <String, Object?>{},
      '',
      'adele-',
      'main',
      'refs/heads/adele-name',
      'adele-Upper',
      'adele-under_score',
      'adele-space name',
      'adele-foo/bar',
      'adele-foo;command',
      'adele-foo\n',
      'adele-foo\x00',
      'adele-foo\x7f',
    ],
  };
  for (final entry in invalidState.entries) {
    test('rejects invalid ${entry.key} types and formats', () {
      final fixture = _Fixture(source);
      for (final value in entry.value) {
        fixture.replaceState({
          ...fixture.environment.providerState!,
          entry.key: value,
        });
        expectUnavailable(
          fixture.capture(),
          entry.key == 'schemaVersion' || entry.key == 'environmentId'
              ? 'invalid or unsupported stock Git v2 state.'
              : 'malformed stock Git paths or branch.',
        );
      }
    });
  }

  test('rejects an absolute outside worktree even when it exists', () {
    final fixture = _Fixture(source);
    final outside = Directory('${temporary.path}/outside')..createSync();
    fixture.replaceState({
      ...fixture.environment.providerState!,
      'worktreeRelativePath': outside.path,
    });
    expectUnavailable(
      fixture.capture(),
      'malformed stock Git paths or branch.',
    );
  });

  for (final location in [
    'https://example.invalid/source',
    'file:relative',
    'file://remote/source',
    'file:///source?query',
    'file:///source#fragment',
  ]) {
    test('rejects unsupported Project source $location', () {
      final fixture = _Fixture(source, sourceLocation: Uri.parse(location));
      expectUnavailable(
        fixture.capture(),
        location == 'file:relative'
            ? 'worktree/source directories are missing or unsafe.'
            : 'Project source is not an absolute local directory.',
      );
    });
  }

  for (final target in ['source', 'worktree', 'selected']) {
    test('missing $target directory is unavailable, not recreated', () {
      final fixture = _Fixture(source, scope: 'nested/selected');
      final directory = switch (target) {
        'source' => fixture.source,
        'worktree' => fixture.worktree,
        _ => fixture.selected,
      };
      directory.deleteSync(recursive: true);
      expectUnavailable(
        fixture.capture(),
        'worktree/source directories are missing or unsafe.',
      );
      expect(directory.existsSync(), isFalse);
    });
  }

  for (final relative in [
    '.adele',
    '.adele/worktrees',
    '.adele/worktrees/primary',
    '.adele/worktrees/primary/nested',
    '.adele/worktrees/primary/nested/selected',
  ]) {
    for (final outside in [false, true]) {
      test('rejects $relative symlink, outside source: $outside', () {
        final fixture = _Fixture(source, scope: 'nested/selected');
        final original = Directory('${fixture.source.path}/$relative');
        final moved = original.renameSync(
          outside
              ? '${temporary.path}/outside'
              : '${original.parent.path}/alias',
        );
        Link(original.path).createSync(moved.path);
        expectUnavailable(
          fixture.capture(),
          'worktree/source directories are missing or unsafe.',
        );
      });
    }
  }

  test('rejects a file in place of a selected directory', () {
    final fixture = _Fixture(source, scope: 'nested/selected');
    fixture.selected.deleteSync();
    File(fixture.selected.path).writeAsStringSync('not a directory');
    expectUnavailable(
      fixture.capture(),
      'worktree/source directories are missing or unsafe.',
    );
  });

  for (final kind in ['missing', 'directory', 'symlink']) {
    test('rejects $kind checkout marker without using enclosing Git', () {
      final fixture = _Fixture(source);
      Directory('${source.path}/.git').createSync();
      final marker = File('${fixture.worktree.path}/.git')..deleteSync();
      if (kind == 'directory') Directory(marker.path).createSync();
      if (kind == 'symlink') {
        final target = File('${temporary.path}/marker')
          ..writeAsStringSync('gitdir: unused\n');
        Link(marker.path).createSync(target.path);
      }
      expectUnavailable(
        fixture.capture(),
        'linked-worktree checkout marker is missing or unsafe.',
      );
    });
  }

  test('unsupported provider cannot impersonate stock Git with its state', () {
    final fixture = _Fixture(
      source,
      providerId: 'dev.adele.git.change-set-source',
    );
    expectUnavailable(fixture.capture(), 'unsupported Environment provider.');
  });

  test('README preserves evaluation guidance and qualifies live evidence', () {
    final readme = _Fixture(source).capture().readme(createdAt);
    for (final value in [
      '# Session Evaluation Handoff',
      'Created (UTC): 2026-10-12T20:14:01.000Z',
      '[evidence.json](evidence.json)',
      'repository root (empty retained scope)',
      "'${'a' * 40}..HEAD'",
      'An empty scope inspects the entire worktree',
      'not a current HEAD',
      'AGENTS.md',
      'implementation and tests',
      'committed baseline-to-HEAD, staged and unstaged',
      'contents of relevant\nuntracked files',
      'command_tools.captures',
      'bounded model-facing result',
      'decisions, failures and validation',
      'reported model usage (when available)',
      'Existing collection/document bounds',
      'never silently truncate',
      'partial/unavailable',
      'not exclusively attributable',
      'Unsaved editor',
      'not one cross-owner atomic',
      'sensitive data',
      'not a portable source archive',
    ]) {
      expect(readme, contains(value));
    }
    expect(readme, isNot(contains(':(top,literal)')));
  });

  test('escapes control characters and Markdown in identity text', () {
    final fixture = _Fixture(source, title: 'Title\n```sh\ncommand\n```\x00');
    final readme = fixture.capture().readme(createdAt);
    expect(readme, contains(r'Title\n\u0060\u0060\u0060sh\ncommand'));
    expect(readme, isNot(contains('Title\n```sh')));
    expect(readme, isNot(contains('\x00')));
  });

  for (final scope in ['', 'nested source/[x]*?']) {
    test(
      'real Git inspection commands cover ${scope.isEmpty ? 'root' : 'nested'} '
      'changes without a false clean result',
      () async {
        source = source.renameSync(
          "${temporary.path}/source with 'quotes' \$(literal);[x]*?",
        );
        final fixture = _Fixture(source, scope: scope);
        // Replace the filesystem-only fixture with a registered linked checkout.
        fixture.worktree.deleteSync(recursive: true);
        final environment = {
          'PATH': Platform.environment['PATH']!,
          'HOME': temporary.path,
          'LC_ALL': 'C',
          'GIT_CONFIG_NOSYSTEM': '1',
          'GIT_CONFIG_GLOBAL': '/dev/null',
          'GIT_AUTHOR_NAME': 'ADELE Test',
          'GIT_AUTHOR_EMAIL': 'adele-test@example.invalid',
          'GIT_COMMITTER_NAME': 'ADELE Test',
          'GIT_COMMITTER_EMAIL': 'adele-test@example.invalid',
          'GIT_AUTHOR_DATE': '2026-10-13T00:00:00Z',
          'GIT_COMMITTER_DATE': '2026-10-13T00:00:00Z',
        };
        Future<String> git(Directory directory, List<String> arguments) async {
          final result = await Process.run(
            'git',
            ['--literal-pathspecs', '-C', directory.path, ...arguments],
            environment: environment,
            includeParentEnvironment: false,
          );
          expect(result.exitCode, 0, reason: '${result.stderr}');
          return result.stdout as String;
        }

        final scopes = {
          'selected': scope.isEmpty ? '' : '$scope/',
          // This sibling would match the selected scope if treated as a glob.
          if (scope.isNotEmpty) 'sibling': 'nested source/x-other/',
        };
        await git(source, ['init', '-b', 'main']);
        File(
          '${source.path}/.gitignore',
        ).writeAsStringSync('.adele/\nignored.txt\n');
        for (final entry in scopes.entries) {
          for (final layer in ['committed', 'staged', 'unstaged']) {
            final file = File(
              '${source.path}/${entry.value}${entry.key}-$layer.txt',
            );
            file.parent.createSync(recursive: true);
            file.writeAsStringSync('${entry.key} $layer baseline\n');
          }
        }
        await git(source, ['add', '.']);
        await git(source, ['commit', '-m', 'Baseline']);
        final baseline = (await git(source, ['rev-parse', 'HEAD'])).trim();
        await git(source, [
          'worktree',
          'add',
          '-b',
          'adele-primary',
          fixture.worktree.path,
          baseline,
        ]);
        fixture.setBaseline(baseline);
        for (final entry in scopes.entries) {
          final committed = '${entry.value}${entry.key}-committed.txt';
          File(
            '${fixture.worktree.path}/$committed',
          ).writeAsStringSync('${entry.key} committed change\n');
          await git(fixture.worktree, ['add', '--', committed]);
          await git(fixture.worktree, [
            'commit',
            '-m',
            '${entry.key} post-baseline commit',
          ]);
        }
        for (final entry in scopes.entries) {
          for (final layer in ['staged', 'unstaged', 'untracked']) {
            final path = '${entry.value}${entry.key}-$layer.txt';
            File(
              '${fixture.worktree.path}/$path',
            ).writeAsStringSync('${entry.key} $layer change\n');
            if (layer == 'staged') {
              await git(fixture.worktree, ['add', '--', path]);
            }
          }
        }
        File(
          '${fixture.selected.path}/ignored.txt',
        ).writeAsStringSync('ignored');

        final handoff = fixture.capture();
        expect(handoff.worktreeRoot, fixture.worktree.path);
        expect(handoff.sourceRelativePath, scope);
        expect(handoff.baselineCommit, baseline);
        expect(
          (await git(fixture.worktree, ['rev-parse', 'HEAD'])).trim(),
          isNot(baseline),
        );
        final commands = handoff
            .readme(createdAt)
            .split('```sh\n')[1]
            .split('```')[0]
            .trim()
            .split('\n');
        expect(commands, hasLength(6));
        final output = <String>[];
        for (final command in commands) {
          final result = await Process.run(
            'sh',
            ['-c', command],
            workingDirectory: temporary.path,
            environment: environment,
            includeParentEnvironment: false,
          );
          expect(result.exitCode, 0, reason: '$command\n${result.stderr}');
          output.add(result.stdout as String);
        }
        expect(output[0], contains('M  '));
        expect(output[0], contains(' M '));
        expect(output[0], contains('?? '));
        for (final layer in ['staged', 'unstaged', 'untracked']) {
          expect(output[0], contains('selected-$layer.txt'));
        }
        expect(output[1], contains('selected post-baseline commit'));
        for (final (index, layer) in [
          (2, 'committed'),
          (3, 'staged'),
          (4, 'unstaged'),
        ]) {
          expect(output[index], contains('selected-$layer.txt'));
          expect(output[index], contains('+selected $layer change'));
        }
        expect(output[5].trim(), '${scopes['selected']}selected-untracked.txt');
        for (final result in output) {
          expect(result, isNot(contains('sibling')));
          expect(result, isNot(contains('ignored.txt')));
        }
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'shell quoting keeps metacharacters literal in every scoped command',
    () async {
      const scope = r'''nested/quote'"$(printf BAD);[x]*?`printf BAD`''';
      final fixture = _Fixture(source, scope: scope);
      final handoff = fixture.capture();
      expect(handoff.sourceRelativePath, scope);
      expect(
        handoff.selectedSourceDirectory,
        '${fixture.worktree.path}/$scope',
      );
      final readme = handoff.readme(createdAt);
      final commands = readme.split('```sh\n')[1].split('```')[0].trim();
      // A shell function records argv without running Git or inspecting a checkout.
      final result = await Process.run('sh', [
        '-c',
        "git() { printf '%s\\0' \"\$@\"; printf 'END\\0'; }\n$commands",
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stderr, isEmpty);
      final invocations = result.stdout.toString().split('END\x00')
        ..removeLast();
      expect(invocations, hasLength(6));
      final arguments = invocations.map((line) {
        final values = line.split('\x00')..removeLast();
        expect(values.take(2), ['-C', fixture.worktree.path]);
        expect(values.sublist(values.length - 2), [
          '--',
          ':(top,literal)$scope',
        ]);
        return values;
      }).toList();
      expect(arguments[1], contains('${'a' * 40}..HEAD'));
      expect(arguments[2], contains('a' * 40));
      expect(arguments[2], contains('HEAD'));
      expect(arguments[3], contains('--cached'));
      expect(readme, contains("'\"'\"'"));
    },
    skip: Platform.isWindows,
  );
}

final class _Fixture {
  _Fixture(
    Directory repository, {
    String scope = '',
    bool additional = false,
    String providerId = 'dev.adele.environment.git-worktree',
    Uri? sourceLocation,
    String title = 'Evaluate the selected Task',
    bool backing = true,
  }) {
    Directory('${repository.path}/.git').createSync();
    source = scope.isEmpty
        ? repository
        : (Directory('${repository.path}/$scope')..createSync(recursive: true));
    project = Project(
      id: ProjectId('project'),
      sourceLocation: sourceLocation ?? source.uri,
    );
    task = Task(id: TaskId('task'), projectId: project.id, title: title);
    Environment createEnvironment(String name, EnvironmentRole role) =>
        Environment(
          id: EnvironmentId(name),
          taskId: task.id,
          role: role,
          providerId: ProviderId(
            role == EnvironmentRole.primary && additional
                ? 'dev.adele.environment.git-worktree'
                : providerId,
          ),
          providerState: {
            'schemaVersion': 2,
            'environmentId': name,
            'sourceRelativePath': scope,
            'worktreeRelativePath': '.adele/worktrees/$name',
            'branch': 'adele-$name',
          },
        );
    final primary = createEnvironment('primary', EnvironmentRole.primary);
    environment = additional
        ? createEnvironment('additional', EnvironmentRole.additional)
        : primary;
    session = Session(
      id: SessionId('session'),
      taskId: task.id,
      strategyId: OrchestrationStrategyId('unavailable.strategy'),
    );
    store.publishRestoredProject(
      project: project,
      tasks: [task],
      environments: [primary, if (additional) environment],
      sessions: [session],
      authorities: [(session.id, environment.id)],
      runRecords: [],
    );
    lifecycle = ProductLifecycleCoordinator.generated(
      store: store,
      registry: CapabilityRegistry(),
      extensions: ExtensionRegistry(),
    );
    addTearDown(lifecycle.close);
    if (backing) {
      database = lifecycle.databaseForSession(
        session.id,
        accessMode: ProjectStorageAccessMode.durableOrTemporary,
      )!;
      database.ensurePluginSchema('dev.adele.plugin.git', [
        '''CREATE TABLE adele_git_task_anchors (
          environment_id TEXT PRIMARY KEY,
          baseline_commit TEXT,
          expected_branch_ref TEXT
        )''',
      ]);
      for (final value in [primary, if (additional) environment]) {
        database.executePluginTransaction([
          RelationalStatement(
            sql:
                'INSERT INTO adele_git_task_anchors VALUES (:id,:baseline,:branch)',
            parameters: {
              ':id': value.id.value,
              ':baseline': value.role == EnvironmentRole.primary
                  ? 'a' * 40
                  : 'b' * 64,
              ':branch': 'refs/heads/${value.providerState!['branch']}',
            },
            expectedRows: 1,
          ),
        ]);
      }
    }
    worktree = Directory(
      '${source.path}/.adele/worktrees/${environment.id.value}',
    )..createSync(recursive: true);
    File(
      '${worktree.path}/.git',
    ).writeAsStringSync('gitdir: unused-metadata\n');
    selected = scope.isEmpty
        ? worktree
        : (Directory('${worktree.path}/$scope')..createSync(recursive: true));
  }

  final store = InMemoryProductStore();
  late final ProductLifecycleCoordinator lifecycle;
  late final ProjectDatabase database;
  late final Project project;
  late final Task task;
  late final Session session;
  late final Environment environment;
  late final Directory source;
  late final Directory worktree;
  late final Directory selected;

  SessionEvaluationHandoff capture() =>
      SessionEvaluationHandoff.capture(lifecycle, session);

  void setBaseline(Object? baseline) => database.executePluginTransaction([
    RelationalStatement(
      sql:
          'UPDATE adele_git_task_anchors SET baseline_commit=:baseline WHERE environment_id=:id',
      parameters: {':baseline': baseline, ':id': environment.id.value},
      expectedRows: 1,
    ),
  ]);

  void replaceState(Map<String, Object?> state) => store.replaceEnvironment(
    Environment(
      id: environment.id,
      taskId: environment.taskId,
      role: environment.role,
      providerId: environment.providerId,
      providerState: state,
    ),
  );
}
