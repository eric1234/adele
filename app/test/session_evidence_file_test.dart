import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';

import '../tool/session_evidence_exporter.dart';

void main() {
  late Directory directory;
  late File destination;
  final bytes = utf8.encode(
    '{"schema":"$sessionEvidenceSchema","exact":"a\\nb"}',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'adele-export-file-test-',
    );
    destination = File('${directory.path}/evidence.json');
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> write({void Function()? validate}) =>
      writeSessionEvidenceFile(destination, bytes, validate: validate ?? () {});

  void expectNoStaging() => expect(
    directory.listSync().map((entry) => entry.path),
    everyElement(isNot(contains('.adele-session-evidence-'))),
  );

  test('writes exact bytes and safely replaces an existing file', () async {
    await write();
    expect(await destination.readAsBytes(), bytes);
    await destination.writeAsString('previous destination');
    await write();
    expect(await destination.readAsBytes(), bytes);
    expectNoStaging();
  });

  for (final phase in ['write', 'rename']) {
    test('$phase failure preserves destination and cleans staging', () async {
      await destination.writeAsString('previous destination');
      await expectLater(
        IOOverrides.runWithIOOverrides(write, _StagingOverrides(failAt: phase)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination.readAsString(), 'previous destination');
      expectNoStaging();
    });
  }

  test('does not expose incomplete staging as a new destination', () async {
    await expectLater(
      IOOverrides.runWithIOOverrides(write, _StagingOverrides(failAt: 'write')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await destination.exists(), isFalse);
    expectNoStaging();
  });

  test(
    'revocation after staging prevents commit and removes staged data',
    () async {
      await destination.writeAsString('previous destination');
      final entered = Completer<void>();
      final release = Completer<void>();
      var active = true;
      final writing = IOOverrides.runWithIOOverrides(
        () => write(
          validate: () {
            if (!active) throw StateError('Closed');
          },
        ),
        _StagingOverrides(entered: entered, release: release),
      );
      await entered.future;
      expect(await destination.readAsString(), 'previous destination');
      active = false;
      release.complete();
      await expectLater(writing, throwsStateError);
      expect(await destination.readAsString(), 'previous destination');
      expectNoStaging();
    },
  );

  test(
    'missing parent fails without creating destination directories',
    () async {
      destination = File('${directory.path}/missing/evidence.json');
      await expectLater(write(), throwsA(isA<FileSystemException>()));
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'existing destination directory is not removed on failed rename',
    () async {
      await Directory(destination.path).create();
      final retained = File('${destination.path}/retained')
        ..writeAsStringSync('old');
      await expectLater(write(), throwsA(isA<FileSystemException>()));
      expect(await retained.readAsString(), 'old');
      expectNoStaging();
    },
  );

  test('replacement does not follow the destination symlink', () async {
    final other = File('${directory.path}/other')..writeAsStringSync('private');
    await Link(destination.path).create(other.path);
    await write();
    expect(await destination.readAsBytes(), bytes);
    expect(await other.readAsString(), 'private');
    expectNoStaging();
  });

  test('over-bound data is rejected before touching destination', () async {
    await destination.writeAsString('previous destination');
    await expectLater(
      writeSessionEvidenceFile(
        destination,
        List<int>.filled(sessionEvidenceMaxBytes + 1, 32),
        validate: () {},
      ),
      throwsFormatException,
    );
    expect(await destination.readAsString(), 'previous destination');
    expectNoStaging();
  });
}

final class _StagingOverrides extends IOOverrides {
  _StagingOverrides({this.failAt, this.entered, this.release});

  final String? failAt;
  final Completer<void>? entered;
  final Completer<void>? release;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.contains('/.adele-session-evidence-')
        ? _StagedFile(file, this)
        : file;
  }
}

final class _StagedFile implements File {
  _StagedFile(this.file, this.overrides);
  final File file;
  final _StagingOverrides overrides;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    expect(flush, isTrue);
    if (overrides.failAt == 'write') {
      await file.writeAsBytes(bytes.take(3).toList(), mode: mode, flush: flush);
      throw FileSystemException('Injected partial staging failure', file.path);
    }
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    overrides.entered?.complete();
    await overrides.release?.future;
    return this;
  }

  @override
  Future<File> rename(String newPath) {
    if (overrides.failAt == 'rename') {
      throw FileSystemException('Injected finalization failure', file.path);
    }
    return file.rename(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
