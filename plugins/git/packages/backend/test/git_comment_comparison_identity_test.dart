@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_environment/adele_environment.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart';
import 'package:test/test.dart';

import 'support/git_portable_review_approval_support.dart';

void main() {
  for (final format in ['sha1', 'sha256']) {
    test(
      '$format certifies all layers independently of approval and unrelated files',
      () async {
        final repo = await TestRepo.create(format: format);
        addTearDown(repo.close);
        final baseline = (await repo.git(['rev-parse', 'HEAD'])).trim();
        final oldOid = (await repo.git([
          'rev-parse',
          'HEAD:tracked.txt',
        ])).trim();
        await repo.write('tracked.txt', lines({2: 'committed'}));
        await repo.commit();
        final headOid = (await repo.git([
          'rev-parse',
          'HEAD:tracked.txt',
        ])).trim();
        await repo.write('tracked.txt', lines({2: 'committed', 15: 'staged'}));
        await repo.git(['add', '--', 'tracked.txt']);
        final indexOid = (await repo.git(['rev-parse', ':tracked.txt'])).trim();
        final working = lines({2: 'committed', 15: 'staged', 35: 'unstaged'});
        await repo.write('tracked.txt', working);
        final workingOid = _blobOid(format, working);
        final service = GitPortableUnstagedSnapshotService(
          processes: repo.processes,
          taskAnchor: GitTaskComparisonAnchor(
            baselineCommit: baseline,
            expectedBranchRef: 'refs/heads/main',
          ),
        );
        final snapshot = await service.snapshotTaskChanges();
        final layers = [
          snapshot.committed,
          snapshot.uncommitted.staged,
          snapshot.uncommitted.unstaged,
        ];
        final identities = layers
            .map((layer) => _identity(layer.files.single))
            .toList();
        expect(identities.toSet(), hasLength(3));
        expect(
          repo.processes.identityCalls,
          1,
          reason: 'comments and review share the captured association',
        );
        expect(snapshot.committed.files.single.reviewRevision, isNull);
        expect(snapshot.committed.files.single.fileReviewRevision, isNull);
        expect(snapshot.committed.layerReviewRevision, isNull);
        for (final (index, layer, oldSource, newSource, left, right) in [
          (0, 'committed', 'baseline', 'head', oldOid, headOid),
          (1, 'staged', 'head', 'index', headOid, indexOid),
          (2, 'unstaged', 'index', 'working', indexOid, workingOid),
        ]) {
          expect(left.length, format == 'sha256' ? 64 : 40);
          expect(
            identities[index],
            _expectedIdentity(
              repo,
              layers[index].files.single,
              layer,
              oldSource,
              newSource,
              left,
              right,
            ),
          );
        }
        final uncommitted = await service.snapshotUncommitted();
        expect(_identity(uncommitted.staged.files.single), identities[1]);
        expect(_identity(uncommitted.unstaged.files.single), identities[2]);
        expect(
          _identity((await service.snapshotUnstaged()).files.single),
          identities[2],
        );

        // A same-byte rewrite changes stat metadata, while the other-file commit
        // changes HEAD, tree and index identities but none of this file's sides.
        await repo.write('tracked.txt', working);
        await repo.write('other.txt', 'unrelated committed change\n');
        await repo.git([
          'commit',
          '--only',
          '-m',
          'Other file',
          '--',
          'other.txt',
        ]);
        await repo.write(
          'unrelated-untracked.txt',
          'not part of tracked.txt\n',
        );
        final refreshed = await service.snapshotTaskChanges();
        expect([
          _identity(_file(refreshed.committed, 'tracked.txt')),
          _identity(_file(refreshed.uncommitted.staged, 'tracked.txt')),
          _identity(_file(refreshed.uncommitted.unstaged, 'tracked.txt')),
        ], identities);
        expect(repo.processes.writes, isEmpty);
      },
    );

    test(
      '$format additions deletions partial additions and newline bytes',
      () async {
        final repo = await TestRepo.create(format: format);
        addTearDown(repo.close);
        await repo.write('deleted.txt', 'deleted\r\nlast deleted');
        await repo.write('empty-deleted.txt', '');
        await repo.write('recreated.txt', 'original\n');
        await repo.commit();
        await File('${repo.repository.path}/deleted.txt').delete();
        await File('${repo.repository.path}/empty-deleted.txt').delete();
        await File('${repo.repository.path}/recreated.txt').delete();
        await repo.write('added.txt', 'added\r\nlast added');
        await repo.write('empty-added.txt', '');
        await repo.git(['add', '--all']);
        await repo.write('added.txt', 'added\r\nlater working');
        await repo.write('recreated.txt', 'recreated\n');
        await repo.write('untracked.txt', 'untracked\r\nlast untracked');
        await repo.write('intent.txt', 'intent\n');
        await repo.git(['add', '--intent-to-add', '--', 'intent.txt']);
        final snapshot = await repo.snapshots.snapshotUncommitted();
        for (final path in ['deleted.txt', 'recreated.txt', 'added.txt']) {
          _identity(_file(snapshot.staged, path));
        }
        for (final path in [
          'added.txt',
          'recreated.txt',
          'untracked.txt',
          'intent.txt',
        ]) {
          _identity(_file(snapshot.unstaged, path));
        }
        for (final path in ['empty-deleted.txt', 'empty-added.txt']) {
          final file = _file(snapshot.staged, path);
          expect(file.contentStatus, 'text');
          expect(file.hunks, isEmpty);
          expect(file.commentComparisonIdentity, isNull);
        }
        final partial = _file(snapshot.unstaged, 'added.txt');
        expect(
          partial.fileReviewRevision,
          isNull,
          reason: 'further edits of a staged addition are still commentable',
        );
        expect(
          _identity(partial),
          isNot(_identity(_file(snapshot.staged, 'added.txt'))),
        );
        final deletion = _file(snapshot.staged, 'deleted.txt');
        expect(
          deletion.hunks.single.lines.map(
            (line) => (line.kind, line.text, line.noNewline),
          ),
          [
            ('deletion', 'deleted\r', false),
            ('deletion', 'last deleted', true),
          ],
        );
        final before = _identity(_file(snapshot.unstaged, 'untracked.txt'));
        await repo.write('untracked.txt', 'untracked\r\nlast untracked\n');
        final withNewline = _identity(
          await repo.changed(path: 'untracked.txt'),
        );
        expect(withNewline, isNot(before));
        await repo.write('untracked.txt', 'untracked\nlast untracked\n');
        expect(
          _identity(await repo.changed(path: 'untracked.txt')),
          isNot(withNewline),
        );
        expect(repo.processes.writes, isEmpty);
      },
    );
  }

  test(
    'captured Session and Environment associations never share identities',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      await repo.write('tracked.txt', lines({2: 'changed'}));
      final original = _identity(await repo.changed());
      repo.processes.environmentId = 'other-environment';
      final otherEnvironment = _identity(await repo.changed());
      expect(otherEnvironment, isNot(original));
      repo.processes.environmentId = 'selected-review-environment';
      repo.processes.sessionId = 'other-session';
      final otherSession = _identity(await repo.changed());
      expect(otherSession, isNot(original));
      expect(otherSession, isNot(otherEnvironment));
      repo.processes.sessionId = 'review-session';
      expect(_identity(await repo.changed()), original);
    },
  );

  test(
    'repository and nested source scopes bind otherwise identical comparisons',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      await repo.write('nested/tracked.txt', lines());
      await repo.commit();
      await repo.write('tracked.txt', lines({2: 'changed'}));
      await repo.write('nested/tracked.txt', lines({2: 'changed'}));
      final root = _identity(await repo.changed());
      final nestedPath = _identity(
        await repo.changed(path: 'nested/tracked.txt'),
      );
      expect(nestedPath, isNot(root), reason: 'literal path is identity');
      repo.processes.root = Directory('${repo.repository.path}/nested');
      final nested = _identity(await repo.changed());
      expect(nested, isNot(root), reason: 'source scope is identity');
      expect(nested, isNot(nestedPath));
      final other = await TestRepo.create();
      addTearDown(other.close);
      await other.write('tracked.txt', lines({2: 'changed'}));
      expect(
        _identity(await other.changed()),
        isNot(root),
        reason: 'repository scope is identity',
      );
    },
  );

  test(
    'special literal paths remain distinct including approval-ineligible names',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      final paths = [
        "dir/space 'quote' \u03bb.txt",
        '-leading',
        ':(glob)*',
        'tab\tline\nfile',
      ];
      for (final path in paths) {
        await repo.write(path, 'old\r\nlast old');
      }
      await repo.commit();
      for (final path in paths) {
        await repo.write(path, 'new\r\nlast new');
      }
      final snapshot = await repo.snapshots.snapshotUnstaged();
      expect(
        snapshot.files.map((file) => file.relativePath),
        unorderedEquals(paths),
      );
      expect(snapshot.files.map(_identity).toSet(), hasLength(paths.length));
      final controlPath = _file(snapshot, paths.last);
      expect(controlPath.reviewRevision, isNull);
      expect(controlPath.fileReviewRevision, isNull);
      expect(controlPath.hunks.single.lines.last.noNewline, isTrue);
      final again = await repo.snapshots.snapshotUnstaged();
      expect(again.files.map(_identity), snapshot.files.map(_identity));
    },
  );

  test(
    'unsafe unsupported binary oversized conflict and no-line entries stay uncertified',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      for (final path in [
        'binary',
        'invalid',
        'oversized',
        'mode',
        'flagged',
        'link',
        'converted',
        'conflict',
        r'back\slash',
        'C:drive',
        'empty-deleted',
      ]) {
        await repo.write(path, path == 'empty-deleted' ? '' : 'old\n');
      }
      await repo.commit();
      await File('${repo.repository.path}/binary').writeAsBytes([0, 1]);
      await File('${repo.repository.path}/invalid').writeAsBytes([255]);
      await repo.write('oversized', 'x' * 17);
      await runLocal('/usr/bin/chmod', ['755', '${repo.repository.path}/mode']);
      await repo.git(['update-index', '--assume-unchanged', '--', 'flagged']);
      await File('${repo.repository.path}/link').delete();
      await Link('${repo.repository.path}/link').create('tracked.txt');
      await repo.write('converted', 'new\n');
      await repo.write('.gitattributes', 'converted text\n');
      await repo.makeConflict(path: 'conflict');
      await repo.write(r'back\slash', 'new\n');
      await repo.write('C:drive', 'new\n');
      await File('${repo.repository.path}/empty-deleted').delete();
      await repo.write('empty-added', '');
      final snapshot = await repo
          .snapshotsWith(const GitPortableUnstagedLimits(fileBytes: 16))
          .snapshotUncommitted();
      final files = {
        ...{
          for (final file in snapshot.unstaged.files) file.relativePath: file,
        },
        ...{for (final file in snapshot.conflicts) file.relativePath: file},
      };
      for (final path in [
        'binary',
        'invalid',
        'oversized',
        'mode',
        'flagged',
        'link',
        'converted',
        'conflict',
        r'back\slash',
        'C:drive',
        'empty-deleted',
        'empty-added',
      ]) {
        expect(files.containsKey(path), isTrue, reason: path);
        expect(files[path]!.commentComparisonIdentity, isNull, reason: path);
      }
      expect(files['binary']!.contentStatus, 'binary');
      expect(files['oversized']!.contentStatus, 'oversized');
      expect(files['conflict']!.contentStatus, 'conflicted');
      expect(files[r'back\slash']!.contentStatus, 'text');
      expect(files['C:drive']!.contentStatus, 'text');
    },
  );

  test(
    'unstaged deletion requires observed safe absence but not approval',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      await repo.write('parent/deleted.txt', 'old\n');
      await File('${repo.repository.path}/other.txt').writeAsBytes([0, 1]);
      await repo.commit();
      await repo.write('other.txt', 'index text\n');
      await repo.git(['add', '--', 'other.txt']);
      await File('${repo.repository.path}/other.txt').delete();
      await File('${repo.repository.path}/parent/deleted.txt').delete();
      final safe = await repo.snapshots.snapshotUnstaged();
      _identity(_file(safe, 'parent/deleted.txt'));
      final noApproval = _file(safe, 'other.txt');
      expect(
        noApproval.fileReviewRevision,
        isNull,
        reason: 'HEAD is binary but the displayed index side is verified text',
      );
      _identity(noApproval);

      await repo.git(['-C', 'parent', 'init', '--initial-branch=main']);
      final unsafe = await repo.changed(path: 'parent/deleted.txt');
      expect(unsafe.contentStatus, 'text');
      expect(unsafe.commentComparisonIdentity, isNull);
      expect(unsafe.fileReviewRevision, isNull);
      // Removing the index entry certifies a different immutable comparison; the
      // unsafe current working path is not either side of the staged deletion.
      await repo.git([
        'update-index',
        '--force-remove',
        '--',
        'parent/deleted.txt',
      ]);
      _identity(await repo.changed(path: 'parent/deleted.txt', staged: true));
    },
  );

  test(
    'committed text remains certified despite working conflicts and conversion attributes',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      final baseline = (await repo.git(['rev-parse', 'HEAD'])).trim();
      await repo.write('tracked.txt', lines({2: 'committed'}));
      await repo.commit();
      await repo.makeConflict();
      await repo.write('.gitattributes', 'tracked.txt filter=unsafe text\n');
      final snapshot = await GitPortableUnstagedSnapshotService(
        processes: repo.processes,
        taskAnchor: GitTaskComparisonAnchor(
          baselineCommit: baseline,
          expectedBranchRef: 'refs/heads/main',
        ),
      ).snapshotTaskChanges();
      final committed = snapshot.committed.files.single;
      _identity(committed);
      expect(committed.reviewRevision, isNull);
      expect(committed.fileReviewRevision, isNull);
      expect(
        snapshot.uncommitted.conflicts.single.commentComparisonIdentity,
        isNull,
      );
    },
  );

  test(
    'exact verified hunk layout contributes beyond source blob identities',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      await repo.write(
        'tracked.txt',
        lines({2: 'changed', 35: 'last changed'}),
      );
      final original = await repo.changed();
      repo.processes.intercept = (request, run) => run(
        EnvironmentBufferedProcessRequest(
          program: request.program,
          arguments: [
            for (final arg in request.arguments)
              arg == '--unified=3' ? '--unified=0' : arg,
          ],
          relativeWorkingDirectory: request.relativeWorkingDirectory,
          timeoutSeconds: request.timeoutSeconds,
          stdinBase64: request.stdinBase64,
        ),
      );
      final noContext = await repo.changed();
      expect(
        noContext.hunks
            .expand((hunk) => hunk.lines)
            .any((line) => line.kind == 'context'),
        isFalse,
      );
      expect(_identity(noContext), isNot(_identity(original)));
      repo.processes.intercept = null;
      expect(_identity(await repo.changed()), _identity(original));
    },
  );

  test(
    'source objects and modes contribute even when displayed hunks match',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      await repo.write('tracked.txt', lines({2: 'changed'}));
      final original = await repo.changed();
      await repo.write('tracked.txt', lines({35: 'outside displayed hunk'}));
      await repo.git(['add', '--', 'tracked.txt']);
      await repo.write(
        'tracked.txt',
        lines({2: 'changed', 35: 'outside displayed hunk'}),
      );
      final changedSources = await repo.changed();
      List<Object> display(ChangedFile file) => [
        for (final hunk in file.hunks)
          [
            hunk.oldStart,
            hunk.oldCount,
            hunk.newStart,
            hunk.newCount,
            for (final line in hunk.lines)
              [line.kind, line.text, line.noNewline],
          ],
      ];
      expect(display(changedSources), display(original));
      expect(_identity(changedSources), isNot(_identity(original)));
      await runLocal('/usr/bin/chmod', [
        '755',
        '${repo.repository.path}/tracked.txt',
      ]);
      final indexOid = (await repo.git(['rev-parse', ':tracked.txt'])).trim();
      await repo.git([
        'update-index',
        '--cacheinfo',
        '100755,$indexOid,tracked.txt',
      ]);
      final changedModes = await repo.changed();
      expect(display(changedModes), display(original));
      expect(_identity(changedModes), isNot(_identity(changedSources)));
      expect(changedModes.fileReviewRevision, isNull);
    },
  );

  test(
    'verified unstaged text needs no HEAD or approval eligibility',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      await repo.git(['symbolic-ref', 'HEAD', 'refs/heads/unborn']);
      await repo.write('tracked.txt', lines({2: 'changed'}));
      final file = await repo.changed();
      _identity(file);
      expect(file.reviewRevision, isNull);
      expect(file.fileReviewRevision, isNull);
    },
  );

  for (final corruption in ['text', 'coordinates', 'newline', 'incomplete']) {
    test(
      'unverified $corruption patch never receives a comment certificate',
      () async {
        final repo = await TestRepo.create();
        addTearDown(repo.close);
        await repo.write(
          'tracked.txt',
          lines({2: 'changed', 35: 'last changed'}),
        );
        repo.processes.intercept = (request, run) async {
          final result = await run(request);
          if (!request.arguments.contains('--no-index')) return result;
          final original = utf8.decode(base64Decode(result.stdoutBase64));
          final patch = switch (corruption) {
            'text' => original.replaceFirst('+changed\n', '+forged\n'),
            'coordinates' => original.replaceFirst('+1,', '+2,'),
            'newline' => original.replaceFirst(
              '+changed\n',
              '+changed\n\\ No newline at end of file\n',
            ),
            _ => original.substring(
              0,
              original.indexOf('\n@@', original.indexOf('\n@@') + 1) + 1,
            ),
          };
          expect(patch, isNot(original));
          return EnvironmentBufferedProcessResult(
            exitCode: result.exitCode,
            stdoutBase64: base64Encode(utf8.encode(patch)),
            stderrBase64: result.stderrBase64,
          );
        };
        await expectLater(
          repo.snapshots.snapshotUnstaged(),
          throwsA(
            isA<ChangeSetFailure>().having(
              (failure) => failure.code,
              'code',
              'invalid_git_output',
            ),
          ),
        );
        expect(repo.processes.identityCalls, 0);
        expect(repo.processes.writes, isEmpty);
      },
    );
  }

  test(
    'clean batching and rendered-file process counts stay unchanged',
    () async {
      final repo = await TestRepo.create();
      addTearDown(repo.close);
      for (var index = 2; index < 160; index++) {
        await repo.write('file-$index', 'unchanged\n');
      }
      await repo.commit();
      expect((await repo.snapshots.snapshotUnstaged()).files, isEmpty);
      expect(repo.processes.requests, hasLength(20 + 4 * 2));
      expect(repo.processes.identityCalls, 0);
      repo.processes.requests.clear();
      await repo.write('tracked.txt', lines({2: 'changed'}));
      _identity(await repo.changed());
      expect(repo.processes.requests, hasLength(20 + 4 * 2 + 16));
      expect(repo.processes.identityCalls, 1);
      expect(
        repo.processes.requests.where(
          (request) => request.arguments.contains('hash-object'),
        ),
        hasLength(2),
      );
      expect(
        repo.processes.requests.where(
          (request) => request.arguments.contains('/usr/bin/head'),
        ),
        hasLength(2),
      );
      expect(repo.processes.writes, isEmpty);
    },
  );
}

