import 'dart:convert';
import 'dart:io';

import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:path/path.dart' as p;

/// Internal host persistence for `settings.toml`, not a plugin storage service.
///
/// Use one owning isolate per process for all configuration operations. These
/// synchronous operations cannot interleave within that isolate; Dart's Unix
/// file locks coordinate processes, NOT isolates within the same process.
/// All cooperating writers must use the same local-state root and must never
/// remove or replace the stable lock file while writers may be running.
final class ConfigurationStore {
  ConfigurationStore(PlatformStorageRoots roots)
    : filePath = p.join(roots.configurationRoot, 'settings.toml'),
      lockPath = p.join(roots.localStateRoot, 'configuration', 'settings.lock');

  final String filePath;
  final String lockPath;

  /// Reads and validates without creating directories, files, or locks.
  ///
  /// Only a missing file becomes an empty document. [TomlException] retains
  /// parser diagnostics; [FormatException] indicates invalid UTF-8; filesystem
  /// failures remain [FileSystemException]. A dangling file symlink is an error.
  ConfigurationSnapshot load() {
    final bytes = _readBytes();
    return ConfigurationSnapshot._(
      filePath,
      TomlDocument.parse(bytes == null ? '' : utf8.decode(bytes)),
      bytes,
    );
  }

  /// Publishes [document] only if the file still matches [expected] byte for
  /// byte, including existence. Returns the new baseline on success.
  ///
  /// A no-op still checks for conflicts but performs no writes, including locks.
  /// Changed saves use a stable advisory lock, stage and flush on the target
  /// filesystem, recheck the baseline, then rename. External editors do not
  /// share this lock: this is not atomic compare-and-swap against them.
  ///
  /// Writes currently require Linux and `chmod`. File symlinks are rejected;
  /// symlinked parent directories work normally. Mode bits are preserved (new
  /// files use 0600); ownership, ACLs and extended attributes are not copied.
  /// There is no directory fsync or unconditional power-loss durability promise.
  ConfigurationSnapshot save(
    ConfigurationSnapshot expected,
    TomlDocument document,
  ) {
    if (expected._filePath != filePath) {
      throw ArgumentError(
        'The snapshot belongs to another configuration file.',
      );
    }
    if (document.source == expected.document.source) {
      _checkBaseline(expected);
      return expected;
    }
    if (!Platform.isLinux) {
      throw UnsupportedError('Configuration writes currently require Linux.');
    }
    _rejectFileSymlink();
    final bytes = utf8.encode(document.source);
    final lock = File(lockPath);
    lock.parent.createSync(recursive: true);
    final handle = lock.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.blockingExclusive);
      try {
        _rejectFileSymlink();
        _checkBaseline(expected);
        final file = File(filePath);
        file.parent.createSync(recursive: true);
        // A private sibling directory keeps staged contents inaccessible until
        // their final mode has been applied, and keeps rename on one filesystem.
        final staging = file.parent.createTempSync('.settings.toml.');
        try {
          final temporary = File(p.join(staging.path, 'settings.toml'));
          temporary.writeAsBytesSync(bytes, flush: true);
          _checkBaseline(expected);
          final mode = expected.exists ? file.statSync().mode & 0x1ff : 0x180;
          // Open before chmod so read-only destination modes can be preserved.
          final stagedHandle = temporary.openSync(mode: FileMode.append);
          try {
            final permissions = Process.runSync('chmod', [
              mode.toRadixString(8),
              temporary.path,
            ]);
            if (permissions.exitCode != 0) {
              throw FileSystemException(
                'Could not set configuration permissions: ${permissions.stderr}',
                temporary.path,
              );
            }
            // Flush data and mode before the publication point.
            stagedHandle.flushSync();
          } finally {
            stagedHandle.closeSync();
          }
          _checkBaseline(expected);
          _rejectFileSymlink();
          temporary.renameSync(filePath);
          return ConfigurationSnapshot._(filePath, document, bytes);
        } finally {
          staging.deleteSync(recursive: true);
        }
      } finally {
        handle.unlockSync();
      }
    } finally {
      handle.closeSync();
    }
  }

  List<int>? _readBytes() {
    final type = FileSystemEntity.typeSync(filePath, followLinks: true);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Expected a regular configuration file.',
        filePath,
      );
    }
    try {
      return File(filePath).readAsBytesSync();
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if ((code == 2 || (Platform.isWindows && code == 3)) &&
          FileSystemEntity.typeSync(filePath, followLinks: false) ==
              FileSystemEntityType.notFound) {
        return null;
      }
      rethrow;
    }
  }

  void _checkBaseline(ConfigurationSnapshot expected) {
    final current = _readBytes();
    final baseline = expected._bytes;
    if (current == null || baseline == null) {
      if (current == baseline) return;
    } else if (current.length == baseline.length) {
      var equal = true;
      for (var index = 0; index < current.length; index++) {
        if (current[index] != baseline[index]) {
          equal = false;
          break;
        }
      }
      if (equal) return;
    }
    throw ConfigurationConflictException(filePath);
  }

  void _rejectFileSymlink() {
    if (FileSystemEntity.typeSync(filePath, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ConfigurationSymlinkException(filePath);
    }
  }
}

/// A validated immutable document plus its opaque, existence-aware baseline.
final class ConfigurationSnapshot {
  ConfigurationSnapshot._(this._filePath, this.document, List<int>? bytes)
    : _bytes = bytes == null ? null : List<int>.unmodifiable(bytes);

  final String _filePath;
  final List<int>? _bytes;
  final TomlDocument document;
  bool get exists => _bytes != null;
}

/// The caller must reload and deliberately retry; no automatic merging occurs.
final class ConfigurationConflictException implements Exception {
  const ConfigurationConflictException(this.path);

  final String path;

  @override
  String toString() =>
      'Configuration changed on disk; reload before saving: $path';
}

/// File-level symlinks may be read, but changed saves never replace them.
final class ConfigurationSymlinkException implements Exception {
  const ConfigurationSymlinkException(this.path);

  final String path;

  @override
  String toString() =>
      'Refusing to replace a configuration file symlink: $path';
}
