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
    show GitPortableUnstagedSnapshotService;
import 'package:test/test.dart';

void main() {
  late Directory container;
  late Directory repository;
  late _Processes processes;
  late EnvironmentBufferedProcessRequest sourceRequest;

  final baseline = List.generate(40, (index) => 'line $index\n').join();
  final first = baseline.replaceFirst('line 4\n', 'first edit  \n');
  final second = baseline.replaceFirst('line 34\n', 'second edit\n');
  final both = first.replaceFirst('line 34\n', 'second edit\n');

  Future<void> write(String path, String content) async {
    final file = File('${repository.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<void> fixture(Map<String, String> files) async {
    for (final entry in files.entries) {
      await write(entry.key, entry.value);
    }
    // Git add is fixture preparation only, never the action under test.
    await _git(repository, ['add', '--all']);
    await _git(repository, ['commit', '-m', 'Fixture']);
  }

  Future<ChangeSetSnapshot> capture({bool staged = false}) async {
    final service = GitPortableUnstagedSnapshotService(processes: processes);
    final snapshot = staged
        ? (await service.snapshotUncommitted()).staged
        : await service.snapshotUnstaged();
    sourceRequest = processes.requests.firstWhere(
      (request) =>
          request.arguments.contains('ls-files') &&
          request.arguments.contains('--cached'),
    );
    expect(sourceRequest.program, '/bin/sh');
    expect(
      sourceRequest.arguments,
      containsAll([
        '--git-dir=${repository.path}/.git',
        '--work-tree=${repository.path}',
        '--literal-pathspecs',
        'core.fsmonitor=false',
        'core.hooksPath=/dev/null',
      ]),
    );
    return snapshot;
  }

  Future<EnvironmentBufferedProcessResult> command(
    List<String> arguments, {
    String input = '',
  }) => processes.runBufferedProcess(
    _withCommand(sourceRequest, arguments, input: input),
  );

  Future<EnvironmentBufferedProcessResult> apply(
    String patch, {
    bool reverse = false,
    bool zeroContext = false,
    bool check = false,
  }) => command([
    '-c',
    'apply.ignoreWhitespace=false',
    'apply',
    '--cached',
    if (reverse) '--reverse',
    if (check) '--check',
    '--whitespace=nowarn',
    '--no-ignore-whitespace',
    '-p1',
    if (zeroContext) '--unidiff-zero',
    '--',
    '-',
  ], input: patch);

  Future<void> expectIndex(
    String path,
    String content, {
    String mode = '100644',
  }) async {
    final expectedBytes = utf8.encode(content);
    final inventory = _success(
      await command(['ls-files', '--stage', '-z', '--', './$path']),
    );
    final fields = utf8.decode(inventory).split('\t').first.split(' ');
    expect(fields, hasLength(3));
    final oid = fields[1];
    expect(
      utf8.decode(inventory),
      '$mode ${_blobOid(expectedBytes, sha256Format: oid.length == 64)} 0\t$path\u0000',
    );
    expect(
      _success(await command(['cat-file', 'blob', oid])),
      orderedEquals(expectedBytes),
    );
  }

  setUp(() async {
    container = await Directory.systemTemp.createTemp('adele-hunk-apply-');
    repository = await Directory('${container.path}/repository').create();
    processes = _Processes(repository, container);
    await _git(repository, ['init', '--initial-branch=main']);
    await _git(repository, ['config', 'user.name', 'ADELE Test']);
    await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
  });

  tearDown(() async {
    await container.delete(recursive: true);
  });

  for (final format in ['sha1', 'sha256']) {
    for (final mode in ['100644', '100755']) {
      for (final (name, text) in [
        ('UTF-8 BOM and CRLF', '\ufeffcaf\u00e9\r\n\r\nlast  \n'),
        ('empty', ''),
        ('missing newline', 'caf\u00e9\nlast'),
      ]) {
        test('deletion $name $mode $format check/write/reverse', () async {
          if (format == 'sha256') {
            repository = await Directory('${container.path}/sha256').create();
            await _git(repository, ['init', '--object-format=sha256']);
            await _git(repository, ['config', 'user.name', 'ADELE Test']);
            await _git(repository, [
              'config',
              'user.email',
              'adele@example.invalid',
            ]);
          }
          const path =
              'selected/project/-literal [x] \\ "\u00e9"\$(touch EXECUTED)';
          final relativePath = path.substring('selected/project/'.length);
          await write(path, text);
          final workingFile = File('${repository.path}/$path');
          expect(
            (await Process.run('/usr/bin/chmod', [
              mode == '100755' ? '755' : '644',
              workingFile.path,
            ])).exitCode,
            0,
          );
          await fixture({path: text, 'untouched': 'unrelated\n'});
          await workingFile.delete();
          processes = _Processes(
            Directory('${repository.path}/selected/project'),
            container,
          );
          final file = (await capture()).files.single;
          expect(file.relativePath, relativePath);
          expect(file.changeKind, 'deleted');
          expect(file.contentStatus, 'text');
          final oid = _blobOid(
            utf8.encode(text),
            sha256Format: format == 'sha256',
          );
          final patch = _deletionPatch(path, text, mode: mode, oid: oid);
          expect(patch, contains('deleted file mode $mode\n'));
          expect(patch, contains('index $oid..${'0' * oid.length}\n'));
          expect(patch, contains('+++ /dev/null\n'));
          expect(patch.contains('@@'), text.isNotEmpty);
          final originalIndex = await _git(repository, [
            'ls-files',
            '--stage',
            '-z',
          ]);
          final index = await File(
            '${repository.path}/.git/index',
          ).readAsBytes();
          final working = await _workingHashes(repository);
          final head = await _git(repository, ['rev-parse', 'HEAD']);
          final reference = await _git(repository, ['symbolic-ref', 'HEAD']);
          await expectIndex(relativePath, text, mode: mode);
          final start = processes.requests.length;
          _success(await apply(patch, check: true));
          expect(
            await File('${repository.path}/.git/index').readAsBytes(),
            index,
          );
          _success(await apply(patch));
          expect(processes.requests.skip(start), hasLength(2));
          expect(
            _success(
              await command([
                'ls-files',
                '--stage',
                '-z',
                '--',
                './$relativePath',
              ]),
            ),
            isEmpty,
          );
          expect(
            await FileSystemEntity.type(workingFile.path, followLinks: false),
            FileSystemEntityType.notFound,
          );
          final deleted = await File(
            '${repository.path}/.git/index',
          ).readAsBytes();
          final reverseStart = processes.requests.length;
          _success(await apply(patch, reverse: true, check: true));
          expect(
            await File('${repository.path}/.git/index').readAsBytes(),
            deleted,
          );
          _success(await apply(patch, reverse: true));
          expect(processes.requests.skip(reverseStart), hasLength(2));
          await expectIndex(relativePath, text, mode: mode);
          expect(
            await _git(repository, ['ls-files', '--stage', '-z']),
            originalIndex,
          );
          expect(
            await FileSystemEntity.type(workingFile.path, followLinks: false),
            FileSystemEntityType.notFound,
          );
          expect(await _workingHashes(repository), working);
          expect(await _git(repository, ['rev-parse', 'HEAD']), head);
          expect(await _git(repository, ['symbolic-ref', 'HEAD']), reference);
          expect(
            await File('${processes.root.path}/EXECUTED').exists(),
            isFalse,
          );
          expect(
            processes.requests.where(
              (r) =>
                  r.arguments.contains('apply') &&
                  !r.arguments.contains('--check'),
            ),
            hasLength(2),
          );
        });
      }
      for (final (name, text) in [
        ('UTF-8', '\ufeffcaf\u00e9\r\n\r\nlast  \n'),
        ('empty', ''),
        ('missing newline', 'caf\u00e9\nlast'),
      ]) {
        test('new-file $name $mode $format check/write/reverse', () async {
          if (format == 'sha256') {
            repository = await Directory('${container.path}/sha256').create();
            await _git(repository, ['init', '--object-format=sha256']);
            await _git(repository, ['config', 'user.name', 'ADELE Test']);
            await _git(repository, [
              'config',
              'user.email',
              'adele@example.invalid',
            ]);
          }
          await fixture({'untouched': 'unrelated\n'});
          const path =
              'selected/project/-literal [x] \\ "\u00e9"\$(touch EXECUTED)';
          final relativePath = path.substring('selected/project/'.length);
          await write(path, text);
          final workingFile = File('${repository.path}/$path');
          final chmod = await Process.run('/usr/bin/chmod', [
            mode == '100755' ? '755' : '644',
            workingFile.path,
          ]);
          expect(chmod.exitCode, 0);
          processes = _Processes(
            Directory('${repository.path}/selected/project'),
            container,
          );
          final file = (await capture()).files.single;
          expect(file.relativePath, relativePath);
          expect(file.changeKind, 'added');
          expect(file.contentStatus, 'text');
          final oid = _blobOid(
            utf8.encode(text),
            sha256Format: format == 'sha256',
          );
          final patch = _additionPatch(path, text, mode: mode, oid: oid);
          expect(patch, contains('new file mode $mode\n'));
          expect(patch, contains('index ${'0' * oid.length}..$oid\n'));
          expect(patch, contains('--- /dev/null\n'));
          expect(patch.contains('@@'), text.isNotEmpty);
          final index = await File(
            '${repository.path}/.git/index',
          ).readAsBytes();
          final working = await _workingHashes(repository);
          final head = await _git(repository, ['rev-parse', 'HEAD']);
          final reference = await _git(repository, ['symbolic-ref', 'HEAD']);
          expect(
            _success(
              await command([
                'ls-files',
                '--stage',
                '-z',
                '--',
                './$relativePath',
              ]),
            ),
            isEmpty,
          );
          final start = processes.requests.length;
          _success(await apply(patch, check: true));
          expect(
            await File('${repository.path}/.git/index').readAsBytes(),
            index,
          );
          _success(await apply(patch));
          expect(processes.requests.skip(start), hasLength(2));
          await expectIndex(relativePath, text, mode: mode);
          final added = await File(
            '${repository.path}/.git/index',
          ).readAsBytes();
          _success(await apply(patch, reverse: true, check: true));
          expect(
            await File('${repository.path}/.git/index').readAsBytes(),
            added,
          );
          _success(await apply(patch, reverse: true));
          expect(
            _success(
              await command([
                'ls-files',
                '--stage',
                '-z',
                '--',
                './$relativePath',
              ]),
            ),
            isEmpty,
          );
          expect(
            await _git(repository, ['ls-files', '--stage']),
            contains('\tuntouched\n'),
          );
          expect(await workingFile.readAsBytes(), utf8.encode(text));
          expect(await _workingHashes(repository), working);
          expect(await _git(repository, ['rev-parse', 'HEAD']), head);
          expect(await _git(repository, ['symbolic-ref', 'HEAD']), reference);
          expect(
            await File('${repository.path}/.git/index.lock').exists(),
            isFalse,
          );
          expect(
            await File('${processes.root.path}/EXECUTED').exists(),
            isFalse,
          );
          expect(
            processes.requests.any((r) => r.arguments.contains('add')),
            isFalse,
          );
        });
      }
    }
  }

  for (final format in ['sha1', 'sha256']) {
    for (final reverse in [false, true]) {
      for (final rejectLast in [false, true]) {
        test(
          'whole-layer mixed $format ${reverse ? 'reverse' : 'forward'} '
          '${rejectLast ? 'bad final file rejects every edit' : 'check then one write'}',
          () async {
            if (format == 'sha256') {
              repository = await Directory('${container.path}/sha256').create();
              await _git(repository, ['init', '--object-format=sha256']);
              await _git(repository, ['config', 'user.name', 'ADELE Test']);
              await _git(repository, [
                'config',
                'user.email',
                'adele@example.invalid',
              ]);
            }
            const prefix = 'selected/project/';
            const modified = '01-literal [x] \\ "\u00e9"\$(touch EXECUTED)';
            final shifted = baseline
                .replaceFirst('line 4\n', 'first\ninserted\nlines\n')
                .replaceFirst('line 20\nline 21\n', 'middle\n')
                .replaceFirst('line 34\n', 'last edit\n');
            // Null means absent membership, distinct from an empty regular file.
            final changes = <String, (String?, String?, String)>{
              modified: (baseline, shifted, '100644'),
              '02-added': (null, '\ufeffcaf\u00e9\r\n\r\nlast  ', '100644'),
              '03-deleted': ('\ufeffold\r\n\r\nlast  ', null, '100755'),
              '04-empty-added': (null, '', '100755'),
              '05-empty-deleted': ('', null, '100644'),
              '06-filled': ('', 'filled\n', '100644'),
              '07-emptied': ('emptied\n', '', '100644'),
              '99-final': (baseline, both, '100644'),
            };
            for (final entry in changes.entries) {
              final (oldText, _, mode) = entry.value;
              if (oldText == null) continue;
              await write('$prefix${entry.key}', oldText);
              expect(
                (await Process.run('/usr/bin/chmod', [
                  mode == '100755' ? '755' : '644',
                  '${repository.path}/$prefix${entry.key}',
                ])).exitCode,
                0,
              );
            }
            await fixture({
              '${prefix}untouched': 'unrelated\n',
              'outside': 'outside HEAD\n',
            });
            for (final entry in changes.entries) {
              final (_, newText, mode) = entry.value;
              if (newText == null) {
                await File('${repository.path}/$prefix${entry.key}').delete();
              } else {
                await write('$prefix${entry.key}', newText);
                expect(
                  (await Process.run('/usr/bin/chmod', [
                    mode == '100755' ? '755' : '644',
                    '${repository.path}/$prefix${entry.key}',
                  ])).exitCode,
                  0,
                );
              }
            }
            if (reverse) {
              await _git(repository, ['add', '--all']);
              await write('$prefix$modified', '${shifted}working-only tail\n');
              await write('${prefix}02-added', 'later working-only addition\n');
            }
            // Preserve unrelated staged and unstaged work outside the source scope.
            await write('outside', 'outside staged\n');
            await _git(repository, ['add', '--', 'outside']);
            await write('outside', 'outside working\n');
            processes = _Processes(
              Directory('${repository.path}/selected/project'),
              container,
            );
            final files = (await capture(staged: reverse)).files;
            expect(files.map((file) => file.relativePath), changes.keys);
            final patches = <String, String>{};
            for (final file in files) {
              final (oldText, newText, mode) = changes[file.relativePath]!;
              final path = '$prefix${file.relativePath}';
              expect(file.contentStatus, 'text');
              expect(
                file.changeKind,
                oldText == null
                    ? 'added'
                    : (newText == null ? 'deleted' : 'modified'),
              );
              final patch = oldText == null
                  ? _additionPatch(
                      path,
                      newText!,
                      mode: mode,
                      oid: _blobOid(
                        utf8.encode(newText),
                        sha256Format: format == 'sha256',
                      ),
                    )
                  : newText == null
                  ? _deletionPatch(
                      path,
                      oldText,
                      mode: mode,
                      oid: _blobOid(
                        utf8.encode(oldText),
                        sha256Format: format == 'sha256',
                      ),
                    )
                  : _fullPatch(path, file.hunks);
              if (file.relativePath == modified) {
                expect(file.hunks, hasLength(3));
                expect(file.hunks[1].newStart, isNot(file.hunks[1].oldStart));
              }
              if (file.relativePath.startsWith('04-') ||
                  file.relativePath.startsWith('05-')) {
                expect(file.hunks, isEmpty);
                expect(patch, isNot(contains('@@')));
                expect(patch, contains('file mode $mode\n'));
              }
              patches[file.relativePath] = patch;
            }
            final patch = _combinedPatch(patches);
            expect(
              _combinedPatch(
                Map.fromEntries(patches.entries.toList().reversed),
              ),
              patch,
              reason: 'Input enumeration must not change the combined bytes',
            );
            expect(
              RegExp(r'^diff --git ', multiLine: true).allMatches(patch),
              hasLength(changes.length),
            );
            expect(patch, contains(r'\ No newline at end of file'));
            expect(patch.endsWith(patches['99-final']!), isTrue);
            final zeroContext = files.any(
              (file) => file.hunks.any(
                (hunk) => hunk.lines.every((line) => line.kind != 'context'),
              ),
            );
            expect(zeroContext, isTrue);
            final indexFile = File('${repository.path}/.git/index');
            final index = await indexFile.readAsBytes();
            final inventory = await _git(repository, [
              'ls-files',
              '--stage',
              '-z',
            ]);
            final working = await _workingHashes(repository);
            final head = await _git(repository, ['rev-parse', 'HEAD']);
            final reference = await _git(repository, ['symbolic-ref', 'HEAD']);
            var selectedPatch = patch;
            if (rejectLast) {
              // Establish that every preceding file would apply, including both
              // empty membership transitions. The failure must be in the last file.
              _success(
                await apply(
                  _combinedPatch({...patches}..remove('99-final')),
                  reverse: reverse,
                  zeroContext: zeroContext,
                  check: true,
                ),
              );
              expect(await indexFile.readAsBytes(), index);
              selectedPatch = patch.replaceFirst(
                reverse ? '+second edit\n' : '-line 34\n',
                reverse ? '+wrong final preimage\n' : '-wrong final preimage\n',
                patch.length - patches['99-final']!.length,
              );
              expect(selectedPatch, isNot(patch));
            }
            final start = processes.requests.length;
            final checked = await apply(
              selectedPatch,
              reverse: reverse,
              zeroContext: zeroContext,
              check: true,
            );
            if (rejectLast) {
              expect(checked.exitCode, isNot(0));
              expect(_stderr(checked), contains('${prefix}99-final'));
              expect(_stderr(checked), contains('patch does not apply'));
            } else {
              _success(checked);
            }
            expect(await indexFile.readAsBytes(), index);
            // Deliberately attempt the rejected payload as well: --check alone
            // cannot establish atomicity of the actual index-mutating command.
            final written = await apply(
              selectedPatch,
              reverse: reverse,
              zeroContext: zeroContext,
            );
            final actionRequests = processes.requests.skip(start).toList();
            expect(actionRequests, hasLength(2));
            expect(actionRequests.first.arguments, contains('--check'));
            expect(actionRequests.last.arguments, isNot(contains('--check')));
            for (final request in actionRequests) {
              expect(
                request.arguments,
                containsAll(['apply', '--cached', '--unidiff-zero']),
              );
              expect(request.arguments.contains('--reverse'), reverse);
              expect(
                base64Decode(request.stdinBase64),
                utf8.encode(selectedPatch),
              );
            }
            if (rejectLast) {
              expect(written.exitCode, isNot(0));
              expect(_stderr(written), contains('${prefix}99-final'));
              expect(_stderr(written), contains('patch does not apply'));
              expect(await indexFile.readAsBytes(), index);
              expect(
                await _git(repository, ['ls-files', '--stage', '-z']),
                inventory,
              );
            } else {
              _success(written);
              expect(await indexFile.readAsBytes(), isNot(index));
            }
            final expectedRecords = <String, String>{};
            for (final entry in changes.entries) {
              final (oldText, newText, mode) = entry.value;
              final text = (reverse != rejectLast) ? oldText : newText;
              if (text == null) {
                expect(
                  _success(
                    await command([
                      'ls-files',
                      '--stage',
                      '-z',
                      '--',
                      './${entry.key}',
                    ]),
                  ),
                  isEmpty,
                );
              } else {
                await expectIndex(entry.key, text, mode: mode);
                expectedRecords['$prefix${entry.key}'] =
                    '$mode ${_blobOid(utf8.encode(text), sha256Format: format == 'sha256')} 0\t$prefix${entry.key}\u0000';
              }
            }
            await expectIndex('untouched', 'unrelated\n');
            for (final (path, text) in [
              ('${prefix}untouched', 'unrelated\n'),
              ('outside', 'outside staged\n'),
            ]) {
              expectedRecords[path] =
                  '100644 ${_blobOid(utf8.encode(text), sha256Format: format == 'sha256')} 0\t$path\u0000';
            }
            final expectedPaths = expectedRecords.keys.toList()..sort();
            expect(
              await _git(repository, ['ls-files', '--stage', '-z']),
              expectedPaths.map((path) => expectedRecords[path]!).join(),
            );
            expect(await _workingHashes(repository), working);
            expect(await _git(repository, ['rev-parse', 'HEAD']), head);
            expect(await _git(repository, ['symbolic-ref', 'HEAD']), reference);
            expect(
              await File('${repository.path}/.git/index.lock').exists(),
              isFalse,
            );
            expect(
              await File('${processes.root.path}/EXECUTED').exists(),
              isFalse,
            );
            expect(
              processes.requests.any(
                (request) => request.arguments.contains('add'),
              ),
              isFalse,
            );
            expect(
              processes.requests.where(
                (request) =>
                    request.arguments.contains('apply') &&
                    !request.arguments.contains('--check'),
              ),
              hasLength(1),
            );
          },
        );
      }
    }
  }

  for (final reverse in [false, true]) {
    test(
      'one complete patch ${reverse ? 'reverses' : 'applies'} shifting hunks atomically',
      () async {
        final changed = baseline
            .replaceFirst('line 4\n', 'first\ninserted\nlines\n')
            .replaceFirst('line 20\nline 21\n', 'middle\n')
            .replaceFirst('line 34\n', 'last edit\n');
        await fixture({'tracked': baseline, 'untouched': 'unrelated\n'});
        await write('tracked', changed);
        if (reverse) {
          await _git(repository, ['add', '--', 'tracked']);
          await write('tracked', '${changed}working-only tail\n');
        }
        final file = (await capture(staged: reverse)).files.single;
        expect(file.hunks, hasLength(3));
        expect(file.hunks[1].newStart, isNot(file.hunks[1].oldStart));
        final patch = _fullPatch('tracked', file.hunks);
        final index = await File('${repository.path}/.git/index').readAsBytes();
        final working = await _workingHashes(repository);
        final head = await _git(repository, ['rev-parse', 'HEAD']);
        final reference = await _git(repository, ['symbolic-ref', 'HEAD']);
        final start = processes.requests.length;
        _success(await apply(patch, reverse: reverse, check: true));
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          index,
        );
        _success(await apply(patch, reverse: reverse));
        expect(processes.requests.skip(start), hasLength(2));
        await expectIndex('tracked', reverse ? baseline : changed);
        await expectIndex('untouched', 'unrelated\n');
        expect(await _workingHashes(repository), working);
        expect(await _git(repository, ['rev-parse', 'HEAD']), head);
        expect(await _git(repository, ['symbolic-ref', 'HEAD']), reference);
      },
    );

    test(
      'a bad final full-patch hunk rejects every ${reverse ? 'reverse' : 'forward'} edit',
      () async {
        await fixture({'tracked': baseline});
        await write('tracked', both);
        if (reverse) await _git(repository, ['add', '--', 'tracked']);
        final file = (await capture(staged: reverse)).files.single;
        final patch = _fullPatch('tracked', file.hunks).replaceFirst(
          reverse ? '+second edit\n' : '-line 34\n',
          reverse ? '+wrong final preimage\n' : '-wrong final preimage\n',
        );
        final index = await File('${repository.path}/.git/index').readAsBytes();
        final working = await _workingHashes(repository);
        expect(
          (await apply(patch, reverse: reverse, check: true)).exitCode,
          isNot(0),
        );
        expect((await apply(patch, reverse: reverse)).exitCode, isNot(0));
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          index,
        );
        await expectIndex('tracked', reverse ? both : baseline);
        expect(await _workingHashes(repository), working);
      },
    );

    test(
      'cached ${reverse ? 'reverse' : 'forward'} applies only one of two distant hunks',
      () async {
        await fixture({'tracked': baseline, 'untouched': 'unrelated\n'});
        await write('tracked', both);
        if (reverse) {
          await _git(repository, ['add', '--', 'tracked']);
          await write('tracked', '${both}working-only tail\n');
        }
        final file = (await capture(staged: reverse)).files.single;
        expect(file.contentStatus, 'text');
        expect(file.hunks, hasLength(2));
        final working = await _workingHashes(repository);
        final head = await File('${repository.path}/.git/HEAD').readAsBytes();
        final headOid = _success(
          await command(['rev-parse', '--verify', 'HEAD^{commit}']),
        );
        final patch = _patch('tracked', file.hunks.first);
        final index = await File('${repository.path}/.git/index').readAsBytes();
        _success(await apply(patch, reverse: reverse, check: true));
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          orderedEquals(index),
        );
        _success(await apply(patch, reverse: reverse));
        await expectIndex('tracked', reverse ? second : first);
        await expectIndex('untouched', 'unrelated\n');
        expect(await _workingHashes(repository), working);
        expect(
          await File('${repository.path}/.git/HEAD').readAsBytes(),
          orderedEquals(head),
        );
        expect(
          _success(await command(['rev-parse', '--verify', 'HEAD^{commit}'])),
          orderedEquals(headOid),
        );
        expect(
          await File('${repository.path}/.git/index.lock').exists(),
          isFalse,
        );
        expect(
          processes.requests.any(
            (request) => request.arguments.contains('add'),
          ),
          isFalse,
        );
      },
    );
  }

  test('cached apply also writes the exact SHA-256 index blob', () async {
    repository = await Directory(
      '${container.path}/sha256-repository',
    ).create();
    processes = _Processes(repository, container);
    await _git(repository, ['init', '--object-format=sha256']);
    await _git(repository, ['config', 'user.name', 'ADELE Test']);
    await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
    await fixture({'tracked': baseline});
    await write('tracked', both);
    final file = (await capture()).files.single;
    final working = await _workingHashes(repository);
    _success(await apply(_patch('tracked', file.hunks.first)));
    await expectIndex('tracked', first);
    expect(
      utf8
          .decode(
            _success(await command(['ls-files', '--stage', '--', 'tracked'])),
          )
          .split(' ')[1],
      hasLength(64),
    );
    expect(await _workingHashes(repository), working);
  });

  test(
    'C-quoted tabs, newlines and shell/pathspec syntax stay literal',
    () async {
      const paths = [
        'space name',
        'tab\tname',
        'line\nname',
        '-leading',
        ':(glob)*',
        '[literal]*?',
        r'quote\"$(touch EXECUTED)',
      ];
      await fixture({for (final path in paths) path: baseline});
      for (final path in paths) {
        await write(path, both);
      }
      final files = (await capture()).files;
      expect(files, hasLength(paths.length));
      final working = await _workingHashes(repository);
      for (final file in files) {
        expect(file.hunks, hasLength(2));
        final patch = _patch(file.relativePath, file.hunks.first);
        expect(patch, startsWith('diff --git "a/'));
        if (file.relativePath.contains('\t')) expect(patch, contains(r'\t'));
        if (file.relativePath.contains('\n')) expect(patch, contains(r'\n'));
        _success(await apply(patch));
        await expectIndex(file.relativePath, first);
        _success(await apply(patch, reverse: true));
        await expectIndex(file.relativePath, baseline);
      }
      expect(await _workingHashes(repository), working);
      expect(await File('${repository.path}/EXECUTED').exists(), isFalse);
    },
  );

  test(
    'nested cwd requires repository-relative headers and a verified result',
    () async {
      await fixture({
        'selected/project/tracked': baseline,
        'tracked': 'outside scope\n',
      });
      await write('selected/project/tracked', both);
      processes = _Processes(
        Directory('${repository.path}/selected/project'),
        container,
      );
      final file = (await capture()).files.single;
      expect(file.relativePath, 'tracked');
      expect(file.hunks, hasLength(2));
      final working = await _workingHashes(repository);
      final index = await File('${repository.path}/.git/index').readAsBytes();
      // Git silently skips headers outside the current prefix, with exit zero.
      // Success status alone does not establish that the selected hunk was written.
      _success(await apply(_patch('tracked', file.hunks.first)));
      await expectIndex('tracked', baseline);
      expect(
        await File('${repository.path}/.git/index').readAsBytes(),
        orderedEquals(index),
      );
      final patch = _patch('selected/project/tracked', file.hunks.first);
      _success(await apply(patch));
      await expectIndex('tracked', first);
      _success(await apply(patch, reverse: true));
      await expectIndex('tracked', baseline);
      expect(
        _success(await command(['cat-file', 'blob', ':tracked'])),
        orderedEquals(utf8.encode('outside scope\n')),
      );
      expect(await _workingHashes(repository), working);
    },
  );

  for (final (oldText, newText) in [('', 'added\n'), ('removed\n', '')]) {
    test(
      'empty tracked sides retain exact zero-count coordinates ${jsonEncode(oldText)}',
      () async {
        await fixture({'tracked': oldText});
        await write('tracked', newText);
        final file = (await capture()).files.single;
        expect(file.changeKind, 'modified');
        final hunk = file.hunks.single;
        expect(hunk.lines.every((line) => line.kind != 'context'), isTrue);
        expect(oldText.isEmpty ? hunk.oldCount : hunk.newCount, 0);
        final working = await _workingHashes(repository);
        final patch = _patch('tracked', hunk);
        _success(await apply(patch, zeroContext: true));
        await expectIndex('tracked', newText);
        _success(await apply(patch, reverse: true, zeroContext: true));
        await expectIndex('tracked', oldText);
        expect(await _workingHashes(repository), working);
      },
    );
  }

  for (final (oldText, newText) in [
    ('before', 'after'),
    ('before', 'after\n'),
    ('before\n', 'after'),
  ]) {
    test(
      'no-final-newline markers round trip ${jsonEncode(oldText)} to ${jsonEncode(newText)}',
      () async {
        await fixture({'tracked': oldText});
        await write('tracked', newText);
        final hunk = (await capture()).files.single.hunks.single;
        expect(hunk.lines.any((line) => line.noNewline), isTrue);
        final working = await _workingHashes(repository);
        final patch = _patch('tracked', hunk);
        expect(patch, contains('\\ No newline at end of file\n'));
        _success(await apply(patch));
        await expectIndex('tracked', newText);
        _success(await apply(patch, reverse: true));
        await expectIndex('tracked', oldText);
        expect(await _workingHashes(repository), working);
      },
    );
  }

  test(
    'zero-context replacement requires an explicit unidiff-zero opt-in',
    () async {
      await fixture({'tracked': baseline});
      await write('tracked', both);
      await capture();
      final hunk = DiffHunk(
        oldStart: 5,
        oldCount: 1,
        newStart: 5,
        newCount: 1,
        lines: const [
          DiffLine(kind: 'deletion', text: 'line 4', noNewline: false),
          DiffLine(kind: 'addition', text: 'first edit  ', noNewline: false),
        ],
      );
      final patch = _patch('tracked', hunk);
      final index = await File('${repository.path}/.git/index').readAsBytes();
      final working = await _workingHashes(repository);
      final rejected = await apply(patch);
      expect(rejected.exitCode, isNot(0));
      expect(_stderr(rejected), contains('patch does not apply'));
      expect(
        await File('${repository.path}/.git/index').readAsBytes(),
        orderedEquals(index),
      );
      _success(await apply(patch, zeroContext: true));
      await expectIndex('tracked', first);
      _success(await apply(patch, reverse: true, zeroContext: true));
      await expectIndex('tracked', baseline);
      expect(await _workingHashes(repository), working);
    },
  );

  test(
    'explicit whitespace options preserve bytes and reject changed context',
    () async {
      await fixture({'tracked': baseline});
      await write('tracked', both);
      final file = (await capture()).files.single;
      final patch = _patch('tracked', file.hunks.first);
      for (final (key, value) in [
        ('apply.ignoreWhitespace', 'true'),
        ('apply.whitespace', 'fix'),
        ('core.whitespace', 'blank-at-eol,blank-at-eof,space-before-tab'),
      ]) {
        await _git(repository, ['config', key, value]);
      }
      final working = await _workingHashes(repository);
      _success(await apply(patch));
      await expectIndex('tracked', first);
      _success(await apply(patch, reverse: true));
      await expectIndex('tracked', baseline);
      // A different writer changes context, not the selected line. No whitespace
      // matching or fixing may silently widen the selected operation.
      final contextPatch = _patch(
        'tracked',
        DiffHunk(
          oldStart: 1,
          oldCount: 3,
          newStart: 1,
          newCount: 3,
          lines: const [
            DiffLine(kind: 'context', text: 'line 0', noNewline: false),
            DiffLine(kind: 'deletion', text: 'line 1', noNewline: false),
            DiffLine(kind: 'addition', text: ' line 1', noNewline: false),
            DiffLine(kind: 'context', text: 'line 2', noNewline: false),
          ],
        ),
      );
      _success(await apply(contextPatch));
      final index = await File('${repository.path}/.git/index').readAsBytes();
      final rejected = await apply(patch);
      expect(rejected.exitCode, isNot(0));
      expect(_stderr(rejected), contains('patch does not apply'));
      expect(
        await File('${repository.path}/.git/index').readAsBytes(),
        orderedEquals(index),
      );
      await expectIndex(
        'tracked',
        baseline.replaceFirst('line 1\n', ' line 1\n'),
      );
      expect(await _workingHashes(repository), working);
    },
  );

  test('text patch OIDs and check are not index compare-and-swap', () async {
    await fixture({'tracked': baseline});
    await write('tracked', both);
    final file = (await capture()).files.single;
    final oldOid = _blobOid(utf8.encode(baseline));
    final newOid = _blobOid(utf8.encode(first));
    final patch = _patch(
      'tracked',
      file.hunks.first,
      index: '$oldOid..$newOid 100644',
    );
    final working = await _workingHashes(repository);
    _success(await apply(patch, check: true));
    _success(await apply(_patch('tracked', file.hunks.last)));
    await expectIndex('tracked', second);
    // The old OID is now stale, and the new OID describes only the first hunk.
    // Git still succeeds. Callers need revalidation and exact post-write checks;
    // neither an index header nor a separate --check is an atomic stale guard.
    _success(await apply(patch));
    await expectIndex('tracked', both);
    expect(await _workingHashes(repository), working);
  });

  for (final reverse in [false, true]) {
    test(
      'index lock rejects ${reverse ? 'reverse' : 'forward'} without writes',
      () async {
        await fixture({'tracked': baseline});
        await write('tracked', both);
        if (reverse) await _git(repository, ['add', '--', 'tracked']);
        final file = (await capture(staged: reverse)).files.single;
        final index = await File('${repository.path}/.git/index').readAsBytes();
        final working = await _workingHashes(repository);
        final lock = File('${repository.path}/.git/index.lock');
        await lock.writeAsString('another writer owns this lock\n');
        final result = await apply(
          _patch('tracked', file.hunks.first),
          reverse: reverse,
        );
        expect(result.exitCode, isNot(0));
        expect(_stderr(result), contains('index.lock'));
        expect(_stderr(result), contains('File exists'));
        expect(await lock.readAsString(), 'another writer owns this lock\n');
        expect(
          await File('${repository.path}/.git/index').readAsBytes(),
          orderedEquals(index),
        );
        await expectIndex('tracked', reverse ? both : baseline);
        expect(await _workingHashes(repository), working);
      },
    );
  }

  test(
    'concurrent cached writers cannot both apply the same selected hunk',
    () async {
      await fixture({'tracked': baseline, 'untouched': 'unrelated\n'});
      await write('tracked', both);
      final file = (await capture()).files.single;
      final patch = _patch('tracked', file.hunks.first);
      final working = await _workingHashes(repository);
      final results = await Future.wait([apply(patch), apply(patch)]);
      expect(results.where((result) => result.exitCode == 0), hasLength(1));
      _success(results.singleWhere((result) => result.exitCode == 0));
      final rejected = results.singleWhere((result) => result.exitCode != 0);
      // Scheduling may serialize the children: the loser then sees changed text
      // instead of a live lock. Either outcome must retain exactly one result.
      expect(
        _stderr(rejected),
        anyOf(contains('index.lock'), contains('patch does not apply')),
      );
      await expectIndex('tracked', first);
      await expectIndex('untouched', 'unrelated\n');
      expect(await _workingHashes(repository), working);
      expect(
        await File('${repository.path}/.git/index.lock').exists(),
        isFalse,
      );
    },
  );

  test(
    'cached apply never executes configured helpers, even beyond preflight',
    () async {
      const paths = ['tracked', 'clean', 'process', 'custom'];
      await fixture({for (final path in paths) path: baseline});
      for (final path in paths) {
        await write(path, both);
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
        final helper = File('${container.path}/$name');
        await helper.writeAsString(
          '#!/bin/sh\nprintf executed > "${container.path}/$name.executed"\nexit 99\n',
        );
        final chmod = await Process.run('/usr/bin/chmod', ['+x', helper.path]);
        expect(chmod.exitCode, 0);
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
        ('core.hooksPath', container.path),
        ('core.untrackedCache', 'true'),
      ]) {
        await _git(repository, ['config', key, value]);
      }
      await File('${repository.path}/.git/info/attributes').writeAsString(
        'clean filter=clean\nprocess filter=process\ncustom diff=hostile\n',
      );
      processes.environment.addAll({
        'GIT_EXTERNAL_DIFF': helpers['external']!,
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'core.fsmonitor',
        'GIT_CONFIG_VALUE_0': helpers['fsmonitor']!,
        'GIT_INDEX_FILE': '${container.path}/wrong-index',
        'GIT_DIR': '${container.path}/wrong-repository',
        'GIT_TRACE': '${container.path}/trace.executed',
      });
      final files = {
        for (final file in (await capture()).files) file.relativePath: file,
      };
      final ordinary = files['tracked']!;
      expect(ordinary.contentStatus, 'text');
      expect(ordinary.hunks, hasLength(2));
      for (final path in paths.skip(1)) {
        expect(files[path]!.contentStatus, 'unsupported');
        expect(files[path]!.hunks, isEmpty);
      }
      final working = await _workingHashes(repository);
      final config = await File('${repository.path}/.git/config').readAsBytes();
      for (final path in paths) {
        // Deliberately bypass classification for three fixture paths to establish
        // whether cached apply itself can run their configured filters/drivers.
        // This does not authorize such paths in any production mutation policy.
        for (final full in [false, true]) {
          final patch = _fullPatch(
            path,
            full ? ordinary.hunks : [ordinary.hunks.first],
          );
          _success(await apply(patch, check: true));
          _success(await apply(patch));
          await expectIndex(path, full ? both : first);
          _success(await apply(patch, reverse: true, check: true));
          _success(await apply(patch, reverse: true));
          await expectIndex(path, baseline);
        }
        await File('${repository.path}/$path').delete();
        final absentWorking = await _workingHashes(repository);
        final deletion = _deletionPatch(
          path,
          baseline,
          mode: '100644',
          oid: _blobOid(utf8.encode(baseline)),
        );
        // Exercise cached deletion and reversal even with hostile attributes;
        // production still rejects conversion/custom-diff targets beforehand.
        _success(await apply(deletion, check: true));
        _success(await apply(deletion));
        expect(
          _success(
            await command(['ls-files', '--stage', '-z', '--', './$path']),
          ),
          isEmpty,
        );
        _success(await apply(deletion, reverse: true, check: true));
        _success(await apply(deletion, reverse: true));
        await expectIndex(path, baseline);
        expect(await _workingHashes(repository), absentWorking);
        expect(
          await FileSystemEntity.type(
            '${repository.path}/$path',
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
        await write(path, both);
      }
      for (final (path, text) in [
        ('new-clean', 'new text\n'),
        ('new-process', ''),
      ]) {
        await write(path, text);
        final bytes = await File('${repository.path}/$path').readAsBytes();
        final patch = _additionPatch(path, text);
        // Also bypass the production conversion exclusion for an absent entry.
        // Cached addition/removal itself must not invoke either configured filter.
        await File('${repository.path}/.git/info/attributes').writeAsString(
          'clean filter=clean\nprocess filter=process\ncustom diff=hostile\n'
          'new-clean filter=clean\nnew-process filter=process\n',
        );
        _success(await apply(patch, check: true));
        _success(await apply(patch));
        await expectIndex(path, text);
        _success(await apply(patch, reverse: true, check: true));
        _success(await apply(patch, reverse: true));
        expect(
          _success(
            await command(['ls-files', '--stage', '-z', '--', './$path']),
          ),
          isEmpty,
        );
        expect(await File('${repository.path}/$path').readAsBytes(), bytes);
        await File('${repository.path}/$path').delete();
      }
      expect(await _workingHashes(repository), working);
      expect(
        await File('${repository.path}/.git/config').readAsBytes(),
        orderedEquals(config),
      );
      for (final name in [...helpers.keys, 'trace']) {
        expect(
          await File('${container.path}/$name.executed').exists(),
          isFalse,
          reason: '$name executed during preflight or cached apply',
        );
      }
      expect(await File('${container.path}/wrong-index').exists(), isFalse);

      // Real Git positive controls prove each trap is configured and executable.
      for (final path in ['clean', 'process']) {
        final result = await _gitResult(repository, [
          'hash-object',
          '--path=$path',
          path,
        ]);
        expect(result.exitCode, isNot(0));
        expect(await File('${container.path}/$path.executed').exists(), isTrue);
      }
      for (final name in ['external', 'textconv']) {
        final result = await _gitResult(repository, [
          '-c',
          'core.fsmonitor=false',
          if (name == 'textconv') ...['-c', 'diff.hostile.command='],
          'diff',
          if (name == 'textconv') ...['--no-ext-diff', '--textconv'],
          '--',
          name == 'textconv' ? 'custom' : 'tracked',
        ]);
        expect(result.exitCode, isNot(0));
        expect(await File('${container.path}/$name.executed').exists(), isTrue);
      }
      await _gitResult(repository, ['status', '--porcelain']);
      expect(
        await File('${container.path}/fsmonitor.executed').exists(),
        isTrue,
      );
      await _git(repository, [
        '-c',
        'core.fsmonitor=false',
        'update-index',
        '--chmod=+x',
        'tracked',
      ]);
      expect(
        await File('${container.path}/post-index-change.executed').exists(),
        isTrue,
      );
    },
  );
}

