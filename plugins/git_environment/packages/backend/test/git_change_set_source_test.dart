import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  setUp(() async {
    container = await Directory.systemTemp.createTemp('adele-change-set-test-');
    repository = await Directory('${container.path}/repository').create();
    await _git(repository, ['init']);
    await _git(repository, ['config', 'user.name', 'ADELE Test']);
    await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
    await File('${repository.path}/baseline').writeAsString('baseline\n');
    await _git(repository, ['add', '.']);
    await _git(repository, ['commit', '-m', 'Fixture']);
    provider = GitWorktreeEnvironmentProvider();
    authority = _Authority('selected');
    provider.liveObjects.bind(
      EnvironmentId('selected'),
      WorktreeEnvironment(
        repository,
        gitWorktreeRoot: repository,
        gitDirectory: Directory('${repository.path}/.git'),
      ),
    );
  });
  tearDown(() async {
    await provider.close();
    await container.delete(recursive: true);
  });

  Future<ChangeSetSnapshot> snapshot({
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
  ).snapshotUnstaged();

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
        ),
      );
      provider.liveObjects.bind(
        EnvironmentId('primary'),
        WorktreeEnvironment(
          sibling,
          gitWorktreeRoot: repository,
          gitDirectory: Directory('${repository.path}/.git'),
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
      authority.onRead = null;
      authority.environmentId = 'missing';
      await expectLater(snapshot(), throwsA(_code('environment_not_live')));
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

final class _Authority implements AuthorizedEnvironmentReadService {
  _Authority(this.environmentId);
  String environmentId;
  int reads = 0;
  int fileReads = 0;
  void Function(int)? onRead;
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    onRead?.call(++reads);
    return AuthorizedEnvironmentIdentity(
      sessionId: 'session',
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
