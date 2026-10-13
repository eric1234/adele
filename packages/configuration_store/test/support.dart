import 'dart:io';

import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:path/path.dart' as p;

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
  });

  final void Function(File)? beforeWrite;
  final void Function(File)? beforeOpen;
  final void Function(File)? beforeRename;
  final void Function(File)? beforeDelete;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (path.contains(RegExp(r'[/\\]\.[^/\\]+\.toml\.'))) {
      return _StagedFile(file, this);
    }
    return beforeDelete != null && path.endsWith('.toml')
        ? _DeletedFile(file, beforeDelete!)
        : file;
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