// Reuse the actual production shell/environment/pinned roots, not a parallel
// hygiene implementation. Only the ls-files suffix and binary stdin are replaced.
EnvironmentBufferedProcessRequest _withCommand(
  EnvironmentBufferedProcessRequest source,
  List<String> command, {
  required String input,
}) {
  final split = source.arguments.indexOf('ls-files');
  expect(split, greaterThan(0));
  return EnvironmentBufferedProcessRequest(
    program: source.program,
    arguments: [...source.arguments.take(split), ...command],
    relativeWorkingDirectory: source.relativeWorkingDirectory,
    timeoutSeconds: source.timeoutSeconds,
    stdinBase64: base64Encode(utf8.encode(input)),
  );
}

String _quote(String path) =>
    '"${path.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\t', r'\t').replaceAll('\n', r'\n').replaceAll('\r', r'\r')}"';

String _patch(String path, DiffHunk hunk, {String? index}) {
  return _fullPatch(path, [hunk], index: index);
}

String _fullPatch(String path, List<DiffHunk> hunks, {String? index}) {
  final oldPath = _quote('a/$path');
  final newPath = _quote('b/$path');
  final result = StringBuffer('diff --git $oldPath $newPath\n');
  if (index != null) result.writeln('index $index');
  result
    ..writeln('--- $oldPath')
    ..writeln('+++ $newPath');
  for (final hunk in hunks) {
    result.writeln(
      '@@ -${hunk.oldStart},${hunk.oldCount} +${hunk.newStart},${hunk.newCount} @@',
    );
    for (final line in hunk.lines) {
      final marker = switch (line.kind) {
        'context' => ' ',
        'deletion' => '-',
        'addition' => '+',
        _ => throw StateError('Unexpected hunk line kind: ${line.kind}'),
      };
      result.writeln('$marker${line.text}');
      if (line.noNewline) result.writeln(r'\ No newline at end of file');
    }
  }
  return result.toString();
}

