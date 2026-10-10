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
  StagingOverrides({this.beforeWrite, this.beforeOpen, this.beforeRename});

  final void Function(File)? beforeWrite;
  final void Function(File)? beforeOpen;
  final void Function(File)? beforeRename;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.contains('${p.separator}.settings.toml.')
        ? _StagedFile(file, this)
        : file;
  }
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
