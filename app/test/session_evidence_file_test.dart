import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import '../tool/session_evidence_exporter.dart';

void main() {
  late Directory directory;
  late Directory output;
  late Directory worktree;
  final bytes = utf8.encode(
    '{"schema":"$sessionEvidenceSchema","exact":"a\\nb"}',
  );
  const readme = '# Evaluation handoff\nRead evidence.json first.\n';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('adele-handoff-test-');
    output = Directory('${directory.path}/state/evaluations');
    worktree = await Directory('${directory.path}/worktree').create();
    await File('${worktree.path}/.git').writeAsString('fixture marker');
  });
  tearDown(() => directory.delete(recursive: true));

  Future<Directory> write({void Function()? validate}) =>
      writeSessionEvaluationHandoff(
        output,
        bytes,
        readme: readme,
        validate: validate ?? () {},
        excludedDirectories: [worktree],
      );

  void expectNoHandoff() {
    if (output.existsSync()) expect(output.listSync(), isEmpty);
  }

  test(
    'unique private directories retain both files without overwriting',
    () async {
      final first = await write();
      final firstEvidence = File('${first.path}/evidence.json');
      expect(await firstEvidence.readAsBytes(), bytes);
      expect(await File('${first.path}/README.md').readAsString(), readme);
      expect(
        first.listSync().map((file) => file.uri.pathSegments.last).toSet(),
        {'README.md', 'evidence.json'},
      );
      expect(first.isAbsolute, isTrue);
      expect(first.parent.path, output.path);
      if (Platform.isLinux || Platform.isMacOS) {
        expect((await first.stat()).mode & 0x1ff, 0x1c0);
      }
      await firstEvidence.writeAsString('previous handoff');
      final second = await write();
      expect(second.path, isNot(first.path));
      expect(await firstEvidence.readAsString(), 'previous handoff');
      expect(await File('${second.path}/evidence.json').readAsBytes(), bytes);
      expect(await File('${second.path}/README.md').readAsString(), readme);
      expect(output.listSync(), hasLength(2));
      expect(worktree.listSync(), hasLength(1));
    },
  );

  for (final filename in ['evidence.json', 'README.md']) {
    test(
      'partial $filename write fails and removes incomplete output',
      () async {
        final previous = await write();
        final retained = File(
          '${previous.path}/evidence.json',
        ).readAsBytesSync();
        await expectLater(
          IOOverrides.runWithIOOverrides(
            write,
            _WritingOverrides(filename: filename, fail: true),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(output.listSync().map((entry) => entry.path), [previous.path]);
        expect(
          File('${previous.path}/evidence.json').readAsBytesSync(),
          retained,
        );
      },
    );

    test(
      'retirement during $filename write prevents success and cleans up',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        var active = true;
        final writing = IOOverrides.runWithIOOverrides(
          () => write(
            validate: () {
              if (!active) throw StateError('Closed');
            },
          ),
          _WritingOverrides(
            filename: filename,
            entered: entered,
            release: release,
          ),
        );
        await entered.future;
        active = false;
        release.complete();
        await expectLater(writing, throwsStateError);
        expectNoHandoff();
      },
    );
  }

  test('revoked admission creates no output root', () async {
    await expectLater(
      write(validate: () => throw StateError('Closed')),
      throwsStateError,
    );
    expect(output.existsSync(), isFalse);
  });

  test('missing source can remain unavailable without creating it', () async {
    await worktree.delete(recursive: true);
    final destination = await write();
    expect(
      await File('${destination.path}/evidence.json').readAsBytes(),
      bytes,
    );
    expect(worktree.existsSync(), isFalse);
    output = Directory('${worktree.path}/evaluations');
    await expectLater(write(), throwsStateError);
    expect(worktree.existsSync(), isFalse);
  });

  test('file in place of output root fails without modifying it', () async {
    await output.parent.create(recursive: true);
    final existing = File(output.path)..writeAsStringSync('preserve');
    await expectLater(write(), throwsA(isA<FileSystemException>()));
    expect(existing.readAsStringSync(), 'preserve');
  });

  test(
    'unresolvable source alias fails closed without an output directory',
    () async {
      await worktree.delete(recursive: true);
      await Link(worktree.path).create('${directory.path}/missing-source');
      await expectLater(write(), throwsA(isA<FileSystemException>()));
      expect(output.existsSync(), isFalse);
    },
  );

  for (final location in [
    'worktree',
    'nested source',
    'alias',
    'worktree hierarchy',
    'unrelated repository',
  ]) {
    test('rejects output in $location before allocating directories', () async {
      switch (location) {
        case 'worktree':
          output = Directory('${worktree.path}/evaluations');
        case 'nested source':
          final source = await Directory('${worktree.path}/selected').create();
          output = Directory('${worktree.path}/outside-selected/evaluations');
          worktree = source;
        case 'alias':
          final alias = Link('${directory.path}/alias');
          await alias.create(worktree.path);
          output = Directory('${alias.path}/evaluations');
        case 'worktree hierarchy':
          output = Directory(
            '${directory.path}/other/.adele/worktrees/task/evaluations',
          );
        case 'unrelated repository':
          final other = await Directory('${directory.path}/other').create();
          await Directory('${other.path}/.git').create();
          output = Directory('${other.path}/state/evaluations');
      }
      await expectLater(write(), throwsStateError);
      expect(output.existsSync(), isFalse);
    });
  }

  test(
    'canonicalizes an external output alias and handles special paths',
    () async {
      final state = await Directory(
        "${directory.path}/state with 'quotes';\$name",
      ).create();
      final alias = Link('${directory.path}/alias');
      await alias.create(state.path);
      output = Directory('${alias.path}/evaluations');
      final destination = await write();
      expect(destination.parent.path, '${state.path}/evaluations');
      expect(
        await File('${destination.path}/README.md').readAsString(),
        readme,
      );
    },
  );

  test('over-bound evidence is rejected before creating output root', () async {
    await expectLater(
      writeSessionEvaluationHandoff(
        output,
        List<int>.filled(sessionEvidenceMaxBytes + 1, 32),
        readme: readme,
        validate: () {},
        excludedDirectories: [worktree],
      ),
      throwsFormatException,
    );
    expect(output.existsSync(), isFalse);
  });
}

final class _WritingOverrides extends IOOverrides {
  _WritingOverrides({
    required this.filename,
    this.fail = false,
    this.entered,
    this.release,
  });

  final String filename;
  final bool fail;
  final Completer<void>? entered;
  final Completer<void>? release;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('/$filename') ? _WritingFile(file, this) : file;
  }
}

final class _WritingFile implements File {
  _WritingFile(this.file, this.overrides);
  final File file;
  final _WritingOverrides overrides;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    expect(flush, isTrue);
    if (overrides.fail) {
      await file.writeAsBytes(bytes.take(3).toList(), mode: mode, flush: flush);
      throw FileSystemException('Injected partial write failure', file.path);
    }
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    overrides.entered?.complete();
    await overrides.release?.future;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
