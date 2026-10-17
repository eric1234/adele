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
    show GitPortableUnstagedLimits, GitPortableUnstagedSnapshotService;
import 'package:test/test.dart';

void main() {
  late Directory container;
  late Directory repository;
  late _FixtureProcesses processes;

  setUp(() async {
    container = await Directory.systemTemp.createTemp('adele-portable-git-');
    repository = await Directory('${container.path}/repository').create();
    processes = _FixtureProcesses(repository, container);
    await _git(repository, ['init', '--initial-branch=main']);
    await _git(repository, ['config', 'user.name', 'ADELE Test']);
    await _git(repository, ['config', 'user.email', 'adele@example.invalid']);
    await File('${repository.path}/baseline').writeAsString('baseline\n');
    await _git(repository, ['add', '--', 'baseline']);
    await _git(repository, ['commit', '-m', 'Fixture']);
  });

  tearDown(() async {
    await processes.close();
    await container.delete(recursive: true);
  });

  Future<void> write(String path, String text) async {
    final file = File('${repository.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Future<void> commit() async {
    await _git(repository, ['add', '--all']);
    await _git(repository, ['commit', '-m', 'Fixture paths']);
  }

  Future<ChangeSetSnapshot> snapshot({
    AuthorizedEnvironmentBufferedProcessService? through,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) => GitPortableUnstagedSnapshotService(
    processes: through ?? processes,
    limits: limits,
  ).snapshotUnstaged();

  test(
    'default process budget covers batched inventory and changed-file work',
    () {
      const limits = GitPortableUnstagedLimits();
      // Initial/hash/post-hash/final batches, plus fixed setup and final checks.
      final flatCleanRequests =
          4 * ((limits.inventoryEntries + 127) ~/ 128) + 20;
      expect(limits.inventoryEntries, 4096);
      expect(limits.processes, 4096);
      expect(
        limits.processes,
        greaterThan(flatCleanRequests + 10 * limits.files),
      );
      expect(limits.operationTimeout, const Duration(seconds: 30));
      expect(limits.processTimeout, const Duration(seconds: 10));
    },
  );

  test('clean scans scale by batches rather than per-file processes', () async {
    for (var index = 1; index < 160; index++) {
      await write('file-${index.toString().padLeft(3, '0')}', 'small\n');
    }
    await commit();
    final before = await _fingerprint(repository);
    expect((await snapshot()).files, isEmpty);
    expect(processes.requests, hasLength(20 + 4 * 2));
    final hashes = processes.requests
        .where((request) => request.arguments.contains('hash-object'))
        .toList();
    expect(hashes, hasLength(2));
    expect(
      hashes.every((request) => request.arguments.contains('--no-filters')),
      isTrue,
    );
    expect(
      processes.requests.where(
        (request) => request.arguments.contains('/usr/bin/head'),
      ),
      isEmpty,
    );
    expect(await _fingerprint(repository), before);
  });

  test(
    'long literal paths split batches within complete transport metadata bounds',
    () async {
      final parent = List.generate(
        6,
        (index) => '$index${'p' * 180}',
      ).join('/');
      for (var index = 0; index < 75; index++) {
        await write('$parent/file-$index', 'small\n');
      }
      await commit();
      expect((await snapshot()).files, isEmpty);
      expect(
        processes.requests
            .where((request) => request.arguments.contains('hash-object'))
            .length,
        greaterThan(1),
      );
      for (final request in processes.requests) {
        expect(request.arguments.length, lessThanOrEqualTo(256));
        expect(
          request.program.length +
              request.relativeWorkingDirectory.length +
              request.arguments.fold<int>(0, (sum, arg) => sum + arg.length),
          lessThanOrEqualTo(65536),
        );
      }
      expect(processes.requests.length, lessThan(50));
    },
  );

  test(
    'failure in a later real hash batch never publishes its successful prefix',
    () async {
      for (var index = 1; index < 160; index++) {
        await write('file-${index.toString().padLeft(3, '0')}', 'small\n');
      }
      await commit();
      var hashes = 0;
      final through = _InterceptingProcesses(processes, (request, run) async {
        if (request.arguments.contains('hash-object') && ++hashes == 2) {
          await File('${repository.path}/file-159').delete();
        }
        return run(request);
      });
      await expectLater(
        snapshot(through: through),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'git_failed',
          ),
        ),
      );
      expect(hashes, 2);
    },
  );

  test(
    'raw hash input is charged even though only small OIDs cross transport',
    () async {
      await write('large-clean', 'x' * (64 * 1024));
      await commit();
      await expectLater(
        snapshot(
          limits: const GitPortableUnstagedLimits(totalBytes: 64 * 1024),
        ),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'snapshot_too_large',
          ),
        ),
      );
      expect(
        processes.requests.where(
          (request) => request.arguments.contains('hash-object'),
        ),
        isEmpty,
      );
      expect(
        processes.requests.where(
          (request) => request.arguments.contains('/usr/bin/head'),
        ),
        isEmpty,
      );
    },
  );

  test('parent metadata has a bounded observation inventory', () async {
    await write('one/two/three/file', 'small\n');
    await commit();
    await expectLater(
      snapshot(limits: const GitPortableUnstagedLimits(inventoryEntries: 2)),
      throwsA(
        isA<ChangeSetFailure>().having(
          (error) => error.code,
          'code',
          'snapshot_too_large',
        ),
      ),
    );
  });

  test(
    'deep parent names are bounded before metadata requests or retention grows',
    () async {
      final path = '${List.filled(200, 'segment' * 20).join('/')}/file';
      final through = _InterceptingProcesses(processes, (request, run) async {
        final result = await run(request);
        if (!request.arguments.contains('--cached')) return result;
        final raw = utf8.decode(base64Decode(result.stdoutBase64));
        return _result(stdout: raw.replaceFirst('baseline\x00', '$path\x00'));
      });
      await expectLater(
        snapshot(
          through: through,
          limits: const GitPortableUnstagedLimits(totalBytes: 128 * 1024),
        ),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'snapshot_too_large',
          ),
        ),
      );
      expect(
        processes.requests.where(
          (request) => request.arguments.contains('/usr/bin/stat'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'oversized hash batches retain unknown entries beyond their aggregate budget',
    () async {
      for (final path in ['large-a', 'large-b', 'large-c']) {
        await write(path, 'x' * 128);
      }
      await commit();
      final result = await snapshot(
        limits: const GitPortableUnstagedLimits(
          fileBytes: 64,
          verificationFileBytes: 256,
          verificationTotalBytes: 256,
        ),
      );
      expect(result.files.single.relativePath, 'large-c');
      expect(result.files.single.changeKind, 'unsupported');
      expect(result.files.single.contentStatus, 'oversized');
      final operands = processes.requests
          .where((request) => request.arguments.contains('hash-object'))
          .expand((request) => request.arguments);
      expect(operands, containsAll(['./large-a', './large-b']));
      expect(operands, isNot(contains('./large-c')));
    },
  );

  test('raw batch hashing supports SHA-256 index identities', () async {
    final shaRepository = await Directory('${container.path}/sha256').create();
    await _git(shaRepository, ['init', '--object-format=sha256']);
    final file = File('${shaRepository.path}/tracked');
    await file.writeAsString('before\n');
    await _git(shaRepository, ['add', '--', 'tracked']);
    processes = _FixtureProcesses(shaRepository, container);
    expect((await snapshot()).files, isEmpty);
    await file.writeAsString('after\n');
    final changed = (await snapshot()).files.single;
    expect(changed.relativePath, 'tracked');
    expect(_lines(changed), ['deletion:before', 'addition:after']);
  });

  test(
    'raw hashes do not trust stale index timestamps or matching file sizes',
    () async {
      final file = File('${repository.path}/baseline');
      final previous = await file.lastModified();
      await file.writeAsString('changed!\n');
      await file.setLastModified(previous);
      final changed = (await snapshot()).files.single;
      expect(_lines(changed), ['deletion:baseline', 'addition:changed!']);
      expect(
        processes.requests.any(
          (request) => request.arguments.contains('hash-object'),
        ),
        isTrue,
      );
    },
  );

  for (final command in ['stat', 'hash-object']) {
    for (final corruption in [
      'missing',
      'extra',
      'malformed',
      if (command == 'stat') 'reordered',
      if (command == 'stat') 'metadata terminator',
      'partial failure',
      'warning',
    ]) {
      test(
        '$command batch $corruption fails instead of publishing clean',
        () async {
          await write('second', 'second\n');
          await commit();
          var intercepted = false;
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            if (intercepted ||
                !request.arguments.contains(
                  command == 'stat' ? '/usr/bin/stat' : command,
                )) {
              return result;
            }
            intercepted = true;
            final raw = utf8.decode(base64Decode(result.stdoutBase64));
            final delimiter = command == 'stat' ? '\x00' : '\n';
            final records = raw.substring(0, raw.length - 1).split(delimiter);
            final width = command == 'stat' ? 2 : 1;
            switch (corruption) {
              case 'missing':
              case 'partial failure':
                records.removeRange(records.length - width, records.length);
              case 'extra':
                records.addAll(records.take(width).toList());
              case 'malformed':
                records[0] = command == 'stat' ? './wrong-path' : 'not-an-oid';
              case 'reordered':
                final first = records.take(2).toList();
                records.replaceRange(0, 2, records.sublist(2, 4));
                records.replaceRange(2, 4, first);
              case 'metadata terminator':
                records[1] = '${records[1]}\n';
              case 'warning':
                break;
            }
            return _result(
              stdout: '${records.join(delimiter)}$delimiter',
              exitCode: corruption == 'partial failure' ? 1 : 0,
              stderr: const ['partial failure', 'warning'].contains(corruption)
                  ? 'incomplete observation\n'
                  : '',
            );
          });
          await expectLater(
            snapshot(through: through),
            throwsA(
              isA<ChangeSetFailure>().having(
                (error) => error.code,
                'code',
                const ['partial failure', 'warning'].contains(corruption)
                    ? 'git_failed'
                    : 'invalid_git_output',
              ),
            ),
          );
          expect(intercepted, isTrue);
        },
      );
    }
  }

  for (final phase in ['post-hash', 'final metadata']) {
    test('clean file mutation at $phase fails the complete snapshot', () async {
      var statCount = 0;
      var changed = false;
      final through = _InterceptingProcesses(processes, (request, run) async {
        if (request.arguments.contains('/usr/bin/stat')) {
          statCount++;
          if (statCount == (phase == 'post-hash' ? 2 : 3)) {
            changed = true;
            await write('baseline', 'changed!\n');
          }
        }
        return run(request);
      });
      await expectLater(
        snapshot(through: through),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'snapshot_changed',
          ),
        ),
      );
      expect(changed, isTrue);
    });
  }

  test(
    'clean and staged-only snapshots are empty and never mutate Git',
    () async {
      var before = await _fingerprint(repository);
      expect((await snapshot()).files, isEmpty);
      expect(await _fingerprint(repository), before);

      await write('baseline', 'staged only\n');
      await write('staged-new', 'already indexed\n');
      await _git(repository, ['add', '--all']);
      before = await _fingerprint(repository);
      expect((await snapshot()).files, isEmpty);
      expect(await _fingerprint(repository), before);
      expect(processes.requests, isNotEmpty);
      expect(
        processes.requests.every((request) => request.program == '/bin/sh'),
        isTrue,
      );
    },
  );

  test(
    'index is the baseline for modified deleted and untracked files',
    () async {
      await write('deleted', 'remove me\n');
      await write('.gitignore', 'ignored\n');
      await commit();
      await write('baseline', 'indexed\n');
      await _git(repository, ['add', '--', 'baseline']);
      await write('baseline', 'working\n');
      await File('${repository.path}/deleted').delete();
      await write('untracked', 'new\n');
      await write('ignored', 'must not appear\n');
      final before = await _fingerprint(repository);

      final files = (await snapshot()).files;
      expect(files.map((file) => file.relativePath), [
        'baseline',
        'deleted',
        'untracked',
      ]);
      expect(files.map((file) => file.changeKind), [
        'modified',
        'deleted',
        'added',
      ]);
      expect(files.every((file) => file.contentStatus == 'text'), isTrue);
      expect(_lines(files[0]), ['deletion:indexed', 'addition:working']);
      expect(_lines(files[1]), ['deletion:remove me']);
      expect(_lines(files[2]), ['addition:new']);
      expect(await _fingerprint(repository), before);
    },
  );

  test('implicit Git boolean configuration remains supported', () async {
    await File(
      '${repository.path}/.git/config',
    ).writeAsString('\n[core]\nfilemode\n', mode: FileMode.append);
    expect((await snapshot()).files, isEmpty);
    await write('baseline', 'after\n');
    final file = (await snapshot()).files.single;
    expect(file.changeKind, 'modified');
    expect(_lines(file), ['deletion:baseline', 'addition:after']);
  });

  const booleanCases = [
    (null, true),
    ('true', true),
    ('yes', true),
    ('on', true),
    ('1', true),
    ('false', false),
    ('no', false),
    ('off', false),
    ('0', false),
    ('', false),
  ];

  test(
    'Git filemode booleans distinguish implicit true and empty false',
    () async {
      await _command('/usr/bin/chmod', ['755', '${repository.path}/baseline']);
      for (final (value, enabled) in booleanCases) {
        await File('${repository.path}/.git/config').writeAsString(
          '\n[core]\nfilemode${value == null ? '' : ' = $value'}\n',
          mode: FileMode.append,
        );
        expect(
          await _git(repository, [
            'config',
            '--bool',
            '--get',
            'core.filemode',
          ]),
          '$enabled\n',
        );
        final files = (await snapshot()).files;
        if (enabled) {
          expect(
            files.single.changeKind,
            'typeChanged',
            reason: 'filemode=$value',
          );
          expect(files.single.contentStatus, 'unsupported');
        } else {
          expect(files, isEmpty, reason: 'filemode=$value');
        }
      }
      await write('baseline', 'indexed\n');
      await _git(repository, ['add', '--', 'baseline']);
      expect((await snapshot()).files, isEmpty);
      await write('baseline', 'working\n');
      final file = (await snapshot()).files.single;
      expect(file.changeKind, 'modified');
      expect(file.contentStatus, 'text');
      expect(_lines(file), ['deletion:indexed', 'addition:working']);
    },
  );

  test(
    'Git autocrlf booleans distinguish implicit true and empty false',
    () async {
      await write('baseline', 'baseline\r\n');
      for (final (value, enabled) in booleanCases) {
        await File('${repository.path}/.git/config').writeAsString(
          '\n[core]\nautocrlf${value == null ? '' : ' = $value'}\n',
          mode: FileMode.append,
        );
        expect(
          await _git(repository, [
            'config',
            '--bool',
            '--get',
            'core.autocrlf',
          ]),
          '$enabled\n',
        );
        final file = (await snapshot()).files.single;
        expect(file.changeKind, 'modified');
        expect(
          file.contentStatus,
          enabled ? 'unsupported' : 'text',
          reason: 'autocrlf=$value',
        );
        if (enabled) {
          expect(file.hunks, isEmpty);
        } else {
          expect(_lines(file), ['deletion:baseline', 'addition:baseline\r']);
        }
      }
    },
  );

  for (final (rule, attribute, conversion) in [
    ('crlf', 'set', true),
    ('crlf=input', 'input', true),
    ('-crlf', 'unset', false),
    ('', 'unspecified', false),
  ]) {
    test(
      'legacy crlf attribute ${rule.isEmpty ? 'unspecified' : rule} preserves raw-content classification',
      () async {
        await write('converted.txt', 'same\n');
        await commit();
        await File(
          '${repository.path}/.git/info/attributes',
        ).writeAsString(rule.isEmpty ? '' : '*.txt $rule\n');
        await write('converted.txt', 'same\r\n');
        expect(await _git(repository, ['show', ':converted.txt']), 'same\n');
        expect(
          await _git(repository, [
            'check-attr',
            '-z',
            'crlf',
            '--',
            'converted.txt',
          ]),
          'converted.txt\x00crlf\x00$attribute\x00',
        );
        if (conversion) {
          expect(
            (await _gitResult(repository, [
              'diff',
              '--quiet',
              '--',
              'converted.txt',
            ])).exitCode,
            0,
          );
        }
        final file = (await snapshot()).files.single;
        expect(file.relativePath, 'converted.txt');
        expect(file.contentStatus, conversion ? 'unsupported' : 'text');
        if (conversion) {
          expect(file.hunks, isEmpty);
          expect(file.detail, isNotEmpty);
        } else {
          expect(_lines(file), ['deletion:same', 'addition:same\r']);
        }
      },
    );
  }

  for (final corruption in ['framing', 'count', 'order', 'path']) {
    test(
      'malformed $corruption in attribute observation fails closed',
      () async {
        await write('baseline', 'working\n');
        await File(
          '${repository.path}/.git/info/attributes',
        ).writeAsString('baseline -diff\n');
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (!request.arguments.contains('check-attr')) return result;
          final raw = utf8.decode(base64Decode(result.stdoutBase64));
          final fields = raw.split('\x00');
          switch (corruption) {
            case 'framing':
              fields.removeLast();
            case 'count':
              fields.removeRange(18, 21);
            case 'order':
              fields[19] = 'crlf';
            case 'path':
              fields[18] = 'different-path';
          }
          return _result(stdout: fields.join('\x00'));
        });
        await expectLater(
          snapshot(through: through),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              'invalid_git_output',
            ),
          ),
        );
      },
    );
  }

  test('multiple hunks retain exact coordinates and line contents', () async {
    final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
    await write('baseline', original);
    await commit();
    await write(
      'baseline',
      original
          .replaceFirst('line 1\n', 'first edit\n')
          .replaceFirst('line 27\n', 'last edit\n'),
    );

    final file = (await snapshot()).files.single;
    expect(file.hunks, hasLength(2));
    expect(
      file.hunks.map(
        (hunk) => (hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount),
      ),
      [(1, 5, 1, 5), (25, 6, 25, 6)],
    );
    expect(
      file.hunks
          .expand((hunk) => hunk.lines)
          .where((line) => line.kind != 'context')
          .map((line) => '${line.kind}:${line.text}'),
      [
        'deletion:line 1',
        'addition:first edit',
        'deletion:line 27',
        'addition:last edit',
      ],
    );
  });

  test(
    'the authorized cwd scopes paths without a caller-supplied root',
    () async {
      await write('selected/inside', 'before\n');
      await write('outside', 'outside before\n');
      await commit();
      await write('selected/inside', 'after\n');
      await write('outside', 'outside after\n');
      processes = _FixtureProcesses(
        Directory('${repository.path}/selected'),
        container,
      );

      final file = (await snapshot()).files.single;
      expect(file.relativePath, 'inside');
      expect(_lines(file), ['deletion:before', 'addition:after']);
    },
  );

  test(
    'punctuation tabs and newline paths remain literal and sorted',
    () async {
      const paths = [
        '-leading-option',
        ':(glob)*[x]',
        'quotes\'";\$(touch INJECTED)',
        'space name',
        'tab\tname',
        'line\nname',
      ];
      for (final path in paths) {
        await write(path, 'before\n');
      }
      await commit();
      for (final path in paths) {
        await write(path, 'after\n');
      }
      await write('untracked\t\n:(literal)*', 'new\n');

      final files = (await snapshot()).files;
      expect(
        files.map((file) => file.relativePath),
        [...paths, 'untracked\t\n:(literal)*']..sort(),
      );
      for (final file in files.where(
        (file) => paths.contains(file.relativePath),
      )) {
        expect(_lines(file), ['deletion:before', 'addition:after']);
      }
      expect(await File('${repository.path}/INJECTED').exists(), isFalse);
    },
  );

  test(
    'missing final newlines and carriage returns are not normalized',
    () async {
      await write('baseline', 'before\r\nlast before');
      await commit();
      await write('baseline', 'after\r\nlast after');

      final lines = (await snapshot()).files.single.hunks.single.lines;
      expect(lines.map((line) => (line.kind, line.text, line.noNewline)), [
        ('deletion', 'before\r', false),
        ('deletion', 'last before', true),
        ('addition', 'after\r', false),
        ('addition', 'last after', true),
      ]);
    },
  );

  test('empty untracked and intent-to-add files are additions', () async {
    await write('empty', '');
    await write('intent-empty', '');
    await write('intent-text', 'intent\n');
    await _git(repository, [
      'add',
      '--intent-to-add',
      '--',
      'intent-empty',
      'intent-text',
    ]);

    final files = (await snapshot()).files;
    expect(files.map((file) => file.relativePath), [
      'empty',
      'intent-empty',
      'intent-text',
    ]);
    expect(files.every((file) => file.changeKind == 'added'), isTrue);
    expect(files.every((file) => file.contentStatus == 'text'), isTrue);
    expect(files[0].hunks, isEmpty);
    expect(files[1].hunks, isEmpty);
    expect(_lines(files[2]), ['addition:intent']);
  });

  test(
    'equal binary and invalid UTF-8 omit before dirty classification',
    () async {
      final binary = File('${repository.path}/binary');
      final invalid = File('${repository.path}/invalid-utf8');
      await binary.writeAsBytes([1, 0, 2]);
      await invalid.writeAsBytes([255, 254]);
      await commit();
      await binary.setLastModified(DateTime.utc(2000));
      await invalid.setLastModified(DateTime.utc(2000));
      expect((await snapshot()).files, isEmpty);

      await binary.writeAsBytes([2, 0, 3]);
      await invalid.writeAsBytes([254, 255]);
      final files = (await snapshot()).files;
      expect(files.map((file) => file.relativePath), [
        'binary',
        'invalid-utf8',
      ]);
      expect(files.map((file) => file.contentStatus), [
        'binary',
        'unsupported',
      ]);
      for (final file in files) {
        expect(file.changeKind, 'modified');
        expect(file.hunks, isEmpty);
        expect(file.detail, isNotEmpty);
      }
    },
  );

  test(
    'oversized equality is unknown but size changes and additions are known',
    () async {
      final large = 'x' * (1024 * 1024 + 1);
      await write('unknown', large);
      await write('resized', large);
      await write('deleted-large', large);
      await commit();
      await write('resized', 'small now\n');
      await File('${repository.path}/deleted-large').delete();
      await write('new-large', large);

      final files = {
        for (final file in (await snapshot(
          limits: const GitPortableUnstagedLimits(
            verificationFileBytes: 1024 * 1024,
          ),
        )).files)
          file.relativePath: file,
      };
      expect(files.keys, ['deleted-large', 'new-large', 'resized', 'unknown']);
      expect(files['unknown']!.changeKind, 'unsupported');
      expect(files['resized']!.changeKind, 'modified');
      expect(files['new-large']!.changeKind, 'added');
      expect(files['deleted-large']!.changeKind, 'deleted');
      for (final file in files.values) {
        expect(file.contentStatus, 'oversized');
        expect(file.hunks, isEmpty);
        expect(file.detail, isNotEmpty);
      }
      expect(
        processes.requests.where(
          (request) => request.arguments.contains('/usr/bin/head'),
        ),
        isNotEmpty,
      );
    },
  );

  test(
    'bounded oversized verification omits equal raw data and confirms changes',
    () async {
      final bytes = List<int>.generate(128, (i) => i % 256);
      final file = File('${repository.path}/large');
      await file.writeAsBytes(bytes);
      await commit();
      await file.setLastModified(DateTime.utc(2000));
      const limits = GitPortableUnstagedLimits(
        fileBytes: 64,
        verificationFileBytes: 256,
      );
      expect((await snapshot(limits: limits)).files, isEmpty);

      bytes[127] ^= 1;
      await file.writeAsBytes(bytes);
      final changed = (await snapshot(limits: limits)).files.single;
      expect(changed.relativePath, 'large');
      expect(changed.changeKind, 'modified');
      expect(changed.contentStatus, 'oversized');
      expect(changed.hunks, isEmpty);
    },
  );

  test(
    'static symlinks and FIFOs never become outside ordinary text',
    () async {
      for (final path in ['link-file', 'link-fifo', 'fifo']) {
        await write(path, 'before\n');
      }
      final outside = File('${container.path}/outside-text');
      await outside.writeAsString('OUTSIDE_SECRET\n');
      await Link('${repository.path}/tracked-link').create(outside.path);
      await commit();
      await _command('/usr/bin/mkfifo', ['${container.path}/outside-fifo']);
      for (final path in ['link-file', 'link-fifo', 'fifo']) {
        await File('${repository.path}/$path').delete();
      }
      await Link('${repository.path}/link-file').create(outside.path);
      await Link(
        '${repository.path}/link-fifo',
      ).create('${container.path}/outside-fifo');
      await Link('${repository.path}/untracked-link').create(outside.path);
      await _command('/usr/bin/mkfifo', ['${repository.path}/fifo']);

      final result = await snapshot().timeout(const Duration(seconds: 5));
      final files = {for (final file in result.files) file.relativePath: file};
      for (final path in ['link-file', 'link-fifo', 'fifo', 'untracked-link']) {
        expect(files, contains(path));
        expect(files[path]!.contentStatus, 'unsupported');
        expect(files[path]!.hunks, isEmpty);
        expect(files[path]!.detail, isNotEmpty);
      }
      for (final file in result.files) {
        expect(_lines(file).join(), isNot(contains('OUTSIDE_SECRET')));
      }
      expect(await outside.readAsString(), 'OUTSIDE_SECRET\n');
    },
  );

  test(
    'a symlinked parent is conservative rather than a false deletion',
    () async {
      await write('parent/child', 'before\n');
      await commit();
      final outside = await Directory('${container.path}/outside').create();
      await File('${outside.path}/child').writeAsString('OUTSIDE_SECRET\n');
      await Directory('${repository.path}/parent').delete(recursive: true);
      await Link('${repository.path}/parent').create(outside.path);

      final files = (await snapshot()).files;
      final child = files.singleWhere(
        (file) => file.relativePath == 'parent/child',
      );
      expect(child.changeKind, 'unsupported');
      expect(child.contentStatus, 'unsupported');
      expect(child.hunks, isEmpty);
      expect(child.detail, isNotEmpty);
      expect(files.expand(_lines).join(), isNot(contains('OUTSIDE_SECRET')));
    },
  );

  test(
    'nested repositories and real submodules remain unsupported even when clean',
    () async {
      final nested = await Directory('${repository.path}/nested').create();
      await _git(nested, ['init']);
      await File('${nested.path}/child').writeAsString('nested secret\n');
      await _git(repository, [
        '-c',
        'protocol.file.allow=always',
        'submodule',
        'add',
        '--',
        repository.path,
        'module',
      ]);

      for (final dirty in [false, true]) {
        if (dirty) await write('module/baseline', 'dirty submodule\n');
        final files = (await snapshot()).files;
        expect(files.map((file) => file.relativePath), ['module', 'nested']);
        for (final file in files) {
          expect(file.changeKind, 'unsupported');
          expect(file.contentStatus, 'unsupported');
          expect(file.hunks, isEmpty);
          expect(file.detail, isNotEmpty);
        }
      }
    },
  );

  test(
    'unmerged index stages are one explicit conflict, not ordinary text',
    () async {
      await _git(repository, ['checkout', '-b', 'other']);
      await write('baseline', 'other\n');
      await commit();
      await _git(repository, ['checkout', 'main']);
      await write('baseline', 'main\n');
      await commit();
      final merge = await _gitResult(repository, [
        'merge',
        '--no-edit',
        'other',
      ]);
      expect(merge.exitCode, 1);

      final file = (await snapshot()).files.single;
      expect(file.relativePath, 'baseline');
      expect(file.changeKind, 'conflicted');
      expect(file.contentStatus, 'conflicted');
      expect(file.hunks, isEmpty);
    },
  );

  test(
    'skip-worktree and assume-unchanged never produce false clean results',
    () async {
      await write('skip', 'before\n');
      await write('assume', 'before\n');
      await commit();
      await _git(repository, ['update-index', '--skip-worktree', '--', 'skip']);
      await _git(repository, [
        'update-index',
        '--assume-unchanged',
        '--',
        'assume',
      ]);
      await write('skip', 'after\n');
      await write('assume', 'after\n');

      final files = (await snapshot()).files;
      expect(files.map((file) => file.relativePath), ['assume', 'skip']);
      for (final file in files) {
        expect(file.changeKind, 'unsupported');
        expect(file.contentStatus, 'unsupported');
        expect(file.hunks, isEmpty);
      }
    },
  );

  test(
    'hostile attributes filters drivers fsmonitor and hooks never execute',
    () async {
      for (final name in ['clean', 'process', 'custom', 'opaque', 'encoded']) {
        await write(name, 'before\n');
      }
      await commit();
      final marker = File('${container.path}/EXECUTED');
      final hook = File('${container.path}/hostile-hook');
      await hook.writeAsString(
        '#!/bin/sh\nprintf executed > "${marker.path}"\nexit 99\n',
      );
      await _command('/usr/bin/chmod', ['+x', hook.path]);
      for (final (key, value) in [
        ('filter.clean.clean', hook.path),
        ('filter.clean.required', 'true'),
        ('filter.process.process', hook.path),
        ('filter.process.required', 'true'),
        ('diff.hostile.textconv', hook.path),
        ('diff.hostile.command', hook.path),
        ('diff.external', hook.path),
        ('core.fsmonitor', hook.path),
        ('core.hooksPath', container.path),
      ]) {
        await _git(repository, ['config', key, value]);
      }
      await File(
        '${container.path}/post-index-change',
      ).writeAsString(await hook.readAsString());
      await _command('/usr/bin/chmod', [
        '+x',
        '${container.path}/post-index-change',
      ]);
      await write(
        '.gitattributes',
        'clean filter=clean\nprocess filter=process\ncustom diff=hostile\n'
            'opaque -diff\nencoded working-tree-encoding=UTF-16\n',
      );
      for (final name in ['clean', 'process', 'custom', 'opaque', 'encoded']) {
        await write(name, 'after\n');
      }
      final before = await _fingerprint(repository);

      final files = {
        for (final file in (await snapshot()).files) file.relativePath: file,
      };
      for (final name in ['clean', 'process', 'custom', 'encoded']) {
        expect(files[name]!.contentStatus, 'unsupported');
        expect(files[name]!.hunks, isEmpty);
      }
      expect(files['opaque']!.contentStatus, 'binary');
      expect(await marker.exists(), isFalse);
      expect(await _fingerprint(repository), before);
    },
  );

  test(
    'inherited Git routing and executable lookup cannot substitute a repository',
    () async {
      final foreign = await Directory('${container.path}/foreign').create();
      await _git(foreign, ['init']);
      await File(
        '${foreign.path}/foreign-file',
      ).writeAsString('not selected\n');
      await _git(foreign, ['add', '--all']);
      final marker = File('${container.path}/LOOKUP_EXECUTED');
      final fakeGit = File('${repository.path}/git');
      await fakeGit.writeAsString(
        '#!/bin/sh\nprintf executed > "${marker.path}"\nexit 99\n',
      );
      await _command('/usr/bin/chmod', ['+x', fakeGit.path]);
      await write('.gitignore', 'git\n');
      await commit();
      await write('baseline', 'selected\n');
      processes.environment.addAll({
        'PATH': '.:/usr/bin:/bin',
        'GIT_DIR': '${foreign.path}/.git',
        'GIT_WORK_TREE': foreign.path,
        'GIT_INDEX_FILE': '${foreign.path}/.git/index',
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'core.worktree',
        'GIT_CONFIG_VALUE_0': foreign.path,
      });

      final files = (await snapshot()).files;
      expect(files.single.relativePath, 'baseline');
      expect(_lines(files.single), ['deletion:baseline', 'addition:selected']);
      expect(await marker.exists(), isFalse);
    },
  );

  test(
    'missing promisor blobs cannot execute a configured remote helper',
    () async {
      final marker = File('${container.path}/REMOTE_EXECUTED');
      final helper = File('${container.path}/remote-helper');
      await helper.writeAsString(
        '#!/bin/sh\nprintf executed > "${marker.path}"\nexit 99\n',
      );
      await _command('/usr/bin/chmod', ['+x', helper.path]);
      final missing = utf8.encode('missing promisor baseline\n');
      final oid = sha1.convert([
        ...utf8.encode('blob ${missing.length}\x00'),
        ...missing,
      ]).toString();
      await _git(repository, [
        'update-index',
        '--cacheinfo',
        '100644,$oid,baseline',
      ]);
      for (final (key, value) in [
        ('remote.origin.url', 'ext::${helper.path}'),
        ('remote.origin.promisor', 'true'),
        ('remote.origin.partialclonefilter', 'blob:none'),
        ('protocol.ext.allow', 'always'),
      ]) {
        await _git(repository, ['config', key, value]);
      }
      final before = await _fingerprint(repository);
      await expectLater(
        snapshot(),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'git_failed',
          ),
        ),
      );
      expect(await marker.exists(), isFalse);
      expect(await _fingerprint(repository), before);
    },
  );

  test(
    'global ignore configuration still applies to untracked inventory',
    () async {
      final ignore = File('${container.path}/global-ignore');
      await ignore.writeAsString('globally-ignored\n');
      await File(
        '${container.path}/.gitconfig',
      ).writeAsString('[core]\nexcludesFile = ${ignore.path}\n');
      await write('globally-ignored', 'not a Git addition\n');
      await write('visible', 'visible addition\n');
      expect((await snapshot()).files.map((file) => file.relativePath), [
        'visible',
      ]);
    },
  );

  for (final failure in [
    'malformed inventory',
    'nonzero Git',
    'successful Git with an incomplete-observation warning',
    'transport overflow',
    'transport deadline',
  ]) {
    test('$failure fails explicitly instead of returning clean', () async {
      var intercepted = false;
      final through = _InterceptingProcesses(processes, (request, run) async {
        if (!intercepted && request.arguments.contains('ls-files')) {
          intercepted = true;
          switch (failure) {
            case 'malformed inventory':
              return _result(stdout: 'not an index record\x00');
            case 'nonzero Git':
              return _result(exitCode: 128, stderr: 'fatal: injected\n');
            case 'successful Git with an incomplete-observation warning':
              return _result(stderr: 'warning: cannot inspect a directory\n');
            case 'transport overflow':
              throw const EnvironmentFailure(
                code: 'process_output_overflow',
                message: 'Injected transport bound.',
                details: {},
              );
            case 'transport deadline':
              throw const EnvironmentFailure(
                code: 'process_timeout',
                message: 'Injected transport deadline.',
                details: {},
              );
          }
        }
        return run(request);
      });

      final expectedCode = switch (failure) {
        'malformed inventory' => 'invalid_git_output',
        'transport overflow' ||
        'transport deadline' => 'environment_process_failed',
        _ => 'git_failed',
      };
      await expectLater(
        snapshot(through: through),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            expectedCode,
          ),
        ),
      );
      expect(intercepted, isTrue);
    });
  }

  test(
    'malformed successful patch fails rather than publishing a partial snapshot',
    () async {
      await write('baseline', 'after\n');
      var intercepted = false;
      final through = _InterceptingProcesses(processes, (request, run) async {
        if (request.arguments.contains('--no-index')) {
          intercepted = true;
          return _result(exitCode: 1, stdout: '@@ -1 +1 @@\n+incomplete\n');
        }
        return run(request);
      });

      await expectLater(
        snapshot(through: through),
        throwsA(isA<ChangeSetFailure>()),
      );
      expect(intercepted, isTrue);
    },
  );

  for (final (name, limits) in [
    ('inventory', const GitPortableUnstagedLimits(inventoryEntries: 1)),
    ('returned files', const GitPortableUnstagedLimits(files: 1)),
    ('per-command output', const GitPortableUnstagedLimits(outputBytes: 1)),
    ('aggregate bytes', const GitPortableUnstagedLimits(totalBytes: 1)),
    ('hunk lines', const GitPortableUnstagedLimits(lines: 1)),
    ('process count', const GitPortableUnstagedLimits(processes: 1)),
  ]) {
    test('$name bound fails without publishing a prefix', () async {
      await write('baseline', 'after\n');
      await write('second', 'new\n');

      await expectLater(
        snapshot(limits: limits),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            name == 'inventory' ? 'inventory_too_large' : 'snapshot_too_large',
          ),
        ),
      );
    });
  }

  test(
    'snapshot deadline also bounds a transport that never settles',
    () async {
      final never = Completer<EnvironmentBufferedProcessResult>();
      var called = false;
      final through = _InterceptingProcesses(processes, (request, run) {
        called = true;
        return never.future;
      });

      await expectLater(
        snapshot(
          through: through,
          limits: const GitPortableUnstagedLimits(
            operationTimeout: Duration(milliseconds: 20),
          ),
        ).timeout(const Duration(seconds: 2)),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'operation_timeout',
          ),
        ),
      );
      expect(called, isTrue);
    },
  );

  for (final mutation in ['working file', 'index', 'configuration']) {
    test(
      '$mutation changing during observation fails the whole snapshot',
      () async {
        await write('baseline', 'first observed\n');
        var changed = false;
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (!changed && request.arguments.contains('/usr/bin/head')) {
            changed = true;
            switch (mutation) {
              case 'working file':
                await write('baseline', 'changed after capture\n');
              case 'index':
                await _git(repository, ['add', '--', 'baseline']);
              case 'configuration':
                await _git(repository, ['config', 'core.filemode', 'false']);
            }
          }
          return result;
        });

        await expectLater(
          snapshot(through: through),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              'snapshot_changed',
            ),
          ),
        );
        expect(changed, isTrue);
      },
    );
  }
}

