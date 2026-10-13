import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_environment_backend/git_environment_backend.dart';
import 'package:git_environment_backend/src/git_change_set_source.dart';
import 'package:git_environment_backend/src/git_process_environment.dart';
import 'package:test/test.dart';

void main() {
  late Directory container;
  late Directory repository;
  late GitWorktreeEnvironmentProvider provider;
  late _Authority authority;
  late String baselineCommit;
  late String branch;

  setUp(() async {
    container = await Directory.systemTemp.createTemp('adele-change-set-test-');
    repository = await Directory('${container.path}/repository').create();
    await _git(repository, ['init']);
    await _git(repository, ['config', 'user.name', 'ADELE Test']);
    await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
    await File('${repository.path}/baseline').writeAsString('baseline\n');
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Fixture']);
    baselineCommit = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
    branch = (await _git(repository, [
      'symbolic-ref',
      '--short',
      'HEAD',
    ])).trim();
    provider = GitWorktreeEnvironmentProvider();
    authority = _Authority('selected');
    provider.liveObjects.bind(
      EnvironmentId('selected'),
      WorktreeEnvironment(
        repository,
        gitWorktreeRoot: repository,
        gitDirectory: Directory('${repository.path}/.git'),
        gitCommonDirectory: Directory('${repository.path}/.git'),
        baselineCommit: baselineCommit,
        branch: branch,
      ),
    );
  });
  tearDown(() async {
    await provider.close();
    await container.delete(recursive: true);
  });

  GitChangeSetSourceService service({
    GitChangeSetLimits limits = const GitChangeSetLimits(),
    Map<String, String>? parentEnvironment,
  }) => GitChangeSetSourceService(
    provider: provider,
    authorizedRead: authority,
    limits: limits,
    parentEnvironment: {
      'PATH': Platform.environment['PATH']!,
      'HOME': container.path,
      'XDG_CONFIG_HOME': '${container.path}/config',
      ...?parentEnvironment,
    },
  );

  Future<ChangeSetSnapshot> snapshot({
    GitChangeSetLimits limits = const GitChangeSetLimits(),
    Map<String, String>? parentEnvironment,
  }) => service(
    limits: limits,
    parentEnvironment: parentEnvironment,
  ).snapshotUnstaged();

  Future<UncommittedChangeSetSnapshot> uncommitted({
    GitChangeSetLimits limits = const GitChangeSetLimits(),
    Map<String, String>? parentEnvironment,
  }) => service(
    limits: limits,
    parentEnvironment: parentEnvironment,
  ).snapshotUncommitted();

  Future<TaskChangeSetSnapshot> taskChanges({
    GitChangeSetLimits limits = const GitChangeSetLimits(),
    Map<String, String>? parentEnvironment,
  }) => service(
    limits: limits,
    parentEnvironment: parentEnvironment,
  ).snapshotTaskChanges();

  Future<ChangeSetSnapshot> workingChanges(
    String scope, {
    GitChangeSetLimits limits = const GitChangeSetLimits(),
  }) async => switch (scope) {
    'Unstaged' => await snapshot(limits: limits),
    'Uncommitted' => (await uncommitted(limits: limits)).unstaged,
    'Task' => (await taskChanges(limits: limits)).uncommitted.unstaged,
    _ => throw StateError('Unknown review scope: $scope'),
  };

  void bindTask({
    required String? baseline,
    required String? retainedBranch,
    Directory? root,
  }) {
    provider.liveObjects.unbind(EnvironmentId('selected'));
    provider.liveObjects.bind(
      EnvironmentId('selected'),
      WorktreeEnvironment(
        root ?? repository,
        gitWorktreeRoot: repository,
        gitDirectory: Directory('${repository.path}/.git'),
        gitCommonDirectory: Directory('${repository.path}/.git'),
        baselineCommit: baseline,
        branch: retainedBranch,
      ),
    );
  }

  test('Task is clean at baseline and exposes committed-only work', () async {
    final clean = await taskChanges(
      limits: const GitChangeSetLimits(
        totalBytes: 1,
        files: 1,
        inventoryEntries: 1,
      ),
    );
    expect(clean.committed.files, isEmpty);
    expect(clean.uncommitted.staged.files, isEmpty);
    expect(clean.uncommitted.unstaged.files, isEmpty);
    expect(clean.uncommitted.conflicts, isEmpty);
    await File('${repository.path}/baseline').writeAsString('committed\n');
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Committed only']);
    final result = await taskChanges();
    expect(result.committed.files.single.relativePath, 'baseline');
    expect(
      result.committed.files.single.hunks.single.lines.map(
        (l) => '${l.kind}:${l.text}',
      ),
      ['deletion:baseline', 'addition:committed'],
    );
    expect(result.uncommitted.staged.files, isEmpty);
    expect(result.uncommitted.unstaged.files, isEmpty);
    expect(result.uncommitted.conflicts, isEmpty);
    expect((await snapshot()).files, isEmpty);
    expect((await uncommitted()).staged.files, isEmpty);
    expect(authority.fileReads, 0);
  });

  test(
    'Task A to B to C to D preserves independent hunk coordinates',
    () async {
      final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
      final file = File('${repository.path}/baseline');
      await file.writeAsString(original);
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'A']);
      bindTask(
        baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
        retainedBranch: branch,
      );
      String content(String layer) => original
          .replaceFirst('line 1\n', '$layer first\n')
          .replaceFirst('line 27\n', '$layer last\n');
      await file.writeAsString(content('B'));
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'B']);
      await file.writeAsString(content('C'));
      await _git(repository, ['add', '.']);
      await file.writeAsString(content('D'));
      final result = await taskChanges();
      for (final (layer, before, after) in [
        (result.committed, ['line 1', 'line 27'], ['B first', 'B last']),
        (
          result.uncommitted.staged,
          ['B first', 'B last'],
          ['C first', 'C last'],
        ),
        (
          result.uncommitted.unstaged,
          ['C first', 'C last'],
          ['D first', 'D last'],
        ),
      ]) {
        final changed = layer.files.single;
        expect(changed.relativePath, 'baseline');
        expect(changed.hunks, hasLength(2));
        expect(
          changed.hunks.map(
            (h) => (h.oldStart, h.oldCount, h.newStart, h.newCount),
          ),
          [(1, 5, 1, 5), (25, 6, 25, 6)],
        );
        expect(
          changed.hunks.map(
            (h) => h.lines.where((l) => l.kind == 'deletion').single.text,
          ),
          before,
        );
        expect(
          changed.hunks.map(
            (h) => h.lines.where((l) => l.kind == 'addition').single.text,
          ),
          after,
        );
      }
      expect(result.uncommitted.conflicts, isEmpty);
    },
  );

  test('Task cancellation never collapses its three layers', () async {
    final file = File('${repository.path}/baseline');
    await file.writeAsString('committed\n');
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'B']);
    await file.writeAsString('baseline\n');
    await _git(repository, ['add', '.']);
    await file.writeAsString('committed\n');
    final result = await taskChanges();
    for (final (layer, lines) in [
      (result.committed, ['baseline', 'committed']),
      (result.uncommitted.staged, ['committed', 'baseline']),
      (result.uncommitted.unstaged, ['baseline', 'committed']),
    ]) {
      expect(layer.files.single.hunks.single.lines.map((l) => l.text), lines);
    }
    await file.writeAsString('indexed\n');
    await _git(repository, ['add', '.']);
    await file.writeAsString('baseline\n');
    final baselineEqual = await taskChanges();
    for (final (layer, lines) in [
      (baselineEqual.committed, ['baseline', 'committed']),
      (baselineEqual.uncommitted.staged, ['committed', 'indexed']),
      (baselineEqual.uncommitted.unstaged, ['indexed', 'baseline']),
    ]) {
      expect(layer.files.single.hunks.single.lines.map((l) => l.text), lines);
    }
  });

  test(
    'Task committed changes are net baseline to HEAD across commits',
    () async {
      await File(
        '${repository.path}/temporary',
      ).writeAsString('intermediate\n');
      await File('${repository.path}/baseline').writeAsString('intermediate\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Intermediate']);
      await _git(repository, ['rm', 'temporary']);
      await File('${repository.path}/baseline').writeAsString('final\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Final']);
      final result = await taskChanges();
      expect(result.committed.files.single.relativePath, 'baseline');
      expect(
        result.committed.files.single.hunks.single.lines.map((l) => l.text),
        ['baseline', 'final'],
      );
      await File('${repository.path}/baseline').writeAsString('baseline\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Return to baseline']);
      expect((await taskChanges()).committed.files, isEmpty);
    },
  );

  test(
    'Task additions deletions and recreated files retain layer identity',
    () async {
      await _git(repository, ['rm', 'baseline']);
      await File(
        '${repository.path}/added',
      ).writeAsString('committed addition\n');
      await File('${repository.path}/empty').writeAsString('');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Committed paths']);
      await File(
        '${repository.path}/baseline',
      ).writeAsString('recreated staged\n');
      await _git(repository, ['add', 'baseline']);
      await _git(repository, ['rm', 'added']);
      await File(
        '${repository.path}/added',
      ).writeAsString('recreated working\n');
      await File(
        '${repository.path}/baseline',
      ).writeAsString('recreated working\n');
      final result = await taskChanges();
      expect(
        result.committed.files.map((f) => '${f.relativePath}:${f.changeKind}'),
        ['added:added', 'baseline:deleted', 'empty:added'],
      );
      final add = result.committed.files.first.hunks.single;
      final remove = result.committed.files[1].hunks.single;
      expect(
        (add.oldStart, add.oldCount, add.newStart, add.newCount),
        (0, 0, 1, 1),
      );
      expect(
        (remove.oldStart, remove.oldCount, remove.newStart, remove.newCount),
        (1, 1, 0, 0),
      );
      expect(result.committed.files.last.hunks, isEmpty);
      expect(
        result.uncommitted.staged.files.map(
          (f) => '${f.relativePath}:${f.changeKind}',
        ),
        ['added:deleted', 'baseline:added'],
      );
      expect(
        result.uncommitted.unstaged.files.map(
          (f) => '${f.relativePath}:${f.changeKind}',
        ),
        ['added:added', 'baseline:modified'],
      );
    },
  );

  test(
    'Task committed conflict path remains independent of unmerged stages',
    () async {
      await File('${repository.path}/baseline').writeAsString('committed\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Committed conflict path']);
      final oid = (await _git(repository, [
        'rev-parse',
        'HEAD:baseline',
      ])).trim();
      await _git(repository, ['update-index', '--force-remove', 'baseline']);
      await _git(
        repository,
        ['update-index', '--index-info'],
        input: [
          for (var i = 1; i <= 3; i++) '100644 $oid $i\tbaseline\n',
        ].join(),
      );
      final result = await taskChanges();
      expect(
        result.committed.files.single.hunks.single.lines.last.text,
        'committed',
      );
      expect(result.uncommitted.staged.files, isEmpty);
      expect(result.uncommitted.unstaged.files, isEmpty);
      expect(result.uncommitted.conflicts.single.relativePath, 'baseline');
      expect(result.uncommitted.conflicts.single.contentStatus, 'conflicted');
      await expectLater(
        taskChanges(limits: const GitChangeSetLimits(files: 1)),
        throwsA(_code('too_many_files')),
      );
    },
  );

  test(
    'Task source-scoped trees ignore siblings and nested Git redirection',
    () async {
      final nested = await Directory('${repository.path}/selected').create();
      for (final path in ['selected/same', 'outside']) {
        await File(
          '${repository.path}/$path',
        ).writeAsString('retained baseline\n');
      }
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Scoped baseline']);
      bindTask(
        baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
        retainedBranch: branch,
        root: nested,
      );
      for (final layer in ['committed', 'staged', 'working']) {
        for (final path in ['selected/same', 'outside']) {
          await File(
            '${repository.path}/$path',
          ).writeAsString('$layer $path\n');
        }
        if (layer != 'working') await _git(repository, ['add', '.']);
        if (layer == 'committed') {
          await _git(repository, ['commit', '-m', 'Scoped commit']);
        }
      }
      await _git(nested, ['init']);
      await _git(nested, ['config', 'core.worktree', container.path]);
      final result = await taskChanges(
        limits: const GitChangeSetLimits(inventoryEntries: 1),
      );
      for (final (layer, text) in [
        (result.committed, 'committed'),
        (result.uncommitted.staged, 'staged'),
        (result.uncommitted.unstaged, 'working'),
      ]) {
        expect(layer.files.single.relativePath, 'same');
        expect(
          layer.files.single.hunks.single.lines.last.text,
          '$text selected/same',
        );
      }
    },
  );

  test(
    'Task tree paths and committed nontext modes remain literal and explicit',
    () async {
      final paths = [
        ' space ',
        '-option',
        ':(glob)*',
        'tab\tfile',
        'line\nfile',
        r'back\slash',
      ];
      for (final path in [...paths, 'mode', 'binary', 'encoding']) {
        await File('${repository.path}/$path').writeAsString('before\r\nlast');
      }
      await Link('${repository.path}/link').create('/missing-original');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Unusual baseline']);
      bindTask(
        baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
        retainedBranch: branch,
      );
      for (final path in paths) {
        await File('${repository.path}/$path').writeAsString('after\r\nlast');
      }
      await File('${repository.path}/binary').writeAsBytes([0, 1]);
      await File('${repository.path}/encoding').writeAsBytes([255]);
      await Link('${repository.path}/link').update('/missing-after');
      await _git(repository, ['add', '.']);
      await _git(repository, ['update-index', '--chmod=+x', 'mode']);
      await _git(repository, [
        'update-index',
        '--add',
        '--cacheinfo',
        '160000,$baselineCommit,module',
      ]);
      await _git(repository, ['commit', '-m', 'Unusual HEAD']);
      final result = await taskChanges();
      final files = {for (final f in result.committed.files) f.relativePath: f};
      expect(
        files.keys,
        [...paths, 'binary', 'encoding', 'link', 'mode', 'module']..sort(),
      );
      for (final path in paths) {
        expect(files[path]!.hunks.single.lines.map((l) => l.text), [
          'before\r',
          'after\r',
          'last',
        ]);
        expect(files[path]!.hunks.single.lines.last.noNewline, isTrue);
      }
      expect(files['binary']!.contentStatus, 'binary');
      expect(files['mode']!.changeKind, 'typeChanged');
      for (final path in ['encoding', 'link', 'mode', 'module']) {
        expect(files[path]!.contentStatus, 'unsupported');
        expect(files[path]!.hunks, isEmpty);
      }
    },
    skip: Platform.isWindows,
  );

  for (final invalid in [
    'missing',
    'unavailable',
    'expression',
    'blob',
    'tree',
    'tag',
    'branch missing',
    'branch mismatch',
    'detached',
  ]) {
    test(
      'Task rejects $invalid metadata without disabling ordinary scopes',
      () async {
        String? baseline = baselineCommit;
        String? retainedBranch = branch;
        var code = 'invalid_baseline';
        switch (invalid) {
          case 'missing':
            baseline = null;
            code = 'baseline_unavailable';
          case 'unavailable':
            baseline = 'f' * 40;
            code = 'baseline_unavailable';
          case 'expression':
            baseline = 'HEAD^{commit}';
          case 'blob':
            baseline = (await _git(repository, [
              'rev-parse',
              'HEAD:baseline',
            ])).trim();
          case 'tree':
            baseline = (await _git(repository, [
              'rev-parse',
              'HEAD^{tree}',
            ])).trim();
          case 'tag':
            await _git(repository, ['tag', '-a', 'baseline-tag', '-m', 'Tag']);
            baseline = (await _git(repository, [
              'rev-parse',
              'baseline-tag',
            ])).trim();
          case 'branch missing':
            retainedBranch = null;
            code = 'branch_unavailable';
          case 'branch mismatch':
            await _git(repository, ['checkout', '-b', 'unexpected']);
            code = 'unexpected_branch';
          case 'detached':
            await _git(repository, ['checkout', '--detach', 'HEAD']);
            code = 'detached_head';
        }
        bindTask(baseline: baseline, retainedBranch: retainedBranch);
        await File('${repository.path}/baseline').writeAsString('index\n');
        await _git(repository, ['add', '.']);
        await File('${repository.path}/baseline').writeAsString('work\n');
        await expectLater(taskChanges(), throwsA(_code(code)));
        expect(
          (await snapshot()).files.single.hunks.single.lines.last.text,
          'work',
        );
        expect(
          (await uncommitted())
              .staged
              .files
              .single
              .hunks
              .single
              .lines
              .last
              .text,
          'index',
        );
      },
    );
  }

  test(
    'Task shares file content and line limits across all three layers',
    () async {
      final file = File('${repository.path}/baseline');
      await file.writeAsString('head\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Head']);
      await file.writeAsString('index\n');
      await _git(repository, ['add', '.']);
      await file.writeAsString('work\n');
      for (final (limits, code) in [
        (const GitChangeSetLimits(files: 2), 'too_many_files'),
        (const GitChangeSetLimits(lines: 4), 'snapshot_too_large'),
        (const GitChangeSetLimits(totalBytes: 250), 'snapshot_too_large'),
      ]) {
        final ordinary = await uncommitted(limits: limits);
        expect(ordinary.staged.files, hasLength(1));
        expect(ordinary.unstaged.files, hasLength(1));
        await expectLater(taskChanges(limits: limits), throwsA(_code(code)));
      }
      final complete = await taskChanges(
        limits: const GitChangeSetLimits(files: 3, lines: 6),
      );
      expect(complete.committed.files, hasLength(1));
      expect(complete.uncommitted.staged.files, hasLength(1));
      expect(complete.uncommitted.unstaged.files, hasLength(1));
    },
  );

  test(
    'Task bounds the baseline HEAD index and untracked union before sorting',
    () async {
      await _git(repository, ['rm', 'baseline']);
      await File('${repository.path}/head-only').writeAsString('head\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Head-only path']);
      await _git(repository, ['rm', 'head-only']);
      await File('${repository.path}/index-only').writeAsString('index\n');
      await _git(repository, ['add', '.']);
      await File('${repository.path}/untracked-only').writeAsString('work\n');
      expect(
        (await uncommitted(
          limits: const GitChangeSetLimits(inventoryEntries: 3),
        )).staged.files,
        hasLength(2),
      );
      await expectLater(
        taskChanges(limits: const GitChangeSetLimits(inventoryEntries: 3)),
        throwsA(_code('inventory_too_large')),
      );
      final result = await taskChanges(
        limits: const GitChangeSetLimits(inventoryEntries: 4),
      );
      expect(result.committed.files.map((f) => f.relativePath), [
        'baseline',
        'head-only',
      ]);
      expect(result.uncommitted.staged.files.map((f) => f.relativePath), [
        'head-only',
        'index-only',
      ]);
      expect(
        result.uncommitted.unstaged.files.single.relativePath,
        'untracked-only',
      );
    },
  );

  test(
    'Task charges binary inputs across layers and bounded sides of oversized pairs',
    () async {
      final file = File('${repository.path}/baseline');
      await file.writeAsBytes([0, 1, 1]);
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Binary baseline']);
      bindTask(
        baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
        retainedBranch: branch,
      );
      await file.writeAsBytes([0, 2, 2]);
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Binary HEAD']);
      await file.writeAsBytes([0, 3, 3]);
      await _git(repository, ['add', '.']);
      await file.writeAsBytes([0, 4, 4]);
      final ordinary = await uncommitted(
        limits: const GitChangeSetLimits(totalBytes: 12),
      );
      expect(ordinary.staged.files.single.contentStatus, 'binary');
      expect(ordinary.unstaged.files.single.contentStatus, 'binary');
      await expectLater(
        taskChanges(limits: const GitChangeSetLimits(totalBytes: 12)),
        throwsA(_code('snapshot_too_large')),
      );
      for (final oversized in ['baseline', 'HEAD']) {
        await file.writeAsString(
          oversized == 'baseline' ? 'x' * 100 : 'small\n',
        );
        await _git(repository, ['add', '.']);
        await _git(repository, [
          'commit',
          '--allow-empty',
          '-m',
          'Oversized pair baseline',
        ]);
        bindTask(
          baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
          retainedBranch: branch,
        );
        await file.writeAsString(oversized == 'HEAD' ? 'x' * 100 : 'small\n');
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Oversized pair HEAD']);
        expect(
          (await taskChanges(
            limits: const GitChangeSetLimits(fileBytes: 20),
          )).committed.files.single.contentStatus,
          'oversized',
        );
        await expectLater(
          taskChanges(
            limits: const GitChangeSetLimits(fileBytes: 20, totalBytes: 5),
          ),
          throwsA(_code('snapshot_too_large')),
        );
      }
    },
  );

  test(
    'Task shares escaped transport budget with both uncommitted layers',
    () async {
      final file = File('${repository.path}/baseline');
      final escaped = '\u0001' * 360000;
      await file.writeAsString(escaped);
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Escaped HEAD']);
      await file.writeAsString('baseline\n');
      await _git(repository, ['add', '.']);
      await file.writeAsString(escaped);
      final ordinary = await uncommitted();
      expect(ordinary.staged.files, hasLength(1));
      expect(ordinary.unstaged.files, hasLength(1));
      await expectLater(taskChanges(), throwsA(_code('snapshot_too_large')));
    },
  );

  for (final mutation in ['HEAD', 'branch', 'index', 'worktree']) {
    test('Task $mutation race rejects the whole observation', () async {
      final target = File('${repository.path}/baseline');
      await target.writeAsString('head\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Committed']);
      await _git(repository, ['branch', 'other']);
      await target.writeAsString('index\n');
      await _git(repository, ['add', '.']);
      await target.writeAsString('work\n');
      final next = (await _git(repository, [
        'commit-tree',
        'HEAD^{tree}',
        '-p',
        'HEAD',
        '-m',
        'Next',
      ])).trim();
      final action = switch (mutation) {
        'HEAD' =>
          '/usr/bin/git -C ${_quote(repository.path)} update-ref HEAD $next',
        'branch' =>
          '/usr/bin/git -C ${_quote(repository.path)} symbolic-ref HEAD refs/heads/other',
        'index' =>
          '/usr/bin/git -C ${_quote(repository.path)} update-index --force-remove baseline',
        _ => '/usr/bin/printf "raced content\\n" > ${_quote(target.path)}',
      };
      final first = File('${container.path}/first-patch');
      final second = File('${container.path}/second-patch');
      final raced = File('${container.path}/raced');
      final shim = await _shim(container, '''
case " \$* " in
  *" --no-index "*)
    if [ -e ${_quote(second.path)} ]; then $action; /usr/bin/touch ${_quote(raced.path)};
    elif [ -e ${_quote(first.path)} ]; then /usr/bin/touch ${_quote(second.path)};
    else /usr/bin/touch ${_quote(first.path)}; fi ;;
esac
exec /usr/bin/git "\$@"
''');
      TaskChangeSetSnapshot? published;
      await expectLater(
        taskChanges(
          parentEnvironment: {'PATH': shim.path},
        ).then((result) => published = result),
        throwsA(_code('snapshot_changed')),
      );
      expect(published, isNull);
      expect(await raced.exists(), isTrue);
    }, skip: !Platform.isLinux);
  }

  for (final mutation in [
    'baseline',
    'HEAD',
    'index',
    'worktree',
    'retired',
    'replaced',
    'authority',
    'revoked',
  ]) {
    test('Task rejects $mutation changes during authorized settlement', () async {
      await File('${repository.path}/baseline').writeAsString('committed\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Committed']);
      authority.onRead = (count) async {
        if (count != 2) return;
        switch (mutation) {
          case 'baseline':
            await File(
              '${repository.path}/.git/objects/${baselineCommit.substring(0, 2)}/${baselineCommit.substring(2)}',
            ).delete();
          case 'HEAD':
            await _git(repository, ['checkout', '-b', 'other']);
          case 'index':
            await _git(repository, [
              'update-index',
              '--force-remove',
              'baseline',
            ]);
          case 'worktree':
            await File('${repository.path}/baseline').writeAsString('raced\n');
          case 'retired':
            provider.liveObjects.unbind(EnvironmentId('selected'));
          case 'replaced':
            bindTask(baseline: baselineCommit, retainedBranch: branch);
          case 'authority':
            authority.sessionId = 'another-session';
          case 'revoked':
            throw StateError('revoked');
        }
      };
      TaskChangeSetSnapshot? published;
      await expectLater(
        taskChanges().then((result) => published = result),
        mutation == 'revoked'
            ? throwsStateError
            : throwsA(
                _code(switch (mutation) {
                  'retired' || 'replaced' => 'environment_not_live',
                  'authority' => 'authority_changed',
                  'baseline' => 'baseline_unavailable',
                  _ => 'snapshot_changed',
                }),
              ),
      );
      expect(published, isNull);
    });
  }

  test(
    'Task exact baseline reads ignore replacements conversions and hooks without mutation',
    () async {
      await File('${repository.path}/baseline').writeAsString('committed\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Committed']);
      await _git(repository, ['replace', baselineCommit, 'HEAD']);
      expect(
        (await taskChanges())
            .committed
            .files
            .single
            .hunks
            .single
            .lines
            .first
            .text,
        'baseline',
      );
      final sentinel = File('${container.path}/executed');
      for (final key in [
        'filter.evil.clean',
        'filter.evil.process',
        'diff.evil.textconv',
        'diff.external',
        'core.fsmonitor',
      ]) {
        await _git(repository, ['config', key, 'touch ${sentinel.path}']);
      }
      await File(
        '${repository.path}/.git/info/attributes',
      ).writeAsString('baseline filter=evil diff=evil\n');
      final hook = File('${repository.path}/.git/hooks/post-index-change');
      await hook.writeAsString('#!/bin/sh\ntouch ${_quote(sentinel.path)}\n');
      await Process.run('chmod', ['755', hook.path]);
      final paths = [
        '.git/HEAD',
        '.git/index',
        '.git/config',
        '.git/info/attributes',
        'baseline',
      ];
      final before = {
        for (final path in paths)
          path: await File('${repository.path}/$path').readAsBytes(),
      };
      final log = File('${container.path}/baseline-environment');
      final shim = await _shim(container, '''
case " \$* " in
  *" cat-file -t $baselineCommit "*) /usr/bin/env > ${_quote(log.path)} ;;
esac
exec /usr/bin/git "\$@"
''');
      final result = await taskChanges(
        parentEnvironment: {
          'PATH': shim.path,
          'GIT_NO_REPLACE_OBJECTS': '0',
          'GIT_NO_LAZY_FETCH': '0',
          'GIT_ALLOW_PROTOCOL': 'ext',
          'GIT_DIR': '/wrong',
          'GIT_INDEX_FILE': '/wrong',
          'OPENAI_API_KEY': 'secret',
        },
      );
      expect(result.committed.files.single.contentStatus, 'unsupported');
      expect(result.uncommitted.staged.files, isEmpty);
      expect(result.uncommitted.unstaged.files, isEmpty);
      expect(await sentinel.exists(), isFalse);
      final environment = await log.readAsString();
      expect(environment, contains('GIT_NO_REPLACE_OBJECTS=1\n'));
      expect(environment, contains('GIT_NO_LAZY_FETCH=1\n'));
      expect(environment, contains('GIT_ALLOW_PROTOCOL=\n'));
      expect(environment, isNot(contains('secret')));
      expect(environment, isNot(contains('GIT_INDEX_FILE=')));
      for (final path in paths) {
        expect(
          await File('${repository.path}/$path').readAsBytes(),
          before[path],
        );
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'Task unavailable baseline cannot invoke promisor transport helpers',
    () async {
      final sentinel = File('${container.path}/transport-executed');
      for (final (key, value) in [
        ('remote.origin.url', 'ext::/usr/bin/touch ${sentinel.path}'),
        ('remote.origin.promisor', 'true'),
        ('extensions.partialClone', 'origin'),
        ('protocol.ext.allow', 'always'),
      ]) {
        await _git(repository, ['config', key, value]);
      }
      bindTask(baseline: 'f' * 40, retainedBranch: branch);
      await expectLater(taskChanges(), throwsA(_code('baseline_unavailable')));
      expect(await sentinel.exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  for (final bound in ['stdout', 'stderr', 'process', 'operation']) {
    test('Task baseline validation respects $bound limits', () async {
      final action = switch (bound) {
        'stdout' => 'exec /usr/bin/yes',
        'stderr' => 'exec /usr/bin/yes >&2',
        _ => 'exec /bin/sleep 30',
      };
      final reached = File('${container.path}/baseline-validation');
      final shim = await _shim(container, '''
case " \$* " in
  *" cat-file -t $baselineCommit "*) /usr/bin/touch ${_quote(reached.path)}; $action ;;
esac
exec /usr/bin/git "\$@"
''');
      await expectLater(
        taskChanges(
          limits: GitChangeSetLimits(
            outputBytes: 64,
            stderrBytes: 64,
            processTimeout: Duration(
              milliseconds: bound == 'process' ? 500 : 10000,
            ),
            operationTimeout: Duration(
              milliseconds: bound == 'operation' ? 1000 : 30000,
            ),
          ),
          parentEnvironment: {'PATH': shim.path},
        ),
        throwsA(
          _code(switch (bound) {
            'stdout' => 'git_output_limit',
            'stderr' => 'git_diagnostic_limit',
            'process' => 'git_timeout',
            _ => 'operation_timeout',
          }),
        ),
      );
      expect(await reached.exists(), isTrue);
    }, skip: !Platform.isLinux);
  }

  test(
    'uncommitted separates staged unstaged partial hunks and cancellation',
    () async {
      final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
      for (final name in ['partial', 'cancel', 'staged', 'unstaged']) {
        await File('${repository.path}/$name').writeAsString(original);
      }
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Layers']);
      final indexed = original
          .replaceFirst('line 1\n', 'staged first\n')
          .replaceFirst('line 27\n', 'staged last\n');
      for (final name in ['partial', 'cancel', 'staged']) {
        await File('${repository.path}/$name').writeAsString(indexed);
      }
      await _git(repository, ['add', '.']);
      await File('${repository.path}/partial').writeAsString(
        indexed
            .replaceFirst('staged first\n', 'working first\n')
            .replaceFirst('staged last\n', 'working last\n'),
      );
      await File('${repository.path}/cancel').writeAsString(original);
      await File('${repository.path}/unstaged').writeAsString('working only\n');
      final index = await File('${repository.path}/.git/index').readAsBytes();
      final config = await File('${repository.path}/.git/config').readAsBytes();
      final result = await uncommitted();
      expect(result.staged.files.map((f) => f.relativePath), [
        'cancel',
        'partial',
        'staged',
      ]);
      expect(result.unstaged.files.map((f) => f.relativePath), [
        'cancel',
        'partial',
        'unstaged',
      ]);
      expect(result.conflicts, isEmpty);
      final staged = result.staged.files[1];
      final working = result.unstaged.files[1];
      expect(staged.hunks, hasLength(2));
      expect(working.hunks, hasLength(2));
      expect(
        staged.hunks.first.lines.where((l) => l.kind == 'addition').single.text,
        'staged first',
      );
      expect(
        working.hunks.first.lines
            .where((l) => l.kind == 'deletion')
            .single
            .text,
        'staged first',
      );
      expect(
        working.hunks.first.lines
            .where((l) => l.kind == 'addition')
            .single
            .text,
        'working first',
      );
      expect(
        result.unstaged.files.first.hunks.first.lines
            .where((l) => l.kind == 'addition')
            .single
            .text,
        'line 1',
      );
      expect(
        (await snapshot()).files.map((f) => f.relativePath),
        result.unstaged.files.map((f) => f.relativePath),
      );
      expect(await File('${repository.path}/.git/index').readAsBytes(), index);
      expect(
        await File('${repository.path}/.git/config').readAsBytes(),
        config,
      );
      expect(await File('${repository.path}/cancel').readAsString(), original);
      expect(authority.fileReads, 0);
    },
  );

  test(
    'staged additions deletions recreated deletions and ignored untracked paths',
    () async {
      await File('${repository.path}/deleted').writeAsString('deleted HEAD\n');
      await File(
        '${repository.path}/recreated',
      ).writeAsString('original HEAD\n');
      await File('${repository.path}/.gitignore').writeAsString('ignored\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Deletes']);
      await _git(repository, ['rm', 'deleted', 'recreated']);
      await File('${repository.path}/added').writeAsString('index addition\n');
      await File('${repository.path}/empty').writeAsString('');
      await _git(repository, ['add', 'added', 'empty']);
      await File(
        '${repository.path}/added',
      ).writeAsString('working addition\n');
      await File(
        '${repository.path}/recreated',
      ).writeAsString('recreated working\n');
      await File('${repository.path}/untracked').writeAsString('untracked\n');
      await File('${repository.path}/ignored').writeAsString('ignored\n');
      final result = await uncommitted();
      expect(
        result.staged.files.map((f) => '${f.relativePath}:${f.changeKind}'),
        ['added:added', 'deleted:deleted', 'empty:added', 'recreated:deleted'],
      );
      expect(
        result.staged.files.first.hunks.single.lines.single.text,
        'index addition',
      );
      final addition = result.staged.files.first.hunks.single;
      expect(
        (
          addition.oldStart,
          addition.oldCount,
          addition.newStart,
          addition.newCount,
        ),
        (0, 0, 1, 1),
      );
      final deletion = result.staged.files[1].hunks.single;
      expect(
        (
          deletion.oldStart,
          deletion.oldCount,
          deletion.newStart,
          deletion.newCount,
        ),
        (1, 1, 0, 0),
      );
      expect(result.staged.files[2].hunks, isEmpty);
      expect(
        result.staged.files.last.hunks.single.lines.single.text,
        'original HEAD',
      );
      expect(
        result.unstaged.files.map((f) => '${f.relativePath}:${f.changeKind}'),
        ['added:modified', 'recreated:added', 'untracked:added'],
      );
    },
  );

  test(
    'intent to add is unstaged and all conflict stages have one separate entry',
    () async {
      for (final name in ['intent', 'intent-empty']) {
        await File(
          '${repository.path}/$name',
        ).writeAsString(name == 'intent' ? 'intent\n' : '');
        await _git(repository, ['add', '-N', name]);
      }
      final oids = <String>[];
      for (final content in ['base\n', 'ours\n', 'theirs\n']) {
        oids.add(
          (await _git(repository, [
            'hash-object',
            '-w',
            '--stdin',
          ], input: content)).trim(),
        );
      }
      await _git(
        repository,
        ['update-index', '--index-info'],
        input: [
          for (var i = 0; i < 3; i++) '100644 ${oids[i]} ${i + 1}\tconflict\n',
        ].join(),
      );
      await File(
        '${repository.path}/conflict',
      ).writeAsString('conflicted working\n');
      final result = await uncommitted();
      expect(result.staged.files, isEmpty);
      expect(result.unstaged.files.map((f) => f.relativePath), [
        'intent',
        'intent-empty',
      ]);
      expect(
        result.unstaged.files.every((f) => f.changeKind == 'added'),
        isTrue,
      );
      expect(result.conflicts.single.relativePath, 'conflict');
      expect(result.conflicts.single.changeKind, 'conflicted');
      expect(result.conflicts.single.contentStatus, 'conflicted');
      expect(result.conflicts.single.hunks, isEmpty);
      expect((await snapshot()).files.first.contentStatus, 'conflicted');
      await expectLater(
        uncommitted(limits: const GitChangeSetLimits(files: 2)),
        throwsA(_code('too_many_files')),
      );
    },
  );

  test(
    'uncommitted nested scope uses Environment relative HEAD and index paths',
    () async {
      final nested = await Directory('${repository.path}/selected').create();
      for (final path in ['selected/same', 'outside']) {
        await File('${repository.path}/$path').writeAsString('HEAD\n');
      }
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Nested layers']);
      for (final path in ['selected/same', 'outside']) {
        await File('${repository.path}/$path').writeAsString('index $path\n');
      }
      await _git(repository, ['add', '.']);
      await File('${nested.path}/same').writeAsString('working selected\n');
      provider.liveObjects.unbind(EnvironmentId('selected'));
      provider.liveObjects.bind(
        EnvironmentId('selected'),
        WorktreeEnvironment(
          nested,
          gitWorktreeRoot: repository,
          gitDirectory: Directory('${repository.path}/.git'),
          gitCommonDirectory: Directory('${repository.path}/.git'),
        ),
      );
      await _git(nested, ['init']);
      final result = await uncommitted();
      expect(result.staged.files.single.relativePath, 'same');
      expect(
        result.staged.files.single.hunks.single.lines.last.text,
        'index selected/same',
      );
      expect(result.unstaged.files.single.relativePath, 'same');
      expect(
        result.unstaged.files.single.hunks.single.lines.last.text,
        'working selected',
      );
      expect(result.conflicts, isEmpty);
    },
  );

  test(
    'staged NUL tree inventory preserves literal unusual paths',
    () async {
      final paths = [
        ' space ',
        '-option',
        ':(glob)*',
        'tab\tfile',
        'line\nfile',
        r'back\slash',
      ];
      for (final path in paths) {
        await File('${repository.path}/$path').writeAsString('HEAD\n');
      }
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Literal HEAD paths']);
      for (final path in paths) {
        await File('${repository.path}/$path').writeAsString('index\n');
      }
      await _git(repository, ['add', '.']);
      final result = await uncommitted();
      expect(result.staged.files.map((f) => f.relativePath), paths..sort());
      expect(
        result.staged.files.every((f) => f.contentStatus == 'text'),
        isTrue,
      );
      expect(result.unstaged.files, isEmpty);
    },
    skip: Platform.isWindows,
  );

  test(
    'staged unsupported modes flags links gitlinks and nontext remain explicit',
    () async {
      for (final name in ['mode', 'skip', 'assume', 'binary', 'encoding']) {
        await File('${repository.path}/$name').writeAsString('HEAD\n');
      }
      await Link('${repository.path}/link').create('missing-before');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Types']);
      await File('${repository.path}/binary').writeAsBytes([1, 0, 2]);
      await File('${repository.path}/encoding').writeAsBytes([255]);
      await Link('${repository.path}/link').update('missing-after');
      await _git(repository, ['update-index', '--chmod=+x', 'mode']);
      await _git(repository, ['add', 'binary', 'encoding', 'link']);
      await _git(repository, ['update-index', '--skip-worktree', 'skip']);
      await _git(repository, ['update-index', '--assume-unchanged', 'assume']);
      final commit = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
      await _git(repository, [
        'update-index',
        '--add',
        '--cacheinfo',
        '160000,$commit,module',
      ]);
      final result = await uncommitted();
      final staged = {for (final f in result.staged.files) f.relativePath: f};
      expect(staged.keys, ['binary', 'encoding', 'link', 'mode', 'module']);
      expect(staged['binary']!.contentStatus, 'binary');
      expect(staged['mode']!.changeKind, 'typeChanged');
      expect(staged.values.every((f) => f.hunks.isEmpty), isTrue);
      expect(
        staged.values.where((f) => f.contentStatus == 'unsupported'),
        hasLength(4),
      );
      final working = {
        for (final f in result.unstaged.files) f.relativePath: f,
      };
      expect(working['skip']!.contentStatus, 'unsupported');
      expect(working['assume']!.contentStatus, 'unsupported');
      expect(working['module']!.contentStatus, 'unsupported');
      expect(await Link('${repository.path}/link').target(), 'missing-after');
    },
    skip: Platform.isWindows,
  );

  test(
    'staged immutable blob sizes and combined layer budgets are bounded',
    () async {
      await File('${repository.path}/baseline').writeAsString('index\n');
      await _git(repository, ['add', 'baseline']);
      await File('${repository.path}/baseline').writeAsString('work\n');
      await expectLater(
        uncommitted(limits: const GitChangeSetLimits(files: 1)),
        throwsA(_code('too_many_files')),
      );
      await expectLater(
        uncommitted(limits: const GitChangeSetLimits(lines: 3)),
        throwsA(_code('snapshot_too_large')),
      );
      // Each layer fits independently, their inputs plus patches do not.
      expect(
        (await snapshot(
          limits: const GitChangeSetLimits(totalBytes: 200),
        )).files,
        hasLength(1),
      );
      await expectLater(
        uncommitted(limits: const GitChangeSetLimits(totalBytes: 200)),
        throwsA(_code('snapshot_too_large')),
      );
      await File('${repository.path}/baseline').writeAsString('index\n');
      expect(
        (await uncommitted(
          limits: const GitChangeSetLimits(totalBytes: 200),
        )).staged.files,
        hasLength(1),
      );
      await File('${repository.path}/baseline').writeAsString('work\n');
      await File('${repository.path}/large').writeAsString('x' * 100);
      await _git(repository, ['add', 'large']);
      await File('${repository.path}/large').writeAsString('small\n');
      final result = await uncommitted(
        limits: const GitChangeSetLimits(fileBytes: 20),
      );
      expect(result.staged.files.last.contentStatus, 'oversized');
      expect(result.unstaged.files.last.contentStatus, 'oversized');
      await _git(repository, ['commit', '-m', 'Large HEAD']);
      await _git(repository, ['rm', '--cached', 'large']);
      expect(
        (await uncommitted(
          limits: const GitChangeSetLimits(fileBytes: 20),
        )).staged.files.single.contentStatus,
        'oversized',
      );
    },
  );

  test(
    'clean snapshots consume no changed content budget and HEAD index union are bounded',
    () async {
      final clean = await uncommitted(
        limits: const GitChangeSetLimits(
          totalBytes: 1,
          files: 1,
          inventoryEntries: 1,
        ),
      );
      expect(clean.staged.files, isEmpty);
      expect(clean.unstaged.files, isEmpty);
      expect(clean.conflicts, isEmpty);
      await File('${repository.path}/deleted').writeAsString('old\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Inventory']);
      await _git(repository, ['rm', 'deleted']);
      await expectLater(
        uncommitted(limits: const GitChangeSetLimits(inventoryEntries: 1)),
        throwsA(_code('inventory_too_large')),
      );
      await File('${repository.path}/added').writeAsString('new\n');
      await _git(repository, ['add', 'added']);
      await expectLater(
        uncommitted(limits: const GitChangeSetLimits(inventoryEntries: 2)),
        throwsA(_code('inventory_too_large')),
      );
      await File('${repository.path}/another').writeAsString('new\n');
      await _git(repository, ['add', 'another']);
      await expectLater(
        uncommitted(limits: const GitChangeSetLimits(inventoryEntries: 2)),
        throwsA(_code('inventory_too_large')),
      );
    },
  );

  for (final oversized in ['staged HEAD', 'staged index', 'unstaged index']) {
    test(
      'bounded sides of oversized $oversized pairs share the aggregate budget',
      () async {
        for (final name in ['one', 'two']) {
          await File(
            '${repository.path}/$name',
          ).writeAsString(oversized == 'staged index' ? 'small\n' : 'x' * 100);
        }
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Oversized pairs']);
        for (final name in ['one', 'two']) {
          await File(
            '${repository.path}/$name',
          ).writeAsString(oversized == 'staged index' ? 'x' * 100 : 'small\n');
        }
        if (oversized != 'unstaged index') await _git(repository, ['add', '.']);
        final result = await uncommitted(
          limits: const GitChangeSetLimits(fileBytes: 20),
        );
        final files = oversized == 'unstaged index'
            ? result.unstaged.files
            : result.staged.files;
        expect(files, hasLength(2));
        expect(files.every((f) => f.contentStatus == 'oversized'), isTrue);
        await expectLater(
          uncommitted(
            limits: const GitChangeSetLimits(fileBytes: 20, totalBytes: 10),
          ),
          throwsA(_code('snapshot_too_large')),
        );
      },
    );
  }

  test(
    'escaped transport budget is shared by opposing layers of one path',
    () async {
      await File(
        '${repository.path}/baseline',
      ).writeAsString('\u0001' * 525000);
      await _git(repository, ['add', 'baseline']);
      await File('${repository.path}/baseline').writeAsString('baseline\n');
      await expectLater(uncommitted(), throwsA(_code('snapshot_too_large')));
    },
  );

  test(
    'staged read never invokes configured conversions hooks or mutates source',
    () async {
      await File('${repository.path}/baseline').writeAsString('index\n');
      await _git(repository, ['add', 'baseline']);
      final sentinel = File('${container.path}/executed');
      for (final key in [
        'filter.evil.clean',
        'filter.evil.process',
        'diff.evil.textconv',
        'diff.external',
        'core.fsmonitor',
      ]) {
        await _git(repository, ['config', key, 'touch ${sentinel.path}']);
      }
      await File(
        '${repository.path}/.git/info/attributes',
      ).writeAsString('baseline filter=evil diff=evil\n');
      final hook = File('${repository.path}/.git/hooks/post-index-change');
      await hook.writeAsString('#!/bin/sh\ntouch ${_quote(sentinel.path)}\n');
      await Process.run('chmod', ['755', hook.path]);
      final paths = [
        '.git/index',
        '.git/config',
        '.git/info/attributes',
        'baseline',
      ];
      final before = {
        for (final path in paths)
          path: await File('${repository.path}/$path').readAsBytes(),
      };
      final result = await uncommitted();
      expect(result.staged.files.single.contentStatus, 'unsupported');
      expect(result.unstaged.files, isEmpty);
      expect(await sentinel.exists(), isFalse);
      for (final path in paths) {
        expect(
          await File('${repository.path}/$path').readAsBytes(),
          before[path],
        );
      }
    },
    skip: !Platform.isLinux,
  );

  for (final mutation in ['HEAD', 'index', 'worktree']) {
    test('uncommitted $mutation race rejects both layers', () async {
      final target = File('${repository.path}/baseline');
      await target.writeAsString('index\n');
      await _git(repository, ['add', 'baseline']);
      await target.writeAsString('worktree\n');
      final next = (await _git(repository, [
        'commit-tree',
        'HEAD^{tree}',
        '-p',
        'HEAD',
        '-m',
        'Next',
      ])).trim();
      final action = switch (mutation) {
        'HEAD' =>
          '/usr/bin/git -C ${_quote(repository.path)} update-ref HEAD $next',
        'index' =>
          '/usr/bin/git -C ${_quote(repository.path)} update-index --force-remove baseline',
        _ => '/usr/bin/printf "raced content\\n" > ${_quote(target.path)}',
      };
      final count = File('${container.path}/patch-count');
      final shim = await _shim(container, '''
case " \$* " in
  *" --no-index "*)
    if [ -e ${_quote(count.path)} ]; then $action; else /usr/bin/touch ${_quote(count.path)}; fi ;;
esac
exec /usr/bin/git "\$@"
''');
      UncommittedChangeSetSnapshot? published;
      await expectLater(
        uncommitted(
          parentEnvironment: {'PATH': shim.path},
        ).then((result) => published = result),
        throwsA(_code('snapshot_changed')),
      );
      expect(published, isNull);
      expect(await count.exists(), isTrue);
    }, skip: !Platform.isLinux);
  }

  for (final stage in [2, 3]) {
    test(
      'conflict stage $stage identity is revalidated even with unchanged stage one',
      () async {
        final base = (await _git(repository, [
          'rev-parse',
          'HEAD:baseline',
        ])).trim();
        final other = (await _git(repository, [
          'hash-object',
          '-w',
          '--stdin',
        ], input: 'other\n')).trim();
        await _git(
          repository,
          ['update-index', '--index-info'],
          input: [
            for (var i = 1; i <= 3; i++) '100644 $base $i\tconflict\n',
          ].join(),
        );
        await File('${repository.path}/baseline').writeAsString('working\n');
        final shim = await _shim(container, '''
case " \$* " in
  *" --no-index "*) /usr/bin/printf '100644 $other $stage\\tconflict\\n' | /usr/bin/git -C ${_quote(repository.path)} update-index --index-info ;;
esac
exec /usr/bin/git "\$@"
''');
        await expectLater(
          uncommitted(parentEnvironment: {'PATH': shim.path}),
          throwsA(_code('snapshot_changed')),
        );
      },
      skip: !Platform.isLinux,
    );
  }

  test('uncommitted HEAD is revalidated after authorized settlement', () async {
    final head = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
    await _git(repository, ['branch', 'same-commit', head]);
    authority.onRead = (count) {
      if (count == 2) {
        File(
          '${repository.path}/.git/HEAD',
        ).writeAsStringSync('ref: refs/heads/same-commit\n');
      }
    };
    await expectLater(uncommitted(), throwsA(_code('snapshot_changed')));
  });

  test(
    'uncommitted process and operation deadlines do not publish clean results',
    () async {
      final shim = await _shim(container, 'exec /bin/sleep 30');
      await expectLater(
        uncommitted(
          limits: const GitChangeSetLimits(
            processTimeout: Duration(milliseconds: 50),
          ),
          parentEnvironment: {'PATH': shim.path},
        ),
        throwsA(_code('git_timeout')),
      );
      await expectLater(
        uncommitted(
          limits: const GitChangeSetLimits(
            operationTimeout: Duration(milliseconds: 50),
          ),
          parentEnvironment: {'PATH': shim.path},
        ),
        throwsA(_code('operation_timeout')),
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'real index versus worktree includes multiple hunks and excludes staged-only',
    () async {
      final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
      await File('${repository.path}/modified').writeAsString(original);
      await File('${repository.path}/deleted').writeAsString('delete me\n');
      await File('${repository.path}/staged-only').writeAsString('old\n');
      await File('${repository.path}/both').writeAsString('head\n');
      await File('${repository.path}/.gitignore').writeAsString('ignored\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Files']);
      await File('${repository.path}/modified').writeAsString(
        original
            .replaceFirst('line 1\n', 'first edit\n')
            .replaceFirst('line 27\n', 'last edit\n'),
      );
      await File('${repository.path}/deleted').delete();
      await File('${repository.path}/staged-only').writeAsString('staged\n');
      await File('${repository.path}/both').writeAsString('index\n');
      await _git(repository, ['add', 'staged-only', 'both']);
      await File('${repository.path}/both').writeAsString('working\n');
      await File('${repository.path}/new').writeAsString('new file\nlast line');
      await File('${repository.path}/empty').writeAsString('');
      await File('${repository.path}/ignored').writeAsString('ignored\n');
      final index = await File('${repository.path}/.git/index').readAsBytes();
      final config = await File('${repository.path}/.git/config').readAsBytes();
      final result = await snapshot();
      expect(result.files.map((f) => f.relativePath), [
        'both',
        'deleted',
        'empty',
        'modified',
        'new',
      ]);
      final both = result.files.first;
      expect(both.hunks.single.lines.map((l) => '${l.kind}:${l.text}'), [
        'deletion:index',
        'addition:working',
      ]);
      expect(result.files[1].changeKind, 'deleted');
      expect(result.files[1].hunks.single.newCount, 0);
      expect(result.files[2].changeKind, 'added');
      expect(result.files[2].hunks, isEmpty);
      expect(result.files[3].hunks, hasLength(2));
      expect(result.files.last.hunks.single.lines.last.noNewline, isTrue);
      expect(result.files.last.hunks.single.lines.first.noNewline, isFalse);
      expect(await File('${repository.path}/.git/index').readAsBytes(), index);
      expect(
        await File('${repository.path}/.git/config').readAsBytes(),
        config,
      );
      expect(
        await File('${repository.path}/modified').readAsString(),
        original
            .replaceFirst('line 1\n', 'first edit\n')
            .replaceFirst('line 27\n', 'last edit\n'),
      );
    },
  );

  test(
    'exact live Environment root confines nested source and sibling changes',
    () async {
      final nested = await Directory('${repository.path}/selected').create();
      final sibling = await Directory('${repository.path}/sibling').create();
      await File('${nested.path}/same').writeAsString('selected before\n');
      await File('${sibling.path}/same').writeAsString('sibling before\n');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Nested']);
      provider.liveObjects.unbind(EnvironmentId('selected'));
      provider.liveObjects.bind(
        EnvironmentId('selected'),
        WorktreeEnvironment(
          nested,
          gitWorktreeRoot: repository,
          gitDirectory: Directory('${repository.path}/.git'),
          gitCommonDirectory: Directory('${repository.path}/.git'),
        ),
      );
      provider.liveObjects.bind(
        EnvironmentId('primary'),
        WorktreeEnvironment(
          sibling,
          gitWorktreeRoot: repository,
          gitDirectory: Directory('${repository.path}/.git'),
          gitCommonDirectory: Directory('${repository.path}/.git'),
        ),
      );
      await File('${nested.path}/same').writeAsString('selected after\n');
      await File('${nested.path}/new').writeAsString('inside\n');
      await File('${sibling.path}/same').writeAsString('wrong primary\n');
      await File('${sibling.path}/outside').writeAsString('outside\n');
      final result = await snapshot();
      expect(result.files.map((f) => f.relativePath), ['new', 'same']);
      expect(result.files.last.hunks.single.lines.last.text, 'selected after');
      // A nested repository/config must not replace the provider-owned index.
      await _git(nested, ['init']);
      await _git(nested, ['config', 'core.worktree', sibling.path]);
      final afterRedirection = await snapshot();
      expect(afterRedirection.files.map((file) => file.relativePath), [
        'new',
        'same',
      ]);
      expect(
        afterRedirection.files.last.hunks.single.lines.last.text,
        'selected after',
      );
      authority.environmentId = 'missing';
      await expectLater(snapshot(), throwsA(_code('environment_not_live')));
      expect(authority.fileReads, 0);
    },
  );

  test(
    'effective config honors local overrides and disabled file modes',
    () async {
      await File(
        '${container.path}/.gitconfig',
      ).writeAsString('[core]\n\tautocrlf = true\n\tfilemode = true\n');
      await _git(repository, ['config', 'core.autocrlf', 'false']);
      await _git(repository, ['config', 'core.filemode', 'false']);
      final changed = File('${repository.path}/baseline');
      expect((await Process.run('chmod', ['755', changed.path])).exitCode, 0);
      expect((await snapshot()).files, isEmpty);
      await changed.writeAsString('real text change\n');
      final result = await snapshot();
      expect(result.files.single.contentStatus, 'text');
      expect(
        result.files.single.hunks.single.lines.last.text,
        'real text change',
      );
      await _git(repository, ['config', 'core.filemode', 'true']);
      expect((await snapshot()).files.single.changeKind, 'typeChanged');
    },
    skip: Platform.isWindows,
  );

  test(
    'NUL enumeration preserves spaces punctuation tabs newlines and literal magic',
    () async {
      final paths = [
        ' space file ',
        '-option',
        ':(glob)*',
        'star*?[x]',
        'quote"file',
        'tab\tfile',
        'line\nfile',
        r'back\slash',
      ];
      for (final path in paths) {
        await File('${repository.path}/$path').writeAsString('before\n');
      }
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Weird paths']);
      for (final path in paths) {
        await File('${repository.path}/$path').writeAsString('after $path\n');
      }
      await File(
        '${repository.path}/untracked\n:(glob)*',
      ).writeAsString('literal new\n');
      final result = await snapshot();
      expect(
        result.files.map((f) => f.relativePath),
        [...paths, 'untracked\n:(glob)*']..sort(),
      );
      expect(result.files.every((f) => f.contentStatus == 'text'), isTrue);
    },
    skip: Platform.isWindows,
  );

  for (final (initialMode, workingMode, indexMode, modeChanged) in [
    ('0644', '0645', '100644', false),
    ('0755', '0655', '100755', true),
  ]) {
    test(
      'Git owner-execute semantics for $initialMode to $workingMode',
      () async {
        await _git(repository, ['config', 'core.filemode', 'true']);
        final file = File('${repository.path}/permissions');
        await file.writeAsString('unchanged content\n');
        expect(
          (await Process.run('chmod', [initialMode, file.path])).exitCode,
          0,
        );
        await _git(repository, ['add', 'permissions']);
        await _git(repository, ['commit', '-m', 'Tracked mode']);
        expect(
          await _git(repository, ['ls-files', '--stage', '--', 'permissions']),
          startsWith('$indexMode '),
        );
        expect(
          (await Process.run('chmod', [workingMode, file.path])).exitCode,
          0,
        );
        final raw = await _git(repository, [
          'diff',
          '--no-ext-diff',
          '--no-textconv',
          '--raw',
          '--',
          'permissions',
        ]);
        expect(raw, modeChanged ? startsWith(':100755 100644 ') : isEmpty);
        final index = await File('${repository.path}/.git/index').readAsBytes();
        final result = await snapshot();
        if (modeChanged) {
          expect(result.files.single.relativePath, 'permissions');
          expect(result.files.single.changeKind, 'typeChanged');
          expect(result.files.single.contentStatus, 'unsupported');
          expect(result.files.single.hunks, isEmpty);
        } else {
          expect(result.files, isEmpty);
          await file.writeAsString('changed content\n');
          final text = (await snapshot()).files.single;
          expect(text.changeKind, 'modified');
          expect(text.contentStatus, 'text');
          expect(text.hunks.single.lines.last.text, 'changed content');
        }
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          index,
        );
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'stable tracked symlinks omit clean links and preserve dirty placeholders without following targets',
    () async {
      final original = '${container.path}/missing-original-target';
      final changed = '${container.path}/missing-changed-target';
      final link = Link('${repository.path}/a-link');
      await link.create(original);
      await _git(repository, ['add', 'a-link']);
      await _git(repository, ['commit', '-m', 'Tracked link']);
      final index = await File('${repository.path}/.git/index').readAsBytes();
      final config = await File('${repository.path}/.git/config').readAsBytes();
      expect((await snapshot()).files, isEmpty);
      await link.update(changed);
      final dirty = (await snapshot()).files.single;
      expect(dirty.relativePath, 'a-link');
      expect(dirty.contentStatus, 'unsupported');
      expect(dirty.hunks, isEmpty);
      expect(await link.target(), changed);
      expect(await File(original).exists(), isFalse);
      expect(await File(changed).exists(), isFalse);
      expect(authority.fileReads, 0);
      expect(await File('${repository.path}/.git/index').readAsBytes(), index);
      expect(
        await File('${repository.path}/.git/config').readAsBytes(),
        config,
      );
    },
    skip: Platform.isWindows,
  );

  for (final mutation in ['target', 'dirty target', 'missing', 'file']) {
    test(
      'observed tracked symlink $mutation race rejects the whole snapshot',
      () async {
        final original = '${container.path}/missing-original-target';
        final changed = '${container.path}/missing-changed-target';
        final link = Link('${repository.path}/a-link');
        final later = File('${repository.path}/z-later');
        await link.create(original);
        await later.writeAsString('before\n');
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Snapshot observations']);
        if (mutation == 'dirty target') {
          await link.update('${container.path}/missing-dirty-target');
        }
        await later.writeAsString('later edit\n');
        final index = await File('${repository.path}/.git/index').readAsBytes();
        final config = await File(
          '${repository.path}/.git/config',
        ).readAsBytes();
        final checkpoint = File('${container.path}/patch-observed');
        final action = switch (mutation) {
          'target' || 'dirty target' =>
            '/usr/bin/ln -sfn ${_quote(changed)} ${_quote(link.path)}',
          'missing' => '/usr/bin/rm -- ${_quote(link.path)}',
          'file' =>
            '/usr/bin/rm -- ${_quote(link.path)}; /usr/bin/printf %s ${_quote(original)} > ${_quote(link.path)}',
          _ => throw StateError('Unknown mutation'),
        };
        final shim = await _shim(container, '''
case " \$* " in
  *" --no-index "*)
    $action
    /usr/bin/printf 'observed\\n' > ${_quote(checkpoint.path)} ;;
esac
exec /usr/bin/git "\$@"
''');
        ChangeSetSnapshot? published;
        await expectLater(
          snapshot(
            parentEnvironment: {'PATH': shim.path},
          ).then((result) => published = result),
          throwsA(_code('snapshot_changed')),
        );
        expect(published, isNull);
        expect(await checkpoint.exists(), isTrue);
        expect(
          await FileSystemEntity.type(link.path, followLinks: false),
          switch (mutation) {
            'missing' => FileSystemEntityType.notFound,
            'file' => FileSystemEntityType.file,
            _ => FileSystemEntityType.link,
          },
        );
        if (mutation == 'target' || mutation == 'dirty target') {
          expect(await link.target(), changed);
        }
        expect(await File(original).exists(), isFalse);
        expect(await File(changed).exists(), isFalse);
        expect(authority.fileReads, 0);
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          index,
        );
        expect(
          await File('${repository.path}/.git/config').readAsBytes(),
          config,
        );
        expect(await later.readAsString(), 'later edit\n');
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'binary encoding symlink type and conflicts are explicit placeholders',
    () async {
      await File('${repository.path}/binary').writeAsBytes([1, 0, 2]);
      await File('${repository.path}/encoding').writeAsBytes([255]);
      await File('${repository.path}/mode').writeAsString('same\n');
      await File('${repository.path}/conflict').writeAsString('base\n');
      await Link('${repository.path}/tracked-link').create('baseline');
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'Nontext']);
      await File('${repository.path}/binary').writeAsBytes([2, 0, 3]);
      await File('${repository.path}/encoding').writeAsBytes([254]);
      await Link('${repository.path}/tracked-link').update('elsewhere');
      await Link('${repository.path}/untracked-link').create('/not/read');
      await Process.run('chmod', ['755', '${repository.path}/mode']);
      final oid = (await _git(repository, [
        'rev-parse',
        'HEAD:conflict',
      ])).trim();
      await _git(repository, ['update-index', '--force-remove', 'conflict']);
      await _git(
        repository,
        ['update-index', '--index-info'],
        input:
            '100644 $oid 1\tconflict\n100644 $oid 2\tconflict\n100644 $oid 3\tconflict\n',
      );
      final result = {
        for (final file in (await snapshot()).files) file.relativePath: file,
      };
      expect(result['binary']!.contentStatus, 'binary');
      expect(result['encoding']!.contentStatus, 'unsupported');
      expect(result['mode']!.changeKind, 'typeChanged');
      expect(result['tracked-link']!.contentStatus, 'unsupported');
      expect(result['untracked-link']!.contentStatus, 'unsupported');
      expect(result['conflict']!.contentStatus, 'conflicted');
      expect(
        result.values.every((f) => f.hunks.isEmpty && f.detail != null),
        isTrue,
      );
    },
    skip: Platform.isWindows,
  );

  test('dirty submodule remains an explicit unsupported entry', () async {
    final child = await Directory('${repository.path}/module').create();
    await _git(child, ['init']);
    await _git(child, ['config', 'user.name', 'ADELE Test']);
    await _git(child, ['config', 'user.email', 'adele@example.invalid']);
    await File('${child.path}/child').writeAsString('before\n');
    await File('${child.path}/child').setLastModified(DateTime.utc(2030));
    await _git(child, ['add', '.']);
    await _git(child, ['commit', '-m', 'Child']);
    final oid = (await _git(child, ['rev-parse', 'HEAD'])).trim();
    await _git(repository, [
      'update-index',
      '--add',
      '--cacheinfo',
      '160000,$oid,module',
    ]);
    await _git(repository, ['commit', '-m', 'Submodule']);
    expect((await snapshot()).files.single.changeKind, 'unsupported');
    final sentinel = File('${container.path}/child-filter-executed');
    await _git(child, [
      'config',
      'filter.child.clean',
      'touch ${sentinel.path}; cat',
    ]);
    await File(
      '${child.path}/.gitattributes',
    ).writeAsString('child filter=child\n');
    final result = (await snapshot()).files.single;
    expect(result.relativePath, 'module');
    expect(result.contentStatus, 'unsupported');
    expect(result.detail, contains('Submodule'));
    expect(await sentinel.exists(), isFalse);
  });

  test('stat dirty but equal content is not a changed file', () async {
    await File('${repository.path}/baseline').writeAsString('baseline\n');
    expect((await snapshot()).files, isEmpty);
  });

  test(
    'unchanged 1054288-byte tracked binary is clean without mutation',
    () async {
      final file = File('${repository.path}/large.bin');
      final bytes = _binaryBytes();
      expect(bytes, hasLength(1054288));
      await file.writeAsBytes(bytes);
      await _git(repository, ['add', 'large.bin']);
      await _git(repository, ['commit', '-m', 'Large binary']);
      await file.setLastModified(DateTime.utc(2000));
      final index = await File('${repository.path}/.git/index').readAsBytes();

      final result = await snapshot();

      expect(await file.readAsBytes(), bytes);
      expect(await File('${repository.path}/.git/index').readAsBytes(), index);
      expect(result.files, isEmpty);
      expect(authority.fileReads, 0);
    },
  );

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    test(
      '$scope verifies oversized binary and text without rendering them',
      () async {
        final binary = File('${repository.path}/large.bin');
        final text = File('${repository.path}/large.txt');
        final bytes = _binaryBytes();
        final content = '${'x' * 1054287}\n';
        await binary.writeAsBytes(bytes);
        await text.writeAsString(content);
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Oversized tracked files']);
        bindTask(
          baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
          retainedBranch: branch,
        );
        await binary.setLastModified(DateTime.utc(2000));
        await text.setLastModified(DateTime.utc(2000));
        final index = await File('${repository.path}/.git/index').readAsBytes();
        expect(
          (await workingChanges(
            scope,
            limits: const GitChangeSetLimits(totalBytes: 1, files: 1),
          )).files,
          isEmpty,
        );

        bytes[bytes.length - 1] ^= 1;
        await binary.writeAsBytes(bytes);
        await text.writeAsString(
          '${content.substring(0, content.length - 2)}y\n',
        );
        await File(
          '${repository.path}/baseline',
        ).writeAsString('visible edit\n');
        final result = await workingChanges(
          scope,
          limits: const GitChangeSetLimits(
            totalBytes: 1024,
            files: 3,
            lines: 2,
          ),
        );
        expect(result.files.map((f) => f.relativePath), [
          'baseline',
          'large.bin',
          'large.txt',
        ]);
        expect(result.files.first.contentStatus, 'text');
        expect(result.files.first.hunks.single.lines.map((l) => l.text), [
          'baseline',
          'visible edit',
        ]);
        for (final changed in result.files.skip(1)) {
          expect(changed.changeKind, 'modified');
          expect(changed.contentStatus, 'oversized');
          expect(changed.detail!.toLowerCase(), contains('raw'));
          expect(changed.detail!.toLowerCase(), contains('differ'));
          expect(changed.hunks, isEmpty);
        }
        expect(await binary.readAsBytes(), bytes);
        expect(
          await text.readAsString(),
          '${content.substring(0, content.length - 2)}y\n',
        );
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          index,
        );
        expect(authority.fileReads, 0);
      },
    );

    test(
      '$scope separates verification budgets from content budgets',
      () async {
        for (final name in ['a-large', 'b-large', 'c-large']) {
          await File(
            '${repository.path}/$name',
          ).writeAsBytes(_binaryBytes(128));
        }
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Verification budgets']);
        bindTask(
          baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
          retainedBranch: branch,
        );
        final changed = _binaryBytes(128)..[127] ^= 1;
        await File('${repository.path}/b-large').writeAsBytes(changed);
        final result = await workingChanges(
          scope,
          limits: const GitChangeSetLimits(
            fileBytes: 32,
            verificationFileBytes: 128,
            verificationTotalBytes: 256,
            totalBytes: 1,
          ),
        );
        expect(result.files.map((f) => f.relativePath), ['b-large', 'c-large']);
        expect(result.files.first.changeKind, 'modified');
        expect(result.files.first.detail!.toLowerCase(), contains('raw'));
        expect(result.files.last.changeKind, 'unsupported');
        expect(
          result.files.last.detail!.toLowerCase(),
          contains('unavailable'),
        );
        expect(
          result.files.every((f) => f.contentStatus == 'oversized'),
          isTrue,
        );
        expect(result.files.every((f) => f.hunks.isEmpty), isTrue);

        await File(
          '${repository.path}/a-large',
        ).writeAsBytes(_binaryBytes(129));
        await File(
          '${repository.path}/b-large',
        ).writeAsBytes(_binaryBytes(128));
        final perFile = await workingChanges(
          scope,
          limits: const GitChangeSetLimits(
            fileBytes: 32,
            verificationFileBytes: 128,
            verificationTotalBytes: 128,
            totalBytes: 1,
          ),
        );
        expect(perFile.files.map((f) => f.relativePath), [
          'a-large',
          'c-large',
        ]);
        for (final unknown in perFile.files) {
          expect(unknown.changeKind, 'unsupported');
          expect(unknown.contentStatus, 'oversized');
          expect(unknown.detail!.toLowerCase(), contains('unavailable'));
          expect(unknown.hunks, isEmpty);
        }
      },
    );

    test(
      '$scope does not spend verification bytes on untracked files',
      () async {
        await File(
          '${repository.path}/z-tracked',
        ).writeAsBytes(_binaryBytes(128));
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Tracked scan']);
        bindTask(
          baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
          retainedBranch: branch,
        );
        await File(
          '${repository.path}/a-untracked',
        ).writeAsBytes(_binaryBytes(128));
        final result = await workingChanges(
          scope,
          limits: const GitChangeSetLimits(
            fileBytes: 32,
            verificationFileBytes: 128,
            verificationTotalBytes: 128,
            totalBytes: 1,
          ),
        );
        expect(result.files.single.relativePath, 'a-untracked');
        expect(result.files.single.changeKind, 'added');
        expect(result.files.single.contentStatus, 'oversized');
        expect(result.files.single.hunks, isEmpty);
      },
    );

    for (final verified in [true, false]) {
      test(
        '$scope revalidates observed oversized files after verified=$verified',
        () async {
          final large = File('${repository.path}/a-large');
          await large.writeAsBytes(_binaryBytes(128));
          await File('${repository.path}/z-later').writeAsString('before\n');
          await _git(repository, ['add', '.']);
          await _git(repository, ['commit', '-m', 'Observed oversized file']);
          bindTask(
            baseline: (await _git(repository, ['rev-parse', 'HEAD'])).trim(),
            retainedBranch: branch,
          );
          await File('${repository.path}/z-later').writeAsString('after\n');
          final shim = await _shim(container, '''
case " \$* " in
  *" --no-index "*) /usr/bin/printf 'raced' >> ${_quote(large.path)} ;;
esac
exec /usr/bin/git "\$@"
''');
          final source = service(
            limits: GitChangeSetLimits(
              fileBytes: 32,
              verificationFileBytes: verified ? 128 : 1,
            ),
            parentEnvironment: {'PATH': shim.path},
          );
          final read = switch (scope) {
            'Unstaged' => source.snapshotUnstaged(),
            'Uncommitted' => source.snapshotUncommitted(),
            _ => source.snapshotTaskChanges(),
          };
          await expectLater(read, throwsA(_code('snapshot_changed')));
          expect(await large.length(), 133);
        },
        skip: !Platform.isLinux,
      );
    }
  }

  test('verification limits have independent reducible-only defaults', () {
    const defaults = GitChangeSetLimits();
    expect(defaults.verificationFileBytes, 16 * 1024 * 1024);
    expect(defaults.verificationTotalBytes, 64 * 1024 * 1024);
    expect(defaults.fileBytes, 1024 * 1024);
    expect(defaults.totalBytes, 8 * 1024 * 1024);
    for (final limits in [
      const GitChangeSetLimits(verificationFileBytes: 0),
      const GitChangeSetLimits(verificationTotalBytes: 0),
      GitChangeSetLimits(
        verificationFileBytes: defaults.verificationFileBytes + 1,
      ),
      GitChangeSetLimits(
        verificationTotalBytes: defaults.verificationTotalBytes + 1,
      ),
    ]) {
      expect(() => service(limits: limits), throwsArgumentError);
    }
    expect(
      () => service(
        limits: const GitChangeSetLimits(
          verificationFileBytes: 1,
          verificationTotalBytes: 1,
        ),
      ),
      returnsNormally,
    );
  });

  for (final behavior in [
    'partial reads',
    'early EOF',
    'read error',
    'growth',
    'same-size mutation',
    'timeout',
  ]) {
    test(
      'oversized verification handles $behavior without false clean results',
      () async {
        final target = File('${repository.path}/large');
        final bytes = _binaryBytes(65536 + 7);
        await target.writeAsBytes(bytes);
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Streaming verification']);
        final index = await File('${repository.path}/.git/index').readAsBytes();
        final release = Completer<void>();
        final closed = Completer<void>();
        var reads = 0;
        List<int>? firstBuffer;
        final overrides = _ReadOverrides(target.path, (
          file,
          buffer,
          start,
          end,
        ) async {
          reads++;
          expect(buffer, hasLength(65536));
          expect(end - start, inInclusiveRange(1, 65536));
          firstBuffer ??= buffer;
          expect(identical(buffer, firstBuffer), isTrue);
          if (reads == 2) {
            switch (behavior) {
              case 'early EOF':
                return 0;
              case 'read error':
                throw FileSystemException('Injected read failure', target.path);
              case 'growth':
                await target.writeAsString('x', mode: FileMode.append);
              case 'same-size mutation':
                bytes[0] ^= 1;
                await target.writeAsBytes(bytes);
                await target.setLastModified(DateTime.utc(2001));
              case 'timeout':
                await release.future;
            }
          }
          if (behavior == 'partial reads' && end - start > 4093) {
            end = start + 4093;
          }
          return file.readInto(buffer, start, end);
        }, () => closed.complete());
        ChangeSetSnapshot? published;
        final observation = IOOverrides.runWithIOOverrides(
          () => snapshot(
            limits: GitChangeSetLimits(
              fileBytes: 1024,
              operationTimeout: Duration(
                seconds: behavior == 'timeout' ? 2 : 30,
              ),
            ),
          ).then((result) => published = result),
          overrides,
        );
        try {
          if (behavior == 'partial reads' || behavior == 'read error') {
            final result = await observation;
            if (behavior == 'partial reads') {
              expect(result.files, isEmpty);
            } else {
              expect(result.files.single.contentStatus, 'oversized');
              expect(result.files.single.changeKind, 'unsupported');
              expect(result.files.single.detail, contains('unavailable'));
              expect(result.files.single.hunks, isEmpty);
            }
          } else {
            await expectLater(
              observation,
              throwsA(
                _code(
                  behavior == 'timeout'
                      ? 'operation_timeout'
                      : 'snapshot_changed',
                ),
              ),
            );
            expect(published, isNull);
          }
        } finally {
          release.complete();
          if (reads > 0) {
            await closed.future.timeout(const Duration(seconds: 5));
          }
        }
        expect(reads, greaterThanOrEqualTo(2));
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          index,
        );
        if (behavior != 'growth') expect(await target.readAsBytes(), bytes);
      },
    );
  }

  for (final (initial, working, fileMode, changed) in [
    ('0644', '0744', true, true),
    ('0755', '0655', true, true),
    ('0644', '0645', true, false),
    ('0644', '0744', false, false),
  ]) {
    test(
      'oversized mode $initial to $working honors core.filemode=$fileMode',
      () async {
        await _git(repository, ['config', 'core.filemode', 'true']);
        final file = File('${repository.path}/large');
        await file.writeAsBytes(_binaryBytes(128));
        expect((await Process.run('chmod', [initial, file.path])).exitCode, 0);
        await _git(repository, ['add', '.']);
        await _git(repository, ['commit', '-m', 'Oversized mode']);
        expect((await Process.run('chmod', [working, file.path])).exitCode, 0);
        await _git(repository, ['config', 'core.filemode', '$fileMode']);
        final result = await snapshot(
          limits: GitChangeSetLimits(
            fileBytes: 32,
            verificationFileBytes: changed ? 1 : 128,
          ),
        );
        if (changed) {
          expect(result.files.single.changeKind, 'typeChanged');
          expect(result.files.single.contentStatus, 'unsupported');
          expect(result.files.single.detail, contains('mode'));
          expect(result.files.single.hunks, isEmpty);
        } else {
          expect(result.files, isEmpty);
        }
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'SHA256 oversized raw hashes match the index in every review scope',
    () async {
      repository = await Directory('${container.path}/sha256').create();
      await _git(repository, ['init', '--object-format=sha256']);
      await _git(repository, ['config', 'user.name', 'ADELE Test']);
      await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
      final file = File('${repository.path}/large');
      final bytes = _binaryBytes();
      await file.writeAsBytes(bytes);
      await _git(repository, ['add', '.']);
      await _git(repository, ['commit', '-m', 'SHA256 oversized']);
      final commit = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
      expect(commit, hasLength(64));
      bindTask(
        baseline: commit,
        retainedBranch: (await _git(repository, [
          'symbolic-ref',
          '--short',
          'HEAD',
        ])).trim(),
      );
      final index = await File('${repository.path}/.git/index').readAsBytes();
      for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
        expect((await workingChanges(scope)).files, isEmpty);
      }
      bytes[bytes.length - 1] ^= 1;
      await file.writeAsBytes(bytes);
      for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
        final changed = (await workingChanges(scope)).files.single;
        expect(changed.changeKind, 'modified');
        expect(changed.contentStatus, 'oversized');
        expect(changed.detail!.toLowerCase(), contains('raw'));
        expect(changed.hunks, isEmpty);
      }
      expect(await file.readAsBytes(), bytes);
      expect(await File('${repository.path}/.git/index').readAsBytes(), index);
    },
  );

  test(
    'Uncommitted keeps staged new text beside a clean oversized binary',
    () async {
      final binary = File('${repository.path}/large.bin');
      final bytes = _binaryBytes();
      await binary.writeAsBytes(bytes);
      await _git(repository, ['add', 'large.bin']);
      await _git(repository, ['commit', '-m', 'Large binary']);
      await File(
        '${repository.path}/new.txt',
      ).writeAsString('staged addition\n');
      await _git(repository, ['add', 'new.txt']);
      final index = await File('${repository.path}/.git/index').readAsBytes();

      final result = await uncommitted(
        limits: const GitChangeSetLimits(totalBytes: 1024, files: 1),
      );

      expect(result.staged.files.single.relativePath, 'new.txt');
      expect(result.staged.files.single.changeKind, 'added');
      expect(result.staged.files.single.contentStatus, 'text');
      expect(
        result.staged.files.single.hunks.single.lines.single.text,
        'staged addition',
      );
      expect(result.unstaged.files, isEmpty);
      expect(result.conflicts, isEmpty);
      expect(await binary.readAsBytes(), bytes);
      expect(await File('${repository.path}/.git/index').readAsBytes(), index);
    },
  );

  test('stat-dirty unchanged binary and invalid UTF-8 are omitted', () async {
    for (final name in ['binary', 'encoding']) {
      await File(
        '${repository.path}/$name',
      ).writeAsBytes(name == 'binary' ? [1, 0, 2] : [255, 254]);
    }
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Nontext stat']);
    for (final name in ['binary', 'encoding']) {
      await File(
        '${repository.path}/$name',
      ).setLastModified(DateTime.utc(2000));
    }
    expect((await snapshot()).files, isEmpty);
  });

  test('racy tracked files cannot execute clean or process filters', () async {
    final target = File('${repository.path}/racy');
    await target.writeAsString('unchanged\n');
    await target.setLastModified(DateTime.utc(2030));
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Racy stat']);
    final sentinel = File('${container.path}/filter-executed');
    await File(
      '${repository.path}/.gitattributes',
    ).writeAsString('racy filter=evil\n');
    for (final command in ['clean', 'process']) {
      await _git(repository, [
        'config',
        'filter.evil.$command',
        'touch ${sentinel.path}; cat',
      ]);
    }
    await _git(repository, ['config', 'filter.evil.required', 'true']);
    await snapshot();
    expect(await sentinel.exists(), isFalse);
    await _git(repository, [
      'config',
      'filter.bad=name.clean',
      'touch ${sentinel.path}',
    ]);
    await snapshot();
    expect(await sentinel.exists(), isFalse);
    final clean = await snapshot(
      limits: const GitChangeSetLimits(fileBytes: 1),
    );
    expect(clean.files.where((file) => file.relativePath == 'racy'), isEmpty);
    await target.writeAsString('changed raw content\n');
    final oversized = (await snapshot(
      limits: const GitChangeSetLimits(fileBytes: 1),
    )).files.singleWhere((file) => file.relativePath == 'racy');
    expect(oversized.changeKind, 'modified');
    expect(oversized.contentStatus, 'oversized');
    expect(oversized.hunks, isEmpty);
    expect(await sentinel.exists(), isFalse);
  });

  test('core autocrlf never fabricates a raw-byte text edit', () async {
    await _git(repository, ['config', 'core.autocrlf', 'true']);
    final file = File('${repository.path}/crlf');
    await file.writeAsString('same\r\n');
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Normalized']);
    await file.setLastModified(DateTime.utc(2000));
    final result = (await snapshot()).files.single;
    expect(result.relativePath, 'crlf');
    expect(result.contentStatus, 'unsupported');
    expect(result.hunks, isEmpty);
    expect(
      await _git(repository, [
        'diff',
        '--no-ext-diff',
        '--no-textconv',
        '--',
        'crlf',
      ]),
      isEmpty,
    );
    final oversized = (await snapshot(
      limits: const GitChangeSetLimits(fileBytes: 1),
    )).files.single;
    expect(oversized.relativePath, 'crlf');
    expect(oversized.changeKind, 'modified');
    expect(oversized.contentStatus, 'oversized');
    expect(oversized.detail, contains('raw'));
    expect(oversized.hunks, isEmpty);
  });

  test(
    'global ignore discovery and conversion settings remain effective',
    () async {
      final home = await Directory('${container.path}/home').create();
      final config = await Directory(
        '${home.path}/.config/git',
      ).create(recursive: true);
      await File('${config.path}/ignore').writeAsString('ignored-global\n');
      await File(
        '${home.path}/.gitconfig',
      ).writeAsString('[core]\n\tautocrlf = true\n');
      final file = File('${repository.path}/global-crlf');
      await file.writeAsString('same\r\n');
      await _git(repository, [
        '-c',
        'core.autocrlf=true',
        'add',
        'global-crlf',
      ]);
      await _git(repository, ['commit', '-m', 'Global conversion']);
      await File(
        '${repository.path}/ignored-global',
      ).writeAsString('ignored\n');
      final environment = {
        'HOME': home.path,
        'XDG_CONFIG_HOME': '${home.path}/.config',
      };
      final result = (await snapshot(
        parentEnvironment: environment,
      )).files.single;
      expect(result.relativePath, 'global-crlf');
      expect(result.contentStatus, 'unsupported');
      expect(result.hunks, isEmpty);
      final explicit = File('${home.path}/explicit-ignore');
      await explicit.writeAsString('ignored-global\n');
      await File('${home.path}/.gitconfig').writeAsString(
        '[core]\n\tautocrlf = true\n\texcludesFile = ${explicit.path}\n',
      );
      expect(
        (await snapshot(
          parentEnvironment: environment,
        )).files.single.relativePath,
        'global-crlf',
      );
    },
  );

  test(
    'intent-to-add empty files and special index flags never look clean',
    () async {
      await File('${repository.path}/intent-empty').writeAsString('');
      await _git(repository, ['add', '--intent-to-add', 'intent-empty']);
      await _git(repository, ['update-index', '--skip-worktree', 'baseline']);
      await File('${repository.path}/baseline').delete();
      final files = {
        for (final file in (await snapshot()).files) file.relativePath: file,
      };
      expect(files['intent-empty']!.changeKind, 'added');
      expect(files['baseline']!.changeKind, 'unsupported');
      expect(files['baseline']!.contentStatus, 'unsupported');
      await expectLater(
        snapshot(limits: const GitChangeSetLimits(inventoryEntries: 1)),
        throwsA(_code('inventory_too_large')),
      );
    },
  );

  test(
    'new filter configured during inventory is never executed',
    () async {
      final baseline = File('${repository.path}/baseline');
      await baseline.setLastModified(DateTime.utc(2030));
      await _git(repository, ['add', 'baseline']);
      final sentinel = File('${container.path}/raced-filter-executed');
      final injected = File('${container.path}/injected');
      final attributes = File('${repository.path}/.git/info/attributes');
      final shim = await _shim(container, '''
case " \$* " in
  *" --stage "*) if [ ! -e ${_quote(injected.path)} ]; then
    /usr/bin/touch ${_quote(injected.path)}
    /usr/bin/git -C ${_quote(repository.path)} config filter.raced.clean ${_quote('touch ${sentinel.path}; cat')}
    /usr/bin/printf 'baseline filter=raced\\n' > ${_quote(attributes.path)}
  fi ;;
esac
exec /usr/bin/git "\$@"
''');
      final before = await File('${repository.path}/.git/index').readAsBytes();
      expect(
        (await snapshot(parentEnvironment: {'PATH': shim.path})).files,
        isEmpty,
      );
      expect(await injected.exists(), isTrue);
      expect(await sentinel.exists(), isFalse);
      expect(await File('${repository.path}/.git/index').readAsBytes(), before);
    },
    skip: !Platform.isLinux,
  );

  test(
    'conversion and binary attributes never execute filters or external diff',
    () async {
      final sentinel = File('${container.path}/executed');
      await _git(repository, [
        'config',
        'filter.evil.clean',
        'touch ${sentinel.path}',
      ]);
      await _git(repository, [
        'config',
        'diff.evil.textconv',
        'touch ${sentinel.path}',
      ]);
      await _git(repository, [
        'config',
        'diff.external',
        'touch ${sentinel.path}',
      ]);
      await _git(repository, [
        'config',
        'core.fsmonitor',
        'touch ${sentinel.path}',
      ]);
      await File('${repository.path}/.gitattributes').writeAsString(
        'baseline filter=evil\ncustom diff=evil\nopaque -diff\nencoded working-tree-encoding=UTF-16\n',
      );
      await File('${repository.path}/baseline').writeAsString('new content\n');
      await File('${repository.path}/custom').writeAsString('custom\n');
      await File(
        '${repository.path}/opaque',
      ).writeAsString('ascii but binary\n');
      await File('${repository.path}/encoded').writeAsString('encoded\n');
      final files = {
        for (final file in (await snapshot()).files) file.relativePath: file,
      };
      expect(files['baseline']!.contentStatus, 'unsupported');
      expect(files['custom']!.contentStatus, 'unsupported');
      expect(files['opaque']!.contentStatus, 'binary');
      expect(files['encoded']!.contentStatus, 'unsupported');
      expect(await sentinel.exists(), isFalse);
    },
  );

  test(
    'file and patch limits are placeholders; count and aggregate limits fail whole snapshot',
    () async {
      await File('${repository.path}/new').writeAsString('x' * 100);
      expect(
        (await snapshot(
          limits: const GitChangeSetLimits(fileBytes: 10),
        )).files.single.contentStatus,
        'oversized',
      );
      await File('${repository.path}/new').writeAsString('new\n');
      await File('${repository.path}/other').writeAsString('other\n');
      await expectLater(
        snapshot(limits: const GitChangeSetLimits(files: 1)),
        throwsA(_code('too_many_files')),
      );
      await expectLater(
        snapshot(limits: const GitChangeSetLimits(totalBytes: 1)),
        throwsA(_code('snapshot_too_large')),
      );
      await expectLater(
        snapshot(limits: const GitChangeSetLimits(lines: 1)),
        throwsA(_code('snapshot_too_large')),
      );
      await File('${repository.path}/other').delete();
      await File('${repository.path}/new').writeAsString('line\n' * 1000);
      // Attribute/enumeration output fits, but the generated patch does not.
      expect(
        (await snapshot(
          limits: const GitChangeSetLimits(outputBytes: 512),
        )).files.single.contentStatus,
        'oversized',
      );
    },
  );

  test(
    'tracked and untracked paths share a complete-or-error inventory bound',
    () async {
      // The unchanged tracked baseline still consumes one inventory entry.
      await File('${repository.path}/z-last').writeAsString('last addition\n');
      await File(
        '${repository.path}/a-first',
      ).writeAsString('first addition\n');
      const limits = GitChangeSetLimits(inventoryEntries: 3, files: 2);
      for (var i = 0; i < 2; i++) {
        final result = await snapshot(limits: limits);
        expect(result.files.map((file) => file.relativePath), [
          'a-first',
          'z-last',
        ]);
        expect(
          result.files.map((file) => file.hunks.single.lines.single.text),
          ['first addition', 'last addition'],
        );
      }
      await expectLater(
        snapshot(
          limits: const GitChangeSetLimits(inventoryEntries: 3, files: 1),
        ),
        throwsA(_code('too_many_files')),
      );
      await File(
        '${repository.path}/middle',
      ).writeAsString('overflow addition\n');
      ChangeSetSnapshot? published;
      await expectLater(
        snapshot(
          limits: const GitChangeSetLimits(inventoryEntries: 3, files: 3),
        ).then((result) => published = result),
        throwsA(_code('inventory_too_large')),
      );
      expect(published, isNull);
    },
  );

  for (final ordinaryChanges in [false, true]) {
    test(
      'untracked nested repository is unsupported with ordinary changes=$ordinaryChanges',
      () async {
        const nestedPath = 'vendor/repo with spaces';
        final nested = await Directory(
          '${repository.path}/$nestedPath',
        ).create(recursive: true);
        await _git(nested, ['init']);
        final inner = File('${nested.path}/inner.txt');
        await inner.writeAsString('nested tracked content\n');
        await _git(nested, ['add', '.']);
        await _git(nested, [
          '-c',
          'user.name=ADELE Test',
          '-c',
          'user.email=adele@example.invalid',
          'commit',
          '-m',
          'Nested fixture',
        ]);
        final untrackedInner = File('${nested.path}/untracked.txt');
        await untrackedInner.writeAsString('nested untracked content\n');
        final baseline = File('${repository.path}/baseline');
        final outer = File('${repository.path}/outer.txt');
        if (ordinaryChanges) {
          await baseline.writeAsString('outer tracked edit\n');
          await outer.writeAsString('outer addition\n');
        }
        expect(
          await _git(repository, [
            'ls-files',
            '--others',
            '--exclude-standard',
            '-z',
            '--',
            '.',
          ]),
          '${ordinaryChanges ? 'outer.txt\u0000' : ''}$nestedPath/\u0000',
        );
        final before = <String, List<int>>{};
        for (final file in [
          File('${repository.path}/.git/index'),
          File('${repository.path}/.git/config'),
          File('${nested.path}/.git/index'),
          File('${nested.path}/.git/config'),
          baseline,
          inner,
          untrackedInner,
          if (ordinaryChanges) outer,
        ]) {
          before[file.path] = await file.readAsBytes();
        }
        final result = await snapshot();
        expect(result.files.map((file) => file.relativePath), [
          if (ordinaryChanges) ...['baseline', 'outer.txt'],
          nestedPath,
        ]);
        final unsupported = result.files.last;
        expect(unsupported.changeKind, 'unsupported');
        expect(unsupported.contentStatus, 'unsupported');
        expect(
          unsupported.detail,
          'Nested repository contents were not inspected.',
        );
        expect(unsupported.hunks, isEmpty);
        if (ordinaryChanges) {
          expect(result.files.first.contentStatus, 'text');
          expect(
            result.files.first.hunks.single.lines.last.text,
            'outer tracked edit',
          );
          expect(
            result.files[1].hunks.single.lines.single.text,
            'outer addition',
          );
        }
        for (final entry in before.entries) {
          expect(
            await File(entry.key).readAsBytes(),
            entry.value,
            reason: entry.key,
          );
        }
      },
    );
  }

  test(
    'isolated Git environment omits credentials routing and config overrides',
    () async {
      final log = File('${container.path}/environment');
      final shim = await _shim(
        container,
        '/usr/bin/env > ${_quote(log.path)}\nexec /usr/bin/git "\$@"',
      );
      await File('${repository.path}/new').writeAsString('new\n');
      final result = await snapshot(
        parentEnvironment: {
          'PATH': shim.path,
          'GIT_DIR': '/wrong',
          'GIT_WORK_TREE': '/wrong',
          'GIT_INDEX_FILE': '/wrong',
          'GIT_CONFIG_COUNT': '1',
          'GIT_CONFIG_KEY_0': 'diff.external',
          'GIT_CONFIG_VALUE_0': '/wrong',
          'OPENAI_API_KEY': 'secret',
          'ADELE_SECRET': 'secret',
          'HOME': '/wrong',
          'SSH_AUTH_SOCK': '/wrong',
        },
      );
      expect(result.files.single.relativePath, 'new');
      final environment = await log.readAsString();
      expect(environment, contains('GIT_OPTIONAL_LOCKS=0'));
      expect(environment, isNot(contains('secret')));
      expect(environment, isNot(contains('GIT_DIR=')));
      expect(environment, isNot(contains('GIT_INDEX_FILE=')));
      expect(environment, contains('HOME=/wrong'));
      expect(environment, isNot(contains('GIT_CONFIG_KEY_0')));
    },
    skip: !Platform.isLinux,
  );

  test('shared Git environment leaves placement policy unchanged', () {
    final source = {
      'PATH': '/usr/bin',
      'HOME': '/home/test',
      'OPENAI_API_KEY': 'retained-placement-secret',
      'GIT_DIR': '/wrong',
      'GIT_WORK_TREE': '/wrong',
      'GIT_CONFIG_COUNT': '1',
    };
    expect(gitProcessEnvironment(parentEnvironment: source), {
      'PATH': '/usr/bin',
      'HOME': '/home/test',
      'OPENAI_API_KEY': 'retained-placement-secret',
    });
    final inspection = gitProcessEnvironment(
      parentEnvironment: source,
      readOnlyInspection: true,
    );
    expect(inspection['HOME'], '/home/test');
    expect(inspection.containsKey('OPENAI_API_KEY'), isFalse);
    expect(inspection['GIT_OPTIONAL_LOCKS'], '0');
    expect(source['GIT_DIR'], '/wrong');
  });

  test(
    'empty or relative-only PATH never executes worktree git',
    () async {
      final sentinel = File('${container.path}/cwd-git-executed');
      final executable = File('${repository.path}/git');
      await executable.writeAsString(
        '#!/bin/sh\n/usr/bin/touch ${_quote(sentinel.path)}\n',
      );
      await Process.run('chmod', ['755', executable.path]);
      for (final path in ['', '.', 'relative', ':.:']) {
        await expectLater(
          snapshot(parentEnvironment: {'PATH': path}),
          throwsA(_code('git_unavailable')),
        );
      }
      expect(await sentinel.exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );

  test(
    'stdout and stderr are bounded while collected and processes have deadlines',
    () async {
      for (final stderr in [false, true]) {
        final shim = await _shim(
          container,
          'exec /usr/bin/yes ${stderr ? '>&2' : ''}',
        );
        await expectLater(
          snapshot(
            limits: const GitChangeSetLimits(outputBytes: 64, stderrBytes: 64),
            parentEnvironment: {'PATH': shim.path},
          ),
          throwsA(_code(stderr ? 'git_diagnostic_limit' : 'git_output_limit')),
        );
      }
      final shim = await _shim(container, 'exec /bin/sleep 30');
      await expectLater(
        snapshot(
          limits: const GitChangeSetLimits(
            processTimeout: Duration(milliseconds: 50),
          ),
          parentEnvironment: {'PATH': shim.path},
        ),
        throwsA(_code('git_timeout')),
      );
      await expectLater(
        snapshot(
          limits: const GitChangeSetLimits(
            operationTimeout: Duration(milliseconds: 50),
          ),
          parentEnvironment: {'PATH': shim.path},
        ),
        throwsA(_code('operation_timeout')),
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'revoked authority and missing live bindings never publish a snapshot',
    () async {
      authority.onRead = (count) {
        if (count == 2) throw StateError('revoked');
      };
      await expectLater(snapshot(), throwsStateError);
      authority.reads = 0;
      await expectLater(uncommitted(), throwsStateError);
      authority.reads = 0;
      await expectLater(taskChanges(), throwsStateError);
      authority.onRead = null;
      authority.environmentId = 'missing';
      await expectLater(snapshot(), throwsA(_code('environment_not_live')));
      await expectLater(uncommitted(), throwsA(_code('environment_not_live')));
      await expectLater(taskChanges(), throwsA(_code('environment_not_live')));
    },
  );

  test('default row and escaped JSON budgets reject whole results', () async {
    await File('${repository.path}/rows').writeAsString('line\n' * 8193);
    await expectLater(snapshot(), throwsA(_code('snapshot_too_large')));
    await File('${repository.path}/rows').delete();
    for (final name in ['one', 'two']) {
      await File('${repository.path}/$name').writeAsString('\u0001' * 525000);
    }
    await expectLater(snapshot(), throwsA(_code('snapshot_too_large')));
  });

  test(
    'detected working file races fail instead of publishing stale hunks',
    () async {
      final target = File('${repository.path}/baseline');
      await target.writeAsString('snapshot content\n');
      final shim = await _shim(container, '''
case " \$* " in
  *" --no-index "*) /usr/bin/printf 'raced content\\n' > ${_quote(target.path)} ;;
esac
exec /usr/bin/git "\$@"
''');
      await expectLater(
        snapshot(parentEnvironment: {'PATH': shim.path}),
        throwsA(_code('snapshot_changed')),
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'invalid UTF-8 path output is a whole-snapshot failure',
    () async {
      final shim = await _shim(container, r"printf '\377\000'");
      await expectLater(
        snapshot(parentEnvironment: {'PATH': shim.path}),
        throwsA(_code('invalid_git_output')),
      );
    },
    skip: !Platform.isLinux,
  );

  test('index parser rejects malformed framing paths and metadata', () {
    final oid = 'a' * 40;
    final header = '100644 $oid 0';
    const metadata =
        '  ctime: 0:0\n  mtime: 0:0\n  dev: 0\tino: 0\n  uid: 0\tgid: 0\n  size: 0\tflags: 0\n';
    expect(
      parseGitIndex('$header\ta b\u0000$metadata')['a b']!.kind,
      'modified',
    );
    for (final malformed in [
      header,
      '$header\tfile\u0000',
      '$header\t../escape\u0000$metadata',
      '$header\t/absolute\u0000$metadata',
      '$header\ta//b\u0000$metadata',
      '$header\tdirectory/\u0000$metadata',
      '$header\tfile\u0000${metadata.replaceFirst('flags: 0', 'flags: nope')}',
    ]) {
      expect(
        () => parseGitIndex(malformed),
        throwsA(_code('invalid_git_output')),
      );
    }
  });

  test(
    'untracked parser bounds retained entries before scanning the remaining records',
    () {
      final entries = <String, GitIndexEntry>{};
      addGitUntrackedEntries(
        'first\u0000second\u0000',
        entries,
        maximumEntries: 2,
      );
      expect(entries.keys, ['first', 'second']);
      expect(
        () => addGitUntrackedEntries('third\u0000', entries, maximumEntries: 2),
        throwsA(_code('inventory_too_large')),
      );
      expect(entries.keys, ['first', 'second']);
      entries.clear();
      final many = Iterable.generate(1000, (i) => 'n$i\u0000').join();
      expect(
        () => addGitUntrackedEntries(
          '$many../invalid-tail\u0000',
          entries,
          maximumEntries: 3,
        ),
        throwsA(_code('inventory_too_large')),
      );
      expect(entries.keys, ['n0', 'n1', 'n2']);
    },
  );

  test(
    'untracked directory normalization preserves path and collision checks',
    () {
      final entries = <String, GitIndexEntry>{};
      addGitUntrackedEntries('vendor/repo with spaces/\u0000', entries);
      expect(entries.keys, ['vendor/repo with spaces']);
      expect(entries.values.single.kind, 'untrackedRepository');
      expect(entries.values.single.newMode, '040000');
      for (final malformed in [
        'unterminated',
        '\u0000',
        '/\u0000',
        '/absolute/\u0000',
        '../escape/\u0000',
        './relative/\u0000',
        'a/../b/\u0000',
        'a/./b/\u0000',
        'a//b/\u0000',
        'a//\u0000',
      ]) {
        expect(
          () => addGitUntrackedEntries(malformed, {}),
          throwsA(_code('invalid_git_output')),
          reason: malformed,
        );
      }
      for (final records in [
        'same\u0000same\u0000',
        'same/\u0000same/\u0000',
        'same\u0000same/\u0000',
        'same/\u0000same\u0000',
      ]) {
        expect(
          () => addGitUntrackedEntries(records, {}, maximumEntries: 1),
          throwsA(_code('snapshot_changed')),
        );
      }
      final tracked = <String, GitIndexEntry>{
        'tracked': (
          oldMode: '100644',
          newMode: '100644',
          oid: 'a' * 40,
          kind: 'modified',
        ),
      };
      for (final record in ['tracked\u0000', 'tracked/\u0000']) {
        expect(
          () => addGitUntrackedEntries(record, tracked, maximumEntries: 1),
          throwsA(_code('snapshot_changed')),
        );
      }
    },
  );

  test('patch parser validates ranges counts ordering and newline markers', () {
    const prefix =
        'diff --git old new\nindex 123..456 100644\n--- old\n+++ new\n';
    final hunk = parseGitPatch(
      '$prefix@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n',
    ).single;
    expect(hunk.lines.every((line) => line.noNewline), isTrue);
    for (final malformed in [
      '$prefix@@ -1 +1 @@\n-old\n',
      '$prefix@@ -1 +1 @@\n\\ No newline at end of file\n-old\n+new\n',
      '$prefix@@ -1 +1 @@\n-old\n+new\n+extra\n',
      '$prefix@@ -0 +1 @@\n-old\n+new\n',
      '$prefix@@ -1 +1 @@\n-old\n+new\n@@ -1 +1 @@\n-old\n+new\n',
      '$prefix@@ -1 +1 @@\n-old\n+new',
      'Binary files old and new differ\n',
    ]) {
      expect(
        () => parseGitPatch(malformed),
        throwsA(_code('invalid_git_output')),
      );
    }
  });
}

Matcher _code(String code) =>
    isA<ChangeSetFailure>().having((failure) => failure.code, 'code', code);

Uint8List _binaryBytes([int length = 1054288]) => Uint8List.fromList(
  List<int>.generate(length, (i) => (i * 31 + i ~/ 256) & 255),
);

final class _ReadOverrides extends IOOverrides {
  _ReadOverrides(this.path, this.onRead, this.onClose);

  final String path;
  final Future<int> Function(RandomAccessFile, List<int>, int, int) onRead;
  final void Function() onClose;
  final Zone originalZone = Zone.current;

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      originalZone.run(
        () => FileSystemEntity.type(path, followLinks: followLinks),
      );

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == this.path ? _ReadFile(file, this) : file;
  }
}

final class _ReadFile implements File {
  _ReadFile(this.file, this.overrides);

  final File file;
  final _ReadOverrides overrides;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _ReadHandle(await file.open(mode: mode), overrides);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReadHandle implements RandomAccessFile {
  _ReadHandle(this.file, this.overrides);

  final RandomAccessFile file;
  final _ReadOverrides overrides;

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) =>
      overrides.onRead(file, buffer, start, end ?? buffer.length);

  @override
  Future<int> length() => file.length();

  @override
  Future<void> close() async {
    await file.close();
    overrides.onClose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Authority implements AuthorizedEnvironmentReadService {
  _Authority(this.environmentId);
  String environmentId;
  String sessionId = 'session';
  int reads = 0;
  int fileReads = 0;
  FutureOr<void> Function(int)? onRead;
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    await onRead?.call(++reads);
    return AuthorizedEnvironmentIdentity(
      sessionId: sessionId,
      environmentId: environmentId,
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    fileReads++;
    throw StateError('Only identity should be requested.');
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    String relativePath,
  ) async => throw StateError('Only identity should be requested.');
}

Future<String> _git(
  Directory repository,
  List<String> arguments, {
  String? input,
}) async {
  final process = await Process.start(
    'git',
    arguments,
    workingDirectory: repository.path,
    environment: {
      'PATH': Platform.environment['PATH']!,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
    },
    includeParentEnvironment: false,
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final code = await process.exitCode.timeout(const Duration(seconds: 10));
  final text = await output;
  final diagnostic = await error;
  if (code != 0) throw StateError('git $arguments failed: $diagnostic');
  return text;
}

Future<Directory> _shim(Directory container, String body) async {
  final directory = await container.createTemp('bin-');
  final file = File('${directory.path}/git');
  await file.writeAsString('#!/bin/sh\n$body\n');
  final result = await Process.run('chmod', ['755', file.path]);
  if (result.exitCode != 0) throw StateError('chmod failed');
  return directory;
}

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
