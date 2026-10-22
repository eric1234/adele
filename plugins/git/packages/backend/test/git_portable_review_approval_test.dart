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
        GitPortableUnstagedSnapshotService,
        GitTaskComparisonAnchor;
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = await _Fixture.create();
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
        fixture.mutateLayer(_untrustedLayerSelection(), staged: staged),
        throwsA(_failureCode(['stale_selection', 'unsupported_target'])),
      );
    }
    expect(fixture.processes.writes, isEmpty);
    await fixture.expectUnchanged(before);
  });

  for (final format in ['sha1', 'sha256']) {
    test('whole-layer mixed membership roundtrip $format', () async {
      if (format != fixture.format) {
        await fixture.close();
        fixture = await _Fixture.create(format: format);
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
        final selection = _layerSelection(layer);
        fixture.processes.requests.clear();
        await fixture.mutateLayer(selection, staged: staged);
        final patch = _checkedFilePatch(fixture, staged: staged);
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
          throwsA(_failureCode(['stale_selection', 'unsupported_target'])),
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
        'whole-layer ${_direction(staged)} exact nested bytes and outside records $format',
        () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await _Fixture.create(format: format);
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
            await _command('/usr/bin/chmod', [
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
              await _command('/usr/bin/chmod', [
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
          await fixture.mutateLayer(_layerSelection(layer), staged: staged);
          _checkedFilePatch(fixture, staged: staged);
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
    'whole-layer revisions are stable across methods and distinct from file hunk and committed',
    () async {
      final baseline = (await fixture.git(['rev-parse', 'HEAD'])).trim();
      await fixture.layerChanges();
      await fixture.git(['add', '--all']);
      await fixture.write(
        'tracked.txt',
        _text({2: 'working C', 35: 'later C'}),
      );
      await fixture.write('other.txt', _text({2: 'other C', 35: 'later C'}));
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
            throwsA(_failureCode(['stale_selection'])),
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
          throwsA(_failureCode(['stale_selection'])),
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
        fixture.mutateLayer(_untrustedLayerSelection(), limits: limits),
        throwsA(_failureCode(['unsupported_target'])),
      );
      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    },
  );

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
      await fixture.mutateLayer(_layerSelection(layers.staged), staged: true);
      _checkedFilePatch(fixture, staged: true);
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
        _untrustedLayerSelection(),
        staged: true,
        limits: limits,
      ),
      throwsA(_failureCode(['unsupported_target'])),
    );
    expect(fixture.processes.writes, isEmpty);
    await fixture.expectUnchanged(before);
  });

  for (final staged in [false, true]) {
    test(
      'whole-layer ${_direction(staged)} keeps identical blobs on distinct paths',
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
        await fixture.mutateLayer(_layerSelection(layer), staged: staged);
        _checkedFilePatch(fixture, staged: staged);
        final after = await fixture.expectIndexChanges(before, {
          for (final path in paths)
            path: staged ? 'shared HEAD\n' : 'shared working\n',
        });
        expect(after.oids['0:tracked.txt'], after.oids['0:other.txt']);
      },
    );

    for (final cancelling in [false, true]) {
      test(
        'whole-layer ${_direction(staged)} preserves A/B/${cancelling ? 'A' : 'C'} partial staging',
        () async {
          final head = {
            'tracked.txt': _text(),
            'other.txt': 'other original\n',
          };
          final indexed = {
            'tracked.txt': _text({2: 'index B'}),
            'other.txt': 'other index B\n',
          };
          final working = cancelling
              ? head
              : {
                  'tracked.txt': _text({2: 'index B', 35: 'working C'}),
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
            _layerSelection(staged ? layers.staged : layers.unstaged),
            staged: staged,
          );
          _checkedFilePatch(fixture, staged: staged);
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
        'whole-layer ${_direction(staged)} rejects every target when one is $kind',
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
            await _command('/usr/bin/chmod', [
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
              _untrustedLayerSelection(),
              staged: staged,
              limits: limits,
            ),
            throwsA(_failureCode(['unsupported_target'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    test(
      'whole-layer ${_direction(staged)} aggregate stdin bound retains individual eligibility',
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
          fixture.mutateLayer(_untrustedLayerSelection(), staged: staged),
          throwsA(_failureCode(['unsupported_target'])),
        );
        watch.stop();
        print(
          'Whole-layer ${_direction(staged)} performance: rejected aggregate, ${fixture.processes.requests.length} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
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
        'whole-layer ${_direction(staged)} rejects stale $mutation',
        () async {
          final changes = await fixture.layerChanges(staged: staged);
          final selection = _layerSelection(
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
            throwsA(_failureCode(['stale_selection', 'unsupported_target'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
          if (mutation == 'Session' || mutation == 'Environment') {
            final fresh = _layerSelection(await fixture.layer(staged: staged));
            expect(fresh.expectedRevision, isNot(selection.expectedRevision));
            fixture.processes.requests.clear();
            await fixture.mutateLayer(fresh, staged: staged);
            _checkedFilePatch(fixture, staged: staged);
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
        'whole-layer ${_direction(staged)} $loss never retries or reports false success',
        () async {
          final changes = await fixture.layerChanges(
            staged: staged,
            mixed: true,
          );
          final selection = _layerSelection(
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
            if (loss == 'lock' && _isWrite(request)) {
              await fixture.write('.git/index.lock', 'external owner\n');
            }
            final result = await run(request);
            if (loss == 'revoked after check' && check) revoked = true;
            if (_isWrite(request) && loss != 'lock') {
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
              _failureCode([
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
          'whole-layer ${_direction(staged)} external $target $boundary is stale or uncertain',
          () async {
            final changes = await fixture.layerChanges(
              staged: staged,
              mixed: true,
            );
            final selection = _layerSelection(
              await fixture.layer(staged: staged),
            );
            _State? external;
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
              if (boundary == 'at write' && _isWrite(request)) {
                await changeState();
              }
              final result = await run(request);
              if (boundary == 'after check' &&
                      request.arguments.contains('apply') &&
                      request.arguments.contains('--check') ||
                  boundary == 'after apply' && _isWrite(request)) {
                await changeState();
              }
              return result;
            };
            await expectLater(
              fixture.mutateLayer(selection, staged: staged),
              throwsA(
                _failureCode([
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
      'whole-layer ${_direction(staged)} concurrent duplicates have one complete effect',
      () async {
        final changes = await fixture.layerChanges(staged: staged, mixed: true);
        final selection = _layerSelection(await fixture.layer(staged: staged));
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
          _failureCode([
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
        'whole-layer ${_direction(staged)} detects $change after check',
        () async {
          await fixture.write('clean.txt', 'clean HEAD\n');
          await fixture.layerChanges(staged: staged);
          final selection = _layerSelection(
            await fixture.layer(staged: staged),
          );
          _State? external;
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
            throwsA(_failureCode(['stale_selection'])),
          );
          expect(external, isNotNull);
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(external!);
        },
      );
    }

    for (final corruption in ['conflict-only', 'wrong mode', 'absent']) {
      test(
        'whole-layer ${_direction(staged)} later selected $corruption after apply is uncertain',
        () async {
          final changes = await fixture.layerChanges(
            staged: staged,
            mixed: true,
          );
          final selection = _layerSelection(
            await fixture.layer(staged: staged),
          );
          final before = await fixture.state();
          _State? external;
          fixture.processes.requests.clear();
          fixture.processes.intercept = (request, run) async {
            final result = await run(request);
            if (_isWrite(request)) {
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
            throwsA(_failureCode(['outcome_uncertain'])),
          );
          expect(external, isNotNull);
          expect(fixture.processes.writes, hasLength(1));
          await fixture.expectUnchanged(external!);
        },
      );
    }

    test(
      'whole-layer ${_direction(staged)} reserves verification beyond a complete snapshot',
      () async {
        await fixture.layerChanges(staged: staged);
        fixture.processes.requests.clear();
        final selection = _layerSelection(await fixture.layer(staged: staged));
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
          throwsA(_failureCode(['unsupported_target', 'inspection_failed'])),
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
        'whole-layer ${_direction(staged)} $name exhaustion rejects before writing',
        () async {
          await fixture.layerChanges(staged: staged);
          final selection = _layerSelection(
            await fixture.layer(staged: staged),
          );
          final before = await fixture.state();
          fixture.processes.requests.clear();
          await expectLater(
            fixture.mutateLayer(selection, staged: staged, limits: limits),
            throwsA(_failureCode(['inspection_failed'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    for (final (name, count, mixed) in [
      ('two files', 2, false),
      ('mixed', 2, true),
      ('larger bounded', 16, false),
    ]) {
      test('whole-layer ${_direction(staged)} performance $name', () async {
        final changes = await fixture.layerChanges(
          staged: staged,
          mixed: mixed,
          count: count,
        );
        final layer = await fixture.layer(staged: staged);
        final before = await fixture.state();
        fixture.processes.requests.clear();
        final watch = Stopwatch()..start();
        await fixture.mutateLayer(_layerSelection(layer), staged: staged);
        watch.stop();
        final requests = fixture.processes.requests.length;
        print(
          'Whole-layer ${_direction(staged)} performance: $name, ${layer.files.length} files, $requests processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
        );
        final patch = _checkedFilePatch(fixture, staged: staged);
        expect('diff --git '.allMatches(patch), hasLength(layer.files.length));
        expect(requests, lessThan(80 + 40 * layer.files.length));
        await fixture.expectIndexChanges(
          before,
          staged ? changes.head : changes.working,
        );
      });
    }

    test(
      'whole-layer ${_direction(staged)} file-count cap retains file actions',
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
          fixture.mutateLayer(_untrustedLayerSelection(), staged: staged),
          throwsA(_failureCode(['unsupported_target'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
      },
    );
  }

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
              fixture = await _Fixture.create(format: format);
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
            final approve = _fileSelection(deleted);
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
              throwsA(_failureCode(['unsupported_target'])),
            );
            expect(fixture.processes.writes, isEmpty);
            await fixture.expectUnchanged(initial);

            for (final staged in [false, true]) {
              final before = await fixture.state();
              final file = await fixture.changed(staged: staged);
              final selection = _fileSelection(file);
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
                  throwsA(_failureCode(['stale_selection'])),
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
                  throwsA(_failureCode(['unsupported_target'])),
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
              final patch = _checkedFilePatch(fixture, staged: staged);
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
                  _failureCode(['stale_selection', 'unsupported_target']),
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
        'deletion ${_direction(staged)} verifies absent $missing without recreating directories',
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
          await fixture.mutateFile(_fileSelection(file), staged: staged);
          await fixture.expectIndexPresence(
            before,
            path,
            staged ? 'HEAD A\n' : null,
          );
          _checkedFilePatch(fixture, staged: staged);
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
        'deletion ${_direction(staged)} nested literal ${jsonEncode(name)}',
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
          await fixture.mutateFile(_fileSelection(file), staged: staged);
          await fixture.expectIndexPresence(
            before,
            path,
            staged ? 'HEAD A\n' : null,
          );
          _checkedFilePatch(fixture, staged: staged);
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
      test('deletion ${_direction(staged)} excludes $kind', () async {
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
            _untrustedFileSelection(path),
            staged: staged,
            limits: limits,
          ),
          throwsA(_failureCode(['unsupported_target', 'stale_selection'])),
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
        'deletion ${_direction(staged)} excludes conversion $rule',
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
              _untrustedFileSelection('tracked.txt'),
              staged: staged,
            ),
            throwsA(_failureCode(['unsupported_target'])),
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
      test('deletion ${_direction(staged)} rejects stale $mutation', () async {
        const path = 'parent/deleted.txt';
        await fixture.deleteTracked(path: path, staged: staged);
        final selection = _fileSelection(
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
          throwsA(_failureCode(['unsupported_target', 'stale_selection'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
        if (mutation == 'Session' || mutation == 'Environment') {
          final fresh = _fileSelection(
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
          _checkedFilePatch(fixture, staged: staged);
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
        'deletion ${_direction(staged)} absence $failure fails closed in snapshot and mutation',
        () async {
          await fixture.deleteTracked(
            path: 'parent/deleted.txt',
            staged: staged,
          );
          final selection = _fileSelection(
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
            throwsA(_failureCode(['inspection_failed'])),
          );
          expect(probes, 2);
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    for (final boundary in ['after check', 'after apply']) {
      test(
        'deletion ${_direction(staged)} absence inspection error $boundary is not absence',
        () async {
          await fixture.deleteTracked(staged: staged);
          final selection = _fileSelection(
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
                ? _isWrite(request)
                : request.arguments.contains('apply') &&
                      request.arguments.contains('--check')) {
              failProbe = true;
            }
            return result;
          };
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(
              _failureCode([
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
        'deletion ${_direction(staged)} rejects changed missing-parent boundary $replacement',
        () async {
          const path = 'parent/deep/deleted.txt';
          await fixture.deleteTracked(path: path, staged: staged);
          await Directory(
            '${fixture.repository.path}/parent',
          ).delete(recursive: true);
          final selection = _fileSelection(
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
            throwsA(_failureCode(['unsupported_target', 'stale_selection'])),
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
        'deletion ${_direction(staged)} $name bound rejects before writing',
        () async {
          await fixture.deleteTracked(
            original: _text({0: 'deletion bound'}),
            staged: staged,
          );
          final selection = _fileSelection(
            await fixture.changed(staged: staged),
          );
          final before = await fixture.state();
          await expectLater(
            fixture.mutateFile(selection, staged: staged, limits: limits),
            throwsA(_failureCode(['inspection_failed'])),
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
        'deletion ${_direction(staged)} $loss has truthful effect without retry',
        () async {
          await fixture.deleteTracked(staged: staged);
          final selection = _fileSelection(
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
            if (loss == 'lock' && _isWrite(request)) {
              await fixture.write('.git/index.lock', 'external lock owner\n');
            }
            final result = await run(request);
            if (loss == 'revoked after check' && check) revoked = true;
            if (_isWrite(request) && loss != 'lock') {
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
              _failureCode([
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
          'deletion ${_direction(staged)} external $change $boundary never retries',
          () async {
            await fixture.deleteTracked(staged: staged);
            final selection = _fileSelection(
              await fixture.changed(staged: staged),
            );
            _State? external;
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
              if (boundary == 'at write' && _isWrite(request)) {
                await changeState();
              }
              final result = await run(request);
              if (boundary == 'after check' &&
                      request.arguments.contains('apply') &&
                      request.arguments.contains('--check') ||
                  boundary == 'after apply' && _isWrite(request)) {
                await changeState();
              }
              return result;
            };
            await expectLater(
              fixture.mutateFile(selection, staged: staged),
              throwsA(
                _failureCode([
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
      'deletion ${_direction(staged)} concurrent duplicates have one effect',
      () async {
        await fixture.deleteTracked(staged: staged);
        final selection = _fileSelection(await fixture.changed(staged: staged));
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
          _failureCode([
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

    test(
      'deletion ${_direction(staged)} process count is independent of line count',
      () async {
        final counts = <int>[];
        for (final lines in [0, 1, 1000]) {
          final text = List.generate(lines, (i) => 'line $i\n').join();
          await fixture.deleteTracked(original: text, staged: staged);
          final file = await fixture.changed(staged: staged);
          final before = await fixture.state();
          fixture.processes.requests.clear();
          final watch = Stopwatch()..start();
          await fixture.mutateFile(_fileSelection(file), staged: staged);
          watch.stop();
          counts.add(fixture.processes.requests.length);
          print(
            'Deletion ${_direction(staged)} performance: $lines lines, ${counts.last} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
          );
          _checkedFilePatch(fixture, staged: staged);
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

  for (final format in ['sha1', 'sha256']) {
    for (final mode in ['100644', '100755']) {
      for (final staged in [false, true]) {
        for (final (name, text) in [
          ('UTF-8', 'caf\u00e9\nnew text  \n'),
          ('empty', ''),
          ('missing newline', 'new\nlast'),
          ('BOM CRLF', '\ufefffirst\r\n\r\nlast\r\n'),
        ]) {
          test('new-file ${_direction(staged)} $name $mode $format', () async {
            if (format != fixture.format) {
              await fixture.close();
              fixture = await _Fixture.create(format: format);
            }
            const path = 'new.txt';
            await fixture.write(path, text);
            await _command('/usr/bin/chmod', [
              mode == '100755' ? '755' : '644',
              '${fixture.repository.path}/$path',
            ]);
            if (staged) await fixture.git(['add', '--', path]);
            await fixture.write('other.txt', 'unrelated staged\n');
            await fixture.git(['add', '--', 'other.txt']);
            await fixture.write('other.txt', 'unrelated working\n');
            final file = await fixture.changed(path: path, staged: staged);
            expect(file.changeKind, 'added');
            expect(file.contentStatus, 'text');
            expect(
              file.reviewRevision,
              isNull,
              reason: 'additions are file-only',
            );
            expect(file.hunks.isEmpty, text.isEmpty);
            final selection = _fileSelection(file);
            final before = await fixture.state();
            fixture.processes.requests.clear();

            await fixture.mutateFile(selection, staged: staged);

            final after = await fixture.expectIndexPresence(
              before,
              path,
              staged ? null : text,
              mode: mode,
            );
            final applies = fixture.processes.requests
                .where((r) => r.arguments.contains('apply'))
                .toList();
            expect(applies, hasLength(2));
            expect(applies.first.arguments, contains('--check'));
            expect(applies.last.arguments.contains('--reverse'), staged);
            expect(applies.first.stdinBase64, applies.last.stdinBase64);
            final patch = utf8.decode(base64Decode(applies.last.stdinBase64));
            final oid = (staged ? before : after).oids['0:$path']!;
            expect(patch, contains('new file mode $mode\n'));
            expect(patch, contains('index ${'0' * oid.length}..$oid\n'));
            expect(patch, contains('--- /dev/null\n'));
            expect(patch.contains('@@'), text.isNotEmpty);
            expect(fixture.processes.writes, hasLength(1));
            expect(
              fixture.processes.requests.any(
                (r) => r.arguments.contains('add'),
              ),
              isFalse,
            );
            final layers = await fixture.snapshots.snapshotUncommitted();
            expect(
              (staged ? layers.staged : layers.unstaged).files.where(
                (f) => f.relativePath == path,
              ),
              isEmpty,
            );
            final refreshed = (staged ? layers.unstaged : layers.staged).files
                .singleWhere((f) => f.relativePath == path);
            expect(refreshed.changeKind, 'added');
            expect(refreshed.fileReviewRevision, isNotNull);
            expect(refreshed.reviewRevision, isNull);
            fixture.processes.requests.clear();
            await expectLater(
              fixture.mutateFile(selection, staged: staged),
              throwsA(_failureCode(['stale_selection'])),
            );
            expect(fixture.processes.writes, isEmpty);
            await fixture.expectUnchanged(after);
          });
        }
      }
    }
  }

  for (final text in ['new contents\n', '']) {
    test(
      'new-file approve then unapprove preserves ${jsonEncode(text)}',
      () async {
        await fixture.write('new.txt', text);
        final initial = await fixture.state();
        await fixture.mutateFile(
          _fileSelection(await fixture.changed(path: 'new.txt')),
        );
        final staged = await fixture.expectIndexPresence(
          initial,
          'new.txt',
          text,
        );
        fixture.processes.requests.clear();
        await fixture.mutateFile(
          _fileSelection(await fixture.changed(path: 'new.txt', staged: true)),
          staged: true,
        );
        final restored = await fixture.expectIndexPresence(
          staged,
          'new.txt',
          null,
        );
        expect(restored.listing, initial.listing);
        expect(restored.blobs, initial.blobs);
        expect(fixture.processes.writes, hasLength(1));
        expect(
          await fixture.git(['ls-files', '--others', '--exclude-standard']),
          'new.txt\n',
        );
      },
    );
  }

  for (final (stagedText, workingText) in [
    ('staged B\n', 'working C\n'),
    ('', 'working C\n'),
    ('staged B\n', ''),
  ]) {
    test(
      'new-file mixed ${jsonEncode(stagedText)} to ${jsonEncode(workingText)} permits only unapprove',
      () async {
        await fixture.write('new.txt', stagedText);
        await fixture.git(['add', '--', 'new.txt']);
        await fixture.write('new.txt', workingText);
        final layers = await fixture.snapshots.snapshotUncommitted();
        final unstaged = layers.unstaged.files.single;
        final staged = layers.staged.files.single;
        expect(unstaged.changeKind, 'modified');
        expect(unstaged.reviewRevision, isNotNull);
        expect(unstaged.fileReviewRevision, isNull);
        expect(staged.changeKind, 'added');
        expect(staged.reviewRevision, isNull);
        final before = await fixture.state();
        await expectLater(
          fixture.mutateFile(_untrustedFileSelection('new.txt')),
          throwsA(_failureCode(['unsupported_target'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
        await fixture.mutateFile(_fileSelection(staged), staged: true);
        await fixture.expectIndexPresence(before, 'new.txt', null);
        expect(fixture.processes.writes, hasLength(1));
        final refreshed = await fixture.changed(path: 'new.txt');
        expect(refreshed.changeKind, 'added');
        expect(refreshed.hunks.isEmpty, workingText.isEmpty);
        if (workingText.isNotEmpty) {
          expect(refreshed.hunks.single.lines.map((line) => line.text), [
            'working C',
          ]);
        }
        expect(refreshed.fileReviewRevision, isNotNull);
      },
    );
  }

  for (final bound in ['inventory', 'stdout']) {
    test(
      'new-file nested approval reserves $bound growth before writing',
      () async {
        await fixture.write('selected/new.txt', 'new text\n');
        fixture.processes.root = Directory(
          '${fixture.repository.path}/selected',
        );
        final selection = _fileSelection(
          await fixture.changed(path: 'new.txt'),
        );
        final raw = await fixture.gitBytes([
          'ls-files',
          '--cached',
          '--stage',
          '--debug',
          '-z',
        ]);
        final limits = bound == 'inventory'
            ? const GitPortableUnstagedLimits(inventoryEntries: 2)
            : GitPortableUnstagedLimits(outputBytes: raw.length + 10);
        final before = await fixture.state();
        await expectLater(
          fixture.mutateFile(selection, limits: limits),
          throwsA(_failureCode(['unsupported_target', 'inspection_failed'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
      },
    );
  }

  for (final staged in [false, true]) {
    for (final deletion in [false, true]) {
      test(
        '${deletion ? 'deletion' : 'new-file'} ${_direction(staged)} preserves exact outside-source flags stat and conflict records',
        () async {
          const path = 'selected/project/new.txt';
          const text = 'selected new text\n';
          const inventory = ['ls-files', '--stage', '--debug', '-z'];
          if (deletion) {
            await fixture.write('removed.txt', 'unrelated HEAD entry\n');
            await fixture.deleteTracked(
              path: path,
              original: text,
              staged: staged,
            );
            await fixture.git([
              'update-index',
              '--force-remove',
              '--',
              'removed.txt',
            ]);
            await fixture.write('added.txt', 'unrelated index addition\n');
            await fixture.git(['add', '--', 'added.txt']);
            await fixture.write('added.txt', 'unrelated working addition\n');
          } else {
            await fixture.write(path, text);
            if (staged) await fixture.git(['add', '--', path]);
          }
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
            'unrelated assume-unchanged working bytes\n',
          );
          await fixture.write(
            'other.txt',
            'unrelated skip-worktree working bytes\n',
          );
          await fixture.write('conflict.txt', 'unresolved working bytes\n');
          final conflictOids = <String>[];
          for (final side in ['base', 'ours', 'theirs']) {
            conflictOids.add(
              (await fixture.git([
                'hash-object',
                '-w',
                '--stdin',
              ], input: '$side\n')).trim(),
            );
          }
          await fixture.git(
            ['update-index', '--index-info'],
            input: [
              for (var stage = 1; stage <= 3; stage++)
                '${stage == 2 ? '100755' : '100644'} ${conflictOids[stage - 1]} $stage\tconflict.txt\n',
            ].join(),
          );
          expect(
            await fixture.git([
              'ls-files',
              '-v',
              '-z',
              '--',
              'tracked.txt',
              'other.txt',
            ]),
            'S other.txt\x00h tracked.txt\x00',
          );
          fixture.processes.root = Directory(
            '${fixture.repository.path}/selected/project',
          );
          final before = await fixture.state();
          final rawBefore = await fixture.gitBytes(inventory);
          final selectedBefore = await fixture.gitBytes([
            ...inventory,
            '--',
            path,
          ]);
          final presentBefore = deletion ? !staged : staged;
          expect(selectedBefore.isNotEmpty, presentBefore);
          for (final name in ['tracked', 'other']) {
            expect(
              String.fromCharCodes(rawBefore),
              contains(
                RegExp('\\t$name\\.txt\\x00  ctime: [1-9][0-9]*:[0-9]+\\n'),
              ),
              reason:
                  'unrelated entries retain populated stat metadata, not zero fixtures',
            );
          }
          for (var stage = 1; stage <= 3; stage++) {
            expect(before.oids['$stage:conflict.txt'], conflictOids[stage - 1]);
          }
          final records = before.oids.length;
          expect(records, (presentBefore ? 6 : 5) + (deletion ? 1 : 0));
          await expectLater(
            fixture
                .snapshotsWith(
                  GitPortableUnstagedLimits(inventoryEntries: records - 1),
                )
                .snapshotUncommitted(),
            throwsA(
              isA<ChangeSetFailure>().having(
                (failure) => failure.code,
                'code',
                'inventory_too_large',
              ),
            ),
          );
          final layers = await fixture
              .snapshotsWith(
                GitPortableUnstagedLimits(
                  inventoryEntries: records + (presentBefore ? 0 : 1),
                ),
              )
              .snapshotUncommitted();
          expect(
            layers.conflicts,
            isEmpty,
            reason: 'conflicts are outside the selected source',
          );
          final file = (staged ? layers.staged : layers.unstaged).files.single;
          expect(file.relativePath, 'new.txt');
          fixture.processes.requests.clear();

          await fixture.mutateFile(_fileSelection(file), staged: staged);

          await fixture.expectIndexPresence(
            before,
            path,
            presentBefore ? null : text,
          );
          _checkedFilePatch(fixture, staged: staged);
          final rawAfter = await fixture.gitBytes(inventory);
          final selectedAfter = await fixture.gitBytes([
            ...inventory,
            '--',
            path,
          ]);
          expect(selectedAfter.isNotEmpty, !presentBefore);
          List<int> withoutSelected(List<int> raw, List<int> selected) {
            if (selected.isEmpty) return raw;
            // One code unit per byte keeps offsets exact without decoding paths or
            // reusing the production index parser/record-preservation helper.
            final all = String.fromCharCodes(raw);
            final record = String.fromCharCodes(selected);
            final start = all.indexOf(record);
            expect(start, greaterThanOrEqualTo(0));
            expect(all.indexOf(record, start + 1), -1);
            return [...raw.take(start), ...raw.skip(start + selected.length)];
          }

          expect(
            withoutSelected(rawAfter, selectedAfter),
            orderedEquals(withoutSelected(rawBefore, selectedBefore)),
            reason:
                'every unrelated mode, OID, stage, flag and stat byte is unchanged',
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
      '\ufeffnew.txt',
    ]) {
      test(
        'new-file ${_direction(staged)} nested literal ${jsonEncode(name)}',
        () async {
          final path = 'selected/project/$name';
          await fixture.write(path, 'new contents\n');
          if (staged) {
            await fixture.git(['--literal-pathspecs', 'add', '--', path]);
          }
          await fixture.write('other.txt', 'outside staged\n');
          await fixture.git(['add', '--', 'other.txt']);
          await fixture.write('other.txt', 'outside working\n');
          fixture.processes.root = Directory(
            '${fixture.repository.path}/selected/project',
          );
          final file = await fixture.changed(path: name, staged: staged);
          final before = await fixture.state();
          await fixture.mutateFile(_fileSelection(file), staged: staged);
          await fixture.expectIndexPresence(
            before,
            path,
            staged ? null : 'new contents\n',
          );
          expect(fixture.processes.writes, hasLength(1));
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

    for (final kind in [
      'ignored',
      'intent-to-add',
      'HEAD staged-delete recreation',
      'HEAD ancestor',
      'HEAD descendant',
      if (!staged) ...['index ancestor', 'index descendant'],
      'symlink',
      'symlink parent',
      'nested repository',
      'binary',
      'invalid UTF-8',
      'oversized',
      'tab path',
      'newline path',
      'conflict',
      if (staged) ...[
        'working mode mismatch',
        'working missing',
        'later working binary',
        'later working invalid UTF-8',
        'later working oversized',
      ],
    ]) {
      test('new-file ${_direction(staged)} excludes $kind', () async {
        var path = 'new.txt';
        if (kind.endsWith('ancestor')) path = 'parent/new.txt';
        if (kind.endsWith('descendant')) path = 'parent';
        if (kind == 'symlink parent' || kind == 'nested repository') {
          path = 'parent/new.txt';
        }
        if (kind == 'tab path') path = 'new\tname';
        if (kind == 'newline path') path = 'new\nname';
        if (kind.endsWith('ancestor') || kind.endsWith('descendant')) {
          final collision = kind.endsWith('ancestor')
              ? 'parent'
              : 'parent/old.txt';
          await fixture.write(collision, 'collision\n');
          await fixture.git(['add', '--', collision]);
          if (kind.startsWith('HEAD')) {
            await fixture.git(['commit', '-m', 'Collision fixture']);
            await fixture.git(['rm', '--cached', '--', collision]);
          }
          if (kind.endsWith('ancestor')) {
            await File('${fixture.repository.path}/parent').delete();
          } else {
            await Directory(
              '${fixture.repository.path}/parent',
            ).delete(recursive: true);
          }
        }
        if (kind == 'HEAD staged-delete recreation') {
          await fixture.write(path, 'HEAD original\n');
          await fixture.commit();
          await fixture.git(['rm', '--cached', '--', path]);
        }
        await fixture.write(
          path,
          kind == 'oversized' ? 'x' * 100 : 'new text\n',
        );
        if (kind == 'binary' || kind == 'invalid UTF-8') {
          await File(
            '${fixture.repository.path}/$path',
          ).writeAsBytes(kind == 'binary' ? [1, 0, 2] : [255, 254, 10]);
        }
        if (kind == 'symlink') {
          await File('${fixture.repository.path}/$path').delete();
          await Link('${fixture.repository.path}/$path').create('tracked.txt');
        }
        if (kind == 'intent-to-add') {
          await fixture.git(['add', '--intent-to-add', '--', path]);
        } else if (staged && kind != 'HEAD staged-delete recreation') {
          await fixture.git(['add', '--', path]);
        }
        switch (kind) {
          case 'ignored':
            await fixture.write('.git/info/exclude', '$path\n');
          case 'symlink parent':
            await Directory(
              '${fixture.repository.path}/parent',
            ).rename('${fixture.repository.path}/real-parent');
            await Link(
              '${fixture.repository.path}/parent',
            ).create('real-parent');
          case 'nested repository':
            await fixture.git([
              '-C',
              '${fixture.repository.path}/parent',
              'init',
            ]);
          case 'working mode mismatch':
            await _command('/usr/bin/chmod', [
              '755',
              '${fixture.repository.path}/$path',
            ]);
          case 'working missing':
            await File('${fixture.repository.path}/$path').delete();
          case 'later working binary':
            await File(
              '${fixture.repository.path}/$path',
            ).writeAsBytes([1, 0, 2]);
          case 'later working invalid UTF-8':
            await File(
              '${fixture.repository.path}/$path',
            ).writeAsBytes([255, 254, 10]);
          case 'later working oversized':
            await fixture.write(path, 'x' * 100);
          case 'conflict':
            final oid = (await fixture.git([
              'hash-object',
              '-w',
              '--no-filters',
              '--',
              path,
            ])).trim();
            await fixture.git(
              ['update-index', '--index-info'],
              input:
                  '0 ${'0' * oid.length}\t$path\n100644 $oid 1\t$path\n100644 $oid 2\t$path\n100644 $oid 3\t$path\n',
            );
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
        await expectLater(
          fixture.mutateFile(
            _untrustedFileSelection(path),
            staged: staged,
            limits: limits,
          ),
          throwsA(_failureCode(['unsupported_target', 'stale_selection'])),
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
        'new-file ${_direction(staged)} excludes conversion $rule',
        () async {
          await fixture.write('new.txt', 'new\r\n');
          if (staged) await fixture.git(['add', '--', 'new.txt']);
          if (rule.startsWith('config')) {
            await fixture.git([
              'config',
              'core.${rule.split(' ').last}',
              rule.endsWith('autocrlf') ? 'true' : 'crlf',
            ]);
          } else {
            await fixture.write('.git/info/attributes', 'new.txt $rule\n');
          }
          final before = await fixture.state();
          final file = await fixture.changed(path: 'new.txt', staged: staged);
          expect(file.reviewRevision, isNull);
          expect(file.fileReviewRevision, isNull);
          await expectLater(
            fixture.mutateFile(
              _untrustedFileSelection('new.txt'),
              staged: staged,
            ),
            throwsA(_failureCode(['unsupported_target'])),
          );
          expect(fixture.processes.writes, isEmpty);
          await fixture.expectUnchanged(before);
        },
      );
    }

    for (final mutation in [
      'working bytes',
      'working mode',
      'index changed',
      'unrelated index',
      'HEAD',
      'Session',
      'Environment',
      'configuration',
      'attributes',
      'ignored after display',
      'nested repository after display',
    ]) {
      test('new-file ${_direction(staged)} rejects stale $mutation', () async {
        const path = 'parent/new.txt';
        await fixture.write(path, 'displayed\n');
        if (staged) await fixture.git(['add', '--', path]);
        final selection = _fileSelection(
          await fixture.changed(path: path, staged: staged),
        );
        switch (mutation) {
          case 'working bytes':
            await fixture.write(path, 'changed\n');
          case 'working mode':
            await _command('/usr/bin/chmod', [
              '755',
              '${fixture.repository.path}/$path',
            ]);
          case 'index changed':
            if (staged) {
              await fixture.git(['rm', '--cached', '--', path]);
            } else {
              await fixture.git(['add', '--', path]);
            }
          case 'unrelated index':
            await fixture.write('other.txt', 'external staged\n');
            await fixture.git(['add', '--', 'other.txt']);
          case 'HEAD':
            await fixture.git(['checkout', '-b', 'changed-branch']);
          case 'Session':
            fixture.processes.sessionId = 'other-session';
          case 'Environment':
            fixture.processes.environmentId = 'other-environment';
          case 'configuration':
            await fixture.git(['config', 'core.filemode', 'false']);
          case 'attributes':
            await fixture.write('.git/info/attributes', '$path -text\n');
          case 'ignored after display':
            await fixture.write('.git/info/exclude', '$path\n');
          case 'nested repository after display':
            await fixture.git([
              '-C',
              '${fixture.repository.path}/parent',
              'init',
            ]);
        }
        final before = await fixture.state();
        await expectLater(
          fixture.mutateFile(selection, staged: staged),
          throwsA(_failureCode(['unsupported_target', 'stale_selection'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
        if (mutation == 'Session' || mutation == 'Environment') {
          final fresh = _fileSelection(
            await fixture.changed(path: path, staged: staged),
          );
          expect(fresh.expectedRevision, isNot(selection.expectedRevision));
          await fixture.mutateFile(fresh, staged: staged);
          await fixture.expectIndexPresence(
            before,
            path,
            staged ? null : 'displayed\n',
          );
          expect(fixture.processes.writes, hasLength(1));
        }
      });
    }

    for (final loss in [
      'lock',
      'response lost',
      'process timeout',
      'revoked before check',
      'revoked after check',
      'revoked after apply',
    ]) {
      test(
        'new-file ${_direction(staged)} $loss has truthful effect',
        () async {
          await fixture.write('new.txt', 'new text\n');
          if (staged) await fixture.git(['add', '--', 'new.txt']);
          final selection = _fileSelection(
            await fixture.changed(path: 'new.txt', staged: staged),
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
            if (_isWrite(request) && loss == 'lock') {
              await fixture.write('.git/index.lock', 'external lock owner\n');
            }
            final result = await run(request);
            if (loss == 'revoked after check' &&
                request.arguments.contains('apply') &&
                request.arguments.contains('--check')) {
              revoked = true;
            }
            if (_isWrite(request) && loss != 'lock') {
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
              loss == 'revoked before check' || loss == 'revoked after check';
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(
              _failureCode([
                loss == 'lock'
                    ? 'mutation_failed'
                    : prewrite
                    ? 'inspection_failed'
                    : 'outcome_uncertain',
              ]),
            ),
          );
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
              'new.txt',
              staged ? null : 'new text\n',
            );
          }
        },
      );
    }

    for (final boundary in ['after check', 'at write', 'after apply']) {
      test(
        'new-file ${_direction(staged)} external writer $boundary never retries',
        () async {
          await fixture.write('new.txt', 'new text\n');
          if (staged) await fixture.git(['add', '--', 'new.txt']);
          final selection = _fileSelection(
            await fixture.changed(path: 'new.txt', staged: staged),
          );
          _State? external;
          Future<void> changeIndex() async {
            expect(external, isNull, reason: 'no retry');
            if (boundary == 'after apply') {
              await fixture.write('other.txt', 'external staged\n');
              await fixture.git(['add', '--', 'other.txt']);
            } else if (staged) {
              await fixture.git(['rm', '--cached', '--', 'new.txt']);
            } else {
              await fixture.git(['add', '--', 'new.txt']);
            }
            external = await fixture.state();
          }

          fixture.processes.intercept = (request, run) async {
            if (boundary == 'at write' && _isWrite(request)) {
              await changeIndex();
            }
            final result = await run(request);
            if (boundary == 'after check' &&
                    request.arguments.contains('apply') &&
                    request.arguments.contains('--check') ||
                boundary == 'after apply' && _isWrite(request)) {
              await changeIndex();
            }
            return result;
          };
          await expectLater(
            fixture.mutateFile(selection, staged: staged),
            throwsA(
              _failureCode([
                boundary == 'after check'
                    ? 'stale_selection'
                    : 'outcome_uncertain',
              ]),
            ),
          );
          expect(external, isNotNull);
          await fixture.expectUnchanged(external!);
          expect(
            fixture.processes.writes,
            hasLength(boundary == 'after check' ? 0 : 1),
          );
        },
      );
    }

    test(
      'new-file ${_direction(staged)} concurrent duplicates have one effect',
      () async {
        await fixture.write('new.txt', 'new text\n');
        if (staged) await fixture.git(['add', '--', 'new.txt']);
        final selection = _fileSelection(
          await fixture.changed(path: 'new.txt', staged: staged),
        );
        final before = await fixture.state();
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
          _failureCode([
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
          'new.txt',
          staged ? null : 'new text\n',
        );
      },
    );

    test(
      'new-file ${_direction(staged)} process count is independent of line count',
      () async {
        final counts = <int>[];
        for (final lines in [0, 1, 1000]) {
          final text = List.generate(lines, (i) => 'line $i\n').join();
          await fixture.git([
            'update-index',
            '--force-remove',
            '--',
            'new.txt',
          ]);
          await fixture.write('new.txt', text);
          if (staged) await fixture.git(['add', '--', 'new.txt']);
          final file = await fixture.changed(path: 'new.txt', staged: staged);
          final before = await fixture.state();
          fixture.processes.requests.clear();
          final watch = Stopwatch()..start();
          await fixture.mutateFile(_fileSelection(file), staged: staged);
          watch.stop();
          counts.add(fixture.processes.requests.length);
          print(
            'New-file ${_direction(staged)} performance: $lines lines, ${counts.last} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
          );
          expect(fixture.processes.writes, hasLength(1));
          expect(
            fixture.processes.requests.where(
              (r) => r.arguments.contains('apply'),
            ),
            hasLength(2),
          );
          await fixture.expectIndexPresence(
            before,
            'new.txt',
            staged ? null : text,
          );
        }
        expect(
          counts[1],
          counts[2],
          reason:
              'many-line text uses the same bounded process path as short text',
        );
        expect(counts.every((count) => count < 150), isTrue);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final format in ['sha1', 'sha256']) {
    for (final staged in [false, true]) {
      test(
        'file ${_direction(staged)} atomically handles shifting partial layers ($format)',
        () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await _Fixture.create(format: format);
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

          await fixture.mutateFile(_fileSelection(file), staged: staged);

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
            'File ${_direction(staged)} proof ($format): HEAD=${before.head.trim()} -> ${after.head.trim()}; '
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
            fixture.mutateFile(_fileSelection(file), staged: staged),
            throwsA(_failureCode(['stale_selection'])),
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
        test('file ${_direction(staged)} exact $name ($format)', () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await _Fixture.create(format: format);
          }
          await fixture.write('tracked.txt', original);
          await fixture.commit();
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          final before = await fixture.state();
          await fixture.mutateFile(_fileSelection(file), staged: staged);
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
          await _command('/usr/bin/chmod', [
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
          fixture.mutateFile(_untrustedFileSelection(path)),
          throwsA(_failureCode(['unsupported_target'])),
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
      await fixture.write('tracked.txt', _text({2: 'first', 35: 'last'}));
      final file = await fixture.changed();
      final before = await fixture.state();
      await expectLater(
        fixture.mutateFile(_fileSelection(file), limits: limits),
        throwsA(_failureCode(['inspection_failed'])),
      );
      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    });
  }

  for (final target in [
    'modified',
    'new text',
    'new empty',
    'deleted text',
    'deleted empty',
    'whole-layer',
  ]) {
    test(
      'file review $target does not execute hostile configured helpers',
      () async {
        final deletion = target.startsWith('deleted');
        final wholeLayer = target == 'whole-layer';
        final changes = wholeLayer
            ? await fixture.layerChanges(mixed: true)
            : null;
        if (deletion) {
          await fixture.deleteTracked(
            original: target == 'deleted empty' ? '' : '\ufeffHEAD\r\nlast  ',
          );
        }
        final helpers = <String, String>{};
        for (final name in [
          'clean',
          'process',
          'textconv',
          'external',
          'fsmonitor',
          'post-index-change',
        ]) {
          final helper = File('${fixture.container.path}/$name');
          await helper.writeAsString(
            '#!/bin/sh\nprintf executed > "${fixture.container.path}/$name.executed"\nexit 99\n',
          );
          await _command('/usr/bin/chmod', ['+x', helper.path]);
          helpers[name] = helper.path;
        }
        for (final (key, value) in [
          ('filter.clean.clean', helpers['clean']!),
          ('filter.clean.required', 'true'),
          ('filter.process.process', helpers['process']!),
          ('filter.process.required', 'true'),
          ('diff.hostile.textconv', helpers['textconv']!),
          ('diff.hostile.command', helpers['external']!),
          ('diff.external', helpers['external']!),
          ('core.fsmonitor', helpers['fsmonitor']!),
          ('core.hooksPath', fixture.container.path),
          ('apply.whitespace', 'fix'),
          ('apply.ignoreWhitespace', 'true'),
        ]) {
          await fixture.git(['config', key, value]);
        }
        final path = target == 'modified' || deletion
            ? 'tracked.txt'
            : 'new.txt';
        final text = target == 'new empty'
            ? ''
            : _text({2: 'first  ', 35: 'last\t'});
        if (!deletion && !wholeLayer) await fixture.write(path, text);
        for (final staged in [false, true]) {
          final layer = await fixture.layer(staged: staged);
          final before = await fixture.state();
          if (wholeLayer) {
            await fixture.mutateLayer(_layerSelection(layer), staged: staged);
            await fixture.expectIndexChanges(
              before,
              staged ? changes!.head : changes!.working,
            );
          } else {
            await fixture.mutateFile(
              _fileSelection(
                layer.files.singleWhere((file) => file.relativePath == path),
              ),
              staged: staged,
            );
          }
          if (deletion) {
            await fixture.expectIndexPresence(
              before,
              path,
              staged
                  ? (target == 'deleted empty' ? '' : '\ufeffHEAD\r\nlast  ')
                  : null,
            );
            expect(
              await FileSystemEntity.type(
                '${fixture.repository.path}/$path',
                followLinks: false,
              ),
              FileSystemEntityType.notFound,
            );
          } else if (!wholeLayer) {
            expect(
              await File('${fixture.repository.path}/$path').readAsBytes(),
              utf8.encode(text),
            );
          }
          expect(fixture.processes.writes, hasLength(staged ? 2 : 1));
          for (final name in helpers.keys) {
            expect(
              await File('${fixture.container.path}/$name.executed').exists(),
              isFalse,
            );
          }
        }
        if (wholeLayer) {
          for (final rule in [
            'filter=clean',
            'filter=process',
            'diff=hostile',
          ]) {
            await fixture.write('.git/info/attributes', 'tracked.txt $rule\n');
            final before = await fixture.state();
            expect((await fixture.layer()).layerReviewRevision, isNull);
            await expectLater(
              fixture.mutateLayer(_untrustedLayerSelection()),
              throwsA(_failureCode(['unsupported_target'])),
            );
            await fixture.expectUnchanged(before);
            expect(fixture.processes.writes, hasLength(2));
          }
          for (final entry in helpers.entries) {
            final marker = File(
              '${fixture.container.path}/${entry.key}.executed',
            );
            expect(await marker.exists(), isFalse);
            final control = await Process.run(entry.value, const <String>[]);
            expect(control.exitCode, 99);
            expect(await marker.readAsString(), 'executed');
          }
        }
        // Executable positive controls for every helper are maintained in the shared
        // full-patch feasibility test, including hostile conversion attributes.
      },
    );
  }

  for (final staged in [false, true]) {
    test(
      'file ${_direction(staged)} preserves outside-source index records and literal paths',
      () async {
        const name = 'selected/project/-literal [x] \\ "\u00e9".txt';
        await fixture.write(name, _text());
        await fixture.commit();
        await fixture.write(name, _text({2: 'first', 35: 'last'}));
        await fixture.write('other.txt', 'outside staged\n');
        await fixture.git(['add', '--', 'other.txt', if (staged) name]);
        await fixture.write('other.txt', 'outside working\n');
        fixture.processes.root = Directory(
          '${fixture.repository.path}/selected/project',
        );
        final file = (await fixture.layer(staged: staged)).files.single;
        final before = await fixture.state();
        await fixture.mutateFile(_fileSelection(file), staged: staged);
        await fixture.expectIndexChange(
          before,
          name,
          staged ? _text() : _text({2: 'first', 35: 'last'}),
        );
        expect(fixture.processes.writes, hasLength(1));
      },
    );

    test(
      'file ${_direction(staged)} aggregate stdin eligibility preserves hunk revisions',
      () async {
        final oldLine = '\u00e9' * 140000;
        final newLine = '\u00f8' * 140000;
        final original = _text({2: oldLine, 35: oldLine});
        final modified = _text({2: newLine, 35: newLine});
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
            _untrustedFileSelection('tracked.txt'),
            staged: staged,
          ),
          throwsA(_failureCode(['unsupported_target'])),
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
        'file ${_direction(staged)} $loss preserves truthful outcome',
        () async {
          final modified = _text({2: 'first', 35: 'last'});
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final selection = _fileSelection(
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
            if (_isWrite(request) && loss == 'lock') {
              await fixture.write('.git/index.lock', 'external lock\n');
            }
            final result = await run(request);
            if (_isWrite(request) && loss != 'lock') {
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
              _failureCode([
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
              staged ? _text() : modified,
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
        await fixture.write('selected/tracked.txt', _text());
        await fixture.commit();
        await fixture.write(
          'selected/tracked.txt',
          _text({2: 'first', 35: 'last'}),
        );
        fixture.processes.root = Directory(
          '${fixture.repository.path}/selected',
        );
        final selection = _fileSelection((await fixture.layer()).files.single);
        _State? external;
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
                  boundary == 'after apply' && _isWrite(request))) {
            await changeOutside();
          }
          return result;
        };
        await expectLater(
          fixture.mutateFile(selection),
          throwsA(
            _failureCode([
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
      'file ${_direction(staged)} process count does not scale with hunk count',
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
          await fixture.mutateFile(_fileSelection(file), staged: staged);
          watch.stop();
          counts.add(fixture.processes.requests.length);
          print(
            'File ${_direction(staged)} performance: $count hunks, ${counts.last} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
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
        expect(file.fileReviewRevision, isNotNull);

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
        await fixture.mutateFile(
          _fileSelection(file),
          staged: staged,
          limits: limits,
        );
        await fixture.expectIndexChange(
          before,
          'tracked.txt',
          staged ? original : modified,
        );
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
          expect(file.fileReviewRevision, isNull);
          final before = await fixture.state();
          await expectLater(
            fixture.mutate(_untrustedSelection(name), staged: staged),
            throwsA(_failureCode(['unsupported_target', 'invalid_selection'])),
          );
          await expectLater(
            fixture.mutateFile(_untrustedFileSelection(name), staged: staged),
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
        final fileSelectionA = _fileSelection(fileA);
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
        await expectLater(
          fixture.mutateFile(fileSelectionA, staged: staged),
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
      'configuration',
      'attributes',
    ]) {
      test(
        '${_direction(staged)} rejects stale $mutation before a write',
        () async {
          await fixture.write('tracked.txt', _text({2: 'selected edit'}));
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          final selection = _selection(file);
          final fileSelection = _fileSelection(file);
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
            case 'configuration':
              await fixture.git(['config', 'core.filemode', 'false']);
            case 'attributes':
              await fixture.write(
                '.git/info/attributes',
                'tracked.txt -text\n',
              );
          }
          final before = await fixture.state();

          await expectLater(
            fixture.mutate(selection, staged: staged),
            throwsA(_failureCode(['stale_selection', 'unsupported_target'])),
          );
          await expectLater(
            fixture.mutateFile(fileSelection, staged: staged),
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
        expect(
          files
              .singleWhere((file) => file.relativePath == path)
              .fileReviewRevision,
          kind == 'addition' || kind == 'deletion' ? isNotNull : isNull,
          reason:
              'complete additions and deletions are file-only; existing hunk exclusions remain',
        );

        await expectLater(
          fixture.mutate(
            _untrustedSelection(path),
            staged: staged,
            limits: limits,
          ),
          throwsA(_failureCode(['unsupported_target', 'stale_selection'])),
        );
        await expectLater(
          fixture.mutateFile(
            _untrustedFileSelection(path),
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
    await expectLater(
      fixture.mutateFile(_fileSelection(layers.staged.files.single)),
      throwsA(_failureCode(['stale_selection'])),
    );
    await expectLater(
      fixture.mutateFile(
        _fileSelection(layers.unstaged.files.single),
        staged: true,
      ),
      throwsA(_failureCode(['stale_selection'])),
    );
    final file = layers.unstaged.files.single;
    await expectLater(
      fixture.mutateFile(
        ReviewFileSelection(
          relativePath: file.relativePath,
          expectedRevision: file.reviewRevision!,
        ),
      ),
      throwsA(_failureCode(['stale_selection'])),
    );
    await expectLater(
      fixture.mutate(
        ReviewHunkSelection(
          relativePath: file.relativePath,
          hunkIndex: 0,
          expectedRevision: file.fileReviewRevision!,
        ),
      ),
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

  for (final wholeFile in [false, true]) {
    test(
      'concurrent duplicate ${wholeFile ? 'file' : 'hunk'} selections cannot both succeed or exceed selection',
      () async {
        await fixture.write(
          'tracked.txt',
          _text({2: 'selected edit', 35: 'not selected'}),
        );
        final file = await fixture.changed();
        final selection = _selection(file);
        final before = await fixture.state();
        final service = GitPortableReviewApprovalService(
          processes: fixture.processes,
        );
        Future<Object?> invoke() async {
          try {
            if (wholeFile) {
              await service.approveFile(_fileSelection(file));
            } else {
              await service.approveHunk(selection);
            }
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
          _text({2: 'selected edit', if (wholeFile) 35: 'not selected'}),
        );
      },
    );
  }

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

ReviewLayerSelection _layerSelection(ChangeSetSnapshot layer) {
  expect(
    layer.layerReviewRevision,
    isNotNull,
    reason: 'the entire layer must be actionable',
  );
  return ReviewLayerSelection(expectedRevision: layer.layerReviewRevision!);
}

ReviewLayerSelection _untrustedLayerSelection() => ReviewLayerSelection(
  expectedRevision: 'display-only-layer-has-no-review-revision',
);

ReviewFileSelection _fileSelection(ChangedFile file) {
  expect(
    file.fileReviewRevision,
    isNotNull,
    reason: '${file.relativePath} must be file-actionable',
  );
  return ReviewFileSelection(
    relativePath: file.relativePath,
    expectedRevision: file.fileReviewRevision!,
  );
}

ReviewFileSelection _untrustedFileSelection(String path) => ReviewFileSelection(
  relativePath: path,
  expectedRevision: 'display-only-entry-has-no-file-review-revision',
);

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

String _checkedFilePatch(_Fixture fixture, {required bool staged}) {
  final applies = fixture.processes.requests
      .where((request) => request.arguments.contains('apply'))
      .toList();
  expect(applies, hasLength(2));
  expect(applies.first.arguments, contains('--check'));
  expect(applies.last.arguments, isNot(contains('--check')));
  for (final request in applies) {
    expect(request.arguments, contains('--cached'));
    expect(request.arguments.contains('--reverse'), staged);
  }
  expect(applies.first.stdinBase64, applies.last.stdinBase64);
  expect(fixture.processes.writes, hasLength(1));
  expect(
    fixture.processes.requests.any(
      (request) => request.arguments.any(
        ['add', 'rm', 'reset', 'checkout', 'update-index'].contains,
      ),
    ),
    isFalse,
  );
  return utf8.decode(base64Decode(applies.last.stdinBase64));
}

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

  Future<void> mutateFile(
    ReviewFileSelection selection, {
    bool staged = false,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) {
    final service = GitPortableReviewApprovalService(
      processes: processes,
      limits: limits,
    );
    return staged
        ? service.unapproveFile(selection)
        : service.approveFile(selection);
  }

  Future<void> mutateLayer(
    ReviewLayerSelection selection, {
    bool staged = false,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) {
    final service = GitPortableReviewApprovalService(
      processes: processes,
      limits: limits,
    );
    return staged
        ? service.unapproveAllStaged(selection)
        : service.approveAllUnstaged(selection);
  }

  Future<({Map<String, String?> head, Map<String, String?> working})>
  layerChanges({bool staged = false, bool mixed = false, int count = 2}) async {
    final paths = [
      'tracked.txt',
      'other.txt',
      for (var i = 2; i < count; i++) 'file-$i.txt',
    ];
    final head = <String, String?>{
      for (var i = 0; i < paths.length; i++) paths[i]: _text({2: 'HEAD $i'}),
      if (mixed) ...{
        'deleted.txt': 'HEAD deleted\n',
        'empty-deleted.txt': '',
        'new.txt': null,
        'empty-new.txt': null,
      },
    };
    final working = <String, String?>{
      for (var i = 0; i < paths.length; i++)
        paths[i]: _text({2: 'working $i', 35: 'last $i'}),
      if (mixed) ...{
        'deleted.txt': null,
        'empty-deleted.txt': null,
        'new.txt': 'new text\n',
        'empty-new.txt': '',
      },
    };
    for (final entry in head.entries) {
      if (entry.value != null) await write(entry.key, entry.value!);
    }
    await commit();
    for (final entry in working.entries) {
      if (entry.value == null) {
        await File('${repository.path}/${entry.key}').delete();
      } else {
        await write(entry.key, entry.value!);
      }
    }
    if (staged) await git(['add', '--all']);
    return (head: head, working: working);
  }

  Future<void> write(String path, String text) async {
    final file = File('${repository.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<void> deleteTracked({
    String path = 'tracked.txt',
    String original = 'HEAD A\n',
    String? indexed,
    String mode = '100644',
    bool staged = false,
  }) async {
    await write(path, original);
    await _command('/usr/bin/chmod', [
      mode == '100755' ? '755' : '644',
      '${repository.path}/$path',
    ]);
    await commit();
    if (indexed != null && indexed != original) {
      await write(path, indexed);
      await git(['--literal-pathspecs', 'add', '--', path]);
    }
    await File('${repository.path}/$path').delete();
    if (staged) {
      await git([
        '--literal-pathspecs',
        'update-index',
        '--force-remove',
        '--',
        path,
      ]);
    }
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

  Future<void> makeConflict({String path = 'tracked.txt'}) async {
    final oid = (await git(['rev-parse', 'HEAD:$path'])).trim();
    await git(
      ['update-index', '--index-info'],
      input:
          '0 ${'0' * oid.length}\t$path\n'
          '100644 $oid 1\t$path\n'
          '100644 $oid 2\t$path\n'
          '100644 $oid 3\t$path\n',
    );
  }

  Future<_State> state() async {
    final indexBytes = await File(
      '${repository.path}/.git/index',
    ).readAsBytes();
    // Evidence collection must not execute the hostile helper under test.
    final listing = await git([
      '-c',
      'core.fsmonitor=false',
      'ls-files',
      '--stage',
      '-z',
    ]);
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
      blobs[key] = await gitBytes([
        'cat-file',
        match[1] == '160000' ? 'commit' : 'blob',
        match[2]!,
      ]);
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

  Future<_State> expectIndexPresence(
    _State before,
    String path,
    String? text, {
    String mode = '100644',
  }) => expectIndexChanges(before, {path: text}, mode: mode);

  Future<_State> expectIndexChanges(
    _State before,
    Map<String, String?> changes, {
    String mode = '100644',
  }) async {
    final after = await state();
    _expectWorkingAndHead(before, after);
    final records = before.listing.split('\x00')
      ..removeWhere(
        (record) =>
            record.isEmpty ||
            changes.keys.any((path) => record.endsWith('\t$path')),
      );
    final oids = {...before.oids};
    final blobs = {...before.blobs};
    for (final entry in changes.entries) {
      final path = entry.key;
      oids.remove('0:$path');
      blobs.remove('0:$path');
      if (entry.value == null) continue;
      final bytes = utf8.encode(entry.value!);
      final oid = (format == 'sha256' ? sha256 : sha1).convert([
        ...utf8.encode('blob ${bytes.length}\x00'),
        ...bytes,
      ]).toString();
      records.add('$mode $oid 0\t$path');
      oids['0:$path'] = oid;
      blobs['0:$path'] = bytes;
    }
    expect(after.indexBytes, isNot(equals(before.indexBytes)));
    expect(
      after.listing.split('\x00').where((record) => record.isNotEmpty),
      unorderedEquals(records),
      reason: 'only selected stage-0 entries may change membership or content',
    );
    expect(after.oids, oids);
    expect(after.blobs, blobs, reason: 'all exact index blob bytes');
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
