@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart' show GitPortableUnstagedLimits;
import 'package:test/test.dart';

import 'support/git_portable_review_approval_support.dart';

void main() {
  late TestRepo fixture;

  setUp(() async {
    fixture = await TestRepo.create();
  });

  tearDown(() async {
    await fixture.close();
  });

  for (final staged in [false, true]) {
    for (final kind in [
      'binary',
      'invalid UTF-8',
      'oversized',
      'symlink HEAD',
      'gitlink HEAD',
      if (staged) ...['working recreation', 'empty recreation'],
      'directory replacement',
      'symlink leaf',
      'dangling symlink',
      'symlink parent',
      'dangling symlink parent',
      'file ancestor',
      'index ancestor',
      'index descendant',
      'nested repository',
      'conflict',
      'tab path',
      'newline path',
      if (!staged) ...[
        'index binary',
        'index invalid UTF-8',
        'index oversized',
        'HEAD binary index text',
        'HEAD invalid UTF-8 index text',
        'HEAD oversized index text',
        'index symlink',
        'index gitlink',
        'index mode mismatch',
        'assume-unchanged',
        'skip-worktree',
        'intent-to-add',
        'new staged addition missing',
      ],
    ]) {
      test('deletion ${reviewVerb(staged)} excludes $kind', () async {
        final path = kind == 'tab path'
            ? 'parent/deleted\tname'
            : kind == 'newline path'
            ? 'parent/deleted\nname'
            : 'parent/deleted.txt';
        await fixture.write(
          path,
          kind == 'oversized' || kind == 'HEAD oversized index text'
              ? 'x' * 100
              : 'HEAD A\n',
        );
        if (kind == 'binary' ||
            kind == 'invalid UTF-8' ||
            kind == 'HEAD binary index text' ||
            kind == 'HEAD invalid UTF-8 index text') {
          await File(
            '${fixture.repository.path}/$path',
          ).writeAsBytes(kind.contains('binary') ? [1, 0, 2] : [255, 254, 10]);
        }
        if (kind == 'symlink HEAD') {
          await File('${fixture.repository.path}/$path').delete();
          await Link(
            '${fixture.repository.path}/$path',
          ).create('../tracked.txt');
        }
        if (kind != 'new staged addition missing') await fixture.commit();
        if (kind.endsWith('index text')) {
          await fixture.write(path, 'index B\n');
          await fixture.git(['add', '--', path]);
        }
        if (kind == 'gitlink HEAD') {
          final oid = (await fixture.git(['rev-parse', 'HEAD'])).trim();
          await fixture.git([
            'update-index',
            '--cacheinfo',
            '160000,$oid,$path',
          ]);
          await fixture.git(['commit', '-m', 'Gitlink fixture']);
        }
        if (kind.startsWith('index ') &&
            [
              'index binary',
              'index invalid UTF-8',
              'index oversized',
            ].contains(kind)) {
          await File('${fixture.repository.path}/$path').writeAsBytes(
            kind == 'index binary'
                ? [1, 0, 2]
                : kind == 'index invalid UTF-8'
                ? [255, 254, 10]
                : utf8.encode('x' * 100),
          );
          await fixture.git(['add', '--', path]);
        }
        if (kind == 'new staged addition missing') {
          await fixture.git(['add', '--', path]);
        }
        if (kind == 'intent-to-add') {
          await fixture.git(['update-index', '--force-remove', '--', path]);
          await fixture.git(['add', '--intent-to-add', '--', path]);
        }
        if (kind == 'symlink HEAD') {
          await Link('${fixture.repository.path}/$path').delete();
        } else {
          await File('${fixture.repository.path}/$path').delete();
        }
        if (staged) {
          await fixture.git(['update-index', '--force-remove', '--', path]);
        }
        switch (kind) {
          case 'working recreation':
            await fixture.write(path, 'recreated\n');
          case 'empty recreation':
            await fixture.write(path, '');
          case 'directory replacement':
            await fixture.write('$path/child.txt', 'replacement\n');
          case 'symlink leaf':
          case 'dangling symlink':
            await Link('${fixture.repository.path}/$path').create(
              kind == 'symlink leaf' ? '../tracked.txt' : 'missing-target',
            );
          case 'symlink parent':
          case 'dangling symlink parent':
            await Directory(
              '${fixture.repository.path}/parent',
            ).rename('${fixture.repository.path}/real-parent');
            await Link('${fixture.repository.path}/parent').create(
              kind == 'symlink parent' ? 'real-parent' : 'missing-parent',
            );
          case 'file ancestor':
            await Directory('${fixture.repository.path}/parent').delete();
            await fixture.write('parent', 'obstruction\n');
          case 'index ancestor':
          case 'index descendant':
            final oid = (await fixture.git([
              'rev-parse',
              'HEAD:tracked.txt',
            ])).trim();
            await fixture.git(['update-index', '--force-remove', '--', path]);
            await fixture.git([
              'update-index',
              '--add',
              '--cacheinfo',
              '100644,$oid,${kind == 'index ancestor' ? 'parent' : '$path/child.txt'}',
            ]);
          case 'nested repository':
            await fixture.git([
              '-C',
              '${fixture.repository.path}/parent',
              'init',
            ]);
          case 'conflict':
            await fixture.makeConflict(path: path);
          case 'index mode mismatch':
            final oid = (await fixture.git(['rev-parse', ':$path'])).trim();
            await fixture.git([
              'update-index',
              '--cacheinfo',
              '100755,$oid,$path',
            ]);
          case 'index symlink':
          case 'index gitlink':
            final oid = (await fixture.git([
              'rev-parse',
              kind == 'index gitlink' ? 'HEAD' : 'HEAD:$path',
            ])).trim();
            await fixture.git([
              'update-index',
              '--cacheinfo',
              '${kind == 'index gitlink' ? '160000' : '120000'},$oid,$path',
            ]);
          case 'assume-unchanged':
          case 'skip-worktree':
            await fixture.git(['update-index', '--$kind', '--', path]);
        }
        final limits = kind.contains('oversized')
            ? const GitPortableUnstagedLimits(fileBytes: 64)
            : const GitPortableUnstagedLimits();
        final before = await fixture.state();
        final snapshot = await fixture
            .snapshotsWith(limits)
            .snapshotUncommitted();
        for (final file in [
          ...(staged ? snapshot.staged : snapshot.unstaged).files,
          ...snapshot.conflicts,
        ].where((file) => file.relativePath == path)) {
          expect(file.fileReviewRevision, isNull);
          expect(file.reviewRevision, isNull);
        }
        fixture.processes.requests.clear();
        await expectLater(
          fixture.mutateFile(
            untrustedFileSelection(path),
            staged: staged,
            limits: limits,
          ),
          throwsA(hasErrorCode(['unsupported_target', 'stale_selection'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
      });
    }

    for (final rule in [
      'filter=hostile',
      'diff=hostile',
      '-diff',
      'text',
      'eol=crlf',
      'crlf',
      'working-tree-encoding=UTF-16',
      'ident',
      'config autocrlf',
      'config eol',
    ]) {
      test(
        'deletion ${reviewVerb(staged)} excludes conversion $rule',
        () async {
          await fixture.deleteTracked(staged: staged);
          if (rule.startsWith('config')) {
            await fixture.git([
              'config',
              'core.${rule.split(' ').last}',
              rule.endsWith('autocrlf') ? 'true' : 'crlf',
            ]);
          } else {
            await fixture.write('.git/info/attributes', 'tracked.txt $rule\n');
          }
          final before = await fixture.state();
          final file = await fixture.changed(staged: staged);
          expect(file.reviewRevision, isNull);
          expect(file.fileReviewRevision, isNull);
          await expectLater(
            fixture.mutateFile(
              untrustedFileSelection('tracked.txt'),
              staged: staged,
            ),
            throwsA(hasErrorCode(['unsupported_target'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    for (final mutation in [
      'working recreation',
      'empty recreation',
      'working directory',
      'dangling symlink',
      'symlink parent',
      'file ancestor',
      'index changed',
      'unrelated index',
      'index metadata',
      'HEAD commit',
      'branch switch',
      'detached HEAD',
      'Session',
      'Environment',
      'source scope',
      'configuration',
      'attributes',
      'conflict',
      'nested repository',
      'parent metadata',
      if (!staged) ...['index mode', 'index flag'],
    ]) {
      test('deletion ${reviewVerb(staged)} rejects stale $mutation', () async {
        const path = 'parent/deleted.txt';
        await fixture.deleteTracked(path: path, staged: staged);
        final selection = selectFileFrom(
          await fixture.changed(path: path, staged: staged),
        );
        switch (mutation) {
          case 'working recreation':
          case 'empty recreation':
            await fixture.write(
              path,
              mutation == 'empty recreation' ? '' : 'recreated\n',
            );
          case 'working directory':
            await fixture.write('$path/child.txt', 'replacement\n');
          case 'dangling symlink':
            await Link(
              '${fixture.repository.path}/$path',
            ).create('missing-target');
          case 'symlink parent':
            await Directory(
              '${fixture.repository.path}/parent',
            ).rename('${fixture.repository.path}/real-parent');
            await Link(
              '${fixture.repository.path}/parent',
            ).create('real-parent');
          case 'file ancestor':
            await Directory('${fixture.repository.path}/parent').delete();
            await fixture.write('parent', 'obstruction\n');
          case 'index changed':
            if (staged) {
              final oid = (await fixture.git([
                'rev-parse',
                'HEAD:$path',
              ])).trim();
              await fixture.git([
                'update-index',
                '--add',
                '--cacheinfo',
                '100644,$oid,$path',
              ]);
            } else {
              await fixture.git(['update-index', '--force-remove', '--', path]);
            }
          case 'unrelated index':
            await fixture.write('other.txt', 'external staged\n');
            await fixture.git(['add', '--', 'other.txt']);
          case 'index metadata':
            final oid = (await fixture.git(['rev-parse', ':other.txt'])).trim();
            await fixture.git([
              'update-index',
              '--cacheinfo',
              '100644,$oid,other.txt',
            ]);
          case 'index mode':
            final oid = (await fixture.git(['rev-parse', ':$path'])).trim();
            await fixture.git([
              'update-index',
              '--cacheinfo',
              '100755,$oid,$path',
            ]);
          case 'index flag':
            await fixture.git([
              'update-index',
              '--assume-unchanged',
              '--',
              path,
            ]);
          case 'HEAD commit':
            final old = (await fixture.git(['rev-parse', 'HEAD'])).trim();
            final tree = (await fixture.git([
              'rev-parse',
              'HEAD^{tree}',
            ])).trim();
            final head = (await fixture.git([
              'commit-tree',
              tree,
              '-p',
              old,
              '-m',
              'External HEAD',
            ])).trim();
            await fixture.git(['update-ref', 'HEAD', head, old]);
          case 'branch switch':
            await fixture.git([
              'symbolic-ref',
              'HEAD',
              'refs/heads/other-branch',
            ]);
            final old = (await fixture.git([
              'rev-parse',
              'refs/heads/main',
            ])).trim();
            await fixture.git(['update-ref', 'HEAD', old]);
          case 'detached HEAD':
            final old = (await fixture.git(['rev-parse', 'HEAD'])).trim();
            await fixture.git(['update-ref', '--no-deref', 'HEAD', old]);
          case 'Session':
            fixture.processes.sessionId = 'other-session';
          case 'Environment':
            fixture.processes.environmentId = 'other-environment';
          case 'source scope':
            fixture.processes.root = Directory(
              '${fixture.repository.path}/parent',
            );
          case 'configuration':
            await fixture.git(['config', 'core.filemode', 'false']);
          case 'attributes':
            await fixture.write('.git/info/attributes', '$path -text\n');
          case 'conflict':
            await fixture.makeConflict(path: path);
          case 'nested repository':
            await fixture.git([
              '-C',
              '${fixture.repository.path}/parent',
              'init',
            ]);
          case 'parent metadata':
            await fixture.write('parent/another.txt', 'new sibling\n');
        }
        final before = await fixture.state();
        fixture.processes.requests.clear();
        await expectLater(
          fixture.mutateFile(selection, staged: staged),
          throwsA(hasErrorCode(['unsupported_target', 'stale_selection'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
        if (mutation == 'Session' || mutation == 'Environment') {
          final fresh = selectFileFrom(
            await fixture.changed(path: path, staged: staged),
          );
          expect(fresh.expectedRevision, isNot(selection.expectedRevision));
          fixture.processes.requests.clear();
          await fixture.mutateFile(fresh, staged: staged);
          await fixture.expectIndexPresence(
            before,
            path,
            staged ? 'HEAD A\n' : null,
          );
          checkedApplyPatch(fixture, staged: staged);
        }
      });
    }

    for (final failure in [
      'nonzero',
      'permission denied',
      'stderr',
      'empty output',
      'truncated output',
      'wrong path',
      'wrong type',
      'unavailable with success',
      'absent with failure',
      'transport loss',
    ]) {
      test(
        'deletion ${reviewVerb(staged)} absence $failure fails closed in snapshot and mutation',
        () async {
          await fixture.deleteTracked(
            path: 'parent/deleted.txt',
            staged: staged,
          );
          final selection = selectFileFrom(
            await fixture.changed(path: 'parent/deleted.txt', staged: staged),
          );
          final before = await fixture.state();
          var probes = 0;
          fixture.processes.requests.clear();
          fixture.processes.intercept = (request, run) async {
            if (!request.arguments.contains('adele-review-absence')) {
              return run(request);
            }
            probes++;
            if (failure == 'transport loss') {
              throw const EnvironmentFailure(
                code: 'process_output_failed',
                message: 'Absence response lost.',
                details: {},
              );
            }
            final valid = await run(request);
            expect(valid.exitCode, 0);
            var bytes = base64Decode(valid.stdoutBase64);
            if (failure == 'empty output') bytes = Uint8List(0);
            if (failure == 'truncated output') {
              bytes = bytes.sublist(0, bytes.length - 1);
            }
            if (failure == 'wrong path') {
              bytes = Uint8List.fromList(
                utf8.encode(
                  utf8
                      .decode(bytes)
                      .replaceFirst(
                        'parent/deleted.txt\x00',
                        'parent/other.txt\x00',
                      ),
                ),
              );
            }
            if (failure == 'wrong type') {
              bytes = Uint8List.fromList(
                utf8.encode(
                  utf8
                      .decode(bytes)
                      .replaceFirst(RegExp(r'\x004[0-9a-f]{3} '), '\x0081a4 '),
                ),
              );
            }
            if (failure == 'unavailable with success') {
              bytes = Uint8List.fromList(utf8.encode('unavailable\x00'));
            }
            return EnvironmentBufferedProcessResult(
              exitCode: failure == 'nonzero' || failure == 'permission denied'
                  ? 2
                  : failure == 'absent with failure'
                  ? 1
                  : 0,
              stdoutBase64: base64Encode(bytes),
              stderrBase64:
                  failure == 'stderr' || failure == 'permission denied'
                  ? base64Encode(utf8.encode('stat: Permission denied\n'))
                  : '',
            );
          };
          await expectLater(
            fixture.snapshots.snapshotUncommitted(),
            throwsA(isA<ChangeSetFailure>()),
          );
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(hasErrorCode(['inspection_failed'])),
          );
          expect(probes, 2);
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    for (final boundary in ['after check', 'after apply']) {
      test(
        'deletion ${reviewVerb(staged)} absence inspection error $boundary is not absence',
        () async {
          await fixture.deleteTracked(staged: staged);
          final selection = selectFileFrom(
            await fixture.changed(staged: staged),
          );
          final before = await fixture.state();
          var failProbe = false;
          var failures = 0;
          fixture.processes.requests.clear();
          fixture.processes.intercept = (request, run) async {
            if (failProbe &&
                request.arguments.contains('adele-review-absence')) {
              failures++;
              return EnvironmentBufferedProcessResult(
                exitCode: 2,
                stdoutBase64: '',
                stderrBase64: base64Encode(
                  utf8.encode('stat: Input/output error\n'),
                ),
              );
            }
            final result = await run(request);
            if (boundary == 'after apply'
                ? isWrite(request)
                : request.arguments.contains('apply') &&
                      request.arguments.contains('--check')) {
              failProbe = true;
            }
            return result;
          };
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(
              hasErrorCode([
                boundary == 'after check'
                    ? 'inspection_failed'
                    : 'outcome_uncertain',
              ]),
            ),
          );
          expect(failures, 1);
          expect(
            fixture.processes.writes,
            hasLength(boundary == 'after check' ? 0 : 1),
          );
          if (boundary == 'after check') {
            await fixture.expectUnchanged(before);
          } else {
            await fixture.expectIndexPresence(
              before,
              'tracked.txt',
              staged ? 'HEAD A\n' : null,
            );
          }
        },
      );
    }

    for (final replacement in ['directory', 'symlink', 'file']) {
      test(
        'deletion ${reviewVerb(staged)} rejects changed missing-parent boundary $replacement',
        () async {
          const path = 'parent/deep/deleted.txt';
          await fixture.deleteTracked(path: path, staged: staged);
          await Directory(
            '${fixture.repository.path}/parent',
          ).delete(recursive: true);
          final selection = selectFileFrom(
            await fixture.changed(path: path, staged: staged),
          );
          if (replacement == 'directory') {
            await Directory(
              '${fixture.repository.path}/parent/deep',
            ).create(recursive: true);
          } else if (replacement == 'symlink') {
            await Link(
              '${fixture.repository.path}/parent',
            ).create('missing-elsewhere');
          } else {
            await fixture.write('parent', 'obstruction\n');
          }
          final before = await fixture.state();
          fixture.processes.requests.clear();
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(hasErrorCode(['unsupported_target', 'stale_selection'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    for (final (name, limits) in [
      ('process count', const GitPortableUnstagedLimits(processes: 1)),
      ('aggregate bytes', const GitPortableUnstagedLimits(totalBytes: 1)),
      ('stdout', const GitPortableUnstagedLimits(outputBytes: 8)),
      ('hunk lines', const GitPortableUnstagedLimits(lines: 1)),
      ('inventory', const GitPortableUnstagedLimits(inventoryEntries: 1)),
    ]) {
      test(
        'deletion ${reviewVerb(staged)} $name bound rejects before writing',
        () async {
          await fixture.deleteTracked(
            original: lines({0: 'deletion bound'}),
            staged: staged,
          );
          final selection = selectFileFrom(
            await fixture.changed(staged: staged),
          );
          final before = await fixture.state();
          await expectLater(
            fixture.mutateFile(selection, staged: staged, limits: limits),
            throwsA(hasErrorCode(['inspection_failed'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    for (final loss in [
      'failed check',
      'lock',
      'response lost',
      'process timeout',
      'revoked before check',
      'revoked after check',
      'revoked after apply',
    ]) {
      test(
        'deletion ${reviewVerb(staged)} $loss has truthful effect without retry',
        () async {
          await fixture.deleteTracked(staged: staged);
          final selection = selectFileFrom(
            await fixture.changed(staged: staged),
          );
          final before = await fixture.state();
          var revoked = false;
          var checks = 0;
          fixture.processes.requests.clear();
          fixture.processes.intercept = (request, run) async {
            final check =
                request.arguments.contains('apply') &&
                request.arguments.contains('--check');
            if (check) checks++;
            if (revoked || loss == 'revoked before check' && check) {
              throw const EnvironmentFailure(
                code: 'grant_revoked',
                message: 'Retired grant.',
                details: {},
              );
            }
            if (loss == 'failed check' && check) {
              return EnvironmentBufferedProcessResult(
                exitCode: 1,
                stdoutBase64: '',
                stderrBase64: base64Encode(
                  utf8.encode('error: patch does not apply\n'),
                ),
              );
            }
            if (loss == 'lock' && isWrite(request)) {
              await fixture.write('.git/index.lock', 'external lock owner\n');
            }
            final result = await run(request);
            if (loss == 'revoked after check' && check) revoked = true;
            if (isWrite(request) && loss != 'lock') {
              expect(result.exitCode, 0);
              revoked = true;
              if (loss == 'response lost' || loss == 'process timeout') {
                throw EnvironmentFailure(
                  code: loss == 'response lost'
                      ? 'process_output_failed'
                      : 'process_timeout',
                  message: 'Write acknowledgement lost.',
                  details: const {},
                );
              }
            }
            return result;
          };
          final prewrite =
              loss == 'failed check' ||
              loss == 'revoked before check' ||
              loss == 'revoked after check';
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(
              hasErrorCode([
                loss == 'lock'
                    ? 'mutation_failed'
                    : prewrite
                    ? 'inspection_failed'
                    : 'outcome_uncertain',
              ]),
            ),
          );
          expect(checks, 1);
          expect(fixture.processes.writes, hasLength(prewrite ? 0 : 1));
          if (prewrite || loss == 'lock') {
            await fixture.expectUnchanged(before);
            if (loss == 'lock') {
              expect(
                await File(
                  '${fixture.repository.path}/.git/index.lock',
                ).readAsString(),
                'external lock owner\n',
              );
            }
          } else {
            await fixture.expectIndexPresence(
              before,
              'tracked.txt',
              staged ? 'HEAD A\n' : null,
            );
          }
        },
      );
    }

    for (final boundary in ['after check', 'at write', 'after apply']) {
      for (final change in ['index', 'working recreation']) {
        test(
          'deletion ${reviewVerb(staged)} external $change $boundary never retries',
          () async {
            await fixture.deleteTracked(staged: staged);
            final selection = selectFileFrom(
              await fixture.changed(staged: staged),
            );
            ReviewState? external;
            Future<void> changeState() async {
              expect(external, isNull, reason: 'no retry');
              if (change == 'working recreation') {
                await fixture.write('tracked.txt', 'external recreation\n');
              } else if (boundary == 'after apply') {
                await fixture.write('other.txt', 'external staged\n');
                await fixture.git(['add', '--', 'other.txt']);
              } else if (staged) {
                final oid = (await fixture.git([
                  'rev-parse',
                  'HEAD:tracked.txt',
                ])).trim();
                await fixture.git([
                  'update-index',
                  '--add',
                  '--cacheinfo',
                  '100644,$oid,tracked.txt',
                ]);
              } else {
                await fixture.git([
                  'update-index',
                  '--force-remove',
                  '--',
                  'tracked.txt',
                ]);
              }
              external = await fixture.state();
            }

            fixture.processes.requests.clear();
            fixture.processes.intercept = (request, run) async {
              if (boundary == 'at write' && isWrite(request)) {
                await changeState();
              }
              final result = await run(request);
              if (boundary == 'after check' &&
                      request.arguments.contains('apply') &&
                      request.arguments.contains('--check') ||
                  boundary == 'after apply' && isWrite(request)) {
                await changeState();
              }
              return result;
            };
            await expectLater(
              fixture.mutateFile(selection, staged: staged),
              throwsA(
                hasErrorCode([
                  boundary == 'after check'
                      ? 'stale_selection'
                      : 'outcome_uncertain',
                ]),
              ),
            );
            expect(external, isNotNull);
            if (change == 'working recreation' && boundary == 'at write') {
              await fixture.expectIndexPresence(
                external!,
                'tracked.txt',
                staged ? 'HEAD A\n' : null,
              );
            } else {
              await fixture.expectUnchanged(external!);
            }
            expect(
              fixture.processes.writes,
              hasLength(boundary == 'after check' ? 0 : 1),
            );
          },
        );
      }
    }

    test(
      'deletion ${reviewVerb(staged)} concurrent duplicates have one effect',
      () async {
        await fixture.deleteTracked(staged: staged);
        final selection = selectFileFrom(await fixture.changed(staged: staged));
        final before = await fixture.state();
        fixture.processes.requests.clear();
        Future<Object?> invoke() async {
          try {
            await fixture.mutateFile(selection, staged: staged);
            return null;
          } on ReviewApprovalFailure catch (error) {
            return error;
          }
        }

        final outcomes = await Future.wait([invoke(), invoke()]);
        expect(outcomes.where((outcome) => outcome == null), hasLength(1));
        expect(
          outcomes.whereType<ReviewApprovalFailure>().single,
          hasErrorCode([
            'stale_selection',
            'unsupported_target',
            'mutation_failed',
            'inspection_failed',
            'outcome_uncertain',
          ]),
        );
        expect(fixture.processes.writes.length, inInclusiveRange(1, 2));
        await fixture.expectIndexPresence(
          before,
          'tracked.txt',
          staged ? 'HEAD A\n' : null,
        );
      },
    );
  }
}