String _combinedPatch(Map<String, String> patches) {
  final paths = patches.keys.toList()..sort();
  return paths.map((path) => patches[path]!).join();
}

String _additionPatch(
  String path,
  String text, {
  String mode = '100644',
  String? oid,
}) {
  oid ??= _blobOid(utf8.encode(text));
  final patch = StringBuffer()
    ..writeln('diff --git ${_quote('a/$path')} ${_quote('b/$path')}')
    ..writeln('new file mode $mode')
    ..writeln('index ${'0' * oid.length}..$oid')
    ..writeln('--- /dev/null')
    ..writeln('+++ ${_quote('b/$path')}');
  if (text.isNotEmpty) {
    final lines = text.split('\n');
    if (text.endsWith('\n')) lines.removeLast();
    patch.writeln('@@ -0,0 +1,${lines.length} @@');
    for (final line in lines) {
      patch.writeln('+$line');
    }
    if (!text.endsWith('\n')) patch.writeln(r'\ No newline at end of file');
  }
  return patch.toString();
}

String _blobOid(List<int> bytes, {bool sha256Format = false}) =>
    (sha256Format ? sha256 : sha1).convert([
      ...utf8.encode('blob ${bytes.length}\u0000'),
      ...bytes,
    ]).toString();

String _deletionPatch(
  String path,
  String text, {
  required String mode,
  required String oid,
}) {
  final patch = StringBuffer()
    ..writeln('diff --git ${_quote('a/$path')} ${_quote('b/$path')}')
    ..writeln('deleted file mode $mode')
    ..writeln('index $oid..${'0' * oid.length}')
    ..writeln('--- ${_quote('a/$path')}')
    ..writeln('+++ /dev/null');
  if (text.isNotEmpty) {
    final lines = text.split('\n');
    if (text.endsWith('\n')) lines.removeLast();
    patch.writeln('@@ -1,${lines.length} +0,0 @@');
    for (final line in lines) {
      patch.writeln('-$line');
    }
    if (!text.endsWith('\n')) patch.writeln(r'\ No newline at end of file');
  }
  return patch.toString();
}

