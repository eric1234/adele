@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_environment/adele_environment.dart';
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

  for (final format in ['sha1', 'sha256']) {
    for (final staged in [false, true]) {
      test(
        'file ${reviewVerb(staged)} atomically handles shifting partial layers ($format)',
        () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await TestRepo.create(format: format);
          }
          final original = List.generate(100, (i) => 'line $i\n').join();
          await fixture.write('tracked.txt', original);
          await fixture.commit();
          final partial = original.replaceFirst('line 2\n', 'already staged\n');
          final complete = partial
              .replaceFirst('line 20\n', 'first\nextra\nlines\n')
              .replaceFirst('line 50\nline 51\n', 'middle\n')
              .replaceFirst('line 80\n', 'last\nextra\n');
          await fixture.write('tracked.txt', staged ? complete : partial);
          await fixture.write('other.txt', 'other staged\n');
          await fixture.git(['add', '--all']);
          final working = staged ? '${complete}working only\n' : complete;
          await fixture.write('tracked.txt', working);
          await fixture.write('other.txt', 'other working\n');
          final file = await fixture.changed(staged: staged);
          expect(file.hunks, hasLength(staged ? 4 : 3));
          expect(file.hunks.last.newStart, isNot(file.hunks.last.oldStart));
          final before = await fixture.state();
          fixture.processes.requests.clear();

          await fixture.mutateFile(selectFileFrom(file), staged: staged);

          final after = await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? original : working,
          );
          final applies = fixture.processes.requests
              .where((r) => r.arguments.contains('apply'))
              .toList();
          expect(applies, hasLength(2));
          expect(applies.first.arguments, contains('--check'));
          expect(applies.last.arguments.contains('--check'), isFalse);
          expect(applies.first.stdinBase64, applies.last.stdinBase64);
          expect(applies.last.arguments.contains('--reverse'), staged);
          final patch = utf8.decode(base64Decode(applies.last.stdinBase64));
          for (final hunk in file.hunks) {
            expect(
              patch,
              contains(
                '@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@',
              ),
            );
          }
          expect(fixture.processes.writes, hasLength(1));
          print(
            'File ${reviewVerb(staged)} proof ($format): HEAD=${before.head.trim()} -> ${after.head.trim()}; '
            'index=${before.oids['0:tracked.txt']} -> ${after.oids['0:tracked.txt']}; '
            'working=${before.working['tracked.txt']} -> ${after.working['tracked.txt']}.',
          );
          final layers = await fixture.snapshots.snapshotUncommitted();
          expect(
            (staged ? layers.staged : layers.unstaged).files.where(
              (f) => f.relativePath == 'tracked.txt',
            ),
            isEmpty,
          );
          final confirmed = await fixture.state();
          fixture.processes.requests.clear();
          await expectLater(
            fixture.mutateFile(selectFileFrom(file), staged: staged),
            throwsA(hasErrorCode(['stale_selection'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(confirmed);
        },
      );

      for (final (name, original, modified) in [
        (
          'BOM CRLF blank no-final-newline',
          '\ufeffbefore\r\n\r\nlast',
          '\ufeffafter\r\n\r\nlast changed',
        ),
        ('empty old side', '', 'new contents\n'),
        ('empty new side', 'old contents\n', ''),
        ('final newline added', 'before', 'after\n'),
        ('final newline removed', 'before\n', 'after'),
      ]) {
        test('file ${reviewVerb(staged)} exact $name ($format)', () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await TestRepo.create(format: format);
          }
          await fixture.write('tracked.txt', original);
          await fixture.commit();
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          final before = await fixture.state();
          await fixture.mutateFile(selectFileFrom(file), staged: staged);
          await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? original : modified,
          );
          expect(fixture.processes.writes, hasLength(1));
        });
      }
    }
  }

  for (final kind in [
    'newly staged addition',
    'staged executable mode',
    'staged symlink replacement',
  ]) {
    test(
      'file approval excludes $kind with later working modifications',
      () async {
        const path = 'later.txt';
        if (kind == 'staged executable mode') {
          await fixture.write(path, 'before\n');
          await fixture.commit();
          await runLocal('/usr/bin/chmod', [
            '755',
            '${fixture.repository.path}/$path',
          ]);
        } else if (kind == 'staged symlink replacement') {
          await Link('${fixture.repository.path}/$path').create('tracked.txt');
          await fixture.commit();
          await Link('${fixture.repository.path}/$path').delete();
        }
        await fixture.write(path, 'staged content\n');
        await fixture.git(['add', '--', path]);
        await fixture.write(path, 'working content\n');
        final file = await fixture.changed(path: path);
        expect(file.changeKind, 'modified');
        expect(
          file.reviewRevision,
          isNotNull,
          reason: 'G6a hunk eligibility is independent',
        );
        expect(file.fileReviewRevision, isNull);
        final before = await fixture.state();
        await expectLater(
          fixture.mutateFile(untrustedFileSelection(path)),
          throwsA(hasErrorCode(['unsupported_target'])),
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
    test('file review $name bound rejects before a write', () async {
      await fixture.write('tracked.txt', lines({2: 'first', 35: 'last'}));
      final file = await fixture.changed();
      final before = await fixture.state();
      await expectLater(
        fixture.mutateFile(selectFileFrom(file), limits: limits),
        throwsA(hasErrorCode(['inspection_failed'])),
      );
      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    });
  }

  for (final staged in [false, true]) {
    test(
      'file ${reviewVerb(staged)} preserves outside-source index records and literal paths',
      () async {
        const name = 'selected/project/-literal [x] \\ "\u00e9".txt';
        await fixture.write(name, lines());
        await fixture.commit();
        await fixture.write(name, lines({2: 'first', 35: 'last'}));
        await fixture.write('other.txt', 'outside staged\n');
        await fixture.git(['add', '--', 'other.txt', if (staged) name]);
        await fixture.write('other.txt', 'outside working\n');
        fixture.processes.root = Directory(
          '${fixture.repository.path}/selected/project',
        );
        final file = (await fixture.layer(staged: staged)).files.single;
        final before = await fixture.state();
        await fixture.mutateFile(selectFileFrom(file), staged: staged);
        await fixture.expectIndexChange(
          before,
          name,
          staged ? lines() : lines({2: 'first', 35: 'last'}),
        );
        expect(fixture.processes.writes, hasLength(1));
      },
    );

    test(
      'file ${reviewVerb(staged)} aggregate stdin eligibility preserves hunk revisions',
      () async {
        final oldLine = '\u00e9' * 140000;
        final newLine = '\u00f8' * 140000;
        final original = lines({2: oldLine, 35: oldLine});
        final modified = lines({2: newLine, 35: newLine});
        await fixture.write('tracked.txt', original);
        await fixture.commit();
        await fixture.write('tracked.txt', modified);
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final file = await fixture.changed(staged: staged);
        expect(file.hunks, hasLength(2));
        expect(file.reviewRevision, isNotNull);
        expect(file.fileReviewRevision, isNull);
        final before = await fixture.state();
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

    for (final loss in [
      'lock',
      'response lost',
      'revoked before check',
      'revoked after apply',
    ]) {
      test(
        'file ${reviewVerb(staged)} $loss preserves truthful outcome',
        () async {
          final modified = lines({2: 'first', 35: 'last'});
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final selection = selectFileFrom(
            await fixture.changed(staged: staged),
          );
          final before = await fixture.state();
          var revoked = false;
          fixture.processes.intercept = (request, run) async {
            if (revoked ||
                loss == 'revoked before check' &&
                    request.arguments.contains('apply')) {
              throw const EnvironmentFailure(
                code: 'grant_revoked',
                message: 'Retired grant.',
                details: {},
              );
            }
            if (isWrite(request) && loss == 'lock') {
              await fixture.write('.git/index.lock', 'external lock\n');
            }
            final result = await run(request);
            if (isWrite(request) && loss != 'lock') {
              expect(result.exitCode, 0);
              revoked = true;
              if (loss == 'response lost') {
                throw const EnvironmentFailure(
                  code: 'process_output_failed',
                  message: 'Lost acknowledgement.',
                  details: {},
                );
              }
            }
            return result;
          };
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(
              hasErrorCode([
                loss == 'lock'
                    ? 'mutation_failed'
                    : loss == 'revoked before check'
                    ? 'inspection_failed'
                    : 'outcome_uncertain',
              ]),
            ),
          );
          expect(
            fixture.processes.writes,
            hasLength(loss == 'revoked before check' ? 0 : 1),
          );
          if (loss == 'lock' || loss == 'revoked before check') {
            await fixture.expectUnchanged(before);
          } else {
            await fixture.expectIndexChange(
              before,
              'tracked.txt',
              staged ? lines() : modified,
            );
          }
        },
      );
    }
  }

  for (final boundary in ['before invocation', 'after check', 'after apply']) {
    test(
      'file review detects outside-source index changes $boundary',
      () async {
        await fixture.write('selected/tracked.txt', lines());
        await fixture.commit();
        await fixture.write(
          'selected/tracked.txt',
          lines({2: 'first', 35: 'last'}),
        );
        fixture.processes.root = Directory(
          '${fixture.repository.path}/selected',
        );
        final selection = selectFileFrom((await fixture.layer()).files.single);
        ReviewState? external;
        Future<void> changeOutside() async {
          await fixture.write('other.txt', 'outside index changed\n');
          await fixture.git(['add', '--', 'other.txt']);
          external = await fixture.state();
        }

        if (boundary == 'before invocation') await changeOutside();
        fixture.processes.intercept = (request, run) async {
          final result = await run(request);
          if (request.arguments.contains('apply') &&
              (boundary == 'after check' &&
                      request.arguments.contains('--check') ||
                  boundary == 'after apply' && isWrite(request))) {
            await changeOutside();
          }
          return result;
        };
        await expectLater(
          fixture.mutateFile(selection),
          throwsA(
            hasErrorCode([
              boundary == 'after apply'
                  ? 'outcome_uncertain'
                  : 'stale_selection',
            ]),
          ),
        );
        expect(external, isNotNull);
        await fixture.expectUnchanged(external!);
        expect(
          fixture.processes.writes,
          hasLength(boundary == 'after apply' ? 1 : 0),
        );
      },
    );
  }

  for (final staged in [false, true]) {
    test(
      'file ${reviewVerb(staged)} process count does not scale with hunk count',
      () async {
        final counts = <int>[];
        for (final count in [1, 3, 40]) {
          final original = List.generate(500, (i) => 'line $i\n').join();
          await fixture.write('tracked.txt', original);
          // Each iteration starts from the prior operation's possibly staged result.
          await fixture.git(['add', '--all']);
          await fixture.git([
            'commit',
            '--allow-empty',
            '-m',
            'Performance fixture',
          ]);
          var modified = original;
          for (var i = 0; i < count; i++) {
            modified = modified.replaceFirst(
              'line ${i * 12 + 4}\n',
              'edit $i\nextra $i\n',
            );
          }
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          expect(file.hunks, hasLength(count));
          final before = await fixture.state();
          fixture.processes.requests.clear();
          final watch = Stopwatch()..start();
          await fixture.mutateFile(selectFileFrom(file), staged: staged);
          watch.stop();
          counts.add(fixture.processes.requests.length);
          print(
            'File ${reviewVerb(staged)} performance: $count hunks, ${counts.last} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
          );
          expect(fixture.processes.writes, hasLength(1));
          expect(
            fixture.processes.requests.where(
              (r) => r.arguments.contains('apply'),
            ),
            hasLength(2),
          );
          await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? original : modified,
          );
        }
        expect(counts.toSet(), hasLength(1));
        expect(counts.first, lessThan(100));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
