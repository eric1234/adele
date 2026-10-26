@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

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

  for (final format in ['sha1', 'sha256']) {
    for (final mode in ['100644', '100755']) {
      for (final staged in [false, true]) {
        for (final (name, text) in [
          ('UTF-8', 'caf\u00e9\nnew text  \n'),
          ('empty', ''),
          ('missing newline', 'new\nlast'),
          ('BOM CRLF', '\ufefffirst\r\n\r\nlast\r\n'),
        ]) {
          test('new-file ${reviewVerb(staged)} $name $mode $format', () async {
            if (format != fixture.format) {
              await fixture.close();
              fixture = await TestRepo.create(format: format);
            }
            const path = 'new.txt';
            await fixture.write(path, text);
            await runLocal('/usr/bin/chmod', [
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
            final selection = selectFileFrom(file);
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
              throwsA(hasErrorCode(['stale_selection'])),
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
          selectFileFrom(await fixture.changed(path: 'new.txt')),
        );
        final staged = await fixture.expectIndexPresence(
          initial,
          'new.txt',
          text,
        );
        fixture.processes.requests.clear();
        await fixture.mutateFile(
          selectFileFrom(await fixture.changed(path: 'new.txt', staged: true)),
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
          fixture.mutateFile(untrustedFileSelection('new.txt')),
          throwsA(hasErrorCode(['unsupported_target'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
        await fixture.mutateFile(selectFileFrom(staged), staged: true);
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
        final selection = selectFileFrom(
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
          throwsA(hasErrorCode(['unsupported_target', 'inspection_failed'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
      },
    );
  }

  for (final staged in [false, true]) {
    for (final name in [
      'space name',
      '-leading-option',
      ':(glob)*[x]',
      r'back\slash',
      'quotes\'";\$(touch INJECTED) \u00e9',
      '\ufeffnew.txt',
    ]) {
      test(
        'new-file ${reviewVerb(staged)} nested literal ${jsonEncode(name)}',
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
          await fixture.mutateFile(selectFileFrom(file), staged: staged);
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
      test('new-file ${reviewVerb(staged)} excludes $kind', () async {
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
            await runLocal('/usr/bin/chmod', [
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
        'new-file ${reviewVerb(staged)} excludes conversion $rule',
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
              untrustedFileSelection('new.txt'),
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
      test('new-file ${reviewVerb(staged)} rejects stale $mutation', () async {
        const path = 'parent/new.txt';
        await fixture.write(path, 'displayed\n');
        if (staged) await fixture.git(['add', '--', path]);
        final selection = selectFileFrom(
          await fixture.changed(path: path, staged: staged),
        );
        switch (mutation) {
          case 'working bytes':
            await fixture.write(path, 'changed\n');
          case 'working mode':
            await runLocal('/usr/bin/chmod', [
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
          throwsA(hasErrorCode(['unsupported_target', 'stale_selection'])),
        );
        expect(fixture.processes.writes, isEmpty);
        await fixture.expectUnchanged(before);
        if (mutation == 'Session' || mutation == 'Environment') {
          final fresh = selectFileFrom(
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
        'new-file ${reviewVerb(staged)} $loss has truthful effect',
        () async {
          await fixture.write('new.txt', 'new text\n');
          if (staged) await fixture.git(['add', '--', 'new.txt']);
          final selection = selectFileFrom(
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
            if (isWrite(request) && loss == 'lock') {
              await fixture.write('.git/index.lock', 'external lock owner\n');
            }
            final result = await run(request);
            if (loss == 'revoked after check' &&
                request.arguments.contains('apply') &&
                request.arguments.contains('--check')) {
              revoked = true;
            }
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
              loss == 'revoked before check' || loss == 'revoked after check';
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
        'new-file ${reviewVerb(staged)} external writer $boundary never retries',
        () async {
          await fixture.write('new.txt', 'new text\n');
          if (staged) await fixture.git(['add', '--', 'new.txt']);
          final selection = selectFileFrom(
            await fixture.changed(path: 'new.txt', staged: staged),
          );
          ReviewState? external;
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
            if (boundary == 'at write' && isWrite(request)) {
              await changeIndex();
            }
            final result = await run(request);
            if (boundary == 'after check' &&
                    request.arguments.contains('apply') &&
                    request.arguments.contains('--check') ||
                boundary == 'after apply' && isWrite(request)) {
              await changeIndex();
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
          await fixture.expectUnchanged(external!);
          expect(
            fixture.processes.writes,
            hasLength(boundary == 'after check' ? 0 : 1),
          );
        },
      );
    }

    test(
      'new-file ${reviewVerb(staged)} concurrent duplicates have one effect',
      () async {
        await fixture.write('new.txt', 'new text\n');
        if (staged) await fixture.git(['add', '--', 'new.txt']);
        final selection = selectFileFrom(
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
          'new.txt',
          staged ? null : 'new text\n',
        );
      },
    );

    test(
      'new-file ${reviewVerb(staged)} process count is independent of line count',
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
          await fixture.mutateFile(selectFileFrom(file), staged: staged);
          watch.stop();
          counts.add(fixture.processes.requests.length);
          print(
            'New-file ${reviewVerb(staged)} performance: $lines lines, ${counts.last} processes, ${watch.elapsedMilliseconds} ms (diagnostic).',
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
}