String _stderr(EnvironmentBufferedProcessResult result) =>
    utf8.decode(base64Decode(result.stderrBase64));

List<int> _success(EnvironmentBufferedProcessResult result) {
  expect(result.exitCode, 0, reason: _stderr(result));
  expect(_stderr(result), isEmpty);
  return base64Decode(result.stdoutBase64);
}

Future<Map<String, Object>> _workingHashes(Directory root) async {
  final hashes = <String, Object>{};
  Future<void> visit(Directory directory) async {
    await for (final entry in directory.list(followLinks: false)) {
      if (entry.path == '${root.path}/.git') continue;
      if (entry is Directory) {
        await visit(entry);
      } else if (entry is File) {
        final stat = await entry.stat();
        hashes[entry.path.substring(root.path.length + 1)] = (
          sha256.convert(await entry.readAsBytes()).toString(),
          stat.size,
          stat.mode,
        );
      } else {
        throw StateError('Unexpected working-tree entry: ${entry.path}');
      }
    }
  }

  await visit(root);
  return hashes;
}

final class _Processes implements AuthorizedEnvironmentBufferedProcessService {
  _Processes(this.root, Directory home)
    : environment = {
        'PATH': '/usr/bin:/bin',
        'HOME': home.path,
        'XDG_CONFIG_HOME': '${home.path}/config',
      };