List<String> _lines(ChangedFile file) => [
  for (final hunk in file.hunks)
    for (final line in hunk.lines) '${line.kind}:${line.text}',
];

EnvironmentBufferedProcessResult _result({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
}) => EnvironmentBufferedProcessResult(
  exitCode: exitCode,
  stdoutBase64: base64Encode(utf8.encode(stdout)),
  stderrBase64: base64Encode(utf8.encode(stderr)),
);

typedef _Run =
    Future<EnvironmentBufferedProcessResult> Function(
      EnvironmentBufferedProcessRequest,
    );

final class _InterceptingProcesses
    implements AuthorizedEnvironmentBufferedProcessService {
  _InterceptingProcesses(this.delegate, this.intercept);

  final AuthorizedEnvironmentBufferedProcessService delegate;
  final Future<EnvironmentBufferedProcessResult> Function(
    EnvironmentBufferedProcessRequest,
    _Run,
  )
  intercept;

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) => intercept(request, delegate.runBufferedProcess);
}

// Deliberately independent of the Git Worktree provider and its process supervisor.
final class _FixtureProcesses
    implements AuthorizedEnvironmentBufferedProcessService {
  _FixtureProcesses(this.root, Directory home)
    : environment = {
        'PATH': '/usr/bin:/bin',
        'HOME': home.path,
        'XDG_CONFIG_HOME': '${home.path}/config',
        'LC_ALL': 'C',
      };

  final Directory root;
  final Map<String, String> environment;
  final requests = <EnvironmentBufferedProcessRequest>[];
  final _active = <Process>{};

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    requests.add(request);
    expect(request.program, '/bin/sh');
    expect(request.relativeWorkingDirectory, isEmpty);
    expect(request.timeoutSeconds, inInclusiveRange(1, 10));
    final input = decodeEnvironmentProcessBytes(
      request.stdinBase64,
      maximumBytes: environmentBufferedProcessStdinLimit,
    );
    final process = await Process.start(
      request.program,
      request.arguments,
      workingDirectory: root.path,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    _active.add(process);
    try {
      final completed = await Future.wait<Object?>([
        _capture(process.stdout, environmentBufferedProcessStdoutLimit),
        _capture(process.stderr, environmentBufferedProcessStderrLimit),
        process.exitCode,
        () async {
          process.stdin.add(input);
          await process.stdin.close();
        }(),
      ], eagerError: true).timeout(Duration(seconds: request.timeoutSeconds));
      return EnvironmentBufferedProcessResult(
        exitCode: completed[2]! as int,
        stdoutBase64: base64Encode(completed[0]! as List<int>),
        stderrBase64: base64Encode(completed[1]! as List<int>),
      );
    } on TimeoutException {
      throw const EnvironmentFailure(
        code: 'process_timeout',
        message: 'Fixture child exceeded the requested deadline.',
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

Future<List<int>> _capture(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw const EnvironmentFailure(
        code: 'process_output_overflow',
        message: 'Fixture child exceeded its binary output bound.',
        details: {},
      );
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
        'XDG_CONFIG_HOME': '${root.parent.path}/config',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'LC_ALL': 'C',
      },
      includeParentEnvironment: false,
    );

Future<void> _command(String program, List<String> arguments) async {
  final result = await Process.run(program, arguments);
  expect(result.exitCode, 0, reason: '$program $arguments: ${result.stderr}');
}

Future<Map<String, Object>> _fingerprint(Directory root) async {
  final result = <String, Object>{};
  await for (final entry in root.list(recursive: true, followLinks: false)) {
    final path = entry.path.substring(root.path.length + 1);
    if (entry is File) {
      final stat = await entry.stat();
      result[path] = (
        sha256.convert(await entry.readAsBytes()).toString(),
        stat.size,
        stat.mode,
        stat.modified.microsecondsSinceEpoch,
      );
    } else if (entry is Link) {
      result[path] = ('link', await entry.target());
    } else {
      result[path] = 'directory';
    }
  }
  return result;
}
