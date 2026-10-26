@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_environment/adele_environment.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart'
    show GitPortableReviewApprovalService, GitPortableUnstagedLimits;
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
    for (final deletion in [false, true]) {
      test(
        '${deletion ? 'deletion' : 'new-file'} ${reviewVerb(staged)} preserves exact outside-source flags stat and conflict records',
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

          await fixture.mutateFile(selectFileFrom(file), staged: staged);

          await fixture.expectIndexPresence(
            before,
            path,
            presentBefore ? null : text,
          );
          checkedApplyPatch(fixture, staged: staged);
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
          await runLocal('/usr/bin/chmod', ['+x', helper.path]);
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
            : lines({2: 'first  ', 35: 'last\t'});
        if (!deletion && !wholeLayer) await fixture.write(path, text);
        for (final staged in [false, true]) {
          final layer = await fixture.layer(staged: staged);
          final before = await fixture.state();
          if (wholeLayer) {
            await fixture.mutateLayer(selectLayerFrom(layer), staged: staged);
            await fixture.expectIndexChanges(
              before,
              staged ? changes!.head : changes!.working,
            );
          } else {
            await fixture.mutateFile(
              selectFileFrom(
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
              fixture.mutateLayer(untrustedLayerSelection()),
              throwsA(hasErrorCode(['unsupported_target'])),
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

  for (final format in ['sha1', 'sha256']) {
    for (final staged in [false, true]) {
      test(
        '${reviewVerb(staged)} one of two distant hunks with $format objects',
        () async {
          if (format != fixture.format) {
            await fixture.close();
            fixture = await TestRepo.create(format: format);
          }
          final both = lines({2: 'first edit', 35: 'last edit'});
          await fixture.write('tracked.txt', both);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          expect(file.hunks, hasLength(2));
          final before = await fixture.state();

          await fixture.mutate(_selection(file), staged: staged);

          final after = await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? lines({35: 'last edit'}) : lines({2: 'first edit'}),
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
      '${reviewVerb(staged)} isolates the second hunk after a line-count shift',
      () async {
        final firstOnly = lines().replaceFirst(
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
          staged ? firstOnly : lines({35: 'last edit'}),
        );
        expect(fixture.processes.writes, hasLength(1));
      },
    );

    test(
      '${reviewVerb(staged)} preserves mixed layers in the same and other files',
      () async {
        await fixture.write('tracked.txt', lines({2: 'already staged'}));
        await fixture.write('other.txt', 'other staged\n');
        await fixture.git(['add', '--', 'tracked.txt', 'other.txt']);
        await fixture.write(
          'tracked.txt',
          lines({2: 'already staged', 35: 'working only'}),
        );
        await fixture.write('other.txt', 'other working\n');
        final file = await fixture.changed(staged: staged);
        final before = await fixture.state();

        await fixture.mutate(_selection(file), staged: staged);

        await fixture.expectIndexChange(
          before,
          'tracked.txt',
          staged ? lines() : lines({2: 'already staged', 35: 'working only'}),
        );
      },
    );

    test(
      '${reviewVerb(staged)} retains cancelling HEAD index working layers',
      () async {
        await fixture.write('tracked.txt', lines({2: 'index only'}));
        await fixture.git(['add', '--', 'tracked.txt']);
        await fixture.write('tracked.txt', lines());
        final layers = await fixture.snapshots.snapshotUncommitted();
        expect(layers.staged.files.single.reviewRevision, isNotNull);
        expect(layers.unstaged.files.single.reviewRevision, isNotNull);
        final before = await fixture.state();

        await fixture.mutate(
          _selection((staged ? layers.staged : layers.unstaged).files.single),
          staged: staged,
        );

        await fixture.expectIndexChange(before, 'tracked.txt', lines());
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
      test('${reviewVerb(staged)} preserves $name exactly', () async {
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
        '${reviewVerb(staged)} scopes nested literal ${jsonEncode(name)} to the Environment',
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
        '${reviewVerb(staged)} preserves UTF-8 BOM in ${line == 0 ? 'first-line' : 'distant'} hunk',
        () async {
          final original = '\ufeff${lines()}';
          final modified = '\ufeff${lines({line: 'selected edit'})}';
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
      '${reviewVerb(staged)} offers no revision when an isolated hunk exceeds the byte limit',
      () async {
        final removable = 'y' * 80;
        final original = lines({35: removable});
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
          throwsA(hasErrorCode(['unsupported_target'])),
        );

        await fixture.expectUnchanged(before);
        expect(fixture.processes.writes, isEmpty);
        await fixture.mutateFile(
          selectFileFrom(file),
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
        '${reviewVerb(staged)} conservatively rejects control-character paths',
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
            throwsA(hasErrorCode(['unsupported_target', 'invalid_selection'])),
          );
          await expectLater(
            fixture.mutateFile(untrustedFileSelection(name), staged: staged),
            throwsA(hasErrorCode(['unsupported_target', 'invalid_selection'])),
          );
          await fixture.expectUnchanged(before);
          expect(fixture.processes.writes, isEmpty);
        },
      );
    }

    test(
      '${reviewVerb(staged)} requires a fresh revision across Sessions sharing an Environment',
      () async {
        fixture.processes.sessionId = 'review-session-a';
        await fixture.write(
          'tracked.txt',
          lines({2: 'first edit', 35: 'last edit'}),
        );
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final fileA = await fixture.changed(staged: staged);
        expect(fileA.hunks, hasLength(2));
        final selectionA = _selection(fileA);
        final fileSelectionA = selectFileFrom(fileA);
        final before = await fixture.state();
        expect(
          (await fixture.changed(staged: staged)).reviewRevision,
          selectionA.expectedRevision,
        );

        fixture.processes.sessionId = 'review-session-b';
        await expectLater(
          fixture.mutate(selectionA, staged: staged),
          throwsA(hasErrorCode(['stale_selection'])),
        );
        await expectLater(
          fixture.mutateFile(fileSelectionA, staged: staged),
          throwsA(hasErrorCode(['stale_selection'])),
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
          staged ? lines({35: 'last edit'}) : lines({2: 'first edit'}),
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
        '${reviewVerb(staged)} rejects stale $mutation before a write',
        () async {
          await fixture.write('tracked.txt', lines({2: 'selected edit'}));
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final file = await fixture.changed(staged: staged);
          final selection = _selection(file);
          final fileSelection = selectFileFrom(file);
          switch (mutation) {
            case 'working edit':
              await fixture.write(
                'tracked.txt',
                lines({2: 'changed after display'}),
              );
            case 'working deletion':
              await File('${fixture.repository.path}/tracked.txt').delete();
            case 'manual git add':
              await fixture.write(
                'tracked.txt',
                lines({2: 'new index content'}),
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
              await runLocal('/usr/bin/chmod', [
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
            throwsA(hasErrorCode(['stale_selection', 'unsupported_target'])),
          );
          await expectLater(
            fixture.mutateFile(fileSelection, staged: staged),
            throwsA(hasErrorCode(['stale_selection', 'unsupported_target'])),
          );

          await fixture.expectUnchanged(before);
          expect(fixture.processes.writes, isEmpty);
        },
      );
    }

    test('${reviewVerb(staged)} cannot reuse a consumed selection', () async {
      await fixture.write('tracked.txt', lines({2: 'selected edit'}));
      if (staged) await fixture.git(['add', '--', 'tracked.txt']);
      final selection = _selection(await fixture.changed(staged: staged));
      await fixture.mutate(selection, staged: staged);
      final before = await fixture.state();
      fixture.processes.requests.clear();

      await expectLater(
        fixture.mutate(selection, staged: staged),
        throwsA(hasErrorCode(['stale_selection', 'unsupported_target'])),
      );

      await fixture.expectUnchanged(before);
      expect(fixture.processes.writes, isEmpty);
    });

    test(
      '${reviewVerb(staged)} rejects an unavailable hunk without mutation',
      () async {
        await fixture.write('tracked.txt', lines({2: 'selected edit'}));
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final file = await fixture.changed(staged: staged);
        final before = await fixture.state();

        await expectLater(
          fixture.mutate(_selection(file, hunkIndex: 8191), staged: staged),
          throwsA(hasErrorCode(['hunk_unavailable'])),
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
      test('${reviewVerb(staged)} offers no revision for $kind', () async {
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
            await fixture.write(path, lines({2: 'selected edit'}));
        }
        if (kind == 'mode change') {
          await runLocal('/usr/bin/chmod', [
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
          throwsA(hasErrorCode(['unsupported_target', 'stale_selection'])),
        );
        await expectLater(
          fixture.mutateFile(
            untrustedFileSelection(path),
            staged: staged,
            limits: limits,
          ),
          throwsA(hasErrorCode(['unsupported_target', 'stale_selection'])),
        );

        await fixture.expectUnchanged(before);
        expect(fixture.processes.writes, isEmpty);
      });
    }

    test(
      '${reviewVerb(staged)} reports a real index.lock failure without retry',
      () async {
        await fixture.write('tracked.txt', lines({2: 'selected edit'}));
        if (staged) await fixture.git(['add', '--', 'tracked.txt']);
        final selection = _selection(await fixture.changed(staged: staged));
        final before = await fixture.state();
        final lock = File('${fixture.repository.path}/.git/index.lock');
        fixture.processes.intercept = (request, run) async {
          if (isWrite(request)) {
            await lock.writeAsString('external lock owner\n');
          }
          return run(request);
        };

        await expectLater(
          fixture.mutate(selection, staged: staged),
          throwsA(hasErrorCode(['mutation_failed'])),
        );

        expect(fixture.processes.writes, hasLength(1));
        expect(await lock.readAsString(), 'external lock owner\n');
        await fixture.expectUnchanged(before);
      },
    );

    for (final loss in ['response lost', 'process timeout']) {
      test(
        '${reviewVerb(staged)} reports $loss after apply as outcome_uncertain',
        () async {
          final modified = lines({2: 'selected edit', 35: 'other hunk'});
          await fixture.write('tracked.txt', modified);
          if (staged) await fixture.git(['add', '--', 'tracked.txt']);
          final selection = _selection(await fixture.changed(staged: staged));
          final before = await fixture.state();
          fixture.processes.intercept = (request, run) async {
            final result = await run(request);
            if (isWrite(request)) {
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
            throwsA(hasErrorCode(['outcome_uncertain'])),
          );

          expect(fixture.processes.writes, hasLength(1));
          await fixture.expectIndexChange(
            before,
            'tracked.txt',
            staged ? lines({35: 'other hunk'}) : lines({2: 'selected edit'}),
          );
        },
      );
    }
  }

  test('layer revisions cannot be exchanged on a mixed file', () async {
    await fixture.write('tracked.txt', lines({2: 'staged'}));
    await fixture.git(['add', '--', 'tracked.txt']);
    await fixture.write('tracked.txt', lines({2: 'staged', 35: 'working'}));
    final layers = await fixture.snapshots.snapshotUncommitted();
    final before = await fixture.state();
    await expectLater(
      fixture.mutate(_selection(layers.staged.files.single)),
      throwsA(hasErrorCode(['stale_selection'])),
    );
    await expectLater(
      fixture.mutate(_selection(layers.unstaged.files.single), staged: true),
      throwsA(hasErrorCode(['stale_selection'])),
    );
    await expectLater(
      fixture.mutateFile(selectFileFrom(layers.staged.files.single)),
      throwsA(hasErrorCode(['stale_selection'])),
    );
    await expectLater(
      fixture.mutateFile(
        selectFileFrom(layers.unstaged.files.single),
        staged: true,
      ),
      throwsA(hasErrorCode(['stale_selection'])),
    );
    final file = layers.unstaged.files.single;
    await expectLater(
      fixture.mutateFile(
        ReviewFileSelection(
          relativePath: file.relativePath,
          expectedRevision: file.reviewRevision!,
        ),
      ),
      throwsA(hasErrorCode(['stale_selection'])),
    );
    await expectLater(
      fixture.mutate(
        ReviewHunkSelection(
          relativePath: file.relativePath,
          hunkIndex: 0,
          expectedRevision: file.fileReviewRevision!,
        ),
      ),
      throwsA(hasErrorCode(['stale_selection'])),
    );
    await fixture.expectUnchanged(before);
    expect(fixture.processes.writes, isEmpty);
  });

  test(
    'approve does not charge an unrelated staged hunk to the selected layer line budget',
    () async {
      await fixture.write('tracked.txt', lines({2: 'staged'}));
      await fixture.git(['add', '--', 'tracked.txt']);
      final modified = lines({2: 'staged', 35: 'working'});
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
        await fixture.write('tracked.txt', lines({2: 'selected edit'}));
        final selection = _selection(await fixture.changed());
        final original = await fixture.state();
        ReviewState? externallyChanged;
        fixture.processes.intercept = (request, run) async {
          final atBoundary = failedWrite
              ? isWrite(request)
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
            hasErrorCode([
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
      final modified = lines({2: 'selected edit', 35: 'manual addition'});
      await fixture.write('tracked.txt', modified);
      final selection = _selection(await fixture.changed());
      ReviewState? externallyStaged;
      fixture.processes.intercept = (request, run) async {
        if (isWrite(request)) {
          await fixture.git(['add', '--', 'tracked.txt']);
          externallyStaged = await fixture.state();
        }
        return run(request);
      };

      await expectLater(
        fixture.mutate(selection),
        throwsA(hasErrorCode(['outcome_uncertain'])),
      );

      expect(externallyStaged, isNotNull);
      await fixture.expectUnchanged(externallyStaged!);
      expect(fixture.processes.writes, hasLength(1));
    },
  );

  test(
    'a distant manual add accepted by Git is detected as an uncertain postimage',
    () async {
      final modified = lines({2: 'selected edit', 35: 'external edit'});
      await fixture.write('tracked.txt', modified);
      final selection = _selection(await fixture.changed());
      ReviewState? externallyStaged;
      fixture.processes.intercept = (request, run) async {
        if (isWrite(request)) {
          await fixture.write('tracked.txt', lines({35: 'external edit'}));
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
        throwsA(hasErrorCode(['outcome_uncertain'])),
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
          lines({2: 'selected edit', 35: 'not selected'}),
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
              await service.approveFile(selectFileFrom(file));
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
          hasErrorCode([
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
          lines({2: 'selected edit', if (wholeFile) 35: 'not selected'}),
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
      await fixture.write('tracked.txt', lines({2: 'selected edit'}));
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
        throwsA(hasErrorCode(['inspection_failed'])),
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
      await fixture.write('tracked.txt', lines({2: 'selected edit'}));
      final selection = _selection(await fixture.changed());
      final before = await fixture.state();

      await expectLater(
        fixture.mutate(selection, limits: limits),
        throwsA(hasErrorCode(['inspection_failed'])),
      );

      expect(fixture.processes.writes, isEmpty);
      await fixture.expectUnchanged(before);
    });
  }

  test(
    'a prewrite deadline fences late transport completion and later commands',
    () async {
      await fixture.write('tracked.txt', lines({2: 'selected edit'}));
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
        throwsA(hasErrorCode(['operation_timeout'])),
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
      await fixture.write('tracked.txt', lines({2: 'selected edit'}));
      final selection = _selection(await fixture.changed());
      final before = await fixture.state();
      final held = Completer<EnvironmentBufferedProcessResult>();
      EnvironmentBufferedProcessResult? applied;
      fixture.processes.intercept = (request, run) async {
        final result = await run(request);
        if (isWrite(request)) {
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
        throwsA(hasErrorCode(['outcome_uncertain'])),
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
        lines({2: 'selected edit'}),
      );
    },
  );
}

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
