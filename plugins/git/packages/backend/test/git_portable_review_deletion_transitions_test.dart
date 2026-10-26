@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:diff_viewer_contract/diff_viewer_contract.dart';
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
    for (final mode in ['100644', '100755']) {
      for (final (name, original, indexed) in [
        ('ordinary', 'HEAD A\n', 'HEAD A\n'),
        ('partially staged', 'HEAD A\n', 'index B\n'),
        ('empty', '', ''),
        ('empty index', 'HEAD A\n', ''),
        ('empty HEAD', '', 'index B\n'),
        (
          'BOM CRLF no newline',
          '\ufeffHEAD\r\n\r\nlast',
          '\ufeffindex\r\nlast B',
        ),
      ]) {
        test(
          'deletion cycle $name $mode $format restores HEAD not index',
          () async {
            if (format != fixture.format) {
              await fixture.close();
              fixture = await TestRepo.create(format: format);
            }
            await fixture.deleteTracked(
              original: original,
              indexed: indexed,
              mode: mode,
            );
            final initial = await fixture.state();
            final headOid = (await fixture.git([
              'rev-parse',
              'HEAD:tracked.txt',
            ])).trim();
            final layers = await fixture.snapshots.snapshotUncommitted();
            expect(layers.staged.files.isEmpty, original == indexed);
            final deleted = layers.unstaged.files.single;
            expect(deleted.changeKind, 'deleted');
            expect(deleted.contentStatus, 'text');
            expect(deleted.reviewRevision, isNull);
            expect(deleted.hunks.isEmpty, indexed.isEmpty);
            final approve = selectFileFrom(deleted);
            expect(
              (await fixture.changed()).fileReviewRevision,
              approve.expectedRevision,
            );
            fixture.processes.requests.clear();
            await expectLater(
              fixture.mutate(
                ReviewHunkSelection(
                  relativePath: 'tracked.txt',
                  hunkIndex: 0,
                  expectedRevision: approve.expectedRevision,
                ),
              ),
              throwsA(hasErrorCode(['unsupported_target'])),
            );
            expect(fixture.processes.writes, isEmpty);
            await fixture.expectUnchanged(initial);

            for (final staged in [false, true]) {
              final before = await fixture.state();
              final file = await fixture.changed(staged: staged);
              final selection = selectFileFrom(file);
              expect(file.changeKind, 'deleted');
              expect(file.contentStatus, 'text');
              expect(file.reviewRevision, isNull);
              expect(file.hunks.isEmpty, (staged ? original : indexed).isEmpty);
              if (staged) {
                expect(
                  selection.expectedRevision,
                  isNot(approve.expectedRevision),
                );
              }
              fixture.processes.requests.clear();
              if (staged) {
                await expectLater(
                  fixture.mutateFile(approve, staged: true),
                  throwsA(hasErrorCode(['stale_selection'])),
                );
                await expectLater(
                  fixture.mutate(
                    ReviewHunkSelection(
                      relativePath: file.relativePath,
                      hunkIndex: 0,
                      expectedRevision: selection.expectedRevision,
                    ),
                    staged: true,
                  ),
                  throwsA(hasErrorCode(['unsupported_target'])),
                );
                expect(fixture.processes.writes, isEmpty);
                await fixture.expectUnchanged(before);
                fixture.processes.requests.clear();
              }

              await fixture.mutateFile(selection, staged: staged);

              final after = await fixture.expectIndexPresence(
                before,
                'tracked.txt',
                staged ? original : null,
                mode: mode,
              );
              expect(
                await FileSystemEntity.type(
                  '${fixture.repository.path}/tracked.txt',
                  followLinks: false,
                ),
                FileSystemEntityType.notFound,
              );
              final patch = checkedApplyPatch(fixture, staged: staged);
              final oid = staged ? headOid : initial.oids['0:tracked.txt']!;
              expect(patch, contains('deleted file mode $mode\n'));
              expect(patch, contains('index $oid..${'0' * oid.length}\n'));
              expect(patch, contains('+++ /dev/null\n'));
              final oldText = staged ? original : indexed;
              expect(patch.contains('@@'), oldText.isNotEmpty);
              expect(
                patch.contains('\\ No newline at end of file'),
                oldText.isNotEmpty && !oldText.endsWith('\n'),
              );
              final refreshed = await fixture.snapshots.snapshotUncommitted();
              expect(
                (staged ? refreshed.staged : refreshed.unstaged).files,
                isEmpty,
              );
              final remaining =
                  (staged ? refreshed.unstaged : refreshed.staged).files.single;
              expect(remaining.changeKind, 'deleted');
              expect(remaining.reviewRevision, isNull);
              expect(remaining.fileReviewRevision, isNotNull);
              expect(remaining.hunks.isEmpty, original.isEmpty);
              fixture.processes.requests.clear();
              await expectLater(
                fixture.mutateFile(selection, staged: staged),
                throwsA(
                  hasErrorCode(['stale_selection', 'unsupported_target']),
                ),
              );
              expect(fixture.processes.writes, isEmpty);
              await fixture.expectUnchanged(after);
            }
            final restored = await fixture.state();
            expect(restored.oids['0:tracked.txt'], headOid);
            expect(restored.blobs['0:tracked.txt'], utf8.encode(original));
            expect(restored.working, initial.working);
          },
        );
      }
    }
  }

  for (final staged in [false, true]) {
    for (final missing in ['leaf', 'one parent', 'several parents']) {
      test(
        'deletion ${reviewVerb(staged)} verifies absent $missing without recreating directories',
        () async {
          const path = 'selected/project/parent/deep/deleted.txt';
          await fixture.deleteTracked(path: path, staged: staged);
          if (missing != 'leaf') {
            await Directory(
              '${fixture.repository.path}/selected/project/parent${missing == 'one parent' ? '/deep' : ''}',
            ).delete(recursive: true);
          }
          fixture.processes.root = Directory(
            '${fixture.repository.path}/selected/project',
          );
          final file = await fixture.changed(
            path: 'parent/deep/deleted.txt',
            staged: staged,
          );
          final before = await fixture.state();
          fixture.processes.requests.clear();
          await fixture.mutateFile(selectFileFrom(file), staged: staged);
          await fixture.expectIndexPresence(
            before,
            path,
            staged ? 'HEAD A\n' : null,
          );
          checkedApplyPatch(fixture, staged: staged);
          expect(
            await FileSystemEntity.type(
              '${fixture.repository.path}/$path',
              followLinks: false,
            ),
            FileSystemEntityType.notFound,
          );
        },
      );
    }

    for (final name in [
      'space name',
      '-leading-option',
      ':(glob)*[x]',
      r'back\slash',
      'quotes\'";\$(touch INJECTED) \u00e9',
      '\ufeffdeleted.txt',
    ]) {
      test(
        'deletion ${reviewVerb(staged)} nested literal ${jsonEncode(name)}',
        () async {
          final path = 'selected/project/$name';
          await fixture.deleteTracked(path: path, staged: staged);
          await fixture.write('other.txt', 'outside staged\n');
          await fixture.git(['add', '--', 'other.txt']);
          await fixture.write('other.txt', 'outside working\n');
          fixture.processes.root = Directory(
            '${fixture.repository.path}/selected/project',
          );
          final file = await fixture.changed(path: name, staged: staged);
          final before = await fixture.state();
          fixture.processes.requests.clear();
          await fixture.mutateFile(selectFileFrom(file), staged: staged);
          await fixture.expectIndexPresence(
            before,
            path,
            staged ? 'HEAD A\n' : null,
          );
          checkedApplyPatch(fixture, staged: staged);
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

    test(
      'deletion ${reviewVerb(staged)} process count is independent of line count',
      () async {
        final counts = <int>[];
        for (final lines in [0, 1, 1000]) {
          final text = List.generate(lines, (i) => 'line $i\n').join();
          await fixture.deleteTracked(original: text, staged: staged);
          final file = await fixture.changed(staged: staged);
          final before = await fixture.state();
          fixture.processes.requests.clear();
          final watch = Stopwatch()..start();
          await fixture.mutateFile(selectFileFrom(file), staged: staged);
          watch.stop();
          counts.add(fixture.processes.requests.length);
          print(
            'Deletion ${reviewVerb(staged)} performance: $lines lines, ${counts.last} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
          );
          checkedApplyPatch(fixture, staged: staged);
          await fixture.expectIndexPresence(
            before,
            'tracked.txt',
            staged ? text : null,
          );
        }
        expect(
          counts[1],
          counts[2],
          reason: 'long text has the same bounded process path as short text',
        );
        expect(counts.every((count) => count < 150), isTrue);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
