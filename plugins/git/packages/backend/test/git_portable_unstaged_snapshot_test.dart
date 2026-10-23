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
        GitPortableUnstagedLimits,
        GitPortableUnstagedSnapshotService,
        GitTaskComparisonAnchor;
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

  Future<UncommittedChangeSetSnapshot> uncommitted({
    AuthorizedEnvironmentBufferedProcessService? through,
    GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
  }) => GitPortableUnstagedSnapshotService(
    processes: through ?? processes,
    limits: limits,
  ).snapshotUncommitted();

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

  for (final scope in ['Unstaged', 'Uncommitted']) {
    Future<ChangeSetSnapshot> working({
      GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
    }) async {
      if (scope == 'Unstaged') return snapshot(limits: limits);
      final layered = await uncommitted(limits: limits);
      expect(layered.staged.files, isEmpty);
      expect(layered.conflicts, isEmpty);
      return layered.unstaged;
    }

    for (final dirty in [false, true]) {
      test(
        '$scope ${dirty ? 'modified' : 'clean'} tracked small files exceed 8 MiB without exhausting transport',
        () async {
          const count = 160;
          const fileBytes = 64 * 1024;
          const limits = GitPortableUnstagedLimits();
          expect(fileBytes, lessThan(limits.fileBytes));
          expect((count - 1) * fileBytes, greaterThan(limits.totalBytes));
          expect(
            (count - 1) * fileBytes + 32,
            lessThan(limits.verificationTotalBytes),
          );
          for (var index = 1; index < count; index++) {
            await write(
              'file-${index.toString().padLeft(3, '0')}',
              'x' * fileBytes,
            );
          }
          await commit();
          if (dirty) await write('baseline', 'visible edit\n');
          final before = await _fingerprint(repository);
          final result = await working();
          if (dirty) {
            final file = result.files.single;
            expect(file.relativePath, 'baseline');
            expect(file.changeKind, 'modified');
            expect(file.contentStatus, 'text');
            expect(_lines(file), [
              'deletion:baseline',
              'addition:visible edit',
            ]);
          } else {
            expect(result.files, isEmpty);
          }
          final cleanRequests = (scope == 'Unstaged' ? 20 : 26) + 4 * 2;
          expect(
            processes.requests.length,
            dirty ? lessThanOrEqualTo(cleanRequests + 16) : cleanRequests,
          );
          final hashes = processes.requests
              .where((request) => request.arguments.contains('hash-object'))
              .toList();
          expect(hashes, hasLength(2));
          expect(
            hashes.expand(
              (request) =>
                  request.arguments.skip(request.arguments.indexOf('--') + 1),
            ),
            hasLength(count),
          );
          final reads = processes.requests.where(
            (request) => request.arguments.contains('/usr/bin/head'),
          );
          expect(reads, hasLength(dirty ? 2 : 0));
          expect(
            reads.every((request) => request.arguments.last == './baseline'),
            isTrue,
          );
          expect(await _fingerprint(repository), before);
        },
      );
    }

    test(
      '$scope raw hashes use verification allowance but rendered bytes still consume transport',
      () async {
        const size = 64 * 1024;
        await write('large-clean', 'x' * size);
        await commit();
        const limits = GitPortableUnstagedLimits(
          totalBytes: size,
          verificationFileBytes: size,
          verificationTotalBytes: size + 9,
        );
        expect((await working(limits: limits)).files, isEmpty);
        expect(
          processes.requests.where(
            (request) => request.arguments.contains('hash-object'),
          ),
          hasLength(1),
        );
        expect(
          processes.requests.where(
            (request) => request.arguments.contains('/usr/bin/head'),
          ),
          isEmpty,
        );

        await write('large-clean', '${'x' * (size - 1)}y');
        processes.requests.clear();
        await expectLater(
          working(limits: limits),
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
            (request) => request.arguments.contains('/usr/bin/head'),
          ),
          hasLength(1),
        );
      },
    );

    for (final bound in ['file', 'total']) {
      test(
        '$scope reduced $bound verification budget cannot report unverified small files clean',
        () async {
          const size = 64 * 1024;
          await write('unverified', 'x' * size);
          await commit();
          final limits = bound == 'file'
              ? const GitPortableUnstagedLimits(verificationFileBytes: size - 1)
              : const GitPortableUnstagedLimits(
                  verificationTotalBytes: size + 8,
                );
          for (final dirty in [false, true]) {
            if (dirty) await write('unverified', '${'x' * (size - 1)}y');
            processes.requests.clear();
            await expectLater(
              working(limits: limits),
              throwsA(
                isA<ChangeSetFailure>()
                    .having((error) => error.code, 'code', 'snapshot_too_large')
                    .having(
                      (error) => error.message,
                      'message',
                      contains('verification budget'),
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
          }
        },
      );
    }
  }

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
    'small and oversized hash inputs share one aggregate verification budget',
    () async {
      for (final path in ['large-a', 'large-b', 'large-c']) {
        await write(path, 'x' * 128);
      }
      await commit();
      final result = await snapshot(
        limits: const GitPortableUnstagedLimits(
          fileBytes: 64,
          verificationFileBytes: 256,
          verificationTotalBytes: 256 + 9,
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
      final reduced = await snapshot(
        limits: const GitPortableUnstagedLimits(
          fileBytes: 64,
          verificationFileBytes: 256,
          verificationTotalBytes: 256 + 8,
        ),
      );
      expect(reduced.files.map((file) => file.relativePath), [
        'large-b',
        'large-c',
      ]);
      for (final file in reduced.files) {
        expect(file.changeKind, 'unsupported');
        expect(file.contentStatus, 'oversized');
        expect(file.detail, contains('change state is unknown'));
      }
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

  for (final scope in ['Unstaged', 'Uncommitted', 'Task']) {
    test(
      '$scope rejects per-worktree core.worktree ancestor redirection',
      () async {
        await write('.gitignore', '/linked/\n');
        await commit();
        final source = repository;
        final anchor = GitTaskComparisonAnchor(
          baselineCommit: (await _git(source, ['rev-parse', 'HEAD'])).trim(),
          expectedBranchRef: 'refs/heads/task',
        );
        final linked = Directory('${source.path}/linked');
        await _git(source, ['worktree', 'add', '-b', 'task', linked.path]);
        final marker = File('${linked.path}/.git');
        final originalMarker = await marker.readAsString();
        await _git(source, ['config', 'extensions.worktreeConfig', 'true']);
        await _git(linked, [
          'config',
          '--worktree',
          'core.worktree',
          source.path,
        ]);
        expect(await marker.readAsString(), originalMarker);
        expect(
          (await _git(linked, ['rev-parse', '--show-toplevel'])).trim(),
          source.path,
        );
        expect(
          (await _git(linked, ['rev-parse', '--show-prefix'])).trim(),
          'linked/',
        );
        expect(
          await _git(linked, ['ls-files', '--cached', '--', '.']),
          isEmpty,
        );
        expect(
          await _git(linked, [
            'ls-files',
            '--others',
            '--exclude-standard',
            '--',
            '.',
          ]),
          isEmpty,
        );
        await processes.close();
        repository = linked;
        processes = _FixtureProcesses(linked, container);
        Future<ChangeSetSnapshot> working() async {
          final engine = GitPortableUnstagedSnapshotService(
            processes: processes,
            taskAnchor: anchor,
          );
          return switch (scope) {
            'Unstaged' => await engine.snapshotUnstaged(),
            'Uncommitted' => (await engine.snapshotUncommitted()).unstaged,
            _ => (await engine.snapshotTaskChanges()).uncommitted.unstaged,
          };
        }

        await expectLater(
          working(),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              'unsupported_repository_configuration',
            ),
          ),
        );
        await _git(linked, [
          'config',
          '--worktree',
          '--unset',
          'core.worktree',
        ]);
        await write('baseline', 'actual selected checkout edit\n');
        expect((await working()).files.single.relativePath, 'baseline');
      },
    );
    test(
      '$scope presentation budget includes all escaped layer text',
      () async {
        final length = switch (scope) {
          'Unstaged' => 600000,
          'Uncommitted' => 300000,
          _ => 200000,
        };
        await write('baseline', '${'a' * length}\n');
        await commit();
        final anchor = GitTaskComparisonAnchor(
          baselineCommit: (await _git(repository, [
            'rev-parse',
            'HEAD',
          ])).trim(),
          expectedBranchRef: 'refs/heads/main',
        );
        if (scope == 'Task') {
          await write('baseline', '${'b' * length}\n');
          await commit();
        }
        if (scope != 'Unstaged') {
          await write('baseline', '${'c' * length}\n');
          await _git(repository, ['add', 'baseline']);
        }
        await write('baseline', '${'d' * length}\n');
        final source = GitPortableUnstagedSnapshotService(
          processes: processes,
          taskAnchor: anchor,
        );
        final Future<Object> result = switch (scope) {
          'Unstaged' => source.snapshotUnstaged(),
          'Uncommitted' => source.snapshotUncommitted(),
          _ => source.snapshotTaskChanges(),
        };
        await expectLater(
          result,
          throwsA(
            isA<ChangeSetFailure>()
                .having((error) => error.code, 'code', 'snapshot_too_large')
                .having(
                  (error) => error.message,
                  'message',
                  contains('presentation budget'),
                ),
          ),
        );
      },
    );
    for (final format in ['sha1', 'sha256']) {
      test(
        '$scope verifies 1054288-byte $format binary and text without rendering',
        () async {
          if (format == 'sha256') {
            await processes.close();
            repository = await Directory('${container.path}/sha256').create();
            processes = _FixtureProcesses(repository, container);
            await _git(repository, [
              'init',
              '--object-format=sha256',
              '--initial-branch=main',
            ]);
            await _git(repository, ['config', 'user.name', 'ADELE Test']);
            await _git(repository, [
              'config',
              'user.email',
              'adele@example.invalid',
            ]);
            await write('baseline', 'baseline\n');
          }
          final bytes = Uint8List.fromList(
            List.generate(1054288, (i) => (i * 31 + i ~/ 256) & 255),
          );
          final binary = File('${repository.path}/large.bin');
          final text = File('${repository.path}/large.txt');
          await binary.writeAsBytes(bytes);
          await text.writeAsString('${'x' * 1054287}\n');
          await commit();
          final anchor = GitTaskComparisonAnchor(
            baselineCommit: (await _git(repository, [
              'rev-parse',
              'HEAD',
            ])).trim(),
            expectedBranchRef: 'refs/heads/main',
          );
          Future<ChangeSetSnapshot> working() async {
            final source = GitPortableUnstagedSnapshotService(
              processes: processes,
              taskAnchor: anchor,
            );
            return switch (scope) {
              'Unstaged' => await source.snapshotUnstaged(),
              'Uncommitted' => (await source.snapshotUncommitted()).unstaged,
              _ => (await source.snapshotTaskChanges()).uncommitted.unstaged,
            };
          }

          await binary.setLastModified(DateTime.utc(2000));
          await text.setLastModified(DateTime.utc(2000));
          final before = await _fingerprint(repository);
          expect((await working()).files, isEmpty);
          expect(
            processes.requests.where(
              (request) => request.arguments.contains('/usr/bin/head'),
            ),
            isEmpty,
          );
          expect(await _fingerprint(repository), before);
          bytes[bytes.length - 1] ^= 1;
          await binary.writeAsBytes(bytes);
          await text.writeAsString('${'x' * 1054286}y\n');
          await write('baseline', 'visible edit\n');
          final dirtyBefore = await _fingerprint(repository);
          final files = (await working()).files;
          expect(files.map((file) => file.relativePath), [
            'baseline',
            'large.bin',
            'large.txt',
          ]);
          expect(_lines(files.first), [
            'deletion:baseline',
            'addition:visible edit',
          ]);
          for (final file in files.skip(1)) {
            expect(file.changeKind, 'modified');
            expect(file.contentStatus, 'oversized');
            expect(file.hunks, isEmpty);
          }
          expect(await binary.readAsBytes(), bytes);
          expect(await _fingerprint(repository), dirtyBefore);
        },
      );
    }
    for (final verified in [true, false]) {
      test(
        '$scope revalidates oversized observations after verified=$verified',
        () async {
          final large = File('${repository.path}/a-large');
          await large.writeAsBytes(List.generate(128, (i) => i));
          await write('z-later', 'before\n');
          await commit();
          final anchor = GitTaskComparisonAnchor(
            baselineCommit: (await _git(repository, [
              'rev-parse',
              'HEAD',
            ])).trim(),
            expectedBranchRef: 'refs/heads/main',
          );
          await write('z-later', 'after\n');
          var changed = false;
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            if (!changed && request.arguments.contains('--no-index')) {
              changed = true;
              await large.writeAsBytes([0], mode: FileMode.append);
            }
            return result;
          });
          final source = GitPortableUnstagedSnapshotService(
            processes: through,
            taskAnchor: anchor,
            limits: GitPortableUnstagedLimits(
              fileBytes: 32,
              verificationFileBytes: verified ? 128 : 32,
            ),
          );
          final Future<Object> result = switch (scope) {
            'Unstaged' => source.snapshotUnstaged(),
            'Uncommitted' => source.snapshotUncommitted(),
            _ => source.snapshotTaskChanges(),
          };
          await expectLater(
            result,
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

  group('Task', () {
    late GitTaskComparisonAnchor anchor;

    Future<GitTaskComparisonAnchor> captureAnchor() async =>
        GitTaskComparisonAnchor(
          baselineCommit: (await _git(repository, [
            'rev-parse',
            'HEAD',
          ])).trim(),
          expectedBranchRef: (await _git(repository, [
            'symbolic-ref',
            'HEAD',
          ])).trim(),
        );

    setUp(() async => anchor = await captureAnchor());

    Future<TaskChangeSetSnapshot> task({
      AuthorizedEnvironmentBufferedProcessService? through,
      GitPortableUnstagedLimits limits = const GitPortableUnstagedLimits(),
      GitTaskComparisonAnchor? comparison,
    }) => GitPortableUnstagedSnapshotService(
      processes: through ?? processes,
      limits: limits,
      taskAnchor: comparison ?? anchor,
    ).snapshotTaskChanges();

    Matcher code(String value) =>
        isA<ChangeSetFailure>().having((error) => error.code, 'code', value);

    test(
      'A to B to C to D preserves independent multi-hunk coordinates',
      () async {
        final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
        await write('baseline', original);
        await commit();
        anchor = await captureAnchor();
        String content(String layer) => original
            .replaceFirst('line 1\n', '$layer first\n')
            .replaceFirst('line 27\n', '$layer last\n');
        await write('baseline', content('B'));
        await commit();
        await write('baseline', content('C'));
        await _git(repository, ['add', '.']);
        await write('baseline', content('D'));
        final result = await task();
        for (final (layer, before, after) in [
          (result.committed, ['line 1', 'line 27'], ['B first', 'B last']),
          (
            result.uncommitted.staged,
            ['B first', 'B last'],
            ['C first', 'C last'],
          ),
          (
            result.uncommitted.unstaged,
            ['C first', 'C last'],
            ['D first', 'D last'],
          ),
        ]) {
          final changed = layer.files.single;
          expect(changed.relativePath, 'baseline');
          expect(
            changed.hunks.map(
              (h) => (h.oldStart, h.oldCount, h.newStart, h.newCount),
            ),
            [(1, 5, 1, 5), (25, 6, 25, 6)],
          );
          expect(
            changed.hunks.map(
              (h) =>
                  h.lines.where((line) => line.kind == 'deletion').single.text,
            ),
            before,
          );
          expect(
            changed.hunks.map(
              (h) =>
                  h.lines.where((line) => line.kind == 'addition').single.text,
            ),
            after,
          );
        }
        expect(result.uncommitted.conflicts, isEmpty);
      },
    );

    test(
      'retains independent reversals progression and net cancellation',
      () async {
        for (final path in [
          'reverse',
          'progress',
          'cancel',
          'committed',
          'staged',
          'working',
        ]) {
          await write(path, 'A\n');
        }
        await commit();
        anchor = await captureAnchor();
        for (final path in ['reverse', 'progress', 'cancel', 'committed']) {
          await write(path, 'B\n');
        }
        await commit();
        await write('reverse', 'A\n');
        await write('progress', 'C\n');
        await write('cancel', 'C\n');
        await write('staged', 'S\n');
        await _git(repository, ['add', '--all']);
        await write('reverse', 'B\n');
        await write('progress', 'D\n');
        await write('cancel', 'A\n');
        await write('working', 'W\n');
        final before = await _fingerprint(repository);
        final result = await task();
        expect(result.committed.files.map((file) => file.relativePath), [
          'cancel',
          'committed',
          'progress',
          'reverse',
        ]);
        expect(
          result.uncommitted.staged.files.map((file) => file.relativePath),
          ['cancel', 'progress', 'reverse', 'staged'],
        );
        expect(
          result.uncommitted.unstaged.files.map((file) => file.relativePath),
          ['cancel', 'progress', 'reverse', 'working'],
        );
        for (final (layer, path, left, right) in [
          (result.committed, 'reverse', 'A', 'B'),
          (result.uncommitted.staged, 'reverse', 'B', 'A'),
          (result.uncommitted.unstaged, 'reverse', 'A', 'B'),
          (result.uncommitted.staged, 'progress', 'B', 'C'),
          (result.uncommitted.unstaged, 'progress', 'C', 'D'),
          (result.uncommitted.unstaged, 'cancel', 'C', 'A'),
        ]) {
          expect(
            _lines(
              layer.files.singleWhere((file) => file.relativePath == path),
            ),
            ['deletion:$left', 'addition:$right'],
          );
        }
        expect(result.uncommitted.conflicts, isEmpty);
        expect(await _fingerprint(repository), before);
        expect(
          processes.requests.where(
            (request) => request.arguments.contains('--show-toplevel'),
          ),
          hasLength(2),
        );
      },
    );

    test(
      'equal baseline is empty and the same anchor stays stable across commits',
      () async {
        final service = GitPortableUnstagedSnapshotService(
          processes: processes,
          taskAnchor: anchor,
        );
        expect((await service.snapshotTaskChanges()).committed.files, isEmpty);
        for (final text in ['first', 'second', 'baseline']) {
          await write('baseline', '$text\n');
          await commit();
          final result = await service.snapshotTaskChanges();
          if (text == 'baseline') {
            expect(result.committed.files, isEmpty);
          } else {
            expect(_lines(result.committed.files.single), [
              'deletion:baseline',
              'addition:$text',
            ]);
          }
          expect(result.uncommitted.staged.files, isEmpty);
          expect(result.uncommitted.unstaged.files, isEmpty);
        }
        expect(service.taskAnchor, same(anchor));
      },
    );

    test('conflict does not erase an independent committed change', () async {
      await _git(repository, ['checkout', '-b', 'other']);
      await write('baseline', 'other\n');
      await commit();
      await _git(repository, ['checkout', 'main']);
      await write('baseline', 'main\n');
      await commit();
      expect(
        (await _gitResult(repository, [
          'merge',
          '--no-edit',
          'other',
        ])).exitCode,
        1,
      );
      final result = await task();
      expect(_lines(result.committed.files.single), [
        'deletion:baseline',
        'addition:main',
      ]);
      expect(result.uncommitted.staged.files, isEmpty);
      expect(result.uncommitted.unstaged.files, isEmpty);
      final conflict = result.uncommitted.conflicts.single;
      expect(
        (conflict.relativePath, conflict.changeKind, conflict.contentStatus),
        ('baseline', 'conflicted', 'conflicted'),
      );
      expect(conflict.hunks, isEmpty);
      await expectLater(
        task(limits: const GitPortableUnstagedLimits(files: 1)),
        throwsA(code('snapshot_too_large')),
      );
    });

    test(
      'committed empty sides renames and file-directory replacements are exact',
      () async {
        await write('empty-deleted', '');
        await write('rename-old', 'rename\n');
        await write('file-to-dir', 'parent\n');
        await write('dir-to-file/child', 'child\n');
        await commit();
        anchor = await captureAnchor();
        await _git(repository, [
          'rm',
          '--',
          'empty-deleted',
          'file-to-dir',
          'dir-to-file/child',
        ]);
        await _git(repository, ['mv', '--', 'rename-old', 'rename-new']);
        await write('empty-added', '');
        await write('file-to-dir/child', 'new child\n');
        await write('dir-to-file', 'new parent\n');
        await commit();
        await write('empty-deleted', 'recreated\n');
        final result = await task();
        expect(
          result.committed.files.map(
            (file) => '${file.relativePath}:${file.changeKind}',
          ),
          [
            'dir-to-file:added',
            'dir-to-file/child:deleted',
            'empty-added:added',
            'empty-deleted:deleted',
            'file-to-dir:deleted',
            'file-to-dir/child:added',
            'rename-new:added',
            'rename-old:deleted',
          ],
        );
        expect(result.committed.files.map(_lines), <List<String>>[
          ['addition:new parent'],
          ['deletion:child'],
          [],
          [],
          ['deletion:parent'],
          ['addition:new child'],
          ['addition:rename'],
          ['deletion:rename'],
        ]);
        expect(
          result.committed.files.every((file) => file.contentStatus == 'text'),
          isTrue,
        );
        expect(result.uncommitted.staged.files, isEmpty);
        expect(_lines(result.uncommitted.unstaged.files.single), [
          'addition:recreated',
        ]);
      },
    );

    test(
      'binary invalid UTF8 modes types gitlinks and oversized objects are explicit',
      () async {
        for (final path in ['binary', 'invalid', 'mode', 'type', 'large-new']) {
          await write(path, 'before\n');
        }
        for (final path in ['large-old', 'large-deleted']) {
          await write(path, 'x' * 128);
        }
        await Link('${repository.path}/link').create('before');
        await commit();
        anchor = await captureAnchor();
        await File('${repository.path}/binary').writeAsBytes([1, 0, 2]);
        await File('${repository.path}/invalid').writeAsBytes([255, 254]);
        await File('${repository.path}/type').delete();
        await Link('${repository.path}/type').create('missing');
        await Link('${repository.path}/link').update('after');
        await _command('/usr/bin/chmod', ['755', '${repository.path}/mode']);
        await write('large-old', 'small\n');
        await write('large-new', 'y' * 128);
        await write('large-added', 'z' * 128);
        await _git(repository, ['rm', '--', 'large-deleted']);
        await _git(repository, ['add', '--all']);
        await _git(repository, [
          'update-index',
          '--add',
          '--cacheinfo',
          '160000,${anchor.baselineCommit},module',
        ]);
        await _git(repository, ['commit', '-m', 'Types']);
        await _git(repository, ['config', 'core.filemode', 'false']);
        final result = await task(
          limits: const GitPortableUnstagedLimits(fileBytes: 64),
        );
        final files = {
          for (final file in result.committed.files) file.relativePath: file,
        };
        expect(files.keys, [
          'binary',
          'invalid',
          'large-added',
          'large-deleted',
          'large-new',
          'large-old',
          'link',
          'mode',
          'module',
          'type',
        ]);
        expect(files['binary']!.contentStatus, 'binary');
        expect(files['invalid']!.contentStatus, 'unsupported');
        for (final path in [
          'large-added',
          'large-deleted',
          'large-new',
          'large-old',
        ]) {
          expect(files[path]!.contentStatus, 'oversized');
        }
        for (final path in ['link', 'mode', 'module', 'type']) {
          expect(files[path]!.contentStatus, 'unsupported');
        }
        expect(files['mode']!.changeKind, 'typeChanged');
        expect(files['type']!.changeKind, 'typeChanged');
        expect(files['module']!.changeKind, 'added');
        for (final file in files.values) {
          expect(file.hunks, isEmpty);
          expect(file.detail, isNotEmpty);
        }
      },
    );

    test(
      'committed objects ignore working attributes conversions and executable helpers',
      () async {
        await write('baseline', 'committed\n');
        await commit();
        final marker = File('${container.path}/TASK_HELPER');
        final hook = File('${container.path}/task-helper');
        await hook.writeAsString(
          '#!/bin/sh\nprintf executed > "${marker.path}"\nexit 99\n',
        );
        await _command('/usr/bin/chmod', ['+x', hook.path]);
        for (final (key, value) in [
          ('filter.hostile.clean', hook.path),
          ('filter.hostile.process', hook.path),
          ('filter.hostile.required', 'true'),
          ('diff.hostile.command', hook.path),
          ('diff.hostile.textconv', hook.path),
          ('diff.external', hook.path),
          ('core.fsmonitor', hook.path),
          ('core.hooksPath', container.path),
          ('core.autocrlf', 'true'),
          ('core.eol', 'crlf'),
        ]) {
          await _git(repository, ['config', key, value]);
        }
        await File('${repository.path}/.git/info/attributes').writeAsString(
          'baseline -diff filter=hostile working-tree-encoding=UTF-16 crlf\n',
        );
        final before = await _fingerprint(repository);
        for (final missing in [false, true]) {
          if (missing) await File('${repository.path}/baseline').delete();
          processes.requests.clear();
          final result = await task();
          expect(_lines(result.committed.files.single), [
            'deletion:baseline',
            'addition:committed',
          ]);
          expect(result.committed.files.single.contentStatus, 'text');
          expect(result.uncommitted.staged.files, isEmpty);
          if (missing) {
            expect(
              result.uncommitted.unstaged.files.single.contentStatus,
              'unsupported',
            );
          } else {
            expect(result.uncommitted.unstaged.files, isEmpty);
            expect(
              processes.requests.where(
                (request) => request.arguments.contains('check-attr'),
              ),
              isEmpty,
            );
            expect(await _fingerprint(repository), before);
          }
          expect(await marker.exists(), isFalse);
        }
        // Positive control: the configured helper is executable, not inert fixture text.
        expect((await Process.run(hook.path, [])).exitCode, 99);
        expect(await marker.exists(), isTrue);
      },
    );

    test(
      'nested scope literal names CRLF and absent final newlines survive all layers',
      () async {
        const paths = [
          ' space ',
          '-option',
          ':(glob)*[x]',
          'tab\tname',
          'line\nname',
          r'back\slash',
          'quote\'";\$(touch INJECTED)',
        ];
        for (final path in [
          ...paths.map((path) => 'selected/$path'),
          'outside',
        ]) {
          await write(path, 'A\r\nlast A');
        }
        await commit();
        anchor = await captureAnchor();
        for (final text in ['B', 'C', 'D']) {
          for (final path in [
            ...paths.map((path) => 'selected/$path'),
            'outside',
          ]) {
            await write(path, '$text\r\nlast $text');
          }
          if (text == 'B') await commit();
          if (text == 'C') await _git(repository, ['add', '--all']);
        }
        processes = _FixtureProcesses(
          Directory('${repository.path}/selected'),
          container,
        );
        final result = await task();
        for (final (layer, left, right) in [
          (result.committed, 'A', 'B'),
          (result.uncommitted.staged, 'B', 'C'),
          (result.uncommitted.unstaged, 'C', 'D'),
        ]) {
          expect(
            layer.files.map((file) => file.relativePath),
            [...paths]..sort(),
          );
          for (final file in layer.files) {
            expect(
              file.hunks.single.lines.map(
                (line) => (line.kind, line.text, line.noNewline),
              ),
              [
                ('deletion', '$left\r', false),
                ('deletion', 'last $left', true),
                ('addition', '$right\r', false),
                ('addition', 'last $right', true),
              ],
            );
          }
        }
        expect(
          await File('${repository.path}/selected/INJECTED').exists(),
          isFalse,
        );
      },
    );

    test(
      'SHA256 anchor commits trees blobs and patches use the selected format',
      () async {
        repository = await Directory('${container.path}/sha256-task').create();
        await _git(repository, [
          'init',
          '--object-format=sha256',
          '--initial-branch=main',
        ]);
        await _git(repository, ['config', 'user.name', 'ADELE Test']);
        await _git(repository, [
          'config',
          'user.email',
          'adele@example.invalid',
        ]);
        await write('baseline', 'A\n');
        await commit();
        anchor = await captureAnchor();
        await write('baseline', 'B\n');
        await commit();
        await write('baseline', 'C\n');
        await _git(repository, ['add', '--all']);
        await write('baseline', 'D\n');
        processes = _FixtureProcesses(repository, container);
        final result = await task();
        expect(anchor.baselineCommit, hasLength(64));
        expect(_lines(result.committed.files.single), [
          'deletion:A',
          'addition:B',
        ]);
        expect(_lines(result.uncommitted.staged.files.single), [
          'deletion:B',
          'addition:C',
        ]);
        expect(_lines(result.uncommitted.unstaged.files.single), [
          'deletion:C',
          'addition:D',
        ]);
        await expectLater(
          task(
            comparison: GitTaskComparisonAnchor(
              baselineCommit: anchor.baselineCommit.substring(0, 40),
              expectedBranchRef: anchor.expectedBranchRef,
            ),
          ),
          throwsA(code('invalid_baseline')),
        );
      },
    );

    test(
      'missing anchor never infers HEAD and does not disable other scopes',
      () async {
        final service = GitPortableUnstagedSnapshotService(
          processes: processes,
        );
        await expectLater(
          service.snapshotTaskChanges(),
          throwsA(code('baseline_unavailable')),
        );
        expect(processes.requests, isEmpty);
        expect((await service.snapshotUnstaged()).files, isEmpty);
        expect((await service.snapshotUncommitted()).staged.files, isEmpty);
        final invalid = GitPortableUnstagedSnapshotService(
          processes: processes,
          taskAnchor: const GitTaskComparisonAnchor(
            baselineCommit: 'HEAD',
            expectedBranchRef: 'main',
          ),
        );
        expect((await invalid.snapshotUncommitted()).staged.files, isEmpty);
      },
    );

    for (final value in [
      '',
      'HEAD',
      'HEAD~1',
      'HEAD^{commit}',
      'abcdef0',
      'A' * 40,
      'g' * 40,
      'a' * 39,
      'a' * 64,
      '${'a' * 39}\n',
    ]) {
      test(
        'rejects malformed or wrong-width anchor ${jsonEncode(value)}',
        () async {
          await expectLater(
            task(
              comparison: GitTaskComparisonAnchor(
                baselineCommit: value,
                expectedBranchRef: anchor.expectedBranchRef,
              ),
            ),
            throwsA(code('invalid_baseline')),
          );
          expect(
            processes.requests.where(
              (request) => request.arguments.contains('cat-file'),
            ),
            isEmpty,
          );
        },
      );
    }

    test(
      'unavailable baseline fails without lazy fetch or a replacement baseline',
      () async {
        await expectLater(
          task(
            comparison: GitTaskComparisonAnchor(
              baselineCommit: 'a' * 40,
              expectedBranchRef: anchor.expectedBranchRef,
            ),
          ),
          throwsA(code('baseline_unavailable')),
        );
      },
    );

    for (final type in ['tag', 'blob', 'tree']) {
      test('rejects actual $type object without peeling it', () async {
        final String oid;
        if (type == 'tag') {
          await _git(repository, ['tag', '-a', 'tagged', '-m', 'Annotated']);
          oid = (await _git(repository, ['rev-parse', 'tagged'])).trim();
        } else {
          oid = (await _git(repository, [
            'rev-parse',
            type == 'tree' ? 'HEAD^{tree}' : 'HEAD:baseline',
          ])).trim();
        }
        await expectLater(
          task(
            comparison: GitTaskComparisonAnchor(
              baselineCommit: oid,
              expectedBranchRef: anchor.expectedBranchRef,
            ),
          ),
          throwsA(code('invalid_baseline')),
        );
        expect(
          processes.requests.any(
            (request) =>
                request.arguments.contains('-t') &&
                request.arguments.last == oid,
          ),
          isTrue,
        );
      });
    }

    for (final reference in [
      '',
      'main',
      'refs/tags/main',
      'refs/heads/',
      'refs/heads/a..b',
      'refs/heads/a.lock',
      'refs/heads/a@{b',
      'refs/heads/a b',
      'refs/heads/a\n',
      'refs/heads/.hidden',
      'refs/heads/a\\b',
    ]) {
      test('rejects malformed full branch ${jsonEncode(reference)}', () async {
        await expectLater(
          task(
            comparison: GitTaskComparisonAnchor(
              baselineCommit: anchor.baselineCommit,
              expectedBranchRef: reference,
            ),
          ),
          throwsA(code('invalid_branch')),
        );
      });
    }

    test('branch mismatch and detached HEAD fail explicitly', () async {
      await expectLater(
        task(
          comparison: GitTaskComparisonAnchor(
            baselineCommit: anchor.baselineCommit,
            expectedBranchRef: 'refs/heads/other',
          ),
        ),
        throwsA(code('unexpected_branch')),
      );
      await _git(repository, ['checkout', '--detach']);
      await expectLater(task(), throwsA(code('detached_head')));
      expect((await uncommitted()).staged.files, isEmpty);
    });

    for (final mutation in [
      'HEAD commit',
      'HEAD branch',
      'index',
      'working',
      'configuration',
      'repository',
      'baseline unavailable',
      'baseline tree',
      'HEAD tree',
      'object format',
    ]) {
      test(
        '$mutation changing after committed patch rejects every layer',
        () async {
          await write('selected/file', 'A\n');
          await commit();
          anchor = await captureAnchor();
          await write('selected/file', 'B\n');
          await commit();
          final capturedHead = (await _git(repository, [
            'rev-parse',
            'HEAD',
          ])).trim();
          final next = (await _git(repository, [
            'commit-tree',
            'HEAD^{tree}',
            '-p',
            'HEAD',
            '-m',
            'Next',
          ])).trim();
          await _git(repository, ['branch', 'same-commit']);
          await write('selected/file', 'C\n');
          await _git(repository, ['add', '--all']);
          await write('selected/file', 'D\n');
          processes = _FixtureProcesses(
            Directory('${repository.path}/selected'),
            container,
          );
          var changed = false;
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            if (changed) {
              if (mutation == 'baseline unavailable' &&
                  request.arguments.contains('-t') &&
                  request.arguments.last == anchor.baselineCommit) {
                return _result(exitCode: 128);
              }
              if ((mutation == 'baseline tree' || mutation == 'HEAD tree') &&
                  request.arguments.contains('ls-tree') &&
                  request.arguments.contains(
                    mutation == 'baseline tree'
                        ? anchor.baselineCommit
                        : capturedHead,
                  )) {
                return _result(stdout: '');
              }
              if (mutation == 'object format' &&
                  request.arguments.contains('--show-object-format')) {
                return _result(stdout: 'sha256\n');
              }
            }
            if (!changed &&
                request.arguments.contains('--patch') &&
                !request.arguments.contains('--cached')) {
              changed = true;
              switch (mutation) {
                case 'HEAD commit':
                  await _git(repository, ['update-ref', 'HEAD', next]);
                case 'HEAD branch':
                  await _git(repository, [
                    'symbolic-ref',
                    'HEAD',
                    'refs/heads/same-commit',
                  ]);
                case 'index':
                  await _git(repository, ['add', '--all']);
                case 'working':
                  await write('selected/file', 'changed after capture\n');
                case 'configuration':
                  await _git(repository, ['config', 'core.filemode', 'false']);
                case 'repository':
                  await _git(processes.root, ['init']);
              }
            }
            return result;
          });
          TaskChangeSetSnapshot? published;
          await expectLater(
            task(through: through).then((value) => published = value),
            throwsA(
              code(
                mutation == 'baseline unavailable'
                    ? 'baseline_unavailable'
                    : 'snapshot_changed',
              ),
            ),
          );
          expect(changed, isTrue);
          expect(published, isNull);
        },
      );
    }

    for (final side in ['baseline', 'HEAD']) {
      for (final phase in ['capture', 'settlement']) {
        test('$side bytes must hash to the captured commit at $phase', () async {
          await write('baseline', 'committed\n');
          await commit();
          var changed = false;
          final oid = side == 'baseline'
              ? anchor.baselineCommit
              : (await _git(repository, ['rev-parse', 'HEAD'])).trim();
          final object = File(
            '${repository.path}/.git/objects/${oid.substring(0, 2)}/${oid.substring(2)}',
          );
          Future<void> corrupt() async {
            final bytes = zlib.decode(await object.readAsBytes());
            // Preserve a parseable commit and its type but change its message.
            bytes[bytes.length - 2] ^= 1;
            await object.delete();
            await object.writeAsBytes(zlib.encode(bytes));
            changed = true;
          }

          if (phase == 'capture') await corrupt();
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            if (!changed && request.arguments.contains('--patch')) {
              await corrupt();
            }
            return result;
          });
          await expectLater(
            task(through: through),
            throwsA(
              side == 'baseline'
                  ? code('invalid_baseline')
                  : anyOf(code('head_unavailable'), code('invalid_git_output')),
            ),
          );
          expect(changed, isTrue);
        });
      }
    }

    for (final side in ['baseline', 'HEAD', 'index']) {
      for (final corruption in ['missing', 'changed bytes']) {
        test(
          'required $side blob $corruption after its patch fails settlement',
          () async {
            final oldOid = (await _git(repository, [
              'rev-parse',
              'HEAD:baseline',
            ])).trim();
            await write('baseline', 'committed\n');
            await commit();
            final headOid = (await _git(repository, [
              'rev-parse',
              'HEAD:baseline',
            ])).trim();
            await write('baseline', 'indexed\n');
            await _git(repository, ['add', '--all']);
            final indexOid = (await _git(repository, [
              'rev-parse',
              ':baseline',
            ])).trim();
            final oid = switch (side) {
              'baseline' => oldOid,
              'HEAD' => headOid,
              _ => indexOid,
            };
            var changed = false;
            final through = _InterceptingProcesses(processes, (
              request,
              run,
            ) async {
              final result = await run(request);
              // Both object layers have consumed their bytes; the clean workfile
              // needs neither a patch nor another index-blob read.
              if (!changed &&
                  request.arguments.contains('--patch') &&
                  request.arguments.contains('--cached')) {
                final object = File(
                  '${repository.path}/.git/objects/${oid.substring(0, 2)}/${oid.substring(2)}',
                );
                if (corruption == 'missing') {
                  await object.delete();
                } else {
                  final bytes = zlib.decode(await object.readAsBytes());
                  bytes[bytes.length - 2] ^= 1;
                  await object.delete();
                  await object.writeAsBytes(zlib.encode(bytes));
                }
                changed = true;
              }
              return result;
            });
            await expectLater(
              task(through: through),
              throwsA(
                code(
                  corruption == 'missing' ? 'git_failed' : 'invalid_git_output',
                ),
              ),
            );
            expect(changed, isTrue);
          },
        );
      }
    }

    test(
      'oversized required objects retain size and availability observations',
      () async {
        await write('large', 'x' * 128);
        await commit();
        anchor = await captureAnchor();
        final oid = (await _git(repository, [
          'rev-parse',
          'HEAD:large',
        ])).trim();
        await write('large', 'small\n');
        await commit();
        var observations = 0;
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (request.arguments.contains('-s') &&
              request.arguments.last == oid &&
              ++observations == 2) {
            return _result(stdout: '129\n');
          }
          return result;
        });
        await expectLater(
          task(
            through: through,
            limits: const GitPortableUnstagedLimits(fileBytes: 64),
          ),
          throwsA(code('snapshot_changed')),
        );
        expect(observations, 2);
      },
    );

    for (final side in ['baseline', 'HEAD']) {
      for (final corruption in ['malformed', 'wrong width', 'missing object']) {
        test(
          '$side tree $corruption fails before any result is returned',
          () async {
            await write('baseline', 'committed\n');
            await commit();
            final commitOid = side == 'baseline'
                ? anchor.baselineCommit
                : (await _git(repository, ['rev-parse', 'HEAD'])).trim();
            var intercepted = false;
            final through = _InterceptingProcesses(processes, (
              request,
              run,
            ) async {
              final result = await run(request);
              if (!intercepted &&
                  request.arguments.contains('ls-tree') &&
                  request.arguments.contains(commitOid)) {
                intercepted = true;
                final raw = utf8.decode(base64Decode(result.stdoutBase64));
                return switch (corruption) {
                  'malformed' => _result(stdout: 'malformed\x00'),
                  'wrong width' => _result(
                    stdout: raw.replaceFirst(RegExp(r'[0-9a-f]{40}'), 'a' * 64),
                  ),
                  _ => _result(exitCode: 128),
                };
              }
              return result;
            });
            await expectLater(
              task(through: through),
              throwsA(
                code(
                  corruption == 'missing object'
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

    test('unborn HEAD fails with an available retained baseline', () async {
      await _git(repository, ['symbolic-ref', 'HEAD', 'refs/heads/unborn']);
      await expectLater(
        task(
          comparison: GitTaskComparisonAnchor(
            baselineCommit: anchor.baselineCommit,
            expectedBranchRef: 'refs/heads/unborn',
          ),
        ),
        throwsA(code('head_unavailable')),
      );
      expect((await snapshot()).files, isEmpty);
    });

    test(
      'empty and nonempty intent-to-add have no committed or staged object',
      () async {
        await write('intent-empty', '');
        await write('intent-text', 'intent\n');
        await _git(repository, [
          'add',
          '--intent-to-add',
          '--',
          'intent-empty',
          'intent-text',
        ]);
        final result = await task();
        expect(result.committed.files, isEmpty);
        expect(result.uncommitted.staged.files, isEmpty);
        expect(
          result.uncommitted.unstaged.files.map((file) => file.relativePath),
          ['intent-empty', 'intent-text'],
        );
        expect(result.uncommitted.unstaged.files.first.hunks, isEmpty);
        expect(_lines(result.uncommitted.unstaged.files.last), [
          'addition:intent',
        ]);
      },
    );

    for (final corruption in [
      'wrong old OID',
      'wrong new OID',
      'valid hunk prefix',
      'malformed',
      'empty',
      'stderr',
      'nonzero',
    ]) {
      test('committed patch $corruption cannot publish partial data', () async {
        final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
        await write('baseline', original);
        await commit();
        anchor = await captureAnchor();
        await write(
          'baseline',
          original
              .replaceFirst('line 1\n', 'first\n')
              .replaceFirst('line 27\n', 'last\n'),
        );
        await commit();
        var intercepted = false;
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (!request.arguments.contains('--patch') ||
              request.arguments.contains('--cached')) {
            return result;
          }
          intercepted = true;
          var raw = utf8.decode(base64Decode(result.stdoutBase64));
          switch (corruption) {
            case 'wrong old OID':
            case 'wrong new OID':
              final identity = RegExp(
                r'^index ([0-9a-f]{40})\.\.([0-9a-f]{40})',
                multiLine: true,
              ).firstMatch(raw)!;
              raw = raw.replaceRange(
                identity.start,
                identity.end,
                'index ${corruption == 'wrong old OID' ? '0' * 40 : identity[1]}..${corruption == 'wrong new OID' ? '0' * 40 : identity[2]}',
              );
            case 'valid hunk prefix':
              final hunks = RegExp(
                r'^@@ ',
                multiLine: true,
              ).allMatches(raw).toList();
              expect(hunks, hasLength(2));
              raw = raw.substring(0, hunks.last.start);
            case 'malformed':
              raw = '$raw+unexpected\n';
            case 'empty':
              raw = '';
          }
          return _result(
            stdout: raw,
            exitCode: corruption == 'nonzero' ? 128 : 1,
            stderr: corruption == 'stderr' ? 'incomplete\n' : '',
          );
        });
        await expectLater(
          task(through: through),
          throwsA(
            code(switch (corruption) {
              'valid hunk prefix' || 'malformed' => 'invalid_git_output',
              'stderr' || 'nonzero' => 'git_failed',
              _ => 'snapshot_changed',
            }),
          ),
        );
        expect(intercepted, isTrue);
      });
    }

    for (final bound in ['entries', 'lines', 'bytes', 'processes']) {
      test(
        '$bound budget is shared across committed staged and unstaged',
        () async {
          await write('baseline', 'B\n');
          await commit();
          await write('baseline', 'C\n');
          await _git(repository, ['add', '--all']);
          await write('baseline', 'D\n');
          var transportedBytes = 0;
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            transportedBytes +=
                base64Decode(request.stdinBase64).length +
                base64Decode(result.stdoutBase64).length +
                base64Decode(result.stderrBase64).length;
            return result;
          });
          final complete = await task(through: through);
          for (final layer in [
            complete.committed,
            complete.uncommitted.staged,
            complete.uncommitted.unstaged,
          ]) {
            expect(layer.files, hasLength(1));
          }
          final limits = switch (bound) {
            'entries' => const GitPortableUnstagedLimits(files: 2),
            'lines' => const GitPortableUnstagedLimits(lines: 5),
            'bytes' => GitPortableUnstagedLimits(
              totalBytes: transportedBytes - 1,
            ),
            _ => GitPortableUnstagedLimits(
              processes: processes.requests.length - 1,
            ),
          };
          final lowerLayers = await uncommitted(limits: limits);
          expect(lowerLayers.staged.files, hasLength(1));
          expect(lowerLayers.unstaged.files, hasLength(1));
          await expectLater(
            task(limits: limits),
            throwsA(code('snapshot_too_large')),
          );
        },
      );
    }

    test(
      'baseline HEAD index untracked union has one inventory bound',
      () async {
        await _git(repository, ['rm', '--', 'baseline']);
        await write('head', 'head\n');
        await commit();
        await _git(repository, ['rm', '--', 'head']);
        await write('index', 'index\n');
        await _git(repository, ['add', '--all']);
        await write('working', 'working\n');
        await expectLater(
          task(limits: const GitPortableUnstagedLimits(inventoryEntries: 3)),
          throwsA(code('inventory_too_large')),
        );
      },
    );

    test(
      'deadline fences a late committed request and its continuation',
      () async {
        await write('baseline', 'committed\n');
        await commit();
        final pending = Completer<EnvironmentBufferedProcessResult>();
        final admitted = Completer<void>();
        var commands = 0;
        final through = _InterceptingProcesses(processes, (request, run) {
          commands++;
          if (request.arguments.contains('--patch')) {
            admitted.complete();
            return pending.future;
          }
          return run(request);
        });
        final operation = task(
          through: through,
          limits: const GitPortableUnstagedLimits(
            processTimeout: Duration(seconds: 1),
          ),
        );
        final failed = expectLater(
          operation,
          throwsA(code('operation_timeout')),
        );
        await admitted.future;
        await failed;
        final stopped = commands;
        pending.complete(_result(exitCode: 1));
        await Future<void>.delayed(Duration.zero);
        expect(commands, stopped);
      },
    );

    for (final count in [100, 500, 900]) {
      test('diagnostic clean $count commit-only and three-layer edits', () async {
        for (var index = 1; index < count; index++) {
          await write('file-${index.toString().padLeft(3, '0')}', 'A\n');
        }
        await commit();
        anchor = await captureAnchor();
        for (final phase in ['clean', 'commit-only', 'three-layer']) {
          if (phase != 'clean') {
            for (var index = 1; index <= 3; index++) {
              await write(
                'file-${index.toString().padLeft(3, '0')}',
                phase == 'commit-only' ? 'B\n' : 'C\n',
              );
            }
            if (phase == 'commit-only') {
              await commit();
            } else {
              await _git(repository, ['add', '--all']);
              for (var index = 1; index <= 3; index++) {
                await write('file-${index.toString().padLeft(3, '0')}', 'D\n');
              }
            }
          }
          processes.requests.clear();
          final watch = Stopwatch()..start();
          final result = await task();
          watch.stop();
          print(
            'portable Task $phase n=$count requests=${processes.requests.length} elapsed=${watch.elapsedMilliseconds}ms',
          );
          expect(result.committed.files, hasLength(phase == 'clean' ? 0 : 3));
          expect(
            result.uncommitted.staged.files,
            hasLength(phase == 'three-layer' ? 3 : 0),
          );
          expect(
            result.uncommitted.unstaged.files,
            hasLength(phase == 'three-layer' ? 3 : 0),
          );
          expect(result.uncommitted.conflicts, isEmpty);
          if (phase == 'clean') {
            expect(
              processes.requests,
              hasLength(35 + 4 * ((count + 127) ~/ 128)),
            );
            expect(
              processes.requests.where(
                (request) =>
                    request.arguments.contains('--patch') ||
                    request.arguments.contains('/usr/bin/head'),
              ),
              isEmpty,
            );
          }
        }
      });
    }
  });

  group('Uncommitted', () {
    test('retains A/B/A cancellation, A/B/C and independent layers', () async {
      final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
      final indexed = original
          .replaceFirst('line 1\n', 'staged first\n')
          .replaceFirst('line 27\n', 'staged last\n');
      final working = indexed
          .replaceFirst('staged first\n', 'working first\n')
          .replaceFirst('staged last\n', 'working last\n');
      for (final path in ['cancel', 'partial', 'staged', 'unstaged']) {
        await write(path, original);
      }
      await commit();
      for (final path in ['cancel', 'partial', 'staged']) {
        await write(path, indexed);
      }
      await _git(repository, ['add', '--all']);
      await write('cancel', original);
      await write('partial', working);
      await write('unstaged', working);
      final before = await _fingerprint(repository);

      final result = await uncommitted();
      expect(result.staged.files.map((file) => file.relativePath), [
        'cancel',
        'partial',
        'staged',
      ]);
      expect(result.unstaged.files.map((file) => file.relativePath), [
        'cancel',
        'partial',
        'unstaged',
      ]);
      expect(result.conflicts, isEmpty);
      for (final layer in [result.staged, result.unstaged]) {
        for (final file in layer.files) {
          expect(file.changeKind, 'modified');
          expect(file.contentStatus, 'text');
          expect(file.hunks, hasLength(2));
          expect(
            file.hunks.map(
              (hunk) =>
                  (hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount),
            ),
            [(1, 5, 1, 5), (25, 6, 25, 6)],
          );
        }
      }
      expect(
        _lines(
          result.staged.files.first,
        ).where((line) => !line.startsWith('context:')),
        [
          'deletion:line 1',
          'addition:staged first',
          'deletion:line 27',
          'addition:staged last',
        ],
      );
      expect(
        _lines(
          result.unstaged.files.first,
        ).where((line) => !line.startsWith('context:')),
        [
          'deletion:staged first',
          'addition:line 1',
          'deletion:staged last',
          'addition:line 27',
        ],
      );
      expect(
        _lines(
          result.unstaged.files[1],
        ).where((line) => !line.startsWith('context:')),
        [
          'deletion:staged first',
          'addition:working first',
          'deletion:staged last',
          'addition:working last',
        ],
      );
      expect(await _fingerprint(repository), before);
      expect(
        processes.requests.where(
          (request) => request.arguments.contains('--show-toplevel'),
        ),
        hasLength(2),
      );
    });

    test('staged-only changes do not leak into Unstaged', () async {
      await write('baseline', 'indexed\n');
      await write('new', 'new indexed\n');
      await _git(repository, ['add', '--all']);
      final before = await _fingerprint(repository);
      expect((await snapshot()).files, isEmpty);
      final result = await uncommitted();
      expect(result.staged.files.map((file) => file.relativePath), [
        'baseline',
        'new',
      ]);
      expect(_lines(result.staged.files.first), [
        'deletion:baseline',
        'addition:indexed',
      ]);
      expect(_lines(result.staged.files.last), ['addition:new indexed']);
      expect(result.unstaged.files, isEmpty);
      expect(result.conflicts, isEmpty);
      expect(await _fingerprint(repository), before);
    });

    test(
      'retains recreated deletions, empty sides and rename deletion/addition',
      () async {
        await write('deleted', 'deleted HEAD\n');
        await write('recreated', 'original HEAD\n');
        await write('empty-deleted', '');
        await write('rename-old', 'rename content\n');
        await write('.gitignore', 'ignored\n');
        await commit();
        await _git(repository, [
          'rm',
          '--',
          'deleted',
          'recreated',
          'empty-deleted',
        ]);
        await _git(repository, ['mv', '--', 'rename-old', 'rename-new']);
        await write('added', 'index addition\n');
        await write('empty-added', '');
        await _git(repository, ['add', '--all']);
        await write('added', 'working addition\n');
        await write('recreated', 'recreated working\n');
        await write('untracked', 'new\n');
        await write('empty-untracked', '');
        await write('ignored', 'ignored\n');
        final before = await _fingerprint(repository);

        final result = await uncommitted();
        expect(
          result.staged.files.map(
            (file) => '${file.relativePath}:${file.changeKind}',
          ),
          [
            'added:added',
            'deleted:deleted',
            'empty-added:added',
            'empty-deleted:deleted',
            'recreated:deleted',
            'rename-new:added',
            'rename-old:deleted',
          ],
        );
        final staged = {
          for (final file in result.staged.files) file.relativePath: file,
        };
        expect(_lines(staged['added']!), ['addition:index addition']);
        expect(_lines(staged['deleted']!), ['deletion:deleted HEAD']);
        expect(_lines(staged['recreated']!), ['deletion:original HEAD']);
        expect(_lines(staged['rename-new']!), ['addition:rename content']);
        expect(_lines(staged['rename-old']!), ['deletion:rename content']);
        for (final path in ['empty-added', 'empty-deleted']) {
          expect(staged[path]!.contentStatus, 'text');
          expect(staged[path]!.hunks, isEmpty);
        }
        expect(
          result.unstaged.files.map(
            (file) => '${file.relativePath}:${file.changeKind}',
          ),
          [
            'added:modified',
            'empty-untracked:added',
            'recreated:added',
            'untracked:added',
          ],
        );
        expect(_lines(result.unstaged.files[0]), [
          'deletion:index addition',
          'addition:working addition',
        ]);
        expect(result.unstaged.files[1].hunks, isEmpty);
        expect(_lines(result.unstaged.files[2]), [
          'addition:recreated working',
        ]);
        expect(result.conflicts, isEmpty);
        expect(await _fingerprint(repository), before);
      },
    );

    test(
      'file/directory replacements retain exact parent and child changes',
      () async {
        await write('file-to-dir', 'old parent\n');
        await write('dir-to-file/child', 'old child\n');
        await commit();
        await _git(repository, [
          'rm',
          '--',
          'file-to-dir',
          'dir-to-file/child',
        ]);
        await write('file-to-dir/child', 'new child\n');
        await write('dir-to-file', 'new parent\n');
        await _git(repository, ['add', '--all']);
        final before = await _fingerprint(repository);

        final result = await uncommitted();
        expect(
          result.staged.files.map(
            (file) => '${file.relativePath}:${file.changeKind}',
          ),
          [
            'dir-to-file:added',
            'dir-to-file/child:deleted',
            'file-to-dir:deleted',
            'file-to-dir/child:added',
          ],
        );
        expect(result.staged.files.map(_lines), [
          ['addition:new parent'],
          ['deletion:old child'],
          ['deletion:old parent'],
          ['addition:new child'],
        ]);
        expect(result.unstaged.files, isEmpty);
        expect(result.conflicts, isEmpty);
        for (final file in result.staged.files) {
          final request = processes.requests.singleWhere(
            (request) =>
                request.arguments.contains('--patch') &&
                request.arguments.last == './${file.relativePath}',
          );
          expect(
            request.arguments,
            contains('--diff-filter=${file.changeKind == 'added' ? 'A' : 'D'}'),
          );
        }
        expect(await _fingerprint(repository), before);
      },
    );

    test(
      'intent-to-add remains absent from staged including empty content',
      () async {
        await write('intent-empty', '');
        await write('intent-text', 'intent\n');
        await _git(repository, [
          'add',
          '--intent-to-add',
          '--',
          'intent-empty',
          'intent-text',
        ]);
        final result = await uncommitted();
        expect(result.staged.files, isEmpty);
        expect(result.unstaged.files.map((file) => file.relativePath), [
          'intent-empty',
          'intent-text',
        ]);
        expect(
          result.unstaged.files.every((file) => file.changeKind == 'added'),
          isTrue,
        );
        expect(result.unstaged.files.first.contentStatus, 'text');
        expect(result.unstaged.files.first.hunks, isEmpty);
        expect(_lines(result.unstaged.files.last), ['addition:intent']);
        expect(result.conflicts, isEmpty);
      },
    );

    Future<void> conflict() async {
      await _git(repository, ['checkout', '-b', 'other']);
      await write('baseline', 'other\n');
      await commit();
      await _git(repository, ['checkout', 'main']);
      await write('baseline', 'main\n');
      await commit();
      expect(
        (await _gitResult(repository, [
          'merge',
          '--no-edit',
          'other',
        ])).exitCode,
        1,
      );
    }

    test(
      'real unmerged stages appear only in the separate conflicts collection',
      () async {
        await conflict();
        await write('staged', 'index\n');
        await _git(repository, ['add', '--', 'staged']);
        await write('unstaged', 'working\n');
        final before = await _fingerprint(repository);
        final result = await uncommitted();
        expect(result.staged.files.map((file) => file.relativePath), [
          'staged',
        ]);
        expect(result.unstaged.files.map((file) => file.relativePath), [
          'unstaged',
        ]);
        final file = result.conflicts.single;
        expect(file.relativePath, 'baseline');
        expect(file.changeKind, 'conflicted');
        expect(file.contentStatus, 'conflicted');
        expect(file.hunks, isEmpty);
        expect(file.detail, isNotEmpty);
        await expectLater(
          uncommitted(limits: const GitPortableUnstagedLimits(files: 2)),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              'snapshot_too_large',
            ),
          ),
        );
        expect(await _fingerprint(repository), before);
      },
    );

    test('binary and invalid UTF-8 stay explicit in both layers', () async {
      for (final path in ['binary', 'invalid']) {
        await write(path, 'HEAD\n');
      }
      await commit();
      await File('${repository.path}/binary').writeAsBytes([1, 0, 2]);
      await File('${repository.path}/invalid').writeAsBytes([255, 254]);
      await _git(repository, ['add', '--all']);
      await File('${repository.path}/binary').writeAsBytes([2, 0, 3]);
      await File('${repository.path}/invalid').writeAsBytes([254, 255]);
      final result = await uncommitted();
      for (final layer in [result.staged, result.unstaged]) {
        expect(layer.files.map((file) => file.relativePath), [
          'binary',
          'invalid',
        ]);
        expect(layer.files.map((file) => file.contentStatus), [
          'binary',
          'unsupported',
        ]);
        for (final file in layer.files) {
          expect(file.changeKind, 'modified');
          expect(file.hunks, isEmpty);
          expect(file.detail, isNotEmpty);
        }
      }
      expect(
        processes.requests.where(
          (request) =>
              request.arguments.contains('--patch') ||
              request.arguments.contains('--no-index'),
        ),
        isEmpty,
      );
    });

    test(
      'mode symlink gitlink and index flags are unsupported without text hunks',
      () async {
        for (final path in ['mode', 'skip', 'assume']) {
          await write(path, 'HEAD\n');
        }
        await Link('${repository.path}/link').create('missing-before');
        await commit();
        await Link('${repository.path}/link').update('missing-after');
        await _git(repository, ['add', '--', 'link']);
        await _git(repository, ['update-index', '--chmod=+x', 'mode']);
        await _git(repository, ['update-index', '--skip-worktree', 'skip']);
        await _git(repository, [
          'update-index',
          '--assume-unchanged',
          'assume',
        ]);
        final head = (await _git(repository, ['rev-parse', 'HEAD'])).trim();
        await _git(repository, [
          'update-index',
          '--add',
          '--cacheinfo',
          '160000,$head,module',
        ]);
        // HEAD/index modes remain meaningful even if working chmod is ignored.
        await _git(repository, ['config', 'core.filemode', 'false']);
        final before = await _fingerprint(repository);
        final result = await uncommitted();
        expect(
          result.staged.files.map(
            (file) => '${file.relativePath}:${file.changeKind}',
          ),
          ['link:modified', 'mode:typeChanged', 'module:added'],
        );
        expect(result.unstaged.files.map((file) => file.relativePath), [
          'assume',
          'link',
          'module',
          'skip',
        ]);
        for (final file in [...result.staged.files, ...result.unstaged.files]) {
          expect(file.contentStatus, 'unsupported');
          expect(file.hunks, isEmpty);
          expect(file.detail, isNotEmpty);
        }
        expect(await _fingerprint(repository), before);
      },
    );

    for (final (rule, status) in [
      ('crlf', 'unsupported'),
      ('crlf=input', 'unsupported'),
      ('-crlf', 'text'),
      ('', 'text'),
      ('filter=hostile', 'unsupported'),
      ('diff=hostile', 'unsupported'),
      ('-diff', 'binary'),
    ]) {
      test('staged content preserves the $rule attribute policy', () async {
        await write('baseline', 'index\n');
        await _git(repository, ['add', '--', 'baseline']);
        await File(
          '${repository.path}/.git/info/attributes',
        ).writeAsString(rule.isEmpty ? '' : 'baseline $rule\n');
        final file = (await uncommitted()).staged.files.single;
        expect(file.changeKind, 'modified');
        expect(file.contentStatus, status);
        if (status == 'text') {
          expect(_lines(file), ['deletion:baseline', 'addition:index']);
        } else {
          expect(file.hunks, isEmpty);
          expect(file.detail, isNotEmpty);
        }
      });
    }

    test(
      'staged conversion respects empty false and implicit true booleans',
      () async {
        await write('baseline', 'index\n');
        await _git(repository, ['add', '--', 'baseline']);
        for (final (setting, status) in [
          ('autocrlf\n', 'unsupported'),
          ('autocrlf =\n', 'text'),
        ]) {
          await File(
            '${repository.path}/.git/config',
          ).writeAsString('\n[core]\n$setting', mode: FileMode.append);
          final file = (await uncommitted()).staged.files.single;
          expect(file.contentStatus, status);
        }
      },
    );

    test(
      'oversized staged sides retain additions modifications and deletions',
      () async {
        for (final path in ['old-large', 'deleted-large']) {
          await write(path, 'x' * 128);
        }
        await write('new-large', 'small\n');
        await commit();
        await write('old-large', 'small\n');
        await write('new-large', 'y' * 128);
        await write('added-large', 'z' * 128);
        await _git(repository, ['rm', '--', 'deleted-large']);
        await _git(repository, ['add', '--all']);
        final result = await uncommitted(
          limits: const GitPortableUnstagedLimits(fileBytes: 64),
        );
        expect(
          result.staged.files.map(
            (file) => '${file.relativePath}:${file.changeKind}',
          ),
          [
            'added-large:added',
            'deleted-large:deleted',
            'new-large:modified',
            'old-large:modified',
          ],
        );
        for (final file in result.staged.files) {
          expect(file.contentStatus, 'oversized');
          expect(file.hunks, isEmpty);
          expect(file.detail, isNotEmpty);
        }
        expect(result.unstaged.files, isEmpty);
      },
    );

    test(
      'nested scope preserves literal unusual names and orders both layers',
      () async {
        const paths = [
          ' space ',
          '-option',
          ':(glob)*[x]',
          'line\nname',
          'tab\tname',
          r'back\slash',
          'quote\'";\$(touch INJECTED)',
        ];
        for (final path in [
          ...paths.map((path) => 'selected/$path'),
          'outside',
        ]) {
          await write(path, 'HEAD\r\nlast HEAD');
        }
        await commit();
        for (final path in [
          ...paths.map((path) => 'selected/$path'),
          'outside',
        ]) {
          await write(path, 'index\r\nlast index');
        }
        await _git(repository, ['add', '--all']);
        for (final path in [
          ...paths.map((path) => 'selected/$path'),
          'outside',
        ]) {
          await write(path, 'working\r\nlast working');
        }
        processes = _FixtureProcesses(
          Directory('${repository.path}/selected'),
          container,
        );
        final before = await _fingerprint(repository);
        final result = await uncommitted();
        for (final (layer, left, right) in [
          (result.staged, 'HEAD', 'index'),
          (result.unstaged, 'index', 'working'),
        ]) {
          expect(
            layer.files.map((file) => file.relativePath),
            [...paths]..sort(),
          );
          for (final file in layer.files) {
            expect(
              file.hunks.single.lines.map(
                (line) => (line.kind, line.text, line.noNewline),
              ),
              [
                ('deletion', '$left\r', false),
                ('deletion', 'last $left', true),
                ('addition', '$right\r', false),
                ('addition', 'last $right', true),
              ],
            );
          }
        }
        expect(
          await File('${repository.path}/selected/INJECTED').exists(),
          isFalse,
        );
        expect(await _fingerprint(repository), before);
      },
    );

    test(
      'detached HEAD works while unborn HEAD fails only Uncommitted',
      () async {
        await _git(repository, ['checkout', '--detach']);
        await write('baseline', 'index\n');
        await _git(repository, ['add', '--', 'baseline']);
        await write('baseline', 'working\n');
        final detached = await uncommitted();
        expect(_lines(detached.staged.files.single), [
          'deletion:baseline',
          'addition:index',
        ]);
        expect(_lines(detached.unstaged.files.single), [
          'deletion:index',
          'addition:working',
        ]);
        final unborn = await Directory('${container.path}/unborn').create();
        await _git(unborn, ['init']);
        await File('${unborn.path}/new').writeAsString('new\n');
        processes = _FixtureProcesses(unborn, container);
        expect(_lines((await snapshot()).files.single), ['addition:new']);
        await expectLater(
          uncommitted(),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              'head_unavailable',
            ),
          ),
        );
      },
    );

    test(
      'SHA-256 HEAD index blobs and full-index patch identities work',
      () async {
        final shaRepository = await Directory(
          '${container.path}/sha256',
        ).create();
        await _git(shaRepository, ['init', '--object-format=sha256']);
        await _git(shaRepository, ['config', 'user.name', 'ADELE Test']);
        await _git(shaRepository, [
          'config',
          'user.email',
          'adele@example.invalid',
        ]);
        final file = File('${shaRepository.path}/tracked');
        await file.writeAsString('HEAD\n');
        await _git(shaRepository, ['add', '--all']);
        await _git(shaRepository, ['commit', '-m', 'SHA256']);
        await file.writeAsString('index\n');
        await _git(shaRepository, ['add', '--all']);
        await file.writeAsString('working\n');
        processes = _FixtureProcesses(shaRepository, container);
        final before = await _fingerprint(shaRepository);
        final result = await uncommitted();
        expect(_lines(result.staged.files.single), [
          'deletion:HEAD',
          'addition:index',
        ]);
        expect(_lines(result.unstaged.files.single), [
          'deletion:index',
          'addition:working',
        ]);
        final cached = processes.requests.singleWhere(
          (request) =>
              request.arguments.contains('diff') &&
              request.arguments.contains('--cached'),
        );
        expect(cached.arguments, contains(matches(RegExp(r'^[0-9a-f]{64}$'))));
        expect(await _fingerprint(shaRepository), before);
      },
    );

    for (final mutation in [
      'HEAD commit',
      'HEAD reference',
      'index',
      'attributes',
      'configuration',
      'working file',
    ]) {
      test(
        '$mutation changing after cached patch rejects the whole result',
        () async {
          await write('baseline', 'index\n');
          await _git(repository, ['add', '--', 'baseline']);
          await write('baseline', 'working\n');
          final next = (await _git(repository, [
            'commit-tree',
            'HEAD^{tree}',
            '-p',
            'HEAD',
            '-m',
            'Next',
          ])).trim();
          await _git(repository, ['branch', 'same-commit']);
          var changed = false;
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            if (!changed &&
                request.arguments.contains('diff') &&
                request.arguments.contains('--cached')) {
              changed = true;
              switch (mutation) {
                case 'HEAD commit':
                  await _git(repository, ['update-ref', 'HEAD', next]);
                case 'HEAD reference':
                  await _git(repository, [
                    'symbolic-ref',
                    'HEAD',
                    'refs/heads/same-commit',
                  ]);
                case 'index':
                  await _git(repository, ['add', '--', 'baseline']);
                case 'attributes':
                  await File(
                    '${repository.path}/.git/info/attributes',
                  ).writeAsString('baseline -diff\n');
                case 'configuration':
                  await _git(repository, ['config', 'core.filemode', 'false']);
                case 'working file':
                  await write('baseline', 'changed after staged capture\n');
              }
            }
            return result;
          });
          UncommittedChangeSetSnapshot? published;
          await expectLater(
            uncommitted(through: through).then((result) => published = result),
            throwsA(
              isA<ChangeSetFailure>().having(
                (error) => error.code,
                'code',
                'snapshot_changed',
              ),
            ),
          );
          expect(changed, isTrue);
          expect(published, isNull);
        },
      );
    }

    test(
      'repository replacement during inspection cannot redirect later source commands',
      () async {
        await write('selected/file', 'HEAD\n');
        await commit();
        await write('selected/file', 'index\n');
        await _git(repository, ['add', '--all']);
        await write('selected/file', 'working\n');
        final selected = Directory('${repository.path}/selected');
        processes = _FixtureProcesses(selected, container);
        var replaced = false;
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (!replaced &&
              request.arguments.contains('diff') &&
              request.arguments.contains('--cached')) {
            replaced = true;
            await _git(selected, ['init']);
          }
          return result;
        });
        await expectLater(
          uncommitted(through: through),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              'snapshot_changed',
            ),
          ),
        );
        expect(replaced, isTrue);
        for (final request in processes.requests.where(
          (request) => request.arguments.contains('ls-files'),
        )) {
          expect(
            request.arguments,
            contains('--git-dir=${repository.path}/.git'),
          );
          expect(request.arguments, contains('--work-tree=${repository.path}'));
        }
      },
    );

    for (final stage in [2, 3]) {
      test(
        'final conflict stage $stage identity is checked with stage one unchanged',
        () async {
          await conflict();
          var inventories = 0;
          var changed = false;
          final replacement = (await _git(repository, [
            'rev-parse',
            ':1:baseline',
          ])).trim();
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            if (request.arguments.contains('ls-files') &&
                request.arguments.contains('--cached') &&
                ++inventories == 2) {
              final raw = utf8.decode(base64Decode(result.stdoutBase64));
              final match = RegExp(
                '100644 ([0-9a-f]{40}) $stage\\tbaseline\\x00',
              ).firstMatch(raw)!;
              expect(match[1], isNot(replacement));
              final mutated = raw.replaceRange(
                match.start,
                match.end,
                '100644 $replacement $stage\tbaseline\x00',
              );
              expect(mutated, isNot(raw));
              final firstStage = RegExp(
                r'100644 [0-9a-f]{40} 1\tbaseline\x00',
              ).firstMatch(raw)![0]!;
              expect(mutated, contains(firstStage));
              changed = true;
              return _result(stdout: mutated);
            }
            return result;
          });
          await expectLater(
            uncommitted(through: through),
            throwsA(
              isA<ChangeSetFailure>().having(
                (error) => error.code,
                'code',
                'snapshot_changed',
              ),
            ),
          );
          expect(changed, isTrue);
          expect(inventories, 2);
        },
      );
    }

    for (final corruption in [
      'malformed initial tree',
      'final tree valid prefix',
      'final tree OID',
      'tree warning',
      'tree nonzero',
    ]) {
      test('$corruption fails instead of publishing layered data', () async {
        await write('second', 'HEAD\n');
        await commit();
        await write('baseline', 'index\n');
        await _git(repository, ['add', '--all']);
        var trees = 0;
        var changed = false;
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (!request.arguments.contains('ls-tree')) return result;
          trees++;
          final finalTree = corruption.startsWith('final');
          if (trees != (finalTree ? 2 : 1)) return result;
          changed = true;
          final raw = utf8.decode(base64Decode(result.stdoutBase64));
          return switch (corruption) {
            'malformed initial tree' => _result(stdout: 'not a tree\x00'),
            'final tree valid prefix' => _result(
              stdout: raw.substring(0, raw.indexOf('\x00') + 1),
            ),
            'final tree OID' => _result(
              stdout: raw.replaceFirst(RegExp(r'[0-9a-f]{40}'), '0' * 40),
            ),
            'tree warning' => _result(
              stdout: raw,
              stderr: 'warning: incomplete tree\n',
            ),
            _ => _result(stdout: raw, exitCode: 128),
          };
        });
        await expectLater(
          uncommitted(through: through),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              switch (corruption) {
                'malformed initial tree' => 'invalid_git_output',
                'final tree valid prefix' ||
                'final tree OID' => 'snapshot_changed',
                _ => 'git_failed',
              },
            ),
          ),
        );
        expect(changed, isTrue);
      });
    }

    for (final corruption in [
      'malformed',
      'valid hunk prefix',
      'wrong old OID',
      'wrong new OID',
      'stderr',
      'nonzero',
      'empty difference',
      'zero with patch',
    ]) {
      test('cached patch $corruption cannot publish a staged prefix', () async {
        final original = '${List.generate(30, (i) => 'line $i').join('\n')}\n';
        await write('baseline', original);
        await commit();
        await write(
          'baseline',
          original
              .replaceFirst('line 1\n', 'first\n')
              .replaceFirst('line 27\n', 'last\n'),
        );
        await _git(repository, ['add', '--all']);
        var changed = false;
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (!request.arguments.contains('diff') ||
              !request.arguments.contains('--cached')) {
            return result;
          }
          changed = true;
          var raw = utf8.decode(base64Decode(result.stdoutBase64));
          expect(result.exitCode, 1);
          switch (corruption) {
            case 'malformed':
              raw = '$raw+unexpected line\n';
            case 'valid hunk prefix':
              final hunks = RegExp(
                r'^@@ ',
                multiLine: true,
              ).allMatches(raw).toList();
              expect(hunks, hasLength(2));
              raw = raw.substring(0, hunks.last.start);
            case 'wrong old OID':
            case 'wrong new OID':
              final identity = RegExp(
                r'^index ([0-9a-f]{40})\.\.([0-9a-f]{40})',
                multiLine: true,
              ).firstMatch(raw)!;
              raw = raw.replaceRange(
                identity.start,
                identity.end,
                'index ${corruption == 'wrong old OID' ? '0' * 40 : identity[1]}..${corruption == 'wrong new OID' ? '0' * 40 : identity[2]}',
              );
            case 'empty difference':
              raw = '';
            case 'stderr':
            case 'nonzero':
            case 'zero with patch':
              break;
          }
          return _result(
            stdout: raw,
            exitCode: corruption == 'nonzero'
                ? 128
                : corruption == 'zero with patch'
                ? 0
                : 1,
            stderr: corruption == 'stderr' ? 'warning: incomplete patch\n' : '',
          );
        });
        UncommittedChangeSetSnapshot? published;
        await expectLater(
          uncommitted(through: through).then((result) => published = result),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              switch (corruption) {
                'malformed' || 'valid hunk prefix' => 'invalid_git_output',
                'stderr' || 'nonzero' => 'git_failed',
                _ => 'snapshot_changed',
              },
            ),
          ),
        );
        expect(changed, isTrue);
        expect(published, isNull);
      });
    }

    test(
      'cached hunks cannot split a new-side line using no-newline markers',
      () async {
        await write('addition', 'hello\n');
        await _git(repository, ['add', '--', 'addition']);
        var changed = false;
        final through = _InterceptingProcesses(processes, (request, run) async {
          final result = await run(request);
          if (!request.arguments.contains('--patch')) return result;
          changed = true;
          final raw = utf8.decode(base64Decode(result.stdoutBase64));
          return _result(
            exitCode: 1,
            stdout:
                '${raw.substring(0, raw.indexOf('@@'))}'
                '@@ -0,0 +1,2 @@\n+he\n\\ No newline at end of file\n+llo\n',
          );
        });
        await expectLater(
          uncommitted(through: through),
          throwsA(
            isA<ChangeSetFailure>().having(
              (error) => error.code,
              'code',
              'invalid_git_output',
            ),
          ),
        );
        expect(changed, isTrue);
      },
    );

    for (final bound in ['entries', 'lines', 'bytes', 'processes']) {
      test(
        '$bound budget is shared across layers rather than restarted',
        () async {
          await write('baseline', 'index\n');
          await _git(repository, ['add', '--', 'baseline']);
          await write('baseline', 'working\n');
          var transportedBytes = 0;
          final through = _InterceptingProcesses(processes, (
            request,
            run,
          ) async {
            final result = await run(request);
            transportedBytes +=
                base64Decode(request.stdinBase64).length +
                base64Decode(result.stdoutBase64).length +
                base64Decode(result.stderrBase64).length;
            return result;
          });
          final complete = await uncommitted(through: through);
          expect(complete.staged.files, hasLength(1));
          expect(complete.unstaged.files, hasLength(1));
          final limits = switch (bound) {
            'entries' => const GitPortableUnstagedLimits(files: 1),
            'lines' => const GitPortableUnstagedLimits(lines: 3),
            'bytes' => GitPortableUnstagedLimits(
              totalBytes: transportedBytes - 1,
            ),
            _ => GitPortableUnstagedLimits(
              processes: processes.requests.length - 1,
            ),
          };
          expect((await snapshot(limits: limits)).files, hasLength(1));
          await write('baseline', 'index\n');
          final stagedOnly = await uncommitted(limits: limits);
          expect(stagedOnly.staged.files, hasLength(1));
          expect(stagedOnly.unstaged.files, isEmpty);
          await write('baseline', 'working\n');
          UncommittedChangeSetSnapshot? published;
          await expectLater(
            uncommitted(limits: limits).then((result) => published = result),
            throwsA(
              isA<ChangeSetFailure>().having(
                (error) => error.code,
                'code',
                'snapshot_too_large',
              ),
            ),
          );
          expect(published, isNull);
        },
      );
    }

    test('HEAD/index/untracked union cannot exceed inventory bounds', () async {
      await _git(repository, ['rm', '--', 'baseline']);
      await write('added', 'index\n');
      await _git(repository, ['add', '--', 'added']);
      await write('untracked', 'working\n');
      await expectLater(
        uncommitted(
          limits: const GitPortableUnstagedLimits(inventoryEntries: 2),
        ),
        throwsA(
          isA<ChangeSetFailure>().having(
            (error) => error.code,
            'code',
            'inventory_too_large',
          ),
        ),
      );
    });

    test('flat clean 160 files use 26 + 4 * ceil(n / 128) requests', () async {
      const count = 160;
      for (var index = 1; index < count; index++) {
        await write('file-${index.toString().padLeft(3, '0')}', 'small\n');
      }
      await commit();
      final before = await _fingerprint(repository);
      final result = await uncommitted();
      expect(result.staged.files, isEmpty);
      expect(result.unstaged.files, isEmpty);
      expect(result.conflicts, isEmpty);
      // Six extra requests: initial/final commit, symbolic reference and tree.
      expect(processes.requests, hasLength(26 + 4 * ((count + 127) ~/ 128)));
      expect(
        processes.requests.where(
          (request) => request.arguments.contains('hash-object'),
        ),
        hasLength(2),
      );
      for (final argument in ['HEAD^{commit}', 'symbolic-ref', 'ls-tree']) {
        expect(
          processes.requests.where(
            (request) => request.arguments.contains(argument),
          ),
          hasLength(2),
        );
      }
      expect(
        processes.requests.where(
          (request) =>
              request.arguments.contains('/usr/bin/head') ||
              request.arguments.contains('diff'),
        ),
        isEmpty,
      );
      expect(await _fingerprint(repository), before);
    });

    for (final count in [100, 500, 900]) {
      test(
        'diagnostic clean $count and three staged plus unstaged edits',
        () async {
          for (var index = 1; index < count; index++) {
            await write('file-${index.toString().padLeft(3, '0')}', 'HEAD\n');
          }
          await commit();
          for (final dirty in [false, true]) {
            if (dirty) {
              for (var index = 1; index <= 3; index++) {
                await write(
                  'file-${index.toString().padLeft(3, '0')}',
                  'index\n',
                );
              }
              await _git(repository, ['add', '--all']);
              for (var index = 1; index <= 3; index++) {
                await write(
                  'file-${index.toString().padLeft(3, '0')}',
                  'working\n',
                );
              }
            }
            processes.requests.clear();
            final watch = Stopwatch()..start();
            final result = await uncommitted();
            watch.stop();
            // Timing is diagnostic only and excludes all fixture setup.
            print(
              'portable Uncommitted ${dirty ? 'three layered edits' : 'clean'} n=$count requests=${processes.requests.length} elapsed=${watch.elapsedMilliseconds}ms',
            );
            expect(result.staged.files, hasLength(dirty ? 3 : 0));
            expect(result.unstaged.files, hasLength(dirty ? 3 : 0));
            expect(result.conflicts, isEmpty);
          }
        },
      );
    }
  });
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
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() =>
      delegate.capturedIdentity();

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
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async =>
      AuthorizedEnvironmentIdentity(
        sessionId: 'portable-session',
        environmentId: 'portable-environment',
      );

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
