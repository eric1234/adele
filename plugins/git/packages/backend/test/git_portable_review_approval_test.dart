@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_environment/adele_environment.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart'
    show
        GitPortableReviewApprovalService,
        GitPortableUnstagedLimits,
        GitPortableUnstagedSnapshotService;
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
  });

  tearDown(() async {
    await fixture.close();
  });

  for (final format in ['sha1', 'sha256']) {
    for (final staged in [false, true]) {
      test(
        '${_direction(staged)} one of two distant hunks with $format objects',
        () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await _Fixture.create(format: format);
          }
          final both = _text({2: 'first edit', 35: 'last edit'});
          await fixture.write('tracked.txt', both);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          expect(file.hunks, hasLength(2));
          final before = await fixture.state();

          await fixture.mutate(_selection(file), staged: staged);

          final after = await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? _text({35: 'last edit'}) : _text({2: 'first edit'}),
          );
          if (!staged) {
            final beforeWorking =
                before.working['tracked.txt']! as (String, int, int);
            final afterWorking =
                after.working['tracked.txt']! as (String, int, int);
            print(
              'Review proof ($format): HEAD=${before.head.trim()} (unchanged); '
              'index[tracked.txt]=${before.oids['0:tracked.txt']} -> '
              '${after.oids['0:tracked.txt']}; working SHA256='
              '${beforeWorking.$1} -> ${afterWorking.$1}.',
            );
          }
          expect(fixture.processes.writes, hasLength(1));
          final layers = await fixture.snapshots.snapshotUncommitted();
          expect(layers.staged.files.single.hunks, hasLength(1));
          expect(layers.unstaged.files.single.hunks, hasLength(1));
          expect(layers.staged.files.single.reviewRevision, isNotNull);
          expect(layers.unstaged.files.single.reviewRevision, isNotNull);
        },
      );
    }
  }

  for (final staged in [false, true]) {
    test(
      '${_direction(staged)} isolates the second hunk after a line-count shift',
      () async {
        final firstOnly = _text().replaceFirst(
          'line 2\n',
          'first\nextra\nlines\n',
        );
        await fixture.write(
          'tracked.txt',
          firstOnly.replaceFirst('line 35\n', 'last edit\n'),
        );
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final file = await fixture.changed(staged: staged);
        expect(file.hunks, hasLength(2));
        final before = await fixture.state();

        await fixture.mutate(_selection(file, hunkIndex: 1), staged: staged);

        await fixture.expectIndexChange(
          before,
          'tracked.txt',
          staged ? firstOnly : _text({35: 'last edit'}),
        );
        expect(fixture.processes.writes, hasLength(1));
      },
    );

    test(
      '${_direction(staged)} preserves mixed layers in the same and other files',
      () async {
        await fixture.write('tracked.txt', _text({2: 'already staged'}));
        await fixture.write('other.txt', 'other staged\n');
        await fixture.git(['add', '--', 'tracked.txt', 'other.txt']);
        await fixture.write(
          'tracked.txt',
          _text({2: 'already staged', 35: 'working only'}),
        );
        await fixture.write('other.txt', 'other working\n');
        final file = await fixture.changed(staged: staged);
        final before = await fixture.state();

        await fixture.mutate(_selection(file), staged: staged);

        await fixture.expectIndexChange(
          before,
          'tracked.txt',
          staged ? _text() : _text({2: 'already staged', 35: 'working only'}),
        );
      },
    );

    test(
      '${_direction(staged)} retains cancelling HEAD index working layers',
      () async {
        await fixture.write('tracked.txt', _text({2: 'index only'}));
        await fixture.git(['add', '--', 'tracked.txt']);
        await fixture.write('tracked.txt', _text());
        final layers = await fixture.snapshots.snapshotUncommitted();
        expect(layers.staged.files.single.reviewRevision, isNotNull);
        expect(layers.unstaged.files.single.reviewRevision, isNotNull);
        final before = await fixture.state();

        await fixture.mutate(
          _selection((staged ? layers.staged : layers.unstaged).files.single),
          staged: staged,
        );

        await fixture.expectIndexChange(before, 'tracked.txt', _text());
        final after = await fixture.snapshots.snapshotUncommitted();
        expect(after.staged.files, isEmpty);
        expect(after.unstaged.files, isEmpty);
      },
    );

    for (final (name, original, modified) in [
      ('missing final newline', 'before\nlast before', 'after\nlast after'),
      ('final newline added', 'before', 'after\n'),
      ('final newline removed', 'before\n', 'after'),
      ('CRLF without conversion', 'before\r\nsame\r\n', 'after\r\nsame\r\n'),
      ('empty context line', 'before\n\nsame\ntail\n', 'after\n\nsame\ntail\n'),
      ('no context lines', 'before\n', 'after\n'),
      ('empty tracked contents', '', 'new contents\n'),
    ]) {
      test('${_direction(staged)} preserves $name exactly', () async {
        await fixture.write('tracked.txt', original);
        await fixture.commit();
        await fixture.write('tracked.txt', modified);
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final file = await fixture.changed(staged: staged);
        expect(file.hunks, hasLength(1));
        if (name == 'missing final newline') {
          expect(
            file.hunks.single.lines.where((line) => line.noNewline),
            hasLength(2),
          );
        }
        if (name == 'empty context line') {
          expect(
            file.hunks.single.lines.any(
              (line) => line.kind == 'context' && line.text.isEmpty,
            ),
            isTrue,
          );
        }
        final before = await fixture.state();

        await fixture.mutate(_selection(file), staged: staged);

        await fixture.expectIndexChange(
          before,
          'tracked.txt',
          staged ? original : modified,
        );
      });
    }

    for (final name in [
      'space name',
      '-leading-option',
      ':(glob)*[x]',
      '[literal]*?',
      r'back\slash',
      'quotes\'";\$(touch INJECTED)',
    ]) {
      test(
        '${_direction(staged)} scopes nested literal ${jsonEncode(name)} to the Environment',
        () async {
          await fixture.write('selected/project/$name', 'before\n');
          await fixture.write(
            'selected/project/unselected.txt',
            'unselected before\n',
          );
          await fixture.commit();
          await fixture.write('selected/project/$name', 'after\n');
          await fixture.write(
            'selected/project/unselected.txt',
            'unselected after\n',
          );
          await fixture.write('other.txt', 'outside selected scope\n');
          if (staged) await fixture.git(['add', '--all']);
          fixture.processes.root = Directory(
            '${fixture.repository.path}/selected/project',
          );
          final initial = await fixture.layer(staged: staged);
          expect(
            initial.files.map((file) => file.relativePath),
            [name, 'unselected.txt']..sort(),
          );
          final file = initial.files.singleWhere(
            (file) => file.relativePath == name,
          );
          final before = await fixture.state();

          await fixture.mutate(_selection(file), staged: staged);

          await fixture.expectIndexChange(
            before,
            'selected/project/$name',
            staged ? 'before\n' : 'after\n',
          );
          expect(
            await File('${fixture.processes.root.path}/INJECTED').exists(),
            isFalse,
          );
          expect(
            await File('${fixture.repository.path}/INJECTED').exists(),
            isFalse,
          );
        },
      );
    }

    for (final line in [0, 35]) {
      test(
        '${_direction(staged)} preserves UTF-8 BOM in ${line == 0 ? 'first-line' : 'distant'} hunk',
        () async {
          final original = '\ufeff${_text()}';
          final modified = '\ufeff${_text({line: 'selected edit'})}';
          await fixture.write('tracked.txt', original);
          await fixture.commit();
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          final before = await fixture.state();

          await fixture.mutate(_selection(file), staged: staged);

          await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? original : modified,
          );
        },
      );
    }

    test(
      '${_direction(staged)} offers no revision when an isolated hunk exceeds the byte limit',
      () async {
        final removable = 'y' * 80;
        final original = _text({35: removable});
        final modified = original
            .replaceFirst('line 2\n', 'line 2\n${'x' * 80}\n')
            .replaceFirst('$removable\n', '');
        expect(utf8.encode(modified).length, utf8.encode(original).length);
        await fixture.write('tracked.txt', original);
        await fixture.commit();
        await fixture.write('tracked.txt', modified);
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final limits = GitPortableUnstagedLimits(
          fileBytes: utf8.encode(original).length,
        );
        final before = await fixture.state();
        final source = fixture.snapshotsWith(limits);
        final file =
            (staged
                    ? (await source.snapshotUncommitted()).staged
                    : await source.snapshotUnstaged())
                .files
                .single;
        expect(file.contentStatus, 'text');
        expect(file.hunks, hasLength(2));
        expect(file.reviewRevision, isNull);

        await expectLater(
          fixture.mutate(
            _untrustedSelection('tracked.txt'),
            staged: staged,
            limits: limits,
          ),
          throwsA(_failureCode(['unsupported_target'])),
        );

        await fixture.expectUnchanged(before);
        expect(fixture.processes.writes, isEmpty);
      },
    );

    for (final name in ['tab\tname', 'line\nname']) {
      test(
        '${_direction(staged)} conservatively rejects control-character paths',
        () async {
          await fixture.write(name, 'before\n');
          await fixture.commit();
          await fixture.write(name, 'after\n');
          if (staged) await fixture.git(['add', '--', name]);
          final file = await fixture.changed(path: name, staged: staged);
          expect(file.reviewRevision, isNull);
          final before = await fixture.state();
          await expectLater(
            fixture.mutate(_untrustedSelection(name), staged: staged),
            throwsA(_failureCode(['unsupported_target', 'invalid_selection'])),
          );
          await fixture.expectUnchanged(before);
          expect(fixture.processes.writes, isEmpty);
        },
      );
    }

    test(
      '${_direction(staged)} requires a fresh revision across Sessions sharing an Environment',
      () async {
        fixture.processes.sessionId = 'review-session-a';
        await fixture.write(
          'tracked.txt',
          _text({2: 'first edit', 35: 'last edit'}),
        );
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final fileA = await fixture.changed(staged: staged);
        expect(fileA.hunks, hasLength(2));
        final selectionA = _selection(fileA);
        final before = await fixture.state();
        expect(
          (await fixture.changed(staged: staged)).reviewRevision,
          selectionA.expectedRevision,
        );

        fixture.processes.sessionId = 'review-session-b';
        await expectLater(
          fixture.mutate(selectionA, staged: staged),
          throwsA(_failureCode(['stale_selection'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);

        final selectionB = _selection(await fixture.changed(staged: staged));
        expect(selectionB.expectedRevision, isNot(selectionA.expectedRevision));
        expect(
          (await fixture.changed(staged: staged)).reviewRevision,
          selectionB.expectedRevision,
        );
        await fixture.expectUnchanged(before);
        await fixture.mutate(selectionB, staged: staged);

        await fixture.expectIndexChange(
          before,
          'tracked.txt',
          staged ? _text({35: 'last edit'}) : _text({2: 'first edit'}),
        );
        expect(fixture.processes.writes, hasLength(1));
      },
    );

    for (final mutation in [
      'working edit',
      'working deletion',
      'manual git add',
      'unrelated index addition',
      'HEAD commit',
      'branch switch',
      'detached HEAD',
      'conflict',
      'working mode',
      'index mode',
      'Environment identity',
    ]) {
      test(
        '${_direction(staged)} rejects stale $mutation before a write',
        () async {
          await fixture.write('tracked.txt', _text({2: 'selected edit'}));
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final selection = _selection(await fixture.changed(staged: staged));
          switch (mutation) {
            case 'working edit':
              await fixture.write(
                'tracked.txt',
                _text({2: 'changed after display'}),
              );
            case 'working deletion':
              await File('${fixture.repository.path}/tracked.txt').delete();
            case 'manual git add':
              await fixture.write(
                'tracked.txt',
                _text({2: 'new index content'}),
              );
              await fixture.git(['add', '--', 'tracked.txt']);
            case 'unrelated index addition':
              await fixture.write('newly-indexed', 'external addition\n');
              await fixture.git(['add', '--', 'newly-indexed']);
            case 'HEAD commit':
              final oldHead = (await fixture.git(['rev-parse', 'HEAD'])).trim();
              final tree = (await fixture.git([
                'rev-parse',
                'HEAD^{tree}',
              ])).trim();
              final newHead = (await fixture.git([
                'commit-tree',
                tree,
                '-p',
                oldHead,
                '-m',
                'External HEAD update',
              ])).trim();
              await fixture.git(['update-ref', 'HEAD', newHead, oldHead]);
            case 'branch switch':
              await fixture.git(['checkout', '-b', 'other-branch']);
            case 'detached HEAD':
              await fixture.git(['checkout', '--detach']);
            case 'conflict':
              await fixture.makeConflict();
            case 'working mode':
              await _command('/usr/bin/chmod', [
                '755',
                '${fixture.repository.path}/tracked.txt',
              ]);
            case 'index mode':
              await fixture.git([
                'update-index',
                '--chmod=+x',
                '--',
                'tracked.txt',
              ]);
            case 'Environment identity':
              fixture.processes.environmentId = 'different-environment';
          }
          final before = await fixture.state();

          await expectLater(
            fixture.mutate(selection, staged: staged),
            throwsA(_failureCode(['stale_selection', 'unsupported_target'])),
          );

          await fixture.expectUnchanged(before);
          expect(fixture.processes.writes, isEmpty);
        },
      );
    }

    test('${_direction(staged)} cannot reuse a consumed selection', () async {
      await fixture.write('tracked.txt', _text({2: 'selected edit'}));
      if (staged) await fixture.git(['add', '--', 'tracked.txt']);
      final selection = _selection(await fixture.changed(staged: staged));
      await fixture.mutate(selection, staged: staged);
      final before = await fixture.state();
      fixture.processes.requests.clear();

      await expectLater(
        fixture.mutate(selection, staged: staged),
        throwsA(_failureCode(['stale_selection', 'unsupported_target'])),
      );

      await fixture.expectUnchanged(before);
      expect(fixture.processes.writes, isEmpty);
    });

    test(
      '${_direction(staged)} rejects an unavailable hunk without mutation',
      () async {
        await fixture.write('tracked.txt', _text({2: 'selected edit'}));
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final file = await fixture.changed(staged: staged);
        final before = await fixture.state();

        await expectLater(
          fixture.mutate(_selection(file, hunkIndex: 8191), staged: staged),
          throwsA(_failureCode(['hunk_unavailable'])),
        );

        await fixture.expectUnchanged(before);
        expect(fixture.processes.writes, isEmpty);
      },
    );

    for (final kind in [
      'addition',
      'deletion',
      'binary',
      'invalid UTF-8',
      'oversized',
      'mode change',
      'skip-worktree',
      'assume-unchanged',
      'filter attribute',
      'conversion attribute',
      'conflict',
    ]) {
      test('${_direction(staged)} offers no revision for $kind', () async {
        var path = 'tracked.txt';
        const small = GitPortableUnstagedLimits(fileBytes: 64);
        final limits = kind == 'oversized'
            ? small
            : const GitPortableUnstagedLimits();
        switch (kind) {
          case 'addition':
            path = 'new.txt';
            await fixture.write(path, 'new file\n');
          case 'deletion':
            await File('${fixture.repository.path}/$path').delete();
          case 'binary':
            await File(
              '${fixture.repository.path}/$path',
            ).writeAsBytes([1, 0, 2]);
          case 'invalid UTF-8':
            await File(
              '${fixture.repository.path}/$path',
            ).writeAsBytes([255, 254, 10]);
          default:
            await fixture.write(path, _text({2: 'selected edit'}));
        }
        if (kind == 'mode change') {
          await _command('/usr/bin/chmod', [
            '755',
            '${fixture.repository.path}/$path',
          ]);
        }
        if (staged) await fixture.git(['add', '--all']);
        switch (kind) {
          case 'skip-worktree':
          case 'assume-unchanged':
            await fixture.git(['update-index', '--$kind', '--', path]);
          case 'filter attribute':
            await fixture.write(
              '.git/info/attributes',
              '$path filter=custom\n',
            );
          case 'conversion attribute':
            await fixture.write(
              '.git/info/attributes',
              '$path text eol=crlf\n',
            );
          case 'conflict':
            await fixture.makeConflict();
        }
        final before = await fixture.state();
        final snapshot = await fixture
            .snapshotsWith(limits)
            .snapshotUncommitted();
        final files = kind == 'conflict'
            ? snapshot.conflicts
            : (staged ? snapshot.staged : snapshot.unstaged).files;
        expect(
          files.singleWhere((file) => file.relativePath == path).reviewRevision,
          isNull,
        );

        await expectLater(
          fixture.mutate(
            _untrustedSelection(path),
            staged: staged,
            limits: limits,
          ),
          throwsA(_failureCode(['unsupported_target', 'stale_selection'])),
        );

        await fixture.expectUnchanged(before);
        expect(fixture.processes.writes, isEmpty);
      });
    }

    test(
      '${_direction(staged)} reports a real index.lock failure without retry',
      () async {
        await fixture.write('tracked.txt', _text({2: 'selected edit'}));
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final selection = _selection(await fixture.changed(staged: staged));
        final before = await fixture.state();
        final lock = File('${fixture.repository.path}/.git/index.lock');
        fixture.processes.intercept = (request, run) async {
          if (_isWrite(request)) {
            await lock.writeAsString('external lock owner\n');
          }
          return run(request);
        };

        await expectLater(
          fixture.mutate(selection, staged: staged),
          throwsA(_failureCode(['mutation_failed'])),
        );

        expect(fixture.processes.writes, hasLength(1));
        expect(await lock.readAsString(), 'external lock owner\n');
        await fixture.expectUnchanged(before);
      },
    );

    for (final loss in ['response lost', 'process timeout']) {
      test(
        '${_direction(staged)} reports $loss after apply as outcome_uncertain',
        () async {
          final modified = _text({2: 'selected edit', 35: 'other hunk'});
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final selection = _selection(await fixture.changed(staged: staged));
          final before = await fixture.state();
          fixture.processes.intercept = (request, run) async {
            final result = await run(request);
            if (_isWrite(request)) {
              expect(result.exitCode, 0);
              throw EnvironmentFailure(
                code: loss == 'response lost'
                    ? 'process_output_failed'
                    : 'process_timeout',
                message:
                    'The process applied the patch but its response was lost.',
                details: const {},
              );
            }
            return result;
          };

          await expectLater(
            fixture.mutate(selection, staged: staged),
            throwsA(_failureCode(['outcome_uncertain'])),
          );

          expect(fixture.processes.writes, hasLength(1));
          await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? _text({35: 'other hunk'}) : _text({2: 'selected edit'}),
          );
        },
      );
    }
  }

  test('layer revisions cannot be exchanged on a mixed file', () async {
    await fixture.write('tracked.txt', _text({2: 'staged'}));
    await fixture.git(['add', '--', 'tracked.txt']);
    await fixture.write('tracked.txt', _text({2: 'staged', 35: 'working'}));
    final layers = await fixture.snapshots.snapshotUncommitted();
    final before = await fixture.state();
    await expectLater(
      fixture.mutate(_selection(layers.staged.files.single)),
      throwsA(_failureCode(['stale_selection'])),
    );
    await expectLater(
      fixture.mutate(_selection(layers.unstaged.files.single), staged: true),
      throwsA(_failureCode(['stale_selection'])),
    );
    await fixture.expectUnchanged(before);
    expect(fixture.processes.writes, isEmpty);
  });

  test(
    'approve does not charge an unrelated staged hunk to the selected layer line budget',
    () async {
      await fixture.write('tracked.txt', _text({2: 'staged'}));
      await fixture.git(['add', '--', 'tracked.txt']);
      final modified = _text({2: 'staged', 35: 'working'});
      await fixture.write('tracked.txt', modified);
      const limits = GitPortableUnstagedLimits(lines: 10);
      final source = fixture.snapshotsWith(limits);
      final selection = _selection(
        (await source.snapshotUnstaged()).files.single,
      );
      await expectLater(
        source.snapshotUncommitted(),
        throwsA(
          isA<ChangeSetFailure>().having(
            (failure) => failure.code,
            'code',
            'snapshot_too_large',
          ),
        ),
      );
      final before = await fixture.state();

      await fixture.mutate(selection, limits: limits);

      await fixture.expectIndexChange(before, 'tracked.txt', modified);
    },
  );

  for (final failedWrite in [false, true]) {
    test(
      'metadata-only index change ${failedWrite ? 'during a failed write is uncertain' : 'after --check is stale before writing'}',
      () async {
        await fixture.write('tracked.txt', _text({2: 'selected edit'}));
        final selection = _selection(await fixture.changed());
        final original = await fixture.state();
        _State? externallyChanged;
        fixture.processes.intercept = (request, run) async {
          final atBoundary = failedWrite
              ? _isWrite(request)
              : request.arguments.contains('apply') &&
                    request.arguments.contains('--check');
          if (!atBoundary) return run(request);
          expect(externallyChanged, isNull, reason: 'no automatic retry');
          final checked = failedWrite ? null : await run(request);
          await fixture.git([
            'update-index',
            '--cacheinfo',
            '100644,${original.oids['0:tracked.txt']},tracked.txt',
          ]);
          if (failedWrite) {
            await fixture.write('.git/index.lock', 'external lock owner\n');
          }
          externallyChanged = await fixture.state();
          expect(externallyChanged!.listing, original.listing);
          expect(
            externallyChanged!.indexBytes,
            isNot(equals(original.indexBytes)),
            reason: 'same mode and OID, but cache metadata really changed',
          );
          return checked ?? await run(request);
        };

        await expectLater(
          fixture.mutate(selection),
          throwsA(
            _failureCode([
              failedWrite ? 'outcome_uncertain' : 'stale_selection',
            ]),
          ),
        );

        expect(externallyChanged, isNotNull);
        await fixture.expectUnchanged(externallyChanged!);
        expect(fixture.processes.writes, hasLength(failedWrite ? 1 : 0));
      },
    );
  }

  test(
    'manual git add at the write boundary is not overwritten or retried',
    () async {
      final modified = _text({2: 'selected edit', 35: 'manual addition'});
      await fixture.write('tracked.txt', modified);
      final selection = _selection(await fixture.changed());
      _State? externallyStaged;
      fixture.processes.intercept = (request, run) async {
        if (_isWrite(request)) {
          await fixture.git(['add', '--', 'tracked.txt']);
          externallyStaged = await fixture.state();
        }
        return run(request);
      };

      await expectLater(
        fixture.mutate(selection),
        throwsA(_failureCode(['outcome_uncertain'])),
      );

      expect(externallyStaged, isNotNull);
      await fixture.expectUnchanged(externallyStaged!);
      expect(fixture.processes.writes, hasLength(1));
    },
  );

  test(
    'a distant manual add accepted by Git is detected as an uncertain postimage',
    () async {
      final modified = _text({2: 'selected edit', 35: 'external edit'});
      await fixture.write('tracked.txt', modified);
      final selection = _selection(await fixture.changed());
      _State? externallyStaged;
      fixture.processes.intercept = (request, run) async {
        if (_isWrite(request)) {
          await fixture.write('tracked.txt', _text({35: 'external edit'}));
          await fixture.git(['add', '--', 'tracked.txt']);
          await fixture.write('tracked.txt', modified);
          externallyStaged = await fixture.state();
          final result = await run(request);
          expect(
            result.exitCode,
            0,
            reason: 'Git apply is not an old-OID compare-and-swap',
          );
          return result;
        }
        return run(request);
      };

      await expectLater(
        fixture.mutate(selection),
        throwsA(_failureCode(['outcome_uncertain'])),
      );

      expect(externallyStaged, isNotNull);
      await fixture.expectIndexChange(
        externallyStaged!,
        'tracked.txt',
        modified,
      );
      expect(fixture.processes.writes, hasLength(1));
    },
  );

  test(
    'concurrent duplicate selections cannot both succeed or stage another hunk',
    () async {
      await fixture.write(
        'tracked.txt',
        _text({2: 'selected edit', 35: 'not selected'}),
      );
      final selection = _selection(await fixture.changed());
      final before = await fixture.state();
      final service = GitPortableReviewApprovalService(
        processes: fixture.processes,
      );
      Future<Object?> invoke() async {
        try {
          await service.approveHunk(selection);
          return null;
        } on ReviewApprovalFailure catch (error) {
          return error;
        }
      }

      final outcomes = await Future.wait([invoke(), invoke()]);

      expect(outcomes.where((outcome) => outcome == null), hasLength(1));
      expect(
        outcomes.whereType<ReviewApprovalFailure>().single,
        _failureCode([
          'stale_selection',
          'unsupported_target',
          'mutation_failed',
          'inspection_failed',
          'outcome_uncertain',
        ]),
      );
      expect(fixture.processes.writes.length, inInclusiveRange(1, 2));
      await fixture.expectIndexChange(
        before,
        'tracked.txt',
        _text({2: 'selected edit'}),
      );
    },
  );

  for (final failure in [
    'nonzero inspection',
    'malformed inventory',
    'transport loss',
  ]) {
    test('$failure fails before writing and preserves exact state', () async {
      await fixture.write('tracked.txt', _text({2: 'selected edit'}));
      final selection = _selection(await fixture.changed());
      final before = await fixture.state();
      var intercepted = false;
      fixture.processes.intercept = (request, run) async {
        if (!intercepted && request.arguments.contains('ls-files')) {
          intercepted = true;
          if (failure == 'transport loss') {
            throw const EnvironmentFailure(
              code: 'process_output_failed',
              message: 'Injected prewrite transport loss.',
              details: {},
            );
          }
          return EnvironmentBufferedProcessResult(
            exitCode: failure == 'nonzero inspection' ? 128 : 0,
            stdoutBase64: base64Encode(utf8.encode('not an index record\x00')),
            stderrBase64: '',
          );
        }
        return run(request);
      };

      await expectLater(
        fixture.mutate(selection),
        throwsA(_failureCode(['inspection_failed'])),
      );

      expect(intercepted, isTrue);
      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    });
  }

  for (final (name, limits) in [
    ('process count', const GitPortableUnstagedLimits(processes: 1)),
    ('aggregate bytes', const GitPortableUnstagedLimits(totalBytes: 1)),
  ]) {
    test('$name exhaustion fails before writing', () async {
      await fixture.write('tracked.txt', _text({2: 'selected edit'}));
      final selection = _selection(await fixture.changed());
      final before = await fixture.state();

      await expectLater(
        fixture.mutate(selection, limits: limits),
        throwsA(_failureCode(['inspection_failed'])),
      );

      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    });
  }

  test(
    'a prewrite deadline fences late transport completion and later commands',
    () async {
      await fixture.write('tracked.txt', _text({2: 'selected edit'}));
      final selection = _selection(await fixture.changed());
      final before = await fixture.state();
      final held = Completer<EnvironmentBufferedProcessResult>();
      fixture.processes.requests.clear();
      fixture.processes.intercept = (_, _) => held.future;

      await expectLater(
        fixture
            .mutate(
              selection,
              limits: const GitPortableUnstagedLimits(
                operationTimeout: Duration(milliseconds: 20),
              ),
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(_failureCode(['operation_timeout'])),
      );

      expect(fixture.processes.requests, hasLength(1));
      held.complete(
        EnvironmentBufferedProcessResult(
          exitCode: 0,
          stdoutBase64: '',
          stderrBase64: '',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.processes.requests, hasLength(1));
      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    },
  );

  test(
    'whole-operation deadline after a real apply is uncertain and never retries',
    () async {
      await fixture.write('tracked.txt', _text({2: 'selected edit'}));
      final selection = _selection(await fixture.changed());
      final before = await fixture.state();
      final held = Completer<EnvironmentBufferedProcessResult>();
      EnvironmentBufferedProcessResult? applied;
      fixture.processes.intercept = (request, run) async {
        final result = await run(request);
        if (_isWrite(request)) {
          expect(result.exitCode, 0);
          applied = result;
          return held.future;
        }
        return result;
      };

      await expectLater(
        fixture
            .mutate(
              selection,
              limits: const GitPortableUnstagedLimits(
                operationTimeout: Duration(seconds: 3),
              ),
            )
            .timeout(const Duration(seconds: 5)),
        throwsA(_failureCode(['outcome_uncertain'])),
      );

      expect(applied, isNotNull);
      final count = fixture.processes.requests.length;
      held.complete(applied!);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.processes.requests, hasLength(count));
      expect(fixture.processes.writes, hasLength(1));
      await fixture.expectIndexChange(
        before,
        'tracked.txt',
        _text({2: 'selected edit'}),
      );
    },
  );
}

String _direction(bool staged) => staged ? 'unapprove' : 'approve';

String _text([Map<int, String> replacements = const {}]) =>
    '${List.generate(40, (index) => replacements[index] ?? 'line $index').join('\n')}\n';

ReviewHunkSelection _selection(ChangedFile file, {int hunkIndex = 0}) {
  expect(
    file.reviewRevision,
    isNotNull,
    reason: '${file.relativePath} must be actionable',
  );
  return ReviewHunkSelection(
    relativePath: file.relativePath,
    hunkIndex: hunkIndex,
    expectedRevision: file.reviewRevision!,
  );
}

ReviewHunkSelection _untrustedSelection(String path) => ReviewHunkSelection(
  relativePath: path,
  hunkIndex: 0,
  expectedRevision: 'display-only-entry-has-no-review-revision',
);

Matcher _failureCode(List<String> codes) => isA<ReviewApprovalFailure>().having(
  (error) => error.code,
  'code',
  isIn(codes),
);

bool _isWrite(EnvironmentBufferedProcessRequest request) =>
    request.arguments.contains('apply') &&
    request.arguments.contains('--cached') &&
    !request.arguments.contains('--check');

final class _Fixture {
  _Fixture(this.container, this.repository, this.processes, this.format);

  final Directory container;
  final Directory repository;
  final _Processes processes;
  final String format;

  static Future<_Fixture> create({String format = 'sha1'}) async {
    final container = await Directory.systemTemp.createTemp(
      'adele-review-approval-',
    );
    final repository = await Directory('${container.path}/repository').create();
    final fixture = _Fixture(
      container,
      repository,
      _Processes(repository, container),
      format,
    );
    await fixture.git([
      'init',
      '--initial-branch=main',
      '--object-format=$format',
    ]);
    await fixture.git(['config', 'user.name', 'ADELE Test']);
    await fixture.git(['config', 'user.email', 'adele@example.invalid']);
    await fixture.git(['config', 'core.autocrlf', 'false']);
    await fixture.write('tracked.txt', _text());
    await fixture.write('other.txt', 'other original\n');
    await fixture.commit();
    return fixture;
  }

  GitPortableUnstagedSnapshotService get snapshots =>
      snapshotsWith(const GitPortableUnstagedLimits());

  GitPortableUnstagedSnapshotService snapshotsWith(
    GitPortableUnstagedLimits limits,
  ) => GitPortableUnstagedSnapshotService(processes: processes, limits: limits);

  Future<ChangeSetSnapshot> layer({bool staged = false}) async => staged
      ? (await snapshots.snapshotUncommitted()).staged
      : await snapshots.snapshotUnstaged();

  Future<ChangedFile> changed({
    String path = 'tracked.txt',
    bool staged = false,
  }) async => (await layer(
    staged: staged,
  )).files.singleWhere((file) => file.relativePath == path);

  Future<void> mutate(
    ReviewHunkSelection selection, {
    bool staged = false,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) {
    final service = GitPortableReviewApprovalService(
      processes: processes,
      limits: limits,
    );
    return staged
        ? service.unapproveHunk(selection)
        : service.approveHunk(selection);
  }

  Future<void> write(String path, String text) async {
    final file = File('${repository.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<String> git(List<String> arguments, {String input = ''}) async =>
      utf8.decode(await gitBytes(arguments, input: input));

  Future<List<int>> gitBytes(
    List<String> arguments, {
    String input = '',
  }) async {
    final process = await Process.start(
      '/usr/bin/git',
      arguments,
      workingDirectory: repository.path,
      environment: {
        'PATH': '/usr/bin:/bin',
        'HOME': container.path,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_OPTIONAL_LOCKS': '0',
        'LC_ALL': 'C',
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    try {
      final result = await Future.wait<Object?>([
        _capture(process.stdout),
        _capture(process.stderr),
        process.exitCode,
        () async {
          process.stdin.add(utf8.encode(input));
          await process.stdin.close();
        }(),
      ], eagerError: true).timeout(const Duration(seconds: 10));
      expect(
        result[2],
        0,
        reason: 'git $arguments: ${utf8.decode(result[1]! as List<int>)}',
      );
      return result[0]! as List<int>;
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  Future<void> commit() async {
    await git(['add', '--all']);
    await git(['commit', '-m', 'Fixture']);
  }

  Future<void> makeConflict() async {
    final oid = (await git(['rev-parse', 'HEAD:tracked.txt'])).trim();
    await git(
      ['update-index', '--index-info'],
      input:
          '0 ${'0' * oid.length}\ttracked.txt\n'
          '100644 $oid 1\ttracked.txt\n'
          '100644 $oid 2\ttracked.txt\n'
          '100644 $oid 3\ttracked.txt\n',
    );
  }

  Future<_State> state() async {
    final indexBytes = await File(
      '${repository.path}/.git/index',
    ).readAsBytes();
    final listing = await git(['ls-files', '--stage', '-z']);
    final oids = <String, String>{};
    final blobs = <String, List<int>>{};
    for (final record
        in listing.split('\x00').where((record) => record.isNotEmpty)) {
      final match = RegExp(
        r'^([0-9]{6}) ([0-9a-f]+) ([0-3])\t(.*)$',
        dotAll: true,
      ).firstMatch(record)!;
      final key = '${match[3]}:${match[4]}';
      oids[key] = match[2]!;
      blobs[key] = await gitBytes(['cat-file', 'blob', match[2]!]);
    }
    final working = <String, Object>{};
    await for (final entity in repository.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = entity.path.substring(repository.path.length + 1);
      if (path == '.git' || path.startsWith('.git/')) continue;
      if (entity is File) {
        final stat = await entity.stat();
        working[path] = (
          sha256.convert(await entity.readAsBytes()).toString(),
          stat.size,
          stat.mode,
        );
      } else if (entity is Link) {
        working[path] = ('link', await entity.target());
      } else {
        working[path] = 'directory';
      }
    }
    return _State(
      indexBytes,
      listing,
      oids,
      blobs,
      working,
      await git(['rev-parse', 'HEAD']),
      await File('${repository.path}/.git/HEAD').readAsString(),
    );
  }

  Future<void> expectUnchanged(_State before) async {
    final after = await state();
    _expectWorkingAndHead(before, after);
    expect(
      after.indexBytes,
      before.indexBytes,
      reason: 'exact index file bytes',
    );
    expect(
      after.listing,
      before.listing,
      reason: 'all index modes, stages and OIDs',
    );
    expect(after.oids, before.oids);
    expect(after.blobs, before.blobs, reason: 'exact index blob bytes');
  }

  Future<_State> expectIndexChange(
    _State before,
    String path,
    String text,
  ) async {
    final after = await state();
    _expectWorkingAndHead(before, after);
    final bytes = utf8.encode(text);
    final expectedOid = (format == 'sha256' ? sha256 : sha1).convert([
      ...utf8.encode('blob ${bytes.length}\x00'),
      ...bytes,
    ]).toString();
    expect(after.indexBytes, isNot(equals(before.indexBytes)));
    expect(
      after.listing,
      before.listing.replaceFirst(
        '${before.oids['0:$path']} 0\t$path\x00',
        '$expectedOid 0\t$path\x00',
      ),
      reason:
          'only the selected index blob may change, not its mode or other entries',
    );
    expect(after.oids, {...before.oids, '0:$path': expectedOid});
    expect(after.blobs, {...before.blobs, '0:$path': bytes});
    return after;
  }

  Future<void> close() async {
    await processes.close();
    await container.delete(recursive: true);
  }
}

void _expectWorkingAndHead(_State before, _State after) {
  expect(
    after.working,
    before.working,
    reason: 'all working SHA256, sizes and modes are unchanged',
  );
  expect(after.head, before.head, reason: 'HEAD commit is unchanged');
  expect(
    after.reference,
    before.reference,
    reason: 'HEAD reference is unchanged',
  );
}

final class _State {
  const _State(
    this.indexBytes,
    this.listing,
    this.oids,
    this.blobs,
    this.working,
    this.head,
    this.reference,
  );

  final List<int> indexBytes;
  final String listing;
  final Map<String, String> oids;
  final Map<String, List<int>> blobs;
  final Map<String, Object> working;
  final String head;
  final String reference;
}

typedef _Run =
    Future<EnvironmentBufferedProcessResult> Function(
      EnvironmentBufferedProcessRequest,
    );
typedef _Intercept =
    Future<EnvironmentBufferedProcessResult> Function(
      EnvironmentBufferedProcessRequest,
      _Run,
    );

// Independent of the stock Worktree provider: all production I/O crosses this grant.
final class _Processes implements AuthorizedEnvironmentBufferedProcessService {
  _Processes(this.root, this.home);

  Directory root;
  final Directory home;
  String sessionId = 'review-session';
  String environmentId = 'selected-review-environment';
  final requests = <EnvironmentBufferedProcessRequest>[];
  final _active = <Process>{};
  _Intercept? intercept;

  Iterable<EnvironmentBufferedProcessRequest> get writes =>
      requests.where(_isWrite);

  @override
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async =>
      AuthorizedEnvironmentIdentity(
        sessionId: sessionId,
        environmentId: environmentId,
      );

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) {
    requests.add(request);
    expect(request.program, '/bin/sh');
    expect(request.relativeWorkingDirectory, isEmpty);
    expect(request.timeoutSeconds, inInclusiveRange(1, 10));
    return intercept?.call(request, _run) ?? _run(request);
  }

  Future<EnvironmentBufferedProcessResult> _run(
    EnvironmentBufferedProcessRequest request,
  ) async {
    final process = await Process.start(
      request.program,
      request.arguments,
      workingDirectory: root.path,
      environment: {
        'PATH': '/usr/bin:/bin',
        'HOME': home.path,
        'XDG_CONFIG_HOME': '${home.path}/config',
        'LC_ALL': 'C',
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
    _active.add(process);
    try {
      final result = await Future.wait<Object?>([
        _capture(process.stdout, limit: environmentBufferedProcessStdoutLimit),
        _capture(process.stderr, limit: environmentBufferedProcessStderrLimit),
        process.exitCode,
        () async {
          process.stdin.add(
            decodeEnvironmentProcessBytes(
              request.stdinBase64,
              maximumBytes: environmentBufferedProcessStdinLimit,
            ),
          );
          await process.stdin.close();
        }(),
      ], eagerError: true).timeout(Duration(seconds: request.timeoutSeconds));
      return EnvironmentBufferedProcessResult(
        exitCode: result[2]! as int,
        stdoutBase64: base64Encode(result[0]! as List<int>),
        stderrBase64: base64Encode(result[1]! as List<int>),
      );
    } on TimeoutException {
      throw const EnvironmentFailure(
        code: 'process_timeout',
        message: 'Fixture deadline expired.',
        details: {},
      );
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      _active.remove(process);
    }
  }

  Future<void> close() async {
    for (final process in _active.toList()) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
}

Future<List<int>> _capture(
  Stream<List<int>> stream, {
  int limit = 2 * 1024 * 1024,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw const EnvironmentFailure(
        code: 'process_output_overflow',
        message: 'Fixture output bound exceeded.',
        details: {},
      );
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<void> _command(String program, List<String> arguments) async {
  final result = await Process.run(program, arguments);
  expect(result.exitCode, 0, reason: '$program $arguments: ${result.stderr}');
}
