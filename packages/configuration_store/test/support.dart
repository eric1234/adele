import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

PlatformStorageRoots rootsAt(String root, {String? configurationRoot}) =>
    PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: configurationRoot ?? p.join(root, 'config'),
      localStateRoot: p.join(root, 'state'),
      localDataRoot: p.join(root, 'data'),
      cacheRoot: p.join(root, 'cache'),
    );

/// Test-only fault/gate injection at real filesystem boundaries, not a fake store.
final class StagingOverrides extends IOOverrides {
  StagingOverrides({
    this.beforeWrite,
    this.beforeOpen,
    this.beforeRename,
    this.beforeDelete,
    this.beforeLock,
    this.missingLock,
    this.afterMissingLock,
  });

  final void Function(File)? beforeWrite;
  final void Function(File)? beforeOpen;
  final void Function(File)? beforeRename;
  final void Function(File)? beforeDelete;
  final void Function()? beforeLock;
  final void Function()? missingLock;
  final void Function()? afterMissingLock;

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) {
    final type = super.fseGetTypeSync(path, followLinks);
    if (type == FileSystemEntityType.notFound &&
        path.endsWith('${p.separator}settings.lock')) {
      afterMissingLock?.call();
    }
    return type;
  }

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (path.endsWith('${p.separator}settings.lock') &&
        (beforeLock != null || missingLock != null)) {
      return _LockFile(file, this);
    }
    if (path.contains(RegExp(r'[/\\]\.[^/\\]+\.toml\.'))) {
      return _StagedFile(file, this);
    }
    return beforeDelete != null && path.endsWith('.toml')
        ? _DeletedFile(file, beforeDelete!)
        : file;
  }
}

final class _LockFile implements File {
  _LockFile(this.file, this.overrides);
  final File file;
  final StagingOverrides overrides;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    try {
      return _LockHandle(file.openSync(mode: mode), overrides);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) overrides.missingLock?.call();
      rethrow;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _LockHandle implements RandomAccessFile {
  _LockHandle(this.handle, this.overrides);
  final RandomAccessFile handle;
  final StagingOverrides overrides;

  @override
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) {
    overrides.beforeLock?.call();
    handle.lockSync(mode, start, end);
  }

  @override
  void unlockSync([int start = 0, int end = -1]) =>
      handle.unlockSync(start, end);

  @override
  void closeSync() => handle.closeSync();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> prepareWriter(
  Directory root, {
  String source = 'test/fixtures/writer.dart',
}) async {
  // Reuse assets prepared by `dart test`. Nested `dart run` invocations on this
  // SDK recopy bundled libraries, unsafe while the parent has them mapped.
  final sdk = File(Platform.resolvedExecutable).parent.parent.path;
  final kernel = p.join(root.path, 'writer.dill');
  final result = await Process.run(p.join(sdk, 'bin', 'dartaotruntime'), [
    p.join(sdk, 'bin', 'snapshots', 'gen_kernel_aot.dart.snapshot'),
    '--platform=${p.join(sdk, 'lib', '_internal', 'vm_platform_strong.dill')}',
    '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
    '--native-assets=${p.absolute('.dart_tool', 'native_assets.yaml')}',
    '--output=$kernel',
    source,
  ]);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  return kernel;
}

final class ConfigurationWriter {
  ConfigurationWriter(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      errors = process.stderr.transform(utf8.decoder).join();

  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;

  static Future<ConfigurationWriter> start(
    String kernel,
    String root,
    String mode, [
    String? value,
    String? recordId,
    String? collectionId,
    String? installations,
  ]) async {
    final writer = ConfigurationWriter(
      await Process.start(Platform.resolvedExecutable, [
        '--disable-dart-dev',
        kernel,
        root,
        mode,
        ?value,
        ?recordId,
        ?collectionId,
        ?installations,
      ]),
    );
    addTearDown(() async {
      writer.process.kill(ProcessSignal.sigkill);
      await writer.process.exitCode;
      await writer.lines.cancel();
    });
    return writer;
  }

  Future<void> expectLine(String expected) async {
    final hasLine = await lines.moveNext().timeout(const Duration(minutes: 1));
    if (!hasLine) {
      fail('Expected $expected before process exit: ${await errors}');
    }
    expect(lines.current, expected);
  }

  Future<void> expectExit() async {
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(minutes: 1));
    expect(code, 0, reason: await errors);
    expect(await errors, isEmpty);
  }
}

final class _DeletedFile implements File {
  _DeletedFile(this.file, this.beforeDelete);

  final File file;
  final void Function(File) beforeDelete;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      file.openSync(mode: mode);

  @override
  void deleteSync({bool recursive = false}) {
    beforeDelete(file);
    file.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StagedFile implements File {
  _StagedFile(this.file, this.overrides);

  final File file;
  final StagingOverrides overrides;

  @override
  String get path => file.path;

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    overrides.beforeWrite?.call(file);
    file.writeAsBytesSync(bytes, mode: mode, flush: flush);
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    overrides.beforeOpen?.call(file);
    return file.openSync(mode: mode);
  }

  @override
  File renameSync(String newPath) {
    overrides.beforeRename?.call(file);
    return file.renameSync(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
