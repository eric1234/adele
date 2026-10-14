@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_environment_backend/git_environment_backend.dart';
import 'package:git_environment_backend/src/git_change_set_source.dart';
import 'package:git_environment_backend/src/git_process_environment.dart';
import 'package:test/test.dart';

void main() {
  late _Repository fixture;
  setUp(() async => fixture = await _Repository.create());
  tearDown(() async => fixture.close());

  test(
    'POSIX index permissions survive restrictive and ordinary umasks',
    () async {
      final mask = Platform.environment['ADELE_REVIEW_MODE_UMASK'];
      if (mask == null) {
        for (final value in ['077', '022']) {
          final result = await Process.run(
            '/bin/sh',
            [
              '-c',
              r'umask "$1"; shift; exec "$@"',
              'review-umask',
              value,
              Platform.resolvedExecutable,
              'test',
              '--concurrency',
              '1',
              '--reporter',
              'expanded',
              'test/git_review_approval_test.dart',
              '--plain-name',
              'POSIX index permissions survive restrictive and ordinary umasks',
            ],
            environment: {
              ...Platform.environment,
              'ADELE_REVIEW_MODE_UMASK': value,
            },
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        }
        return;
      }
      for (final original in mask == '077' ? ['660'] : ['600', '640', '440']) {
        await fixture.close();
        fixture = await _Repository.create(shared: mask == '077');
        final mode = int.parse(original, radix: 8);
        if (mask != '077') {
          expect(
            (await Process.run('/bin/chmod', [
              original,
              fixture.index.path,
            ])).exitCode,
            0,
          );
        }
        expect((await fixture.index.stat()).mode & 0x1ff, mode);
        final head = await fixture.git(['rev-parse', 'HEAD']);
        final unrelated = await fixture.git([
          'ls-files',
          '--stage',
          '--',
          'unrelated',
        ]);
        await fixture.write('file', 'permission-preserving review\n');
        final snapshot = await fixture.source.snapshotUnstaged();
        int? createdMode;
        final parent = Zone.current;
        final lockPath = fixture.lock.path;
        Future<ReviewApprovalResult> observe(
          Future<ReviewApprovalResult> Function() action,
        ) => IOOverrides.runZoned(
          action,
          fseGetType: (path, followLinks) => parent.run(
            () => FileSystemEntity.type(path, followLinks: followLinks),
          ),
          createFile: (path) {
            final file = parent.run(() => File(path));
            return path == lockPath
                ? _IndexLockProbe(
                    file,
                    () => createdMode = file.statSync().mode & 0x1ff,
                  )
                : file;
          },
        );
        expect(
          (await observe(
            () =>
                fixture.review.approve(_select(snapshot, 'file', path: 'file')),
          )).status,
          'applied',
        );
        expect(createdMode, int.parse(mask == '077' ? '600' : '644', radix: 8));
        expect((await fixture.index.stat()).mode & 0x1ff, mode);
        expect(
          await fixture.indexText('file'),
          'permission-preserving review\n',
        );
        expect(await fixture.lock.exists(), isFalse);
        final staged = (await fixture.source.snapshotUncommitted()).staged;
        createdMode = null;
        expect(
          (await observe(
            () =>
                fixture.review.unapprove(_select(staged, 'file', path: 'file')),
          )).status,
          'applied',
        );
        expect(createdMode, int.parse(mask == '077' ? '600' : '644', radix: 8));
        expect((await fixture.index.stat()).mode & 0x1ff, mode);
        expect(await fixture.indexText('file'), fixture.original);
        expect(await fixture.read('file'), 'permission-preserving review\n');
        expect(await fixture.git(['rev-parse', 'HEAD']), head);
        expect(
          await fixture.git(['ls-files', '--stage', '--', 'unrelated']),
          unrelated,
        );
        expect(await fixture.lock.exists(), isFalse);
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'POSIX unavailable trusted mode tool cannot publish an index',
    () async {
      await fixture.close();
      fixture = await _Repository.create(shared: true);
      await fixture.write('file', 'permissions unavailable\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      final before = await fixture.index.readAsBytes();
      final mode = (await fixture.index.stat()).mode & 0xfff;
      final missing = File('${fixture.container.path}/missing-mode-tool');
      final lockPath = fixture.lock.path;
      final parent = Zone.current;
      await expectLater(
        IOOverrides.runZoned(
          () => fixture.review.approve(_select(snapshot, 'file', path: 'file')),
          fseGetType: (path, followLinks) => parent.run(
            () => FileSystemEntity.type(path, followLinks: followLinks),
          ),
          createFile: (path) {
            final file = parent.run(() => File(path));
            if (path == '/usr/bin/chmod' || path == '/bin/chmod') {
              return _UnavailableModeTool(file, missing);
            }
            return path == lockPath
                ? _IndexLockProbe(file, () {
                    expect(
                      Process.runSync('/bin/chmod', ['600', path]).exitCode,
                      0,
                    );
                  })
                : file;
          },
        ),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'index_permissions_unavailable',
          ),
        ),
      );
      expect(await fixture.index.readAsBytes(), before);
      expect((await fixture.index.stat()).mode & 0xfff, mode);
      expect(await fixture.read('file'), 'permissions unavailable\n');
      expect(await fixture.lock.exists(), isFalse);
      expect(
        await fixture.gitDirectory
            .list()
            .where((entry) => entry.path.contains('review-index-mode-'))
            .toList(),
        isEmpty,
      );
    },
    skip: Platform.isWindows,
  );

  for (final target in ['index', 'lock']) {
    test(
      'POSIX $target permission changes at final authority reject publication',
      () async {
        await fixture.close();
        fixture = await _Repository.create(shared: true);
        await fixture.write('file', 'permission-race content\n');
        final snapshot = await fixture.source.snapshotUnstaged();
        final before = await fixture.index.readAsBytes();
        final originalMode = (await fixture.index.stat()).mode & 0xfff;
        fixture.authority.onRead = (call) async {
          if (call == 4) {
            expect(
              (await Process.run('/bin/chmod', [
                '600',
                target == 'index' ? fixture.index.path : fixture.lock.path,
              ])).exitCode,
              0,
            );
          }
        };
        final pending = fixture.review.approve(
          _select(snapshot, 'file', path: 'file'),
        );
        if (target == 'index') {
          expect((await pending).status, 'stale');
        } else {
          await expectLater(
            pending,
            throwsA(
              isA<ReviewApprovalFailure>().having(
                (error) => error.code,
                'code',
                'index_lock_changed',
              ),
            ),
          );
        }
        expect(await fixture.index.readAsBytes(), before);
        expect(
          (await fixture.index.stat()).mode & 0xfff,
          target == 'index' ? int.parse('600', radix: 8) : originalMode,
        );
        expect(await fixture.read('file'), 'permission-race content\n');
        expect(await fixture.lock.exists(), isFalse);
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'POSIX permission adjustment never resolves chmod from repository PATH',
    () async {
      await fixture.close();
      fixture = await _Repository.create(shared: true);
      final commands = await fixture.container.createTemp('untrusted-tools-');
      final marker = File('${fixture.container.path}/untrusted-chmod-ran');
      final untrusted = File('${commands.path}/chmod');
      await untrusted.writeAsString(
        '#!/bin/sh\n: > "${marker.path}"\nexit 93\n',
      );
      expect(
        (await Process.run('/bin/chmod', ['755', untrusted.path])).exitCode,
        0,
      );
      await fixture.write('file', 'trusted mode preparation\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      final mode = (await fixture.index.stat()).mode & 0xfff;
      expect(
        (await fixture
                .reviewWith(
                  parentEnvironment: {'PATH': '${commands.path}:/usr/bin:/bin'},
                )
                .approve(_select(snapshot, 'file', path: 'file')))
            .status,
        'applied',
      );
      expect((await fixture.index.stat()).mode & 0xfff, mode);
      expect(await fixture.indexText('file'), 'trusted mode preparation\n');
      expect(await fixture.read('file'), 'trusted mode preparation\n');
      expect(await marker.exists(), isFalse);
      expect(await fixture.lock.exists(), isFalse);
    },
    skip: Platform.isWindows,
  );

  for (final gate in ['review', 'read']) {
    test(
      'final $gate gate fences ignored directory becoming visible',
      () async {
        await fixture.write('scope/file', 'old\n');
        await fixture.git(['add', '.']);
        await fixture.git(['commit', '-m', 'Ignore authority fixture']);
        fixture.bind(scope: 'scope');
        await fixture.write('scope/file', 'reviewed\n');
        await fixture.write('scope/cache/hidden', 'newly visible\n');
        final excludes = File('${fixture.repository.path}/.git/info/exclude');
        await excludes.writeAsString('scope/cache/\n');
        await excludes.setLastModified(DateTime.utc(2000));
        final snapshot = await fixture.source.snapshotUnstaged();
        expect(snapshot.files.map((file) => file.relativePath), ['file']);
        expect(snapshot.reviewRevision, isNotNull);
        final before = await fixture.index.readAsBytes();
        final entered = Completer<void>();
        final release = Completer<void>();
        Future<void> pause(int call) async {
          if (call == (gate == 'review' ? 2 : 4)) {
            entered.complete();
            await release.future;
          }
        }

        if (gate == 'review') {
          fixture.authority.onReview = pause;
        } else {
          fixture.authority.onRead = pause;
        }
        final pending = fixture.review.approve(_select(snapshot, 'layer'));
        await Future.any([
          entered.future,
          pending.then<void>(
            (value) => throw StateError(
              'Review completed before final gate: ${value.status}',
            ),
          ),
        ]);
        final state = await excludes.stat();
        await excludes.writeAsString('#${' ' * (state.size - 2)}\n');
        await excludes.setLastModified(state.modified);
        release.complete();
        expect((await pending).status, 'stale');
        expect(await fixture.index.readAsBytes(), before);
        expect(await fixture.read('scope/file'), 'reviewed\n');
        expect(await fixture.read('scope/cache/hidden'), 'newly visible\n');
        expect(await fixture.lock.exists(), isFalse);
        final fresh = await fixture.source.snapshotUnstaged();
        expect(fresh.files.map((file) => file.relativePath), [
          'cache/hidden',
          'file',
        ]);
      },
    );

    test(
      'final $gate authority uses the original operation deadline',
      () async {
        await fixture.write('file', 'deadline change\n');
        final snapshot = await fixture.source.snapshotUnstaged();
        final before = await fixture.index.readAsBytes();
        const budget = Duration(seconds: 5);
        const cleanup = Duration(milliseconds: 800);
        final clock = Stopwatch()..start();
        final first = Completer<void>();
        final entered = Completer<void>();
        final late = Completer<void>();
        final consumeBudget = Timer(const Duration(seconds: 2), first.complete);
        fixture.authority.onReview = (call) async {
          if (call == 1) await first.future;
          if (gate == 'review' && call == 2) {
            entered.complete();
            await late.future;
          }
        };
        fixture.authority.onRead = (call) async {
          if (gate == 'read' && call == 4) {
            entered.complete();
            await late.future;
          }
        };
        final pending = fixture
            .reviewWith(
              limits: const GitChangeSetLimits(operationTimeout: budget),
            )
            .approve(_select(snapshot, 'file', path: 'file'));
        final settled = pending.then<Object>(
          (value) => value,
          onError: (Object error, StackTrace stack) => error,
        );
        Object? atDeadline;
        var lockHeldPastDeadline = false;
        try {
          await Future.any([
            entered.future,
            settled.then<void>(
              (value) =>
                  throw StateError('Review did not reach final gate: $value'),
            ),
          ]);
          expect(
            clock.elapsed,
            greaterThanOrEqualTo(const Duration(seconds: 2)),
          );
          expect(await fixture.lock.exists(), isTrue);
          final remaining = budget + cleanup - clock.elapsed;
          expect(remaining, greaterThan(Duration.zero));
          atDeadline = await settled.timeout(
            remaining,
            onTimeout: () => _Unsettled(),
          );
          lockHeldPastDeadline = await fixture.lock.exists();
          expect(await fixture.index.readAsBytes(), before);
          expect(await fixture.read('file'), 'deadline change\n');
          if (atDeadline is ReviewApprovalFailure) {
            expect(atDeadline.code, 'operation_timeout');
            expect(lockHeldPastDeadline, isFalse);
            fixture.authority.onRead = null;
            fixture.authority.onReview = null;
            await fixture.git(['add', 'unrelated']);
            final fresh = await fixture.source.snapshotUnstaged();
            expect(
              (await fixture
                      .reviewWith(
                        limits: const GitChangeSetLimits(
                          operationTimeout: budget,
                        ),
                      )
                      .approve(_select(fresh, 'file', path: 'file')))
                  .status,
              'applied',
            );
            final published = await fixture.index.readAsBytes();
            final reads = fixture.authority.reads;
            late.complete();
            await Future<void>.delayed(Duration.zero);
            expect(fixture.authority.reads, reads);
            expect(await fixture.index.readAsBytes(), published);
            expect(await fixture.indexText('file'), 'deadline change\n');
          }
        } finally {
          consumeBudget.cancel();
          if (!first.isCompleted) first.complete();
          if (!late.isCompleted) late.complete();
          await settled;
        }
        expect(
          atDeadline,
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'operation_timeout',
          ),
          reason: 'Authority waits must not renew the overall budget.',
        );
        expect(lockHeldPastDeadline, isFalse);
        expect(await fixture.lock.exists(), isFalse);
      },
    );
  }

  test(
    'ignore bytes bind revision even with identical effective patterns and mtime',
    () async {
      await fixture.write('file', 'reviewed\n');
      final excludes = File('${fixture.repository.path}/.git/info/exclude');
      await excludes.writeAsString('# first\ncache/\n');
      await excludes.setLastModified(DateTime.utc(2000));
      final previous = await fixture.source.snapshotUnstaged();
      final state = await excludes.stat();
      await excludes.writeAsString('# other\ncache/\n');
      await excludes.setLastModified(state.modified);
      final current = await fixture.source.snapshotUnstaged();
      expect(await excludes.length(), state.size);
      expect((await excludes.stat()).modified, state.modified);
      expect(current.reviewRevision, isNot(previous.reviewRevision));
      final before = await fixture.index.readAsBytes();
      expect(
        (await fixture.review.approve(
          _select(previous, 'file', path: 'file'),
        )).status,
        'stale',
      );
      expect(await fixture.index.readAsBytes(), before);
    },
  );

  test(
    'Git excluded directory local rules cannot unignore its parent',
    () async {
      await fixture.write('.gitignore', 'cache/\n');
      await fixture.write('cache/.gitignore', '!hidden\n!../cache/\n');
      await fixture.write('cache/hidden', 'ignored\n');
      expect(
        await fixture.git(['ls-files', '--others', '--exclude-standard']),
        '.gitignore\n',
      );
      expect(
        (await fixture.runGit(['check-ignore', '--quiet', 'cache/'])).exitCode,
        0,
      );
      expect(
        await fixture.git([
          '-C',
          'cache',
          'ls-files',
          '--others',
          '--exclude-standard',
          '--',
          '.',
        ]),
        isEmpty,
      );
      // Ignoring only the contents is different: the directory must be visited,
      // including local rules even when all its files were previously invisible.
      await fixture.write('.gitignore', 'cache/*\n');
      await fixture.write('cache/.gitignore', '!hidden\n');
      expect(
        await fixture.git(['ls-files', '--others', '--exclude-standard']),
        '.gitignore\ncache/hidden\n',
      );
    },
  );

  for (final kind in [
    'ancestor',
    'nested',
    'configured',
    'relative-configured',
    'default-xdg',
    'default-home',
    'appearance',
    'deletion',
    'replacement',
    'config-switch',
    'symlink',
    'parent-symlink',
  ]) {
    test(
      'final authority fences $kind ignore source',
      () async {
        await fixture.write('scope/file', 'old\n');
        await fixture.git(['add', '.']);
        await fixture.git(['commit', '-m', 'Scoped ignore policy']);
        fixture.bind(scope: 'scope');
        await fixture.write('scope/file', 'reviewed\n');
        final nested = kind == 'nested';
        final hidden = nested
            ? 'scope/empty/cache/hidden'
            : 'scope/cache/hidden';
        await fixture.write(hidden, 'newly visible\n');
        final info = File('${fixture.repository.path}/.git/info/exclude');
        final path = switch (kind) {
          'ancestor' || 'appearance' => '${fixture.worktree.path}/.gitignore',
          'nested' => '${fixture.worktree.path}/scope/empty/.gitignore',
          'configured' ||
          'config-switch' => '${fixture.container.path}/ignore.rules',
          'parent-symlink' => '${fixture.container.path}/policy/ignore.rules',
          'relative-configured' => '${fixture.worktree.path}/ignore.rules',
          'default-xdg' => '${fixture.container.path}/config/git/ignore',
          'default-home' => '${fixture.container.path}/.config/git/ignore',
          _ => info.path,
        };
        final rules = File(path);
        await rules.parent.create(recursive: true);
        final policy = nested ? '.gitignore\ncache/\n' : 'scope/cache/\n';
        if (kind == 'appearance') {
          await info.writeAsString(policy);
        } else {
          await rules.writeAsString(policy);
          await rules.setLastModified(DateTime.utc(2000));
        }
        if (kind == 'configured' ||
            kind == 'relative-configured' ||
            kind == 'config-switch' ||
            kind == 'parent-symlink') {
          await fixture.git([
            'config',
            'core.excludesFile',
            kind == 'relative-configured' ? 'ignore.rules' : path,
          ]);
        }
        final environment = {
          ...fixture.environment,
          if (kind == 'default-home') 'XDG_CONFIG_HOME': '',
        };
        final source = GitChangeSetSourceService(
          provider: fixture.provider,
          authorizedRead: fixture.authority,
          parentEnvironment: environment,
        );
        final marker = File('${fixture.container.path}/executed');
        if (kind == 'ancestor') {
          await fixture.write(
            '.gitattributes',
            'scope/cache/* filter=trap diff=trap\n',
          );
          await fixture.git([
            'config',
            'filter.trap.clean',
            'touch "${marker.path}"; cat',
          ]);
          await fixture.git([
            'config',
            'filter.trap.process',
            'touch "${marker.path}"; exit 1',
          ]);
          await fixture.git([
            'config',
            'diff.trap.textconv',
            'touch "${marker.path}"; cat',
          ]);
          final hooks = await Directory(
            '${fixture.container.path}/hooks',
          ).create();
          final hook = File('${hooks.path}/post-index-change');
          await hook.writeAsString('#!/bin/sh\n: > "${marker.path}"\n');
          await Process.run('chmod', ['755', hook.path]);
          await fixture.git(['config', 'core.hooksPath', hooks.path]);
        }
        final snapshot = await source.snapshotUnstaged();
        expect(snapshot.files.map((file) => file.relativePath), ['file']);
        expect(snapshot.reviewRevision, isNotNull);
        final before = await fixture.index.readAsBytes();
        fixture.authority.onRead = (call) async {
          if (call != 4) return;
          final changed = nested
              ? '.gitignore\n#     \n'
              : '#${' ' * (policy.length - 2)}\n';
          if (kind == 'appearance') {
            await rules.writeAsString('!scope/cache/\n');
          } else if (kind == 'deletion') {
            await rules.delete();
          } else if (kind == 'config-switch') {
            final alternative = File('${fixture.container.path}/other.rules');
            await alternative.writeAsString(changed);
            await fixture.git([
              'config',
              'core.excludesFile',
              alternative.path,
            ]);
          } else if (kind == 'symlink' || kind == 'parent-symlink') {
            final alternative = await Directory(
              '${fixture.container.path}/policy-alias',
            ).create();
            final target = File('${alternative.path}/ignore.rules');
            await target.writeAsString(changed);
            if (kind == 'symlink') {
              await rules.delete();
              await Link(path).create(target.path);
            } else {
              await rules.parent.rename('${fixture.container.path}/old-policy');
              await Link(rules.parent.path).create(alternative.path);
            }
          } else {
            final modified = (await rules.stat()).modified;
            if (kind == 'replacement') {
              final replacement = File('${fixture.container.path}/replacement');
              await replacement.writeAsString(changed);
              await replacement.setLastModified(modified);
              await replacement.rename(path);
            } else {
              await rules.writeAsString(changed);
              await rules.setLastModified(modified);
            }
          }
        };
        expect(
          (await fixture
                  .reviewWith(parentEnvironment: environment)
                  .approve(_select(snapshot, 'layer')))
              .status,
          'stale',
        );
        expect(await fixture.index.readAsBytes(), before);
        expect(await fixture.lock.exists(), isFalse);
        expect(await fixture.read('scope/file'), 'reviewed\n');
        expect(await fixture.read(hidden), 'newly visible\n');
        expect(await marker.exists(), isFalse);
        final fresh = await source.snapshotUnstaged();
        expect(
          fresh.files.map((file) => file.relativePath),
          contains(hidden.substring('scope/'.length)),
        );
        expect(await marker.exists(), isFalse);
      },
      skip:
          Platform.isWindows &&
          ['ancestor', 'symlink', 'parent-symlink'].contains(kind),
    );
  }

  test(
    'snapshot settlement revalidates ignore bytes even when inventory is unchanged',
    () async {
      await fixture.write('file', 'reviewed\n');
      final excludes = File('${fixture.repository.path}/.git/info/exclude');
      await excludes.writeAsString('# first\n');
      await excludes.setLastModified(DateTime.utc(2000));
      final before = await fixture.index.readAsBytes();
      fixture.authority.onRead = (call) async {
        if (call == 2) {
          final modified = (await excludes.stat()).modified;
          await excludes.writeAsString('# other\n');
          await excludes.setLastModified(modified);
        }
      };
      await expectLater(
        fixture.source.snapshotUnstaged(),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'snapshot_changed',
          ),
        ),
      );
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.read('file'), 'reviewed\n');
    },
  );

  for (final phase in ['untracked', 'directory-pruning']) {
    test('ignore capture precedes $phase Git discovery', () async {
      await fixture.write('file', 'reviewed\n');
      final rules = phase == 'untracked'
          ? File('${fixture.repository.path}/.git/info/exclude')
          : File('${fixture.worktree.path}/empty/.gitignore');
      if (phase == 'directory-pruning') {
        await fixture.write('empty/cache/hidden', 'ignored\n');
      }
      await rules.writeAsString('# first\n.gitignore\ncache/\n');
      final marker = File('${fixture.container.path}/discovery-mutated');
      final first = File('${fixture.container.path}/first-prune');
      final shim = await fixture.shim('''
case " \$* " in
  *" ${phase == 'untracked' ? 'ls-files --others --exclude-standard' : 'check-ignore'} "*)
    ${phase == 'directory-pruning' ? "if ! test -f '${first.path}'; then : > '${first.path}'; exec /usr/bin/git \"\$@\"; fi" : ''}
    if ! test -f '${marker.path}'; then
      printf '# other\\n.gitignore\\ncache/\\n' > '${rules.path}'
      : > '${marker.path}'
    fi
    ;;
esac
exec /usr/bin/git "\$@"
''');
      final before = await fixture.index.readAsBytes();
      final source = GitChangeSetSourceService(
        provider: fixture.provider,
        authorizedRead: fixture.authority,
        parentEnvironment: {
          ...fixture.environment,
          'PATH': '${shim.path}:/usr/bin:/bin',
        },
      );
      await expectLater(
        source.snapshotUnstaged(),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'snapshot_changed',
          ),
        ),
      );
      expect(await marker.exists(), isTrue);
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.read('file'), 'reviewed\n');
    }, skip: Platform.isWindows);
  }

  for (final unsupported in [
    'aggregate',
    'indirect',
    'indirect-parent',
    'nonregular',
  ]) {
    test(
      '$unsupported ignore metadata disables only review',
      () async {
        await fixture.write('scope/file', 'old\n');
        await fixture.git(['add', '.']);
        await fixture.git(['commit', '-m', 'Unsupported ignore fixture']);
        fixture.bind(scope: 'scope');
        await fixture.write('scope/file', 'reviewed\n');
        final rules = File('${fixture.container.path}/ignore.rules');
        await rules.writeAsString('# safe\n');
        if (unsupported == 'aggregate') {
          await File(
            '${fixture.repository.path}/.git/info/exclude',
          ).writeAsString('#${' ' * 1100}\n');
          await fixture.write('.gitignore', '#${' ' * 1100}\n');
        } else if (unsupported == 'indirect') {
          final link = Link('${fixture.container.path}/ignore-link');
          await link.create(rules.path);
          await fixture.git(['config', 'core.excludesFile', link.path]);
        } else if (unsupported == 'indirect-parent') {
          final actual = await Directory(
            '${fixture.container.path}/actual',
          ).create();
          await File('${actual.path}/ignore').writeAsString('# safe\n');
          final link = Link('${fixture.container.path}/ignore-parent');
          await link.create(actual.path);
          await fixture.git([
            'config',
            'core.excludesFile',
            '${link.path}/ignore',
          ]);
        } else {
          await fixture.git(['config', 'core.excludesFile', '/dev/null']);
        }
        const limits = GitChangeSetLimits(reviewMetadataBytes: 2048);
        final source = GitChangeSetSourceService(
          provider: fixture.provider,
          authorizedRead: fixture.authority,
          parentEnvironment: fixture.environment,
          limits: limits,
        );
        final snapshot = await source.snapshotUnstaged();
        expect(snapshot.files.single.hunks, isNotEmpty);
        expect(snapshot.files.single.reviewEligible, isFalse);
        expect(snapshot.reviewRevision, isNull);
        final before = await fixture.index.readAsBytes();
        expect(
          (await fixture
                  .reviewWith(limits: limits)
                  .approve(_select(snapshot, 'layer')))
              .status,
          'ineligible',
        );
        expect(await fixture.index.readAsBytes(), before);
        expect(await fixture.read('scope/file'), 'reviewed\n');
        expect(await fixture.lock.exists(), isFalse);
      },
      skip: Platform.isWindows && unsupported != 'aggregate',
    );
  }

  test(
    'inactive default ignore source does not invalidate configured policy',
    () async {
      final configured = File('${fixture.container.path}/configured-ignore');
      await configured.writeAsString('cache/\n');
      await fixture.git(['config', 'core.excludesFile', configured.path]);
      final inactive = File('${fixture.container.path}/config/git/ignore');
      await inactive.parent.create(recursive: true);
      await inactive.writeAsString('# first\n');
      await fixture.write('cache/hidden', 'ignored\n');
      await fixture.write('file', 'reviewed\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      fixture.authority.onRead = (call) async {
        if (call == 4) await inactive.writeAsString('# other\n');
      };
      expect(
        (await fixture.review.approve(_select(snapshot, 'layer'))).status,
        'applied',
      );
      final staged = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(staged.staged, 'layer'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), fixture.original);
      expect(await fixture.read('file'), 'reviewed\n');
      expect(await fixture.read('cache/hidden'), 'ignored\n');
    },
  );

  test(
    'tracked deletion with missing parent directories remains reviewable',
    () async {
      await fixture.write('removed/nested/file', 'old\n');
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'Nested deletion fixture']);
      await Directory(
        '${fixture.worktree.path}/removed',
      ).delete(recursive: true);
      final snapshot = await fixture.source.snapshotUnstaged();
      expect(snapshot.files.single.reviewEligible, isTrue);
      expect(
        (await fixture.review.approve(_select(snapshot, 'layer'))).status,
        'applied',
      );
      final staged = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(staged.staged, 'layer'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('removed/nested/file'), 'old\n');
      expect(
        await Directory('${fixture.worktree.path}/removed').exists(),
        isFalse,
      );
    },
  );

  test(
    'ignored tracked parents do not require walking unrelated cache contents',
    () async {
      await fixture.write('cache/tracked/file', 'old\n');
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'Tracked cache fixture']);
      await File(
        '${fixture.repository.path}/.git/info/exclude',
      ).writeAsString('cache/\n');
      for (var i = 0; i < 4100; i++) {
        await fixture.write('cache/generated/$i', 'ignored\n');
      }
      await fixture.write('cache/tracked/file', 'reviewed\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      expect(snapshot.files.single.reviewEligible, isTrue);
      expect(
        (await fixture.review.approve(
          _select(snapshot, 'file', path: 'cache/tracked/file'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('cache/tracked/file'), 'reviewed\n');
    },
  );

  test(
    'bounded ignore discovery excess retains the complete readonly projection',
    () async {
      await fixture.write('.gitignore', '.gitignore\nignored-*\n');
      for (var i = 0; i < 40; i++) {
        await fixture.write('ignored-$i', 'ignored\n');
      }
      await fixture.write('file', 'reviewed\n');
      const limits = GitChangeSetLimits(inventoryEntries: 32);
      final source = GitChangeSetSourceService(
        provider: fixture.provider,
        authorizedRead: fixture.authority,
        parentEnvironment: fixture.environment,
        limits: limits,
      );
      final snapshot = await source.snapshotUnstaged();
      expect(snapshot.files.single.relativePath, 'file');
      expect(snapshot.files.single.hunks, isNotEmpty);
      expect(snapshot.reviewRevision, isNull);
      expect(snapshot.files.single.reviewEligible, isFalse);
      final before = await fixture.index.readAsBytes();
      expect(
        (await fixture
                .reviewWith(limits: limits)
                .approve(_select(snapshot, 'layer')))
            .status,
        'ineligible',
      );
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.lock.exists(), isFalse);
    },
  );

  test(
    'an ignored nested source root reviews tracked files without walking its cache',
    () async {
      await fixture.write('scope/tracked', 'old\n');
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'Ignored source root']);
      await File(
        '${fixture.repository.path}/.git/info/exclude',
      ).writeAsString('scope/\n');
      fixture.bind(scope: 'scope');
      for (var i = 0; i < 4100; i++) {
        await fixture.write('scope/generated-$i', 'ignored\n');
      }
      await fixture.write('scope/tracked', 'reviewed\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      expect(snapshot.files.single.reviewEligible, isTrue);
      expect(
        (await fixture.review.approve(_select(snapshot, 'layer'))).status,
        'applied',
      );
      expect(await fixture.indexText('scope/tracked'), 'reviewed\n');
    },
  );

  test(
    'Git preparation consumes the same deadline before final authority',
    () async {
      await fixture.write('file', 'preparation deadline\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      final before = await fixture.index.readAsBytes();
      final fifo = File('${fixture.container.path}/prepare-gate');
      expect((await Process.run('mkfifo', [fifo.path])).exitCode, 0);
      // RDWR keeps both FIFO endpoints open without a blocking writer handshake.
      final gate = await fifo.open(mode: FileMode.write);
      final marker = File('${fixture.container.path}/prepare-entered');
      final preparation = Completer<void>();
      final watch = fixture.container
          .watch(events: FileSystemEvent.create)
          .listen((event) {
            if (event.path == marker.path && !preparation.isCompleted) {
              preparation.complete();
            }
          });
      final shim = await fixture.shim('''
case " \$* " in
  *" hash-object "*)
    if ! test -f '${marker.path}'; then
      : > '${marker.path}'
      read -r proceed < '${fifo.path}'
    fi
    ;;
esac
exec /usr/bin/git "\$@"
''');
      final entered = Completer<void>();
      final late = Completer<void>();
      fixture.authority.onReview = (call) async {
        if (call == 2) {
          entered.complete();
          await late.future;
        }
      };
      const budget = Duration(seconds: 5);
      const grace = Duration(milliseconds: 800);
      final clock = Stopwatch()..start();
      final settled = fixture
          .reviewWith(
            limits: const GitChangeSetLimits(operationTimeout: budget),
            parentEnvironment: {'PATH': '${shim.path}:/usr/bin:/bin'},
          )
          .approve(_select(snapshot, 'file', path: 'file'))
          .then<Object>(
            (value) => value,
            onError: (Object error, StackTrace stack) => error,
          );
      Timer? resume;
      Future<void>? resumed;
      Object? atDeadline;
      var lockHeldPastDeadline = false;
      try {
        await Future.any([
          preparation.future,
          settled.then<void>(
            (value) => throw StateError(
              'Review did not reach Git preparation: $value',
            ),
          ),
        ]);
        expect(await fixture.lock.exists(), isTrue);
        final remainingDelay = const Duration(seconds: 2) - clock.elapsed;
        resume = Timer(
          remainingDelay > Duration.zero ? remainingDelay : Duration.zero,
          () => resumed = gate.writeString('resume\n').then<void>((_) {}),
        );
        await Future.any([
          entered.future,
          settled.then<void>(
            (value) =>
                throw StateError('Review did not reach final proof: $value'),
          ),
        ]);
        final finalProofAt = clock.elapsed;
        expect(clock.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
        expect(fixture.authority.reads, 3);
        final remaining = budget + grace - clock.elapsed;
        expect(remaining, greaterThan(Duration.zero));
        atDeadline = await settled.timeout(
          remaining,
          onTimeout: () => _Unsettled(),
        );
        lockHeldPastDeadline = await fixture.lock.exists();
        expect(await fixture.index.readAsBytes(), before);
        expect(await fixture.read('file'), 'preparation deadline\n');
        final checkedLockAt = clock.elapsed;
        expect(
          fixture.authority.reads,
          3,
          reason: 'The expired final proof must not start the final read.',
        );
        if (atDeadline is ReviewApprovalFailure) {
          expect(atDeadline.code, 'operation_timeout');
          expect(lockHeldPastDeadline, isFalse);
          expect(checkedLockAt, lessThanOrEqualTo(budget + grace));
          print(
            'Locked preparation deadline: final proof ${finalProofAt.inMilliseconds}ms; '
            'timeout settled and lock released by ${checkedLockAt.inMilliseconds}ms '
            '(budget ${budget.inMilliseconds}ms, cleanup allowance ${grace.inMilliseconds}ms).',
          );
          await fixture.git(['add', 'unrelated']);
          fixture.authority.onReview = null;
          final fresh = await fixture.source.snapshotUnstaged();
          expect(
            (await fixture
                    .reviewWith(
                      limits: const GitChangeSetLimits(
                        operationTimeout: budget,
                      ),
                    )
                    .approve(_select(fresh, 'file', path: 'file')))
                .status,
            'applied',
          );
          final published = await fixture.index.readAsBytes();
          final reads = fixture.authority.reads;
          late.complete();
          await Future<void>.delayed(Duration.zero);
          expect(fixture.authority.reads, reads);
          expect(await fixture.index.readAsBytes(), published);
        }
      } finally {
        resume?.cancel();
        await resumed;
        await gate.writeString('cleanup\n');
        if (!late.isCompleted) late.complete();
        await settled;
        await gate.close();
        await watch.cancel();
      }
      expect(
        atDeadline,
        isA<ReviewApprovalFailure>().having(
          (error) => error.code,
          'code',
          'operation_timeout',
        ),
      );
      expect(lockHeldPastDeadline, isFalse);
      expect(await fixture.lock.exists(), isFalse);
    },
    skip: Platform.isWindows,
  );

  for (final mutation in [false, true]) {
    test(
      'independent verification budgets allow publication, changed=$mutation',
      () async {
        await fixture.write('file', 'old\n');
        await fixture.write('unrelated', 'o' * 48);
        await fixture.write('ordinary', 'p' * 48);
        await fixture.write('large-a', 'a' * 120);
        await fixture.write('large-b', 'b' * 120);
        await fixture.git(['add', '.']);
        await fixture.git(['commit', '-m', 'Independent verification budgets']);
        await fixture.write('file', 'new\n');
        const limits = GitChangeSetLimits(
          fileBytes: 64,
          verificationFileBytes: 128,
          verificationTotalBytes: 256,
        );
        final source = GitChangeSetSourceService(
          provider: fixture.provider,
          authorizedRead: fixture.authority,
          parentEnvironment: fixture.environment,
          limits: limits,
        );
        final snapshot = await source.snapshotUnstaged();
        expect(snapshot.reviewRevision, isNotNull);
        expect(snapshot.files.single.reviewEligible, isTrue);
        final index = await fixture.index.readAsBytes();
        final entered = Completer<void>();
        final release = Completer<void>();
        fixture.authority.onRead = (call) async {
          if (call == 4) {
            entered.complete();
            await release.future;
          }
        };
        final pending = fixture
            .reviewWith(limits: limits)
            .approve(_select(snapshot, 'file', path: 'file'));
        await entered.future;
        if (mutation) {
          final large = File('${fixture.worktree.path}/large-a');
          final modified = (await large.stat()).modified;
          await large.writeAsString('z' * 120);
          await large.setLastModified(modified);
        }
        release.complete();
        expect((await pending).status, mutation ? 'stale' : 'applied');
        if (mutation) {
          expect(await fixture.index.readAsBytes(), index);
        } else {
          expect(await fixture.indexText('file'), 'new\n');
        }
        expect(await fixture.read('file'), 'new\n');
        expect(await fixture.read('unrelated'), 'o' * 48);
        expect(await fixture.read('ordinary'), 'p' * 48);
        expect(await fixture.read('large-a'), (mutation ? 'z' : 'a') * 120);
        expect(await fixture.read('large-b'), 'b' * 120);
        expect(await fixture.lock.exists(), isFalse);
      },
    );
  }

  for (final category in ['ordinary', 'streamed', 'per-file']) {
    test('$category verification excess withholds approval', () async {
      await fixture.write('file', 'old\n');
      await fixture.write('unrelated', 'o' * 48);
      await fixture.write('large-a', 'a' * 120);
      await fixture.write('large-b', 'b' * 120);
      if (category == 'ordinary') {
        for (var i = 0; i < 5; i++) {
          await fixture.write('ordinary-$i', 'p' * 48);
        }
      }
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'Verification budget excess']);
      await fixture.write('file', 'new\n');
      final limits = GitChangeSetLimits(
        fileBytes: 64,
        verificationFileBytes: category == 'per-file' ? 119 : 128,
        verificationTotalBytes: category == 'streamed' ? 239 : 256,
      );
      final source = GitChangeSetSourceService(
        provider: fixture.provider,
        authorizedRead: fixture.authority,
        parentEnvironment: fixture.environment,
        limits: limits,
      );
      final snapshot = await source.snapshotUnstaged();
      expect(snapshot.reviewRevision, isNull);
      expect(snapshot.files.every((file) => !file.reviewEligible), isTrue);
      expect(
        snapshot.files.singleWhere((file) => file.relativePath == 'file').hunks,
        isNotEmpty,
      );
      final index = await fixture.index.readAsBytes();
      expect(
        (await fixture
                .reviewWith(limits: limits)
                .approve(_select(snapshot, 'file', path: 'file')))
            .status,
        'ineligible',
      );
      expect(await fixture.index.readAsBytes(), index);
      expect(await fixture.read('file'), 'new\n');
      expect(await fixture.lock.exists(), isFalse);
    });
  }

  for (final (attributeSource, gate) in [
    ('info', 'read'),
    ('info', 'review'),
    ('ancestor', 'read'),
    ('ignored', 'read'),
    ('global', 'read'),
    ('relative-global', 'read'),
    ('config', 'read'),
    ('replacement', 'read'),
    ('deletion', 'read'),
  ]) {
    test(
      'final $gate authority gate fences $attributeSource attributes',
      () async {
        await fixture.write('scope/file', 'old\n');
        await fixture.git(['add', '.']);
        await fixture.git(['commit', '-m', 'Scoped attribute fixture']);
        fixture.bind(scope: 'scope');
        await fixture.write('scope/file', 'reviewed\n');
        final info = '${fixture.repository.path}/.git/info/attributes';
        final path = switch (attributeSource) {
          'ancestor' => '${fixture.worktree.path}/.gitattributes',
          'ignored' => '${fixture.worktree.path}/scope/.gitattributes',
          'relative-global' => '${fixture.worktree.path}/attributes.rules',
          'global' ||
          'config' => '${fixture.container.path}/external-attributes',
          _ => info,
        };
        final attributes = File(path);
        final changed = attributeSource == 'ignored'
            ? 'file -diff\n'
            : 'scope/file -diff\n';
        if (attributeSource != 'info') {
          await attributes.writeAsString('#${' ' * (changed.length - 2)}\n');
        }
        if (attributeSource == 'global' ||
            attributeSource == 'relative-global') {
          await fixture.git([
            'config',
            'core.attributesFile',
            attributeSource == 'relative-global' ? 'attributes.rules' : path,
          ]);
        }
        if (attributeSource == 'config') {
          await attributes.writeAsString(changed);
        }
        if (attributeSource == 'ignored') {
          await File(
            '${fixture.repository.path}/.git/info/exclude',
          ).writeAsString('/scope/.gitattributes\n');
        }
        final marker = File('${fixture.container.path}/executed');
        if (attributeSource == 'deletion') {
          await fixture.write(
            '.gitattributes',
            'scope/file filter=reviewtrap\n',
          );
          await attributes.writeAsString('scope/file -filter\n');
          await fixture.git([
            'config',
            'filter.reviewtrap.clean',
            'touch "${marker.path}"; cat',
          ]);
          await fixture.git([
            'config',
            'filter.reviewtrap.process',
            'touch "${marker.path}"; exit 1',
          ]);
          await fixture.git([
            'config',
            'diff.reviewtrap.textconv',
            'touch "${marker.path}"; cat',
          ]);
          if (!Platform.isWindows) {
            final hooks = await Directory(
              '${fixture.container.path}/hooks',
            ).create();
            final hook = File('${hooks.path}/post-index-change');
            await hook.writeAsString('#!/bin/sh\n: > "${marker.path}"\n');
            await Process.run('chmod', ['755', hook.path]);
            await fixture.git(['config', 'core.hooksPath', hooks.path]);
          }
        }
        if (await attributes.exists()) {
          await attributes.setLastModified(DateTime.utc(2000));
        }
        final snapshot = await fixture.source.snapshotUnstaged();
        expect(snapshot.reviewRevision, isNotNull);
        expect(snapshot.files.single.reviewEligible, isTrue);
        final index = await fixture.index.readAsBytes();
        final entered = Completer<void>();
        final release = Completer<void>();
        Future<void> pause(int call) async {
          if (call == (gate == 'read' ? 4 : 2)) {
            entered.complete();
            await release.future;
          }
        }

        if (gate == 'read') {
          fixture.authority.onRead = pause;
        } else {
          fixture.authority.onReview = pause;
        }
        final pending = fixture.review.approve(
          _select(snapshot, 'file', path: 'file'),
        );
        await Future.any([
          entered.future,
          pending.then<void>(
            (result) => throw StateError(
              'Unexpected early mutation result: ${result.status}',
            ),
          ),
        ]);
        final modified = (await attributes.stat()).modified;
        if (attributeSource == 'config') {
          await fixture.git(['config', 'core.attributesFile', path]);
        } else if (attributeSource == 'deletion') {
          await attributes.delete();
        } else if (attributeSource == 'replacement') {
          final replacement = File('${fixture.container.path}/replacement');
          await replacement.writeAsString(changed);
          await replacement.setLastModified(modified);
          await replacement.rename(path);
        } else {
          await attributes.writeAsString(changed);
          if (attributeSource != 'info') {
            await attributes.setLastModified(modified);
          }
        }
        release.complete();
        expect((await pending).status, 'stale');
        expect(await fixture.index.readAsBytes(), index);
        expect(await fixture.read('scope/file'), 'reviewed\n');
        expect(await fixture.lock.exists(), isFalse);
        final fresh = await fixture.source.snapshotUnstaged();
        expect(
          fresh.files.single.contentStatus,
          attributeSource == 'deletion' ? 'unsupported' : 'binary',
        );
        expect(fresh.files.single.reviewEligible, isFalse);
        expect(await marker.exists(), isFalse);
      },
    );
  }

  test(
    'unmonitored config includes disable review but retain text inspection',
    () async {
      final included = File('${fixture.container.path}/included-config');
      await included.writeAsString('[core]\n  filemode = true\n');
      await fixture.git(['config', 'include.path', included.path]);
      await fixture.write('file', 'reviewed\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      expect(snapshot.files.single.hunks, isNotEmpty);
      expect(snapshot.reviewRevision, isNull);
      expect(snapshot.files.single.reviewEligible, isFalse);
      final index = await fixture.index.readAsBytes();
      expect(
        (await fixture.review.approve(
          _select(snapshot, 'file', path: 'file'),
        )).status,
        'ineligible',
      );
      expect(await fixture.index.readAsBytes(), index);
    },
  );

  test(
    'attribute contents bind revisions despite unchanged effective values',
    () async {
      await fixture.write('scope/file', 'old\n');
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'Attribute revision fixture']);
      fixture.bind(scope: 'scope');
      await fixture.write('scope/file', 'reviewed\n');
      final attributes = File(
        '${fixture.repository.path}/.git/info/attributes',
      );
      await attributes.writeAsString('# first\n');
      await attributes.setLastModified(DateTime.utc(2000));
      final previous = await fixture.source.snapshotUnstaged();
      final state = await attributes.stat();
      await attributes.writeAsString('# other\n');
      await attributes.setLastModified(state.modified);
      expect((await attributes.stat()).modified, state.modified);
      expect(await attributes.length(), state.size);
      final current = await fixture.source.snapshotUnstaged();
      expect(current.reviewRevision, isNotNull);
      expect(current.reviewRevision, isNot(previous.reviewRevision));
      expect(current.files.single.reviewEligible, isTrue);
      final index = await fixture.index.readAsBytes();
      expect(
        (await fixture.review.approve(
          _select(previous, 'file', path: 'file'),
        )).status,
        'stale',
      );
      expect(await fixture.index.readAsBytes(), index);
      expect(
        (await fixture.review.approve(
          _select(current, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('scope/file'), 'reviewed\n');
      expect(await fixture.read('scope/file'), 'reviewed\n');
    },
  );

  test(
    'tree-sourced attributes disable review without hiding text inspection',
    () async {
      await fixture.git([
        'update-ref',
        'refs/heads/attribute-policy',
        fixture.baseline,
      ]);
      await fixture.git(['config', 'attr.tree', 'refs/heads/attribute-policy']);
      await fixture.write('file', 'reviewed\n');
      final snapshot = await fixture.source.snapshotUnstaged();
      expect(snapshot.files.single.hunks, isNotEmpty);
      expect(snapshot.reviewRevision, isNull);
      expect(snapshot.files.single.reviewEligible, isFalse);
      final index = await fixture.index.readAsBytes();
      expect(
        (await fixture.review.approve(
          _select(snapshot, 'file', path: 'file'),
        )).status,
        'ineligible',
      );
      expect(await fixture.index.readAsBytes(), index);
    },
  );

  for (final exitCode in [129, 128]) {
    test(
      'optional Git variable discovery handles exit $exitCode narrowly',
      () async {
        await fixture.write('file', 'reviewed\n');
        final wrapper = await fixture.shim('''
case " \$* " in
  *" var GIT_CONFIG_"*|*" var GIT_ATTR_"*) exit $exitCode;;
esac
exec /usr/bin/git "\$@"
''');
        final environment = {
          ...fixture.environment,
          'PATH': '${wrapper.path}:/usr/bin:/bin',
        };
        final source = GitChangeSetSourceService(
          provider: fixture.provider,
          authorizedRead: fixture.authority,
          parentEnvironment: environment,
        );
        final index = await fixture.index.readAsBytes();
        if (exitCode == 129) {
          final snapshot = await source.snapshotUnstaged();
          expect(snapshot.files.single.hunks, isNotEmpty);
          expect(snapshot.reviewRevision, isNull);
          expect(snapshot.files.single.reviewEligible, isFalse);
          expect(
            (await fixture
                    .reviewWith(parentEnvironment: environment)
                    .approve(_select(snapshot, 'file', path: 'file')))
                .status,
            'ineligible',
          );
        } else {
          await expectLater(
            source.snapshotUnstaged(),
            throwsA(
              isA<ChangeSetFailure>().having(
                (error) => error.code,
                'code',
                'git_failed',
              ),
            ),
          );
        }
        expect(await fixture.index.readAsBytes(), index);
        expect(await fixture.lock.exists(), isFalse);
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'aggregate attribute source bounds disable approval without hiding hunks',
    () async {
      await fixture.write('scope/file', 'old\n');
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'Attribute budget fixture']);
      fixture.bind(scope: 'scope');
      await fixture.write('scope/file', 'reviewed\n');
      await File(
        '${fixture.repository.path}/.git/info/attributes',
      ).writeAsString('#${' ' * 1100}\n');
      await fixture.write('.gitattributes', '#${' ' * 1100}\n');
      const limits = GitChangeSetLimits(reviewMetadataBytes: 2048);
      expect(
        await fixture.index.length(),
        lessThan(limits.reviewMetadataBytes),
      );
      final source = GitChangeSetSourceService(
        provider: fixture.provider,
        authorizedRead: fixture.authority,
        parentEnvironment: fixture.environment,
        limits: limits,
      );
      final snapshot = await source.snapshotUnstaged();
      expect(snapshot.files.single.hunks, isNotEmpty);
      expect(snapshot.reviewRevision, isNull);
      expect(snapshot.files.single.reviewEligible, isFalse);
      final index = await fixture.index.readAsBytes();
      expect(
        (await fixture
                .reviewWith(limits: limits)
                .approve(_select(snapshot, 'file', path: 'file')))
            .status,
        'ineligible',
      );
      expect(await fixture.index.readAsBytes(), index);
    },
  );

  test(
    'separate hunk approval and unapproval use exact coordinates and leave working bytes',
    () async {
      final changed = fixture.original
          .replaceFirst('line 1\n', 'first\nextra\n')
          .replaceFirst('line 27\n', 'last\n');
      await fixture.write('file', changed);
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.files.single.hunks, hasLength(2));
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'hunk', path: 'file', hunk: 1),
        )).status,
        'applied',
      );
      expect(
        await fixture.indexText('file'),
        fixture.original.replaceFirst('line 27\n', 'last\n'),
      );
      expect(await fixture.read('file'), changed);
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'hunk', path: 'file', hunk: 0),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), changed);
      snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.staged.files.single.hunks, hasLength(2));
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'hunk', path: 'file', hunk: 1),
        )).status,
        'applied',
      );
      expect(
        await fixture.indexText('file'),
        fixture.original.replaceFirst('line 1\n', 'first\nextra\n'),
      );
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'hunk', path: 'file', hunk: 0),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), fixture.original);
      expect(await fixture.read('file'), changed);
    },
  );

  test(
    'file and all preserve unrelated staged entries and executable modes',
    () async {
      await fixture.write('unrelated', 'already staged\n');
      await fixture.git(['add', 'unrelated']);
      await fixture.git(['update-index', '--chmod=+x', 'unrelated']);
      final unrelated = await fixture.git([
        'ls-files',
        '--stage',
        '--',
        'unrelated',
      ]);
      await fixture.write('file', 'one\n');
      await fixture.write('second', 'two\n');
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(
        await fixture.git(['ls-files', '--stage', '--', 'unrelated']),
        unrelated,
      );
      snapshot = await fixture.source.snapshotUncommitted();
      // The unrelated executable mode mismatch is represented, never silently skipped.
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'layer'),
        )).status,
        'ineligible',
      );
      await Process.run('chmod', ['755', '${fixture.worktree.path}/unrelated']);
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'layer'),
        )).status,
        'applied',
      );
      expect(
        await fixture.git(['ls-files', '--stage', '--', 'unrelated']),
        unrelated,
      );
      expect(await fixture.indexText('second'), 'two\n');
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(
        await fixture.git(['ls-files', '--stage', '--', 'unrelated']),
        unrelated,
      );
    },
    skip: Platform.isWindows ? 'POSIX executable mode evidence' : false,
  );

  test(
    'adds deletes and empty files round trip without working tree writes',
    () async {
      await fixture.write('empty-delete', '');
      await fixture.git(['add', 'empty-delete']);
      await fixture.git(['commit', '-m', 'Empty fixture']);
      await File('${fixture.worktree.path}/empty-delete').delete();
      await File('${fixture.worktree.path}/unrelated').delete();
      await fixture.write('empty-add', '');
      await fixture.write('new', 'new without newline');
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(
        snapshot.unstaged.files.every((file) => file.reviewEligible),
        isTrue,
      );
      expect(
        snapshot.unstaged.files
            .where((file) => file.relativePath.startsWith('empty'))
            .every((file) => file.hunks.isEmpty),
        isTrue,
      );
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'layer'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('new'), 'new without newline');
      expect(await fixture.indexText('empty-add'), '');
      snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.files, isEmpty);
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'layer'),
        )).status,
        'applied',
      );
      expect(await fixture.git(['diff', '--cached', '--name-only']), '');
      expect(await fixture.read('new'), 'new without newline');
      expect(
        await File('${fixture.worktree.path}/unrelated').exists(),
        isFalse,
      );
      expect(
        await File('${fixture.worktree.path}/empty-delete').exists(),
        isFalse,
      );
    },
  );

  test('CRLF and final no-newline bytes survive both directions', () async {
    final original =
        '${List.generate(25, (i) => 'row $i').join('\r\n')}\r\nfinal';
    await fixture.write('file', original);
    await fixture.git(['add', 'file']);
    await fixture.git(['commit', '-m', 'CRLF fixture']);
    final changed = original
        .replaceFirst('row 1\r\n', 'first\r\n')
        .replaceFirst('final', 'last');
    await fixture.write('file', changed);
    var snapshot = await fixture.source.snapshotUncommitted();
    expect(snapshot.unstaged.files.single.hunks, hasLength(2));
    expect(
      (await fixture.review.approve(
        _select(snapshot.unstaged, 'hunk', path: 'file', hunk: 1),
      )).status,
      'applied',
    );
    expect(
      await fixture.indexText('file'),
      original.replaceFirst('final', 'last'),
    );
    snapshot = await fixture.source.snapshotUncommitted();
    expect(
      (await fixture.review.unapprove(
        _select(snapshot.staged, 'hunk', path: 'file', hunk: 0),
      )).status,
      'applied',
    );
    expect(await fixture.indexText('file'), original);
    expect(await fixture.read('file'), changed);
  });

  for (final change in [
    'working-outside-hunk',
    'clean-working-file',
    'index',
    'HEAD',
    'hunk',
    'generation',
  ]) {
    test(
      '$change invalidates the complete revision without index writes',
      () async {
        await fixture.write(
          'file',
          fixture.original.replaceFirst('line 1\n', 'changed\n'),
        );
        final snapshot = await fixture.source.snapshotUncommitted();
        switch (change) {
          case 'working-outside-hunk':
            await fixture.write(
              'file',
              (await fixture.read(
                'file',
              )).replaceFirst('line 25\n', 'outside\n'),
            );
          case 'clean-working-file':
            await fixture.write('unrelated', 'new unstaged change\n');
          case 'index':
            await fixture.write('unrelated', 'new staged change\n');
            await fixture.git(['add', 'unrelated']);
          case 'HEAD':
            await fixture.git(['commit', '--allow-empty', '-m', 'New HEAD']);
          case 'hunk':
            await fixture.write(
              'file',
              (await fixture.read(
                'file',
              )).replaceFirst('changed\n', 'another hunk\n'),
            );
          case 'generation':
            fixture.bind();
        }
        final index = await fixture.index.readAsBytes();
        expect(
          (await fixture.review.approve(
            _select(snapshot.unstaged, 'hunk', path: 'file', hunk: 0),
          )).status,
          'stale',
        );
        expect(await fixture.index.readAsBytes(), index);
        expect(await fixture.lock.exists(), isFalse);
      },
    );
  }

  test(
    'actual linked gitdir lock rejects outside writers and does not lose them',
    () async {
      await fixture.write('file', 'selected\n');
      await fixture.write('unrelated', 'external\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.authority.onRead = (call) async {
        if (call == 4) {
          entered.complete();
          await release.future;
        }
      };
      final pending = fixture.review.approve(
        _select(snapshot.unstaged, 'file', path: 'file'),
      );
      await entered.future;
      expect(await fixture.lock.exists(), isTrue);
      final external = await fixture.runGit(['add', 'unrelated']);
      expect(external.exitCode, isNot(0));
      expect(external.stderr, contains('index.lock'));
      release.complete();
      expect((await pending).status, 'applied');
      expect(await fixture.indexText('unrelated'), 'unrelated\n');
      await fixture.git(['add', 'unrelated']);
      expect(await fixture.indexText('file'), 'selected\n');
      expect(await fixture.indexText('unrelated'), 'external\n');
      final later = await fixture.source.snapshotUncommitted();
      await fixture.lock.writeAsString('external lock sentinel');
      final before = await fixture.index.readAsBytes();
      await expectLater(
        fixture.review.unapprove(_select(later.staged, 'file', path: 'file')),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'index_locked',
          ),
        ),
      );
      expect(await fixture.lock.readAsString(), 'external lock sentinel');
      expect(await fixture.index.readAsBytes(), before);
      await fixture.lock.delete();
    },
  );

  test(
    'multi-file object preparation failure leaves original index exact',
    () async {
      await fixture.write('file', 'first\n');
      await fixture.write('unrelated', 'second\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      final wrapper = await fixture.shim('''
case " \$* " in
  *" hash-object "*)
    if test -f '${fixture.container.path}/first-object'; then exit 91; fi
    : > '${fixture.container.path}/first-object'
    ;;
esac
exec /usr/bin/git "\$@"
''');
      final review = fixture.reviewWith(
        parentEnvironment: {'PATH': '${wrapper.path}:/usr/bin:/bin'},
      );
      await expectLater(
        review.approve(_select(snapshot.unstaged, 'layer')),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'git_failed',
          ),
        ),
      );
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.lock.exists(), isFalse);
      expect(await fixture.read('file'), 'first\n');
      expect(await fixture.read('unrelated'), 'second\n');
    },
    skip: Platform.isWindows,
  );

  test(
    'successful external writer wins before lock admission and its exact index survives',
    () async {
      await fixture.write('file', 'selected\n');
      await fixture.write('unrelated', 'external wins\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.authority.onRead = (call) async {
        if (call == 3) {
          entered.complete();
          await release.future;
        }
      };
      final pending = fixture.review.approve(
        _select(snapshot.unstaged, 'file', path: 'file'),
      );
      await entered.future;
      expect(await fixture.lock.exists(), isFalse);
      await fixture.git(['add', 'unrelated']);
      final externalIndex = await fixture.index.readAsBytes();
      release.complete();
      expect((await pending).status, 'stale');
      expect(await fixture.index.readAsBytes(), externalIndex);
      expect(await fixture.indexText('unrelated'), 'external wins\n');
      expect(await fixture.indexText('file'), fixture.original);
    },
  );

  test(
    'independent provider instances share the actual Git lock boundary',
    () async {
      await fixture.write('file', 'selected\n');
      final other = GitWorktreeEnvironmentProvider();
      addTearDown(other.close);
      other.liveObjects.bind(
        EnvironmentId('selected'),
        fixture.provider.liveObjects.resolve(EnvironmentId('selected')),
      );
      final otherRead = _Authority();
      final otherSource = GitChangeSetSourceService(
        provider: other,
        authorizedRead: otherRead,
        parentEnvironment: fixture.environment,
      );
      final otherReview = GitReviewApprovalService(
        provider: other,
        authorizedRead: otherRead,
        authorizedReview: _Proof(otherRead),
        parentEnvironment: fixture.environment,
      );
      final ownSnapshot = await fixture.source.snapshotUncommitted();
      final otherSnapshot = await otherSource.snapshotUncommitted();
      expect(
        otherSnapshot.unstaged.reviewRevision,
        isNot(ownSnapshot.unstaged.reviewRevision),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.authority.onRead = (call) async {
        if (call == 4) {
          entered.complete();
          await release.future;
        }
      };
      final pending = fixture.review.approve(
        _select(ownSnapshot.unstaged, 'file', path: 'file'),
      );
      await entered.future;
      await expectLater(
        otherReview.approve(
          _select(otherSnapshot.unstaged, 'file', path: 'file'),
        ),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'index_locked',
          ),
        ),
      );
      release.complete();
      expect((await pending).status, 'applied');
      final published = await fixture.index.readAsBytes();
      expect(
        (await otherReview.approve(
          _select(otherSnapshot.unstaged, 'file', path: 'file'),
        )).status,
        'stale',
      );
      expect(await fixture.index.readAsBytes(), published);
    },
  );

  for (final mutation in [
    'working',
    'new-file',
    'HEAD',
    'authority',
    'rebind',
    'close',
  ]) {
    test('$mutation during final authority admission cannot publish', () async {
      await fixture.write('file', 'selected\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      Future<void>? closing;
      fixture.authority.onRead = (call) async {
        if (call != 4) return;
        switch (mutation) {
          case 'working':
            await fixture.write('file', 'late change\n');
          case 'new-file':
            await fixture.write('newly-added', 'late addition\n');
          case 'HEAD':
            final tree = (await fixture.git([
              'rev-parse',
              'HEAD^{tree}',
            ])).trim();
            final commit = (await fixture.git([
              'commit-tree',
              tree,
              '-p',
              fixture.baseline,
              '-m',
              'Late HEAD',
            ])).trim();
            await fixture.git(['update-ref', 'HEAD', commit]);
          case 'authority':
            fixture.authority.revoked = true;
          case 'rebind':
            fixture.bind();
          case 'close':
            closing = fixture.provider.close();
        }
      };
      final pending = fixture.review.approve(
        _select(snapshot.unstaged, 'file', path: 'file'),
      );
      if (mutation == 'working' ||
          mutation == 'new-file' ||
          mutation == 'HEAD') {
        expect((await pending).status, 'stale');
      } else {
        await expectLater(
          pending,
          throwsA(anyOf(isA<ReviewApprovalFailure>(), isA<StateError>())),
        );
      }
      if (closing != null) await closing;
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.lock.exists(), isFalse);
    });
  }

  test(
    'semantic malformed and bounded selectors reject before authority and effects',
    () async {
      final token = ''.padLeft(64, 'a');
      final before = await fixture.index.readAsBytes();
      for (final selection in [
        ReviewSelection(
          expectedRevision: 'invalid',
          granularity: 'layer',
          relativePath: null,
          hunkIndex: null,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'wrong',
          relativePath: 'file',
          hunkIndex: null,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'layer',
          relativePath: 'file',
          hunkIndex: null,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'file',
          relativePath: '../outside',
          hunkIndex: null,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'file',
          relativePath: '/outside',
          hunkIndex: null,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'file',
          relativePath: 'a\u0000b',
          hunkIndex: null,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'file',
          relativePath: ''.padLeft(4097, 'x'),
          hunkIndex: null,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'file',
          relativePath: 'file',
          hunkIndex: 0,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'hunk',
          relativePath: 'file',
          hunkIndex: -1,
        ),
        ReviewSelection(
          expectedRevision: token,
          granularity: 'hunk',
          relativePath: 'file',
          hunkIndex: 8192,
        ),
      ]) {
        expect((await fixture.review.approve(selection)).status, 'ineligible');
        expect(
          (await fixture.review.unapprove(selection)).status,
          'ineligible',
        );
      }
      expect(fixture.authority.reads, 0);
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.lock.exists(), isFalse);
    },
  );

  test(
    'filters hooks inherited routing and external diff cannot execute or redirect mutation',
    () async {
      final sentinel = '${fixture.container.path}/executed';
      await fixture.git([
        'config',
        'core.hooksPath',
        '${fixture.container.path}/hooks',
      ]);
      await Directory('${fixture.container.path}/hooks').create();
      final hook = File('${fixture.container.path}/hooks/post-index-change');
      await hook.writeAsString('#!/bin/sh\ntouch "$sentinel"\n');
      await Process.run('chmod', ['755', hook.path]);
      await fixture.git(['config', 'core.fsmonitor', 'touch $sentinel']);
      await fixture.git(['config', 'diff.external', 'touch $sentinel']);
      await fixture.git(['config', 'filter.evil.clean', 'touch $sentinel']);
      await fixture.git(['config', 'filter.evil.process', 'touch $sentinel']);
      await fixture.write('.gitattributes', 'unrelated filter=evil\n');
      await fixture.write('file', 'approved\n');
      await fixture.write('unrelated', 'unsupported\n');
      final parent = {
        'GIT_DIR': '${fixture.container.path}/foreign',
        'GIT_INDEX_FILE': '${fixture.container.path}/foreign-index',
        'GIT_OBJECT_DIRECTORY': '${fixture.container.path}/foreign-objects',
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'core.hooksPath',
        'GIT_CONFIG_VALUE_0': '${fixture.container.path}/hooks',
      };
      final snapshot = await fixture.source.snapshotUncommitted();
      expect(
        snapshot.unstaged.files
            .singleWhere((file) => file.relativePath == 'unrelated')
            .reviewEligible,
        isFalse,
      );
      final review = fixture.reviewWith(parentEnvironment: parent);
      expect(
        (await review.approve(_select(snapshot.unstaged, 'layer'))).status,
        'ineligible',
      );
      expect(
        (await review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await File(sentinel).exists(), isFalse);
      expect(
        await File('${fixture.container.path}/foreign-index').exists(),
        isFalse,
      );
      expect(
        await Directory('${fixture.container.path}/foreign-objects').exists(),
        isFalse,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'binary ITA and conflicts block all without hiding valid individual files',
    () async {
      await fixture.write('file', 'safe\n');
      await File('${fixture.worktree.path}/binary').writeAsBytes([0, 1, 2]);
      await fixture.write('intent', 'intent\n');
      await fixture.git(['add', '--intent-to-add', 'intent']);
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(
        snapshot.unstaged.files
            .singleWhere((file) => file.relativePath == 'intent')
            .reviewEligible,
        isFalse,
      );
      final before = await fixture.index.readAsBytes();
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'layer'),
        )).status,
        'ineligible',
      );
      expect(await fixture.index.readAsBytes(), before);
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      final oid = (await fixture.git(['rev-parse', 'HEAD:unrelated'])).trim();
      await fixture.gitInput(
        ['update-index', '--index-info'],
        '0 ${'0' * 40}\tunrelated\n100644 $oid 1\tunrelated\n100644 $oid 2\tunrelated\n100644 $oid 3\tunrelated\n',
      );
      snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.conflicts, hasLength(1));
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'layer'),
        )).status,
        'ineligible',
      );
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'file', path: 'file'),
        )).status,
        'applied',
      );
    },
  );

  test(
    'nested source scope stages only its own paths despite nested gitfile',
    () async {
      await fixture.write('scope/inside', 'before\n');
      await fixture.git(['add', 'scope/inside']);
      await fixture.git(['commit', '-m', 'Nested fixture']);
      fixture.bind(scope: 'scope');
      await fixture.write('scope/inside', 'after\n');
      await fixture.write('file', 'outside unstaged\n');
      await fixture.write(
        'scope/.git',
        'gitdir: ${fixture.repository.path}/.git\n',
      );
      final snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.files.map((file) => file.relativePath), [
        'inside',
      ]);
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'layer'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('scope/inside'), 'after\n');
      expect(await fixture.indexText('file'), fixture.original);
      expect(await fixture.read('file'), 'outside unstaged\n');
    },
  );

  test(
    'unknown index extension stays exact and makes review unavailable',
    () async {
      await fixture.write('file', 'changed\n');
      final original = await fixture.index.readAsBytes();
      final contents = [
        ...original.take(original.length - 20),
        ...ascii.encode('TEST'),
        0,
        0,
        0,
        3,
        1,
        2,
        3,
      ];
      final withExtension = [...contents, ...sha1.convert(contents).bytes];
      await fixture.index.writeAsBytes(withExtension);
      final snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.reviewRevision, isNull);
      expect(snapshot.unstaged.files.single.reviewEligible, isFalse);
      expect(await fixture.index.readAsBytes(), withExtension);
    },
  );

  test('mutation process policy strips all inherited Git routing', () {
    final result = gitReviewMutationEnvironment(
      parentEnvironment: {
        'PATH': '.:/usr/bin:relative:/bin',
        'HOME': '/home/test',
        'GIT_DIR': '/evil',
        'GIT_INDEX_FILE': '/evil/index',
        'GIT_CONFIG_PARAMETERS': 'evil',
        'GIT_EXEC_PATH': '/evil',
        'GIT_TRACE': '/evil/log',
        'SECRET': 'hidden',
      },
      privateIndex: '/private/index',
    );
    expect(result['PATH'], '/usr/bin:/bin');
    expect(result['GIT_INDEX_FILE'], '/private/index');
    expect(result['GIT_ALLOW_PROTOCOL'], '');
    expect(result['GIT_NO_LAZY_FETCH'], '1');
    expect(result.containsKey('GIT_DIR'), isFalse);
    expect(result.containsKey('GIT_EXEC_PATH'), isFalse);
    expect(result.containsKey('GIT_TRACE'), isFalse);
    expect(result.containsKey('SECRET'), isFalse);
  });

  test(
    'snapshot scopes share live revisions and committed history is never reviewable',
    () async {
      await fixture.write('file', 'scope revision\n');
      final unstaged = await fixture.source.snapshotUnstaged();
      final task = await fixture.source.snapshotTaskChanges();
      expect(task.committed.reviewRevision, isNull);
      expect(task.uncommitted.unstaged.reviewRevision, unstaged.reviewRevision);
      expect(
        (await fixture.review.approve(
          _select(unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      final uncommitted = await fixture.source.snapshotUncommitted();
      expect(uncommitted.staged.reviewRevision, isNot(unstaged.reviewRevision));
      final before = await fixture.index.readAsBytes();
      expect(
        (await fixture.review.unapprove(
          _select(unstaged, 'file', path: 'file'),
        )).status,
        'stale',
      );
      expect(await fixture.index.readAsBytes(), before);
    },
  );

  test(
    'review proof missing or mismatched fails before read authority and real lock',
    () async {
      await fixture.write('file', 'proof test\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      for (final proof in [_DeniedProof(), _WrongProof()]) {
        final reads = fixture.authority.reads;
        final review = GitReviewApprovalService(
          provider: fixture.provider,
          authorizedRead: fixture.authority,
          authorizedReview: proof,
          parentEnvironment: fixture.environment,
        );
        await expectLater(
          review.approve(_select(snapshot.unstaged, 'file', path: 'file')),
          throwsA(anyOf(isA<StateError>(), isA<ReviewApprovalFailure>())),
        );
        expect(fixture.authority.reads, reads + (proof is _WrongProof ? 1 : 0));
        expect(await fixture.index.readAsBytes(), before);
        expect(await fixture.lock.exists(), isFalse);
      }
    },
  );

  test(
    'unrelated assume-unchanged flags and resolve-undo extension are preserved',
    () async {
      final oid = (await fixture.git(['rev-parse', 'HEAD:unrelated'])).trim();
      await fixture.gitInput(
        ['update-index', '--index-info'],
        '0 ${'0' * 40}\tunrelated\n100644 $oid 1\tunrelated\n100644 $oid 2\tunrelated\n100644 $oid 3\tunrelated\n',
      );
      await fixture.git(['add', 'unrelated']);
      await fixture.git(['update-index', '--assume-unchanged', 'unrelated']);
      final undo = await fixture.git(['ls-files', '--resolve-undo']);
      expect(undo, isNotEmpty);
      final unrelated = await fixture.git([
        'ls-files',
        '--stage',
        '--debug',
        '--',
        'unrelated',
      ]);
      await fixture.write('file', 'selected\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await fixture.git(['ls-files', '--resolve-undo']), undo);
      expect(
        await fixture.git([
          'ls-files',
          '--stage',
          '--debug',
          '--',
          'unrelated',
        ]),
        unrelated,
      );
    },
  );

  test(
    'version four compressed index and literal unusual filenames remain safe',
    () async {
      final names = [
        'space name',
        '-option',
        ':(glob)*',
        'tab\tname',
        'line\nname',
      ];
      for (final path in names) {
        await fixture.write(path, 'before\n');
      }
      await fixture.git(['add', '.']);
      await fixture.git(['commit', '-m', 'Literal paths']);
      await fixture.git(['update-index', '--index-version=4']);
      for (final path in names) {
        await fixture.write(path, 'after\n');
      }
      final snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.files, hasLength(names.length));
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'layer'),
        )).status,
        'applied',
      );
      for (final path in names) {
        expect(await fixture.indexText(path), 'after\n');
        expect(await fixture.read(path), 'after\n');
      }
    },
    skip: Platform.isWindows,
  );

  test(
    'symlink replacement and path traversal never stage another file',
    () async {
      await fixture.write('file', 'selected\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      await File('${fixture.worktree.path}/file').delete();
      await Link('${fixture.worktree.path}/file').create('../repo/unrelated');
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        isNot('applied'),
      );
      expect(await fixture.index.readAsBytes(), before);
      expect(
        await File('${fixture.repository.path}/unrelated').readAsString(),
        'unrelated\n',
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'operation expiry while authority is pending cannot admit late effects',
    () async {
      await fixture.write('file', 'selected\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      final gate = Completer<void>();
      fixture.authority.onRead = (_) => gate.future;
      final review = fixture.reviewWith(
        limits: const GitChangeSetLimits(
          operationTimeout: Duration(milliseconds: 100),
        ),
      );
      await expectLater(
        review.approve(_select(snapshot.unstaged, 'file', path: 'file')),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'operation_timeout',
          ),
        ),
      );
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.lock.exists(), isFalse);
    },
  );

  test(
    'SHA-256 repository approves and unapproves using full object identities',
    () async {
      await fixture.close();
      fixture = await _Repository.create(format: 'sha256');
      await fixture.write('file', 'sha256\n');
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.reviewRevision, hasLength(64));
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), 'sha256\n');
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'layer'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), fixture.original);
      expect(await fixture.read('file'), 'sha256\n');
    },
  );

  test(
    'ignored caches exceeding inventory bounds do not disable review or observe churn',
    () async {
      await fixture.write('.gitignore', 'cache/\n');
      await fixture.git(['add', '.gitignore']);
      await fixture.git(['commit', '-m', 'Ignore fixture cache']);
      final cache = await Directory('${fixture.worktree.path}/cache').create();
      for (var i = 0; i < 4100; i++) {
        await File('${cache.path}/$i').writeAsString('ignored');
      }
      await fixture.write('file', 'reviewable\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.files.single.reviewEligible, isTrue);
      expect(snapshot.unstaged.reviewRevision, isNotNull);
      fixture.authority.onRead = (call) async {
        if (call == 4) {
          await File('${cache.path}/new-cache-file').writeAsString('churn');
        }
      };
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), 'reviewable\n');
    },
  );

  test(
    'late addition within a previously empty nonignored directory is stale',
    () async {
      await Directory(
        '${fixture.worktree.path}/empty/nested',
      ).create(recursive: true);
      await fixture.write('file', 'reviewable\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      fixture.authority.onRead = (call) async {
        if (call == 4) await fixture.write('empty/nested/new', 'late\n');
      };
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'layer'),
        )).status,
        'stale',
      );
      expect(await fixture.index.readAsBytes(), before);
    },
  );

  test(
    'nested source hunk and layer roundtrip remains fresh through read-only Git inspection',
    () async {
      const path = 'nested source/a modified.txt';
      const addition = 'nested source/b ordinary addition.txt';
      final original = List.generate(24, (i) => 'Baseline line $i\n').join();
      final working = original
          .replaceFirst('Baseline line 1\n', 'First reviewed change\n')
          .replaceFirst('Baseline line 20\n', 'Second reviewed change\n');
      await fixture.write(path, original);
      await fixture.git(['add', '--', path]);
      await fixture.git(['commit', '-m', 'Separated hunks']);
      fixture.bind(scope: 'nested source');
      await fixture.write(path, working);
      await fixture.write(addition, 'Ordinary untracked text\n');
      await fixture.write('unrelated', 'outside staged\n');
      await fixture.git(['add', 'unrelated']);
      final snapshot = await fixture.source.snapshotUnstaged();
      expect(
        (await fixture.review.approve(
          _select(snapshot, 'hunk', path: 'a modified.txt', hunk: 0),
        )).status,
        'applied',
      );
      var layers = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(layers.staged, 'hunk', path: 'a modified.txt', hunk: 0),
        )).status,
        'applied',
      );
      layers = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.approve(
          _select(layers.unstaged, 'layer'),
        )).status,
        'applied',
      );
      layers = await fixture.source.snapshotUncommitted();
      expect(layers.unstaged.files, isEmpty);
      final approvedIndex = await fixture.index.readAsBytes();
      expect(
        await fixture.git(['--no-optional-locks', 'show', ':$path']),
        working,
      );
      expect(
        await fixture.git(['--no-optional-locks', 'show', ':$addition']),
        'Ordinary untracked text\n',
      );
      expect(
        await fixture.git([
          '--no-optional-locks',
          '-c',
          'diff.autoRefreshIndex=false',
          'diff',
          '--no-ext-diff',
          '--no-textconv',
          '--',
          'nested source',
        ]),
        isEmpty,
      );
      expect(await fixture.index.readAsBytes(), approvedIndex);
      final inspected = await fixture.source.snapshotUncommitted();
      expect(
        inspected.staged.reviewRevision,
        layers.staged.reviewRevision,
        reason:
            'Read-only inspection must retain the authoritative staged revision',
      );
      expect(
        (await fixture.review.unapprove(
          _select(layers.staged, 'layer'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText(path), original);
      expect(await fixture.indexText('unrelated'), 'outside staged\n');
      expect(await fixture.read(path), working);
    },
  );

  test(
    'mutation process deadline kills preparation and releases its real lock',
    () async {
      await fixture.write('file', 'selected\n');
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      final marker = File('${fixture.container.path}/hash-started');
      final wrapper = await fixture.shim('''
case " \$* " in
  *" hash-object "*) : > '${marker.path}'; exec /bin/sleep 30 ;;
esac
exec /usr/bin/git "\$@"
''');
      final review = fixture.reviewWith(
        parentEnvironment: {'PATH': '${wrapper.path}:/usr/bin:/bin'},
        limits: const GitChangeSetLimits(processTimeout: Duration(seconds: 1)),
      );
      await expectLater(
        review.approve(_select(snapshot.unstaged, 'file', path: 'file')),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'git_timeout',
          ),
        ),
      );
      expect(await marker.exists(), isTrue);
      expect(await fixture.index.readAsBytes(), before);
      expect(await fixture.lock.exists(), isFalse);
      expect(await fixture.read('file'), 'selected\n');
    },
    skip: Platform.isWindows,
  );

  test(
    'object fanout symlinks cannot redirect raw writes into working content',
    () async {
      final objects = Directory('${fixture.repository.path}/.git/objects');
      var content = 'object path safety\n';
      String prefix(String value) => sha1
          .convert([
            ...utf8.encode('blob ${utf8.encode(value).length}\u0000'),
            ...utf8.encode(value),
          ])
          .toString()
          .substring(0, 2);
      while (await Directory('${objects.path}/${prefix(content)}').exists()) {
        content += 'next\n';
      }
      await fixture.write('file', content);
      final redirect = await Directory(
        '${fixture.worktree.path}/redirect',
      ).create();
      await Link('${objects.path}/${prefix(content)}').create(redirect.path);
      final snapshot = await fixture.source.snapshotUncommitted();
      final before = await fixture.index.readAsBytes();
      await expectLater(
        fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        ),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (error) => error.code,
            'code',
            'object_store_unsupported',
          ),
        ),
      );
      expect(await fixture.index.readAsBytes(), before);
      expect(await redirect.list().toList(), isEmpty);
      expect(await fixture.lock.exists(), isFalse);
    },
    skip: Platform.isWindows,
  );

  for (final fileToDirectory in [true, false]) {
    test(
      'D/F replacement $fileToDirectory never removes an unselected index entry',
      () async {
        final restoredPath = fileToDirectory ? 'node' : 'node/child';
        final stagedPath = fileToDirectory ? 'node/child' : 'node';
        await fixture.write(restoredPath, 'HEAD content\n');
        await fixture.git(['add', '--', restoredPath]);
        await fixture.git(['commit', '-m', 'D/F baseline']);
        if (fileToDirectory) {
          await File('${fixture.worktree.path}/node').delete();
        } else {
          await Directory(
            '${fixture.worktree.path}/node',
          ).delete(recursive: true);
        }
        await fixture.write(stagedPath, 'staged replacement\n');
        await fixture.git(['add', '-A']);
        final snapshot = await fixture.source.snapshotUncommitted();
        expect(
          snapshot.staged.files.every((file) => !file.reviewEligible),
          isTrue,
        );
        final before = await fixture.index.readAsBytes();
        for (final granularity in ['file', 'hunk']) {
          expect(
            (await fixture.review.unapprove(
              _select(
                snapshot.staged,
                granularity,
                path: restoredPath,
                hunk: granularity == 'hunk' ? 0 : null,
              ),
            )).status,
            'ineligible',
          );
          expect(await fixture.index.readAsBytes(), before);
          expect(await fixture.indexText(stagedPath), 'staged replacement\n');
        }
        expect(
          snapshot.staged.files.every(
            (file) => file.detail!.contains('File/directory'),
          ),
          isTrue,
        );
        // The single eligibility bit also keeps whole-layer controls unavailable.
        expect(
          (await fixture.review.unapprove(
            _select(snapshot.staged, 'layer'),
          )).status,
          'ineligible',
        );
        expect(await fixture.index.readAsBytes(), before);
        expect(await fixture.read(stagedPath), 'staged replacement\n');
      },
    );
  }

  test(
    'future-mtime unrelated index entries cannot execute filters during serialization',
    () async {
      final sentinel = File('${fixture.container.path}/filter-executed');
      await File(
        '${fixture.worktree.path}/unrelated',
      ).setLastModified(DateTime.utc(2035));
      await fixture.git(['add', 'unrelated']);
      final unrelated = await fixture.git([
        'ls-files',
        '--stage',
        '--debug',
        '--',
        'unrelated',
      ]);
      await fixture.git([
        'config',
        'filter.evil.clean',
        "touch '${sentinel.path}'; cat",
      ]);
      await File(
        '${fixture.repository.path}/.git/info/attributes',
      ).writeAsString('unrelated filter=evil\n');
      await fixture.write('file', 'safe selected bytes\n');
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.files.single.relativePath, 'file');
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await sentinel.exists(), isFalse);
      expect(
        await fixture.git([
          'ls-files',
          '--stage',
          '--debug',
          '--',
          'unrelated',
        ]),
        unrelated,
      );
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await sentinel.exists(), isFalse);
      expect(
        await fixture.git([
          'ls-files',
          '--stage',
          '--debug',
          '--',
          'unrelated',
        ]),
        unrelated,
      );
      expect(await fixture.read('unrelated'), 'unrelated\n');
    },
    skip: Platform.isWindows,
  );

  for (final storage in [
    'leaf-symlink',
    'corrupt-leaf',
    'alternates',
    'http-alternates',
    'pack-symlink',
  ]) {
    test(
      'unsafe $storage storage leaves ignored working sentinel and index unchanged',
      () async {
        const changed = 'new object not already stored\n';
        final objects = Directory('${fixture.repository.path}/.git/objects');
        await File(
          '${fixture.repository.path}/.git/info/exclude',
        ).writeAsString('cache/\n');
        await fixture.write('cache/sentinel', 'ignored working sentinel\n');
        final sentinel = File('${fixture.worktree.path}/cache/sentinel');
        final bytes = utf8.encode(changed);
        final oid = sha1.convert([
          ...utf8.encode('blob ${bytes.length}\u0000'),
          ...bytes,
        ]).toString();
        final leaf = File(
          '${objects.path}/${oid.substring(0, 2)}/${oid.substring(2)}',
        );
        switch (storage) {
          case 'leaf-symlink':
            await leaf.parent.create(recursive: true);
            await Link(leaf.path).create(sentinel.path);
          case 'corrupt-leaf':
            await leaf.parent.create(recursive: true);
            await leaf.writeAsString('not a Git object');
            await leaf.setLastModified(DateTime.utc(2001));
          case 'alternates':
            final alternate = await Directory(
              '${fixture.container.path}/alternate-objects',
            ).create();
            await File(
              '${objects.path}/info/alternates',
            ).writeAsString('${alternate.path}\n');
          case 'http-alternates':
            await File(
              '${objects.path}/info/http-alternates',
            ).writeAsString('disabled\n');
          case 'pack-symlink':
            await fixture.git(['repack', '-ad']);
            final pack =
                (await Directory('${objects.path}/pack').list().toList())
                    .singleWhere((entry) => entry.path.endsWith('.pack'));
            await File(pack.path).rename(sentinel.path);
            await Link(pack.path).create(sentinel.path);
        }
        await sentinel.setLastModified(DateTime.utc(2001));
        final sentinelBytes = await sentinel.readAsBytes();
        final sentinelModified = (await sentinel.stat()).modified;
        final leafModified = storage == 'corrupt-leaf'
            ? (await leaf.stat()).modified
            : null;
        await fixture.write('file', changed);
        final snapshot = await fixture.source.snapshotUncommitted();
        expect(snapshot.unstaged.files.single.reviewEligible, isTrue);
        final before = await fixture.index.readAsBytes();
        await expectLater(
          fixture.review.approve(
            _select(snapshot.unstaged, 'file', path: 'file'),
          ),
          throwsA(
            isA<ReviewApprovalFailure>().having(
              (error) => error.code,
              'code',
              storage == 'corrupt-leaf'
                  ? anyOf('git_failed', 'object_identity_invalid')
                  : 'object_store_unsupported',
            ),
          ),
        );
        expect(await fixture.index.readAsBytes(), before);
        expect(await sentinel.readAsBytes(), sentinelBytes);
        expect((await sentinel.stat()).modified, sentinelModified);
        if (leafModified != null) {
          expect((await leaf.stat()).modified, leafModified);
        }
        expect(await fixture.lock.exists(), isFalse);
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'verified existing packed objects are reused without freshening their mtimes',
    () async {
      await fixture.git(['repack', '-ad']);
      final pack = File(
        (await Directory(
              '${fixture.repository.path}/.git/objects/pack',
            ).list().toList())
            .singleWhere((entry) => entry.path.endsWith('.pack'))
            .path,
      );
      await pack.setLastModified(DateTime.utc(2001));
      final modified = (await pack.stat()).modified;
      await fixture.write('file', 'new loose object\n');
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), fixture.original);
      expect((await pack.stat()).modified, modified);
    },
  );

  test(
    'ordinary text review works beside an unchanged oversized tracked binary',
    () async {
      final image = File('${fixture.worktree.path}/image.bin');
      await image.writeAsBytes(List.filled(1024 * 1024 + 100, 0));
      await fixture.git(['add', 'image.bin']);
      await fixture.git(['commit', '-m', 'Large binary neighbor']);
      final imageEntry = await fixture.git([
        'ls-files',
        '--stage',
        '--debug',
        '--',
        'image.bin',
      ]);
      final imageBytes = await image.readAsBytes();
      await fixture.write('file', 'ordinary text\n');
      var snapshot = await fixture.source.snapshotUncommitted();
      expect(snapshot.unstaged.files.single.relativePath, 'file');
      expect(snapshot.unstaged.reviewRevision, isNotNull);
      expect(
        (await fixture.review.approve(
          _select(snapshot.unstaged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      snapshot = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(snapshot.staged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(
        await fixture.git([
          'ls-files',
          '--stage',
          '--debug',
          '--',
          'image.bin',
        ]),
        imageEntry,
      );
      expect(await image.readAsBytes(), imageBytes);
      expect(await fixture.read('file'), 'ordinary text\n');
    },
  );
  for (final granularity in ['hunk', 'file', 'layer']) {
    test(
      'approval $granularity renders only its unstaged bounded layer',
      () async {
        const neighbors = ['staged-a', 'staged-b', 'staged-c'];
        for (final path in neighbors) {
          await fixture.write(path, 'base $path\n');
        }
        if (!Platform.isWindows) {
          expect(
            (await Process.run('chmod', [
              '755',
              '${fixture.worktree.path}/staged-a',
            ])).exitCode,
            0,
          );
        }
        await fixture.git(['add', '.']);
        await fixture.git(['commit', '-m', 'Staged neighbor baseline']);
        for (final path in neighbors) {
          await fixture.write(path, 'staged $path\n');
        }
        await fixture.git(['add', '--', ...neighbors]);
        final working = fixture.original
            .replaceFirst('line 1\n', 'first\n')
            .replaceFirst('line 27\n', 'last\n');
        await fixture.write('file', working);
        final head = await fixture.git(['rev-parse', 'HEAD']);
        final unrelated = await fixture.git([
          'ls-files',
          '--stage',
          '--debug',
          '--',
          ...neighbors,
        ]);
        final defaultSnapshot = await fixture.source.snapshotUnstaged();
        expect(defaultSnapshot.reviewRevision, isNotNull);
        expect(defaultSnapshot.files.single.hunks, hasLength(2));
        const limits = GitChangeSetLimits(files: 1);
        final bounded = GitChangeSetSourceService(
          provider: fixture.provider,
          authorizedRead: fixture.authority,
          parentEnvironment: fixture.environment,
          limits: limits,
        );
        expect(
          (await bounded.snapshotUnstaged()).reviewRevision,
          defaultSnapshot.reviewRevision,
        );
        for (final observe in [
          bounded.snapshotUncommitted,
          bounded.snapshotTaskChanges,
        ]) {
          await expectLater(
            observe(),
            throwsA(
              isA<ChangeSetFailure>().having(
                (error) => error.code,
                'code',
                'too_many_files',
              ),
            ),
          );
        }
        expect(
          (await fixture
                  .reviewWith(limits: limits)
                  .approve(
                    _select(
                      defaultSnapshot,
                      granularity,
                      path: granularity == 'layer' ? null : 'file',
                      hunk: granularity == 'hunk' ? 1 : null,
                    ),
                  ))
              .status,
          'applied',
        );
        expect(
          await fixture.indexText('file'),
          granularity == 'hunk'
              ? fixture.original.replaceFirst('line 27\n', 'last\n')
              : working,
        );
        expect(
          await fixture.git([
            'ls-files',
            '--stage',
            '--debug',
            '--',
            ...neighbors,
          ]),
          unrelated,
        );
        final approved = await fixture.source.snapshotUncommitted();
        expect(
          (await fixture.review.unapprove(
            _select(approved.staged, 'file', path: 'file'),
          )).status,
          'applied',
        );
        expect(await fixture.indexText('file'), fixture.original);
        expect(
          await fixture.git([
            'ls-files',
            '--stage',
            '--debug',
            '--',
            ...neighbors,
          ]),
          unrelated,
        );
        expect(await fixture.git(['rev-parse', 'HEAD']), head);
        expect(await fixture.read('file'), working);
        for (final path in neighbors) {
          expect(await fixture.indexText(path), 'staged $path\n');
          expect(await fixture.read(path), 'staged $path\n');
        }
        expect(await fixture.lock.exists(), isFalse);
      },
    );
  }

  test(
    'chained symbolic HEAD disables only review and direct HEAD restores it',
    () async {
      await fixture.git(['update-ref', 'refs/heads/main', fixture.baseline]);
      await fixture.git(['symbolic-ref', 'HEAD', 'refs/heads/main']);
      final id = EnvironmentId('selected');
      fixture.provider.liveObjects.unbind(id);
      fixture.provider.liveObjects.bind(
        id,
        WorktreeEnvironment(
          fixture.worktree,
          gitWorktreeRoot: fixture.worktree,
          gitDirectory: fixture.gitDirectory,
          gitCommonDirectory: Directory('${fixture.repository.path}/.git'),
          baselineCommit: fixture.baseline,
          branch: 'main',
        ),
      );
      await fixture.write('unrelated', 'staged\n');
      await fixture.git(['add', 'unrelated']);
      await fixture.write('file', 'working\n');
      final direct = await fixture.source.snapshotUnstaged();
      await fixture.git([
        'symbolic-ref',
        'refs/heads/alias',
        'refs/heads/main',
      ]);
      await fixture.git([
        'symbolic-ref',
        'refs/heads/main\u00a0',
        'refs/heads/main',
      ]);
      await fixture.git(['symbolic-ref', 'HEAD', 'refs/heads/alias']);
      expect(
        (await fixture.git(['symbolic-ref', 'HEAD'])).trim(),
        'refs/heads/main',
      );
      final headFile = File('${fixture.gitDirectory.path}/HEAD');
      final head = await headFile.readAsBytes();
      final refs = await fixture.git([
        'for-each-ref',
        '--format=%(refname) %(objectname) %(symref)',
      ]);
      final index = await fixture.index.readAsBytes();
      final unstaged = await fixture.source.snapshotUnstaged();
      final uncommitted = await fixture.source.snapshotUncommitted();
      final task = await fixture.source.snapshotTaskChanges();
      for (final layer in [
        unstaged,
        uncommitted.staged,
        uncommitted.unstaged,
        task.uncommitted.staged,
        task.uncommitted.unstaged,
      ]) {
        expect(layer.files.single.contentStatus, 'text');
        expect(layer.files.single.hunks, isNotEmpty);
        expect(layer.files.single.reviewEligible, isFalse);
        expect(layer.reviewRevision, isNull);
      }
      expect(
        (await fixture.review.approve(
          _select(direct, 'file', path: 'file'),
        )).status,
        'ineligible',
      );
      expect(
        (await fixture.review.unapprove(
          _select(uncommitted.staged, 'file', path: 'unrelated'),
        )).status,
        'ineligible',
      );
      expect(await fixture.index.readAsBytes(), index);
      expect(await headFile.readAsBytes(), head);
      expect(
        await fixture.git([
          'for-each-ref',
          '--format=%(refname) %(objectname) %(symref)',
        ]),
        refs,
      );
      await fixture.git(['symbolic-ref', 'HEAD', 'refs/heads/main\u00a0']);
      expect((await fixture.source.snapshotUnstaged()).reviewRevision, isNull);
      await fixture.git(['symbolic-ref', 'HEAD', 'refs/heads/main']);
      final restored = await fixture.source.snapshotUnstaged();
      expect(restored.reviewRevision, isNotNull);
      expect(
        (await fixture.review.approve(
          _select(restored, 'file', path: 'file'),
        )).status,
        'applied',
      );
      final staged = await fixture.source.snapshotUncommitted();
      expect(
        (await fixture.review.unapprove(
          _select(staged.staged, 'file', path: 'file'),
        )).status,
        'applied',
      );
      expect(await fixture.indexText('file'), fixture.original);
      expect(await fixture.indexText('unrelated'), 'staged\n');
      expect(await fixture.read('file'), 'working\n');
      expect(await fixture.read('unrelated'), 'staged\n');
      expect(
        await fixture.git([
          'for-each-ref',
          '--format=%(refname) %(objectname) %(symref)',
        ]),
        refs,
      );
      await fixture.git(['switch', '--detach', 'HEAD']);
      expect(
        (await fixture.source.snapshotUnstaged()).reviewRevision,
        isNotNull,
      );
      expect(
        (await fixture.source.snapshotUncommitted()).staged.reviewRevision,
        isNotNull,
      );
      await expectLater(
        fixture.source.snapshotTaskChanges(),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'detached_head',
          ),
        ),
      );
      expect(await fixture.lock.exists(), isFalse);
    },
  );

  test(
    'direct HEAD becoming a chain at final authority cannot publish',
    () async {
      await fixture.write('file', 'working\n');
      await fixture.git([
        'symbolic-ref',
        'refs/heads/alias',
        'refs/heads/task',
      ]);
      final snapshot = await fixture.source.snapshotUnstaged();
      final index = await fixture.index.readAsBytes();
      final refs = await fixture.git([
        'for-each-ref',
        '--format=%(refname) %(objectname) %(symref)',
      ]);
      fixture.authority.onRead = (call) async {
        if (call == 4) {
          await fixture.git(['symbolic-ref', 'HEAD', 'refs/heads/alias']);
        }
      };
      expect(
        (await fixture.review.approve(
          _select(snapshot, 'file', path: 'file'),
        )).status,
        'stale',
      );
      expect(await fixture.index.readAsBytes(), index);
      expect(
        await fixture.git(['symbolic-ref', '--no-recurse', 'HEAD']),
        'refs/heads/alias\n',
      );
      expect(
        await fixture.git([
          'for-each-ref',
          '--format=%(refname) %(objectname) %(symref)',
        ]),
        refs,
      );
      expect(await fixture.read('file'), 'working\n');
      expect(await fixture.lock.exists(), isFalse);
    },
  );

  test('unstaged-only approval never skips a conflict in Whole All', () async {
    await fixture.write('file', 'working\n');
    final oid = (await fixture.git(['rev-parse', 'HEAD:unrelated'])).trim();
    await fixture.gitInput(
      ['update-index', '--index-info'],
      '0 ${'0' * 40}\tunrelated\n100644 $oid 1\tunrelated\n100644 $oid 2\tunrelated\n100644 $oid 3\tunrelated\n',
    );
    final snapshot = await fixture.source.snapshotUnstaged();
    expect(
      snapshot.files.any(
        (file) => file.contentStatus == 'conflicted' && !file.reviewEligible,
      ),
      isTrue,
    );
    final index = await fixture.index.readAsBytes();
    expect(
      (await fixture.review.approve(_select(snapshot, 'layer'))).status,
      'ineligible',
    );
    expect(await fixture.index.readAsBytes(), index);
    expect(await fixture.read('file'), 'working\n');
    expect(await fixture.read('unrelated'), 'unrelated\n');
    expect(await fixture.lock.exists(), isFalse);
  });
}

ReviewSelection _select(
  ChangeSetSnapshot snapshot,
  String granularity, {
  String? path,
  int? hunk,
}) => ReviewSelection(
  expectedRevision: snapshot.reviewRevision ?? ''.padLeft(64, '0'),
  granularity: granularity,
  relativePath: path,
  hunkIndex: hunk,
);

final class _Unsettled {}

final class _IndexLockProbe implements File {
  _IndexLockProbe(this.file, this.created);
  final File file;
  final void Function() created;
  @override
  String get path => file.path;
  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    file.createSync(recursive: recursive, exclusive: exclusive);
    created();
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      file.openSync(mode: mode);
  @override
  File renameSync(String newPath) => file.renameSync(newPath);
  @override
  void deleteSync({bool recursive = false}) =>
      file.deleteSync(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnavailableModeTool implements File {
  _UnavailableModeTool(this.file, this.missing);
  final File file;
  final File missing;
  @override
  String get path => file.path;
  @override
  FileStat statSync() => missing.statSync();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Authority implements AuthorizedEnvironmentReadService {
  int reads = 0;
  int reviewReads = 0;
  bool revoked = false;
  FutureOr<void> Function(int)? onRead;
  FutureOr<void> Function(int)? onReview;
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    reads++;
    await onRead?.call(reads);
    if (revoked) throw StateError('Grant revoked');
    return AuthorizedEnvironmentIdentity(
      sessionId: 'session',
      environmentId: 'selected',
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) =>
      throw StateError('Identity only');
  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      throw StateError('Identity only');
}

final class _Proof implements AuthorizedEnvironmentReviewService {
  _Proof(this.read);
  final _Authority read;
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    await read.onReview?.call(++read.reviewReads);
    if (read.revoked) throw StateError('Review grant revoked');
    return AuthorizedEnvironmentIdentity(
      sessionId: 'session',
      environmentId: 'selected',
    );
  }
}

final class _DeniedProof implements AuthorizedEnvironmentReviewService {
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async =>
      throw StateError('No review grant');
}

final class _WrongProof implements AuthorizedEnvironmentReviewService {
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async =>
      AuthorizedEnvironmentIdentity(
        sessionId: 'another-session',
        environmentId: 'selected',
      );
}

final class _Repository {
  _Repository(
    this.container,
    this.repository,
    this.worktree,
    this.gitDirectory,
    this.baseline,
  );
  final Directory container;
  final Directory repository;
  final Directory worktree;
  final Directory gitDirectory;
  final String baseline;
  final provider = GitWorktreeEnvironmentProvider();
  final authority = _Authority();
  String get original => '${List.generate(30, (i) => 'line $i').join('\n')}\n';
  File get index => File('${gitDirectory.path}/index');
  File get lock => File('${gitDirectory.path}/index.lock');
  Map<String, String> get environment => {
    'PATH': Platform.environment['PATH']!,
    'HOME': container.path,
    'XDG_CONFIG_HOME': '${container.path}/config',
  };
  GitChangeSetSourceService get source => GitChangeSetSourceService(
    provider: provider,
    authorizedRead: authority,
    parentEnvironment: environment,
  );
  GitReviewApprovalService get review => reviewWith();
  GitReviewApprovalService reviewWith({
    Map<String, String>? parentEnvironment,
    GitChangeSetLimits limits = const GitChangeSetLimits(),
  }) => GitReviewApprovalService(
    provider: provider,
    authorizedRead: authority,
    authorizedReview: _Proof(authority),
    limits: limits,
    parentEnvironment: {...environment, ...?parentEnvironment},
  );
  void bind({String? scope}) {
    final id = EnvironmentId('selected');
    if (provider.liveObjects.contains(id)) provider.liveObjects.unbind(id);
    provider.liveObjects.bind(
      id,
      WorktreeEnvironment(
        scope == null ? worktree : Directory('${worktree.path}/$scope'),
        gitWorktreeRoot: worktree,
        gitDirectory: gitDirectory,
        gitCommonDirectory: Directory('${repository.path}/.git'),
        baselineCommit: baseline,
        branch: 'task',
      ),
    );
  }

  Future<void> write(String path, String text) async {
    final file = File('${worktree.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<String> read(String path) =>
      File('${worktree.path}/$path').readAsString();
  Future<String> indexText(String path) => git(['show', ':$path']);
  Future<ProcessResult> runGit(List<String> args) => Process.run(
    'git',
    args,
    workingDirectory: worktree.path,
    environment: {
      ...environment,
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
    },
    includeParentEnvironment: false,
  );
  Future<String> git(List<String> args) async {
    final result = await runGit(args);
    if (result.exitCode != 0) throw StateError('git $args: ${result.stderr}');
    return result.stdout as String;
  }

  Future<void> gitInput(List<String> args, String input) async {
    final process = await Process.start(
      'git',
      args,
      workingDirectory: worktree.path,
      environment: environment,
      includeParentEnvironment: false,
    );
    final out = process.stdout.drain<void>();
    final err = process.stderr.transform(utf8.decoder).join();
    process.stdin.write(input);
    await process.stdin.close();
    final code = await process.exitCode;
    await out;
    final error = await err;
    if (code != 0) throw StateError(error);
  }

  Future<Directory> shim(String body) async {
    final directory = await container.createTemp('shim-');
    final file = File('${directory.path}/git');
    await file.writeAsString('#!/bin/sh\n$body\n');
    await Process.run('chmod', ['755', file.path]);
    return directory;
  }

  Future<void> close() async {
    await provider.close();
    if (await container.exists()) await container.delete(recursive: true);
  }

  static Future<_Repository> create({
    String format = 'sha1',
    bool shared = false,
  }) async {
    final container = await Directory.systemTemp.createTemp(
      'adele-git-review-',
    );
    final repository = await Directory('${container.path}/repo').create();
    final worktree = Directory('${container.path}/worktree');
    Future<String> git(List<String> args) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: repository.path,
        environment: {
          'PATH': Platform.environment['PATH']!,
          'HOME': container.path,
          'GIT_CONFIG_NOSYSTEM': '1',
          'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
        },
        includeParentEnvironment: false,
      );
      if (result.exitCode != 0) throw StateError('git $args: ${result.stderr}');
      return result.stdout as String;
    }

    await git([
      'init',
      '--object-format=$format',
      if (shared) '--shared=group',
    ]);
    await git(['config', 'user.name', 'ADELE Test']);
    await git(['config', 'user.email', 'adele@example.invalid']);
    await File(
      '${repository.path}/file',
    ).writeAsString('${List.generate(30, (i) => 'line $i').join('\n')}\n');
    await File('${repository.path}/unrelated').writeAsString('unrelated\n');
    await git(['add', '.']);
    await git(['commit', '-m', 'Fixture']);
    final baseline = (await git(['rev-parse', 'HEAD'])).trim();
    await git(['worktree', 'add', '-b', 'task', worktree.path]);
    final metadata = (await git([
      '-C',
      worktree.path,
      'rev-parse',
      '--absolute-git-dir',
    ])).trim();
    final result = _Repository(
      container,
      repository,
      worktree,
      Directory(metadata),
      baseline,
    );
    result.bind();
    return result;
  }
}
