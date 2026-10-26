@TestOn('linux')
library;

import 'dart:io';

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
    test('whole-layer mixed membership roundtrip $format', () async {
      if (format != fixture.format) {
        await fixture.close();
        fixture = await TestRepo.create(format: format);
      }
      final changes = await fixture.layerChanges(mixed: true);
      final initial = await fixture.state();
      for (final staged in [false, true]) {
        final layer = await fixture.layer(staged: staged);
        expect(layer.files, hasLength(6));
        expect(
          layer.files.map((file) => file.changeKind),
          unorderedEquals([
            'modified',
            'modified',
            'added',
            'added',
            'deleted',
            'deleted',
          ]),
        );
        expect(
          layer.files
              .where((file) => file.relativePath.contains('empty'))
              .every(
                (file) => file.hunks.isEmpty && file.fileReviewRevision != null,
              ),
          isTrue,
        );
        final before = await fixture.state();
        final selection = selectLayerFrom(layer);
        fixture.processes.requests.clear();
        await fixture.mutateLayer(selection, staged: staged);
        final patch = checkedApplyPatch(fixture, staged: staged);
        expect('diff --git '.allMatches(patch), hasLength(6));
        expect('new file mode '.allMatches(patch), hasLength(2));
        expect('deleted file mode '.allMatches(patch), hasLength(2));
        final after = await fixture.expectIndexChanges(
          before,
          staged ? changes.head : changes.working,
        );
        final refreshed = await fixture.snapshots.snapshotUncommitted();
        expect((staged ? refreshed.staged : refreshed.unstaged).files, isEmpty);
        expect(
          (staged ? refreshed.staged : refreshed.unstaged).layerReviewRevision,
          isNull,
        );
        fixture.processes.requests.clear();
        await expectLater(
          fixture.mutateLayer(selection, staged: staged),
          throwsA(hasErrorCode(['stale_selection', 'unsupported_target'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(after);
      }
      final restored = await fixture.state();
      expect(restored.listing, initial.listing);
      expect(restored.blobs, initial.blobs);
    });

    for (final staged in [false, true]) {
      test(
        'whole-layer ${reviewVerb(staged)} exact nested bytes and outside records $format',
        () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await TestRepo.create(format: format);
          }
          const prefix = 'selected/project/';
          final head = <String, String?>{
            '$prefix-literal [x] \\ "\u00e9".txt': '\ufeffHEAD\r\n\r\nlast',
            '$prefix:(glob)*[x]': 'before\n',
            '$prefix\ufeffdeleted.txt': '\ufeffdeleted\r\nlast',
            '${prefix}empty-deleted': '',
            '${prefix}quotes\'";\$(touch INJECTED)': null,
            '${prefix}empty-new': null,
          };
          final working = <String, String?>{
            head.keys.elementAt(0): '\ufeffworking\r\n\r\nlast changed',
            head.keys.elementAt(1): '',
            head.keys.elementAt(2): null,
            head.keys.elementAt(3): null,
            head.keys.elementAt(4): '\ufeffnew\r\nlast  ',
            head.keys.elementAt(5): '',
          };
          for (final entry in head.entries) {
            if (entry.value == null) continue;
            await fixture.write(entry.key, entry.value!);
            await runLocal('/usr/bin/chmod', [
              '755',
              '${fixture.repository.path}/${entry.key}',
            ]);
          }
          await fixture.write('conflict.txt', 'conflict HEAD\n');
          await fixture.commit();
          for (final entry in working.entries) {
            if (entry.value == null) {
              await File('${fixture.repository.path}/${entry.key}').delete();
            } else {
              await fixture.write(entry.key, entry.value!);
              await runLocal('/usr/bin/chmod', [
                '755',
                '${fixture.repository.path}/${entry.key}',
              ]);
            }
          }
          if (staged) await fixture.git(['add', '--all']);
          await fixture.git([
            'update-index',
            '--assume-unchanged',
            '--',
            'tracked.txt',
          ]);
          await fixture.git([
            'update-index',
            '--skip-worktree',
            '--',
            'other.txt',
          ]);
          await fixture.write(
            'tracked.txt',
            'outside assume-unchanged working\n',
          );
          await fixture.write('other.txt', 'outside skip-worktree working\n');
          await fixture.write('outside-new.txt', 'outside staged\n');
          await fixture.git(['add', '--', 'outside-new.txt']);
          await fixture.write('outside-new.txt', 'outside working\n');
          await fixture.makeConflict(path: 'conflict.txt');
          fixture.processes.root = Directory(
            '${fixture.repository.path}/selected/project',
          );
          const outside = [
            'ls-files',
            '--stage',
            '--debug',
            '-z',
            '--',
            'tracked.txt',
            'other.txt',
            'outside-new.txt',
            'conflict.txt',
          ];
          final outsideBefore = await fixture.gitBytes(outside);
          final before = await fixture.state();
          final layers = await fixture.snapshots.snapshotUncommitted();
          expect(layers.conflicts, isEmpty);
          final layer = staged ? layers.staged : layers.unstaged;
          expect(layer.files, hasLength(6));
          fixture.processes.requests.clear();
          await fixture.mutateLayer(selectLayerFrom(layer), staged: staged);
          checkedApplyPatch(fixture, staged: staged);
          final after = await fixture.expectIndexChanges(
            before,
            staged ? head : working,
            mode: '100755',
          );
          expect(
            await fixture.gitBytes(outside),
            outsideBefore,
            reason:
                'all unrelated flag, stat, mode, OID and conflict-stage bytes',
          );
          expect(
            after.oids.values.every(
              (oid) => oid.length == (format == 'sha256' ? 64 : 40),
            ),
            isTrue,
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
  }

  test(
    'whole-layer unapprove removes staged addition B and preserves working C',
    () async {
      final changes = await fixture.layerChanges(staged: true);
      await fixture.write('new.txt', 'staged B\n');
      await fixture.git(['add', '--', 'new.txt']);
      await fixture.write('new.txt', 'working C\n');
      final layers = await fixture.snapshots.snapshotUncommitted();
      expect(layers.unstaged.layerReviewRevision, isNull);
      expect(layers.staged.files, hasLength(3));
      final before = await fixture.state();
      fixture.processes.requests.clear();
      await fixture.mutateLayer(selectLayerFrom(layers.staged), staged: true);
      checkedApplyPatch(fixture, staged: true);
      await fixture.expectIndexChanges(before, {
        ...changes.head,
        'new.txt': null,
      });
      final refreshed = await fixture.snapshots.snapshotUncommitted();
      expect(refreshed.staged.files, isEmpty);
      expect(refreshed.unstaged.files, hasLength(3));
      expect(refreshed.unstaged.layerReviewRevision, isNotNull);
    },
  );

  for (final staged in [false, true]) {
    test(
      'whole-layer ${reviewVerb(staged)} keeps identical blobs on distinct paths',
      () async {
        const paths = ['tracked.txt', 'other.txt'];
        for (final path in paths) {
          await fixture.write(path, 'shared HEAD\n');
        }
        await fixture.commit();
        for (final path in paths) {
          await fixture.write(path, 'shared working\n');
        }
        if (staged) await fixture.git(['add', '--all']);
        final layer = await fixture.layer(staged: staged);
        expect(layer.files, hasLength(2));
        final before = await fixture.state();
        fixture.processes.requests.clear();
        await fixture.mutateLayer(selectLayerFrom(layer), staged: staged);
        checkedApplyPatch(fixture, staged: staged);
        final after = await fixture.expectIndexChanges(before, {
          for (final path in paths)
            path: staged ? 'shared HEAD\n' : 'shared working\n',
        });
        expect(after.oids['0:tracked.txt'], after.oids['0:other.txt']);
      },
    );

    for (final cancelling in [false, true]) {
      test(
        'whole-layer ${reviewVerb(staged)} preserves A/B/${cancelling ? 'A' : 'C'} partial staging',
        () async {
          final head = {
            'tracked.txt': lines(),
            'other.txt': 'other original\n',
          };
          final indexed = {
            'tracked.txt': lines({2: 'index B'}),
            'other.txt': 'other index B\n',
          };
          final working = cancelling
              ? head
              : {
                  'tracked.txt': lines({2: 'index B', 35: 'working C'}),
                  'other.txt': 'other working C\n',
                };
          for (final entry in indexed.entries) {
            await fixture.write(entry.key, entry.value);
          }
          await fixture.git(['add', '--all']);
          for (final entry in working.entries) {
            await fixture.write(entry.key, entry.value);
          }
          final layers = await fixture.snapshots.snapshotUncommitted();
          expect(layers.staged.files, hasLength(2));
          expect(layers.unstaged.files, hasLength(2));
          final before = await fixture.state();
          fixture.processes.requests.clear();
          await fixture.mutateLayer(
            selectLayerFrom(staged ? layers.staged : layers.unstaged),
            staged: staged,
          );
          checkedApplyPatch(fixture, staged: staged);
          await fixture.expectIndexChanges(before, staged ? head : working);
          final refreshed = await fixture.snapshots.snapshotUncommitted();
          expect(
            (staged ? refreshed.staged : refreshed.unstaged).files,
            isEmpty,
          );
          expect(
            (staged ? refreshed.unstaged : refreshed.staged).files,
            cancelling ? isEmpty : hasLength(2),
          );
        },
      );
    }

    for (final (name, count, mixed) in [
      ('two files', 2, false),
      ('mixed', 2, true),
      ('larger bounded', 16, false),
    ]) {
      test('whole-layer ${reviewVerb(staged)} performance $name', () async {
        final changes = await fixture.layerChanges(
          staged: staged,
          mixed: mixed,
          count: count,
        );
        final layer = await fixture.layer(staged: staged);
        final before = await fixture.state();
        fixture.processes.requests.clear();
        final watch = Stopwatch()..start();
        await fixture.mutateLayer(selectLayerFrom(layer), staged: staged);
        watch.stop();
        final requests = fixture.processes.requests.length;
        print(
          'Whole-layer ${reviewVerb(staged)} performance: $name, ${layer.files.length} files, $requests processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
        );
        final patch = checkedApplyPatch(fixture, staged: staged);
        expect('diff --git '.allMatches(patch), hasLength(layer.files.length));
        expect(requests, lessThan(80 + 40 * layer.files.length));
        await fixture.expectIndexChanges(
          before,
          staged ? changes.head : changes.working,
        );
      });
    }
  }
}