  final Directory root;
  final Map<String, String> environment;
  final requests = <EnvironmentBufferedProcessRequest>[];

  @override
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async =>
      AuthorizedEnvironmentIdentity(
        sessionId: 'feasibility-session',
        environmentId: 'feasibility-environment',
      );

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    requests.add(request);
    final process = await Process.start(
      request.program,
      request.arguments,
      workingDirectory: root.path,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    try {
      final results = await Future.wait<Object?>([
        _capture(process.stdout, environmentBufferedProcessStdoutLimit),
        _capture(process.stderr, environmentBufferedProcessStderrLimit),
        process.exitCode,
        () async {
          process.stdin.add(base64Decode(request.stdinBase64));
          await process.stdin.close();
        }(),
      ], eagerError: true).timeout(Duration(seconds: request.timeoutSeconds));
      return EnvironmentBufferedProcessResult(
        exitCode: results[2]! as int,
        stdoutBase64: base64Encode(results[0]! as List<int>),
        stderrBase64: base64Encode(results[1]! as List<int>),
      );
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
}

Future<List<int>> _capture(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw StateError('Output overflow');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<String> _git(Directory root, List<String> arguments) async {
  final result = await _gitResult(root, arguments);
  expect(result.exitCode, 0, reason: 'git $arguments: ${result.stderr}');
  return result.stdout as String;
}

Future<ProcessResult> _gitResult(Directory root, List<String> arguments) =>
    Process.run(
      '/usr/bin/git',
      arguments,
      workingDirectory: root.path,
      environment: {
        'PATH': '/usr/bin:/bin',
        'HOME': root.parent.path,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'LC_ALL': 'C',
      },
      includeParentEnvironment: false,
      runInShell: false,
    );