ChangedFile _file(ChangeSetSnapshot layer, String path) =>
    layer.files.singleWhere((file) => file.relativePath == path);

String _identity(ChangedFile file) {
  expect(
    file.commentComparisonIdentity,
    matches(r'^git-comment-comparison-v1:[0-9a-f]{64}$'),
    reason: file.relativePath,
  );
  expect(file.commentComparisonIdentity, isNot(file.reviewRevision));
  expect(file.commentComparisonIdentity, isNot(file.fileReviewRevision));
  return file.commentComparisonIdentity!;
}

String _blobOid(String format, String text) {
  final bytes = utf8.encode(text);
  return (format == 'sha256' ? sha256 : sha1).convert([
    ...utf8.encode('blob ${bytes.length}\x00'),
    ...bytes,
  ]).toString();
}

String _expectedIdentity(
  TestRepo repo,
  ChangedFile file,
  String layer,
  String oldSource,
  String newSource,
  String oldOid,
  String newOid,
) {
  const domain = 'git-comment-comparison-v1';
  final root = repo.repository.path;
  final digest = sha256.convert(
    utf8.encode(
      jsonEncode([
        domain,
        repo.processes.sessionId,
        repo.processes.environmentId,
        root,
        root,
        '$root/.git',
        '',
        layer,
        file.relativePath,
        file.changeKind,
        ['old', oldSource, '100644', oldOid],
        ['new', newSource, '100644', newOid],
        for (final hunk in file.hunks)
          [
            hunk.oldStart,
            hunk.oldCount,
            hunk.newStart,
            hunk.newCount,
            for (final line in hunk.lines)
              [line.kind, line.text, line.noNewline],
          ],
      ]),
    ),
  );
  return '$domain:$digest';
}
