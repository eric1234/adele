@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_environment/adele_environment.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart'
    show
        GitPortableUnstagedLimits,
        GitPortableUnstagedSnapshotService,
        GitTaskComparisonAnchor;
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

  test('whole-layer empty snapshots have no action or mutation', () async {
    final layers = await fixture.snapshots.snapshotUncommitted();
    final before = await fixture.state();
    for (final staged in [false, true]) {
      final layer = staged ? layers.staged : layers.unstaged;
      expect(layer.files, isEmpty);
      expect(layer.layerReviewRevision, isNull);
      await expectLater(
        fixture.mutateLayer(untrustedLayerSelection(), staged: staged),
        throwsA(hasErrorCode(['stale_selection', 'unsupported_target'])),
      );
    }
    expect(fixture.processes.writes, isEmpty);
    await fixture.expectUnchanged(before);
  });

  test(
    'whole-layer revisions are stable across methods and distinct from file hunk and committed',
    () async {
      final baseline = (await fixture.git(['rev-parse', 'HEAD'])).trim();
      await fixture.layerChanges();
      await fixture.git(['add', '--all']);
      await fixture.write(
        'tracked.txt',
        lines({2: 'working C', 35: 'later C'}),
      );
      await fixture.write('other.txt', lines({2: 'other C', 35: 'later C'}));
      final source = GitPortableUnstagedSnapshotService(
        processes: fixture.processes,
        taskAnchor: GitTaskComparisonAnchor(
          baselineCommit: baseline,
          expectedBranchRef: 'refs/heads/main',
        ),
      );
      final unstaged = await source.snapshotUnstaged();
      final uncommitted = await source.snapshotUncommitted();
      final task = await source.snapshotTaskChanges();
      final before = await fixture.state();
      expect(task.committed.files, isNotEmpty);
      expect(task.committed.layerReviewRevision, isNull);
      expect(unstaged.layerReviewRevision, isNotNull);
      expect(uncommitted.staged.layerReviewRevision, isNotNull);
      expect(
        unstaged.layerReviewRevision,
        uncommitted.unstaged.layerReviewRevision,
      );
      expect(
        unstaged.layerReviewRevision,
        task.uncommitted.unstaged.layerReviewRevision,
      );
      expect(
        uncommitted.staged.layerReviewRevision,
        task.uncommitted.staged.layerReviewRevision,
      );
      expect(
        (await source.snapshotUnstaged()).layerReviewRevision,
        unstaged.layerReviewRevision,
      );
      expect(
        uncommitted.staged.layerReviewRevision,
        isNot(unstaged.layerReviewRevision),
      );
      for (final staged in [false, true]) {
        final layer = staged ? uncommitted.staged : unstaged;
        final other = staged ? unstaged : uncommitted.staged;
        for (final revision in [
          other.layerReviewRevision!,
          layer.files.first.fileReviewRevision!,
          layer.files.first.reviewRevision!,
        ]) {
          await expectLater(
            fixture.mutateLayer(
              ReviewLayerSelection(expectedRevision: revision),
              staged: staged,
            ),
            throwsA(hasErrorCode(['stale_selection'])),
          );
        }
        await expectLater(
          fixture.mutateFile(
            ReviewFileSelection(
              relativePath: layer.files.first.relativePath,
              expectedRevision: layer.layerReviewRevision!,
            ),
            staged: staged,
          ),
          throwsA(hasErrorCode(['stale_selection'])),
        );
      }
      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    },
  );

  test(
    'whole-layer reserves combined index growth rather than one insertion',
    () async {
      await fixture.write('selected/first.txt', 'first\n');
      await fixture.write('selected/second.txt', 'second\n');
      fixture.processes.root = Directory('${fixture.repository.path}/selected');
      const limits = GitPortableUnstagedLimits(inventoryEntries: 3);
      final before = await fixture.state();
      final layer = await fixture.snapshotsWith(limits).snapshotUnstaged();
      expect(layer.files, hasLength(2));
      expect(
        layer.files.every((file) => file.fileReviewRevision != null),
        isTrue,
      );
      expect(layer.layerReviewRevision, isNull);
      fixture.processes.requests.clear();
      await expectLater(
        fixture.mutateLayer(untrustedLayerSelection(), limits: limits),
        throwsA(hasErrorCode(['unsupported_target'])),
      );
      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    },
  );

  test('whole-layer reserves combined untracked stdout growth', () async {
    final prefix = List.generate(15, (index) => '$index${'p' * 238}').join('/');
    final paths = List.generate(20, (index) => '$prefix/file-$index');
    for (final path in paths) {
      await fixture.write(path, '');
    }
    await fixture.git(['add', '--', ...paths.take(2)]);
    const limits = GitPortableUnstagedLimits(outputBytes: 69 * 1024);
    final untracked = await fixture.gitBytes([
      'ls-files',
      '--others',
      '--exclude-standard',
      '-z',
    ]);
    expect(untracked.length, lessThan(limits.outputBytes));
    expect(
      untracked.length + utf8.encode('${paths[0]}\x00${paths[1]}\x00').length,
      greaterThan(limits.outputBytes),
    );
    final before = await fixture.state();
    final layers = await fixture.snapshotsWith(limits).snapshotUncommitted();
    expect(layers.staged.files, hasLength(2));
    expect(layers.unstaged.files, hasLength(18));
    expect(
      layers.staged.files.every((file) => file.fileReviewRevision != null),
      isTrue,
    );
    expect(layers.staged.layerReviewRevision, isNull);
    fixture.processes.requests.clear();
    await expectLater(
      fixture.mutateLayer(
        untrustedLayerSelection(),
        staged: true,
        limits: limits,
      ),
      throwsA(hasErrorCode(['unsupported_target'])),
    );
    expect(fixture.processes.writes, isEmpty);
    await fixture.expectUnchanged(before);
  });

  for (final staged in [false, true]) {
    for (final kind in [
      'binary',
      'invalid UTF-8',
      'oversized',
      'symlink',
      'submodule',
      'conflict',
      'path collision',
      'assume-unchanged',
      'skip-worktree',
      'intent-to-add',
      'mode change',
      'tab path',
      'newline path',
      'filter=hostile',
      'diff=hostile',
      '-diff',
      'text',
      'eol=crlf',
      'crlf',
      'working-tree-encoding=UTF-16',
      'ident',
      if (!staged) 'staged new further edits',
    ]) {
      test(
        'whole-layer ${reviewVerb(staged)} rejects every target when one is $kind',
        () async {
          final path = kind == 'tab path'
              ? 'bad\tname'
              : kind == 'newline path'
              ? 'bad\nname'
              : 'tracked.txt';
          await fixture.write(path, 'before\n');
          await fixture.write('other.txt', 'safe before\n');
          await fixture.commit();
          await fixture.write('other.txt', 'safe after\n');
          await fixture.write(
            path,
            kind == 'oversized' ? 'x' * 100 : 'after\n',
          );
          if (kind == 'binary' || kind == 'invalid UTF-8') {
            await File(
              '${fixture.repository.path}/$path',
            ).writeAsBytes(kind == 'binary' ? [1, 0, 2] : [255, 254, 10]);
          } else if (kind == 'symlink') {
            await File('${fixture.repository.path}/$path').delete();
            await Link('${fixture.repository.path}/$path').create('other.txt');
          } else if (kind == 'path collision') {
            await File('${fixture.repository.path}/$path').delete();
            await fixture.write('$path/child.txt', 'replacement\n');
          } else if (kind == 'mode change') {
            await runLocal('/usr/bin/chmod', [
              '755',
              '${fixture.repository.path}/$path',
            ]);
          }
          if (staged) await fixture.git(['add', '--all']);
          if (kind == 'submodule') {
            final oid = (await fixture.git(['rev-parse', 'HEAD'])).trim();
            await fixture.git([
              'update-index',
              '--cacheinfo',
              '160000,$oid,$path',
            ]);
          } else if (kind == 'conflict') {
            await fixture.makeConflict(path: path);
          } else if (kind == 'assume-unchanged' || kind == 'skip-worktree') {
            await fixture.git(['update-index', '--$kind', '--', path]);
          } else if (kind == 'intent-to-add') {
            await fixture.git(['update-index', '--force-remove', '--', path]);
            await fixture.git(['add', '--intent-to-add', '--', path]);
          } else if (kind == 'staged new further edits') {
            await fixture.write('new.txt', 'staged B\n');
            await fixture.git(['add', '--', 'new.txt']);
            await fixture.write('new.txt', 'working C\n');
          } else if ([
            'filter=hostile',
            'diff=hostile',
            '-diff',
            'text',
            'eol=crlf',
            'crlf',
            'working-tree-encoding=UTF-16',
            'ident',
          ].contains(kind)) {
            await fixture.write('.git/info/attributes', '$path $kind\n');
          }
          final limits = kind == 'oversized'
              ? const GitPortableUnstagedLimits(fileBytes: 64)
              : const GitPortableUnstagedLimits();
          final before = await fixture.state();
          final layers = await fixture
              .snapshotsWith(limits)
              .snapshotUncommitted();
          final layer = staged ? layers.staged : layers.unstaged;
          expect(
            layer.files
                .singleWhere((file) => file.relativePath == 'other.txt')
                .fileReviewRevision,
            isNotNull,
            reason: 'an eligible companion must not be silently selected alone',
          );
          expect(
            layer.files
                .singleWhere((file) => file.relativePath == 'other.txt')
                .reviewRevision,
            isNotNull,
          );
          expect(layer.layerReviewRevision, isNull);
          if (kind == 'conflict') {
            expect(layers.staged.layerReviewRevision, isNull);
            expect(layers.unstaged.layerReviewRevision, isNull);
          }
          if (!staged) {
            expect(
              (await fixture.snapshotsWith(limits).snapshotUnstaged())
                  .layerReviewRevision,
              isNull,
            );
          }
          fixture.processes.requests.clear();
          await expectLater(
            fixture.mutateLayer(
              untrustedLayerSelection(),
              staged: staged,
              limits: limits,
            ),
            throwsA(hasErrorCode(['unsupported_target'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    test(
      'whole-layer ${reviewVerb(staged)} aggregate stdin bound retains individual eligibility',
      () async {
        // Two-byte text separates the stdin bound from DTO's conservative
        // six-bytes-per-code-unit presentation allowance.
        final original = '${'\u00e9' * 70000}\n';
        final modified = '${'\u00f8' * 70000}\n';
        final paths = ['tracked.txt', 'other.txt', 'third.txt', 'fourth.txt'];
        for (final path in paths) {
          await fixture.write(path, original);
        }
        await fixture.commit();
        for (final path in paths) {
          await fixture.write(path, modified);
        }
        if (staged) await fixture.git(['add', '--all']);
        final layer = await fixture.layer(staged: staged);
        expect(layer.files, hasLength(4));
        expect(
          layer.files.every((file) => file.fileReviewRevision != null),
          isTrue,
        );
        expect(layer.layerReviewRevision, isNull);
        expect(
          utf8.encode(original + modified).length * paths.length,
          greaterThan(environmentBufferedProcessStdinLimit),
        );
        final before = await fixture.state();
        fixture.processes.requests.clear();
        final watch = Stopwatch()..start();
        await expectLater(
          fixture.mutateLayer(untrustedLayerSelection(), staged: staged),
          throwsA(hasErrorCode(['unsupported_target'])),
        );
        watch.stop();
        print(
          'Whole-layer ${reviewVerb(staged)} performance: rejected aggregate, ${fixture.processes.requests.length} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
        );
        expect(fixture.processes.requests.length, lessThan(250));
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
      },
    );

    for (final mutation in [
      'added file',
      'removed file',
      'deleted working file',
      'changed file',
      'working metadata',
      'index',
      'index metadata',
      'HEAD',
      'branch',
      'detached HEAD',
      'Session',
      'Environment',
      'attributes',
      'configuration',
    ]) {
      test(
        'whole-layer ${reviewVerb(staged)} rejects stale $mutation',
        () async {
          final changes = await fixture.layerChanges(staged: staged);
          final selection = selectLayerFrom(
            await fixture.layer(staged: staged),
          );
          switch (mutation) {
            case 'added file':
              await fixture.write('new.txt', 'new after display\n');
              if (staged) await fixture.git(['add', '--', 'new.txt']);
            case 'removed file':
              if (staged) {
                await fixture.git(['reset', 'HEAD', '--', 'other.txt']);
              } else {
                await fixture.write('other.txt', changes.head['other.txt']!);
              }
            case 'changed file':
              await fixture.write('other.txt', 'changed after display\n');
            case 'working metadata':
              await File(
                '${fixture.repository.path}/other.txt',
              ).setLastModified(DateTime.utc(2000));
            case 'deleted working file':
              await File('${fixture.repository.path}/other.txt').delete();
            case 'index':
              await fixture.write('other.txt', 'external index\n');
              await fixture.git(['add', '--', 'other.txt']);
            case 'index metadata':
              final oid = (await fixture.git([
                'rev-parse',
                ':other.txt',
              ])).trim();
              await fixture.git([
                'update-index',
                '--cacheinfo',
                '100644,$oid,other.txt',
              ]);
            case 'HEAD':
              final old = (await fixture.git(['rev-parse', 'HEAD'])).trim();
              final tree = (await fixture.git([
                'rev-parse',
                'HEAD^{tree}',
              ])).trim();
              final next = (await fixture.git([
                'commit-tree',
                tree,
                '-p',
                old,
                '-m',
                'External HEAD',
              ])).trim();
              await fixture.git(['update-ref', 'HEAD', next, old]);
            case 'branch':
              await fixture.git(['checkout', '-b', 'other-branch']);
            case 'detached HEAD':
              await fixture.git(['checkout', '--detach']);
            case 'Session':
              fixture.processes.sessionId = 'other-session';
            case 'Environment':
              fixture.processes.environmentId = 'other-environment';
            case 'attributes':
              await fixture.write('.git/info/attributes', 'other.txt -text\n');
            case 'configuration':
              await fixture.git(['config', 'core.filemode', 'false']);
          }
          final before = await fixture.state();
          fixture.processes.requests.clear();
          await expectLater(
            fixture.mutateLayer(selection, staged: staged),
            throwsA(hasErrorCode(['stale_selection', 'unsupported_target'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
          if (mutation == 'Session' || mutation == 'Environment') {
            final fresh = selectLayerFrom(await fixture.layer(staged: staged));
            expect(fresh.expectedRevision, isNot(selection.expectedRevision));
            fixture.processes.requests.clear();
            await fixture.mutateLayer(fresh, staged: staged);
            checkedApplyPatch(fixture, staged: staged);
            await fixture.expectIndexChanges(
              before,
              staged ? changes.head : changes.working,
            );
          }
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
        'whole-layer ${reviewVerb(staged)} $loss never retries or reports false success',
        () async {
          final changes = await fixture.layerChanges(
            staged: staged,
            mixed: true,
          );
          final selection = selectLayerFrom(
            await fixture.layer(staged: staged),
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
              await fixture.write('.git/index.lock', 'external owner\n');
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
            fixture.mutateLayer(selection, staged: staged),
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
                'external owner\n',
              );
            }
          } else {
            await fixture.expectIndexChanges(
              before,
              staged ? changes.head : changes.working,
            );
          }
        },
      );
    }

    for (final boundary in ['after check', 'at write', 'after apply']) {
      for (final target in ['index', 'working']) {
        test(
          'whole-layer ${reviewVerb(staged)} external $target $boundary is stale or uncertain',
          () async {
            final changes = await fixture.layerChanges(
              staged: staged,
              mixed: true,
            );
            final selection = selectLayerFrom(
              await fixture.layer(staged: staged),
            );
            ReviewState? external;
            Future<void> changeState() async {
              expect(external, isNull, reason: 'no retry');
              if (target == 'working') {
                await fixture.write('other.txt', 'external working\n');
              } else if (boundary == 'after apply') {
                await fixture.write('outside.txt', 'external index addition\n');
                await fixture.git(['add', '--', 'outside.txt']);
              } else {
                await fixture.write('other.txt', 'external index\n');
                await fixture.git(['add', '--', 'other.txt']);
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
              fixture.mutateLayer(selection, staged: staged),
              throwsA(
                hasErrorCode([
                  boundary == 'after check'
                      ? 'stale_selection'
                      : 'outcome_uncertain',
                ]),
              ),
            );
            expect(external, isNotNull);
            expect(
              fixture.processes.writes,
              hasLength(boundary == 'after check' ? 0 : 1),
            );
            if (target == 'working' && boundary == 'at write') {
              await fixture.expectIndexChanges(
                external!,
                staged ? changes.head : changes.working,
              );
            } else {
              await fixture.expectUnchanged(external!);
            }
          },
        );
      }
    }

    test(
      'whole-layer ${reviewVerb(staged)} concurrent duplicates have one complete effect',
      () async {
        final changes = await fixture.layerChanges(staged: staged, mixed: true);
        final selection = selectLayerFrom(await fixture.layer(staged: staged));
        final before = await fixture.state();
        fixture.processes.requests.clear();
        Future<Object?> invoke() async {
          try {
            await fixture.mutateLayer(selection, staged: staged);
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
        await fixture.expectIndexChanges(
          before,
          staged ? changes.head : changes.working,
        );
      },
    );

    for (final change in ['new untracked', 'previously clean tracked']) {
      test(
        'whole-layer ${reviewVerb(staged)} detects $change after check',
        () async {
          await fixture.write('clean.txt', 'clean HEAD\n');
          await fixture.layerChanges(staged: staged);
          final selection = selectLayerFrom(
            await fixture.layer(staged: staged),
          );
          ReviewState? external;
          fixture.processes.requests.clear();
          fixture.processes.intercept = (request, run) async {
            final result = await run(request);
            if (request.arguments.contains('apply') &&
                request.arguments.contains('--check')) {
              expect(external, isNull);
              await fixture.write(
                change == 'new untracked' ? 'late.txt' : 'clean.txt',
                'late change\n',
              );
              external = await fixture.state();
            }
            return result;
          };
          await expectLater(
            fixture.mutateLayer(selection, staged: staged),
            throwsA(hasErrorCode(['stale_selection'])),
          );
          expect(external, isNotNull);
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(external!);
        },
      );
    }

    for (final corruption in ['conflict-only', 'wrong mode', 'absent']) {
      test(
        'whole-layer ${reviewVerb(staged)} later selected $corruption after apply is uncertain',
        () async {
          final changes = await fixture.layerChanges(
            staged: staged,
            mixed: true,
          );
          final selection = selectLayerFrom(
            await fixture.layer(staged: staged),
          );
          final before = await fixture.state();
          ReviewState? external;
          fixture.processes.requests.clear();
          fixture.processes.intercept = (request, run) async {
            final result = await run(request);
            if (isWrite(request)) {
              expect(result.exitCode, 0);
              expect(external, isNull, reason: 'no retry or rollback');
              await fixture.expectIndexChanges(
                before,
                staged ? changes.head : changes.working,
              );
              if (corruption == 'conflict-only') {
                await fixture.makeConflict();
              } else if (corruption == 'wrong mode') {
                await fixture.git([
                  'update-index',
                  '--chmod=+x',
                  '--',
                  'tracked.txt',
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
            return result;
          };
          await expectLater(
            fixture.mutateLayer(selection, staged: staged),
            throwsA(hasErrorCode(['outcome_uncertain'])),
          );
          expect(external, isNotNull);
          expect(fixture.processes.writes, hasLength(1));
          await fixture.expectUnchanged(external!);
        },
      );
    }

    test(
      'whole-layer ${reviewVerb(staged)} reserves verification beyond a complete snapshot',
      () async {
        await fixture.layerChanges(staged: staged);
        fixture.processes.requests.clear();
        final selection = selectLayerFrom(await fixture.layer(staged: staged));
        final snapshotRequests = fixture.processes.requests.length;
        final limits = GitPortableUnstagedLimits(
          processes: snapshotRequests + 10,
        );
        final before = await fixture.state();
        final source = fixture.snapshotsWith(limits);
        final layer = staged
            ? (await source.snapshotUncommitted()).staged
            : await source.snapshotUnstaged();
        expect(
          layer.files.every((file) => file.fileReviewRevision != null),
          isTrue,
        );
        expect(layer.layerReviewRevision, isNull);
        fixture.processes.requests.clear();
        await expectLater(
          fixture.mutateLayer(selection, staged: staged, limits: limits),
          throwsA(hasErrorCode(['unsupported_target', 'inspection_failed'])),
        );
        expect(
          fixture.processes.requests.length,
          greaterThanOrEqualTo(snapshotRequests),
        );
        expect(
          fixture.processes.requests.length,
          lessThanOrEqualTo(limits.processes),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
      },
    );

    for (final (name, limits) in [
      ('process count', const GitPortableUnstagedLimits(processes: 1)),
      ('aggregate bytes', const GitPortableUnstagedLimits(totalBytes: 1)),
      ('stdout', const GitPortableUnstagedLimits(outputBytes: 8)),
      ('hunk lines', const GitPortableUnstagedLimits(lines: 1)),
      ('inventory', const GitPortableUnstagedLimits(inventoryEntries: 1)),
    ]) {
      test(
        'whole-layer ${reviewVerb(staged)} $name exhaustion rejects before writing',
        () async {
          await fixture.layerChanges(staged: staged);
          final selection = selectLayerFrom(
            await fixture.layer(staged: staged),
          );
          final before = await fixture.state();
          fixture.processes.requests.clear();
          await expectLater(
            fixture.mutateLayer(selection, staged: staged, limits: limits),
            throwsA(hasErrorCode(['inspection_failed'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    test(
      'whole-layer ${reviewVerb(staged)} file-count cap retains file actions',
      () async {
        await fixture.layerChanges(staged: staged, count: 17);
        final layer = await fixture.layer(staged: staged);
        expect(layer.files, hasLength(17));
        expect(
          layer.files.every((file) => file.fileReviewRevision != null),
          isTrue,
        );
        expect(layer.layerReviewRevision, isNull);
        final before = await fixture.state();
        fixture.processes.requests.clear();
        await expectLater(
          fixture.mutateLayer(untrustedLayerSelection(), staged: staged),
          throwsA(hasErrorCode(['unsupported_target'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
      },
    );
  }
}
