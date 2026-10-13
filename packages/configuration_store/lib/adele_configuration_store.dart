import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:path/path.dart' as p;

import 'src/linux_directory.dart';

/// Internal host configuration persistence, not a plugin storage service.
///
/// Use one owning isolate per process for all configuration operations. The
/// synchronous file operations cannot interleave within that isolate; Dart's Unix
/// file locks coordinate processes, NOT isolates within the same process.
/// All cooperating writers must use the same local-state root and must never
/// remove or replace the stable lock file while writers may be running.
final class ConfigurationStore {
  ConfigurationStore(PlatformStorageRoots roots)
    : filePath = p.join(roots.configurationRoot, 'settings.toml'),
      lockPath = p.join(roots.localStateRoot, 'configuration', 'settings.lock'),
      _configurationRoot = roots.configurationRoot,
      _collectionPath = null;

  ConfigurationStore._record(
    this._configurationRoot,
    this.lockPath,
    String collectionId,
    String recordId,
  ) : _collectionPath = p.join(_configurationRoot, collectionId),
      filePath = p.join(_configurationRoot, collectionId, '$recordId.toml');

  static const maxRecordBytes = 1024 * 1024;
  static const maxCollectionEntries = 1024;

  final String filePath;
  final String lockPath;
  final String _configurationRoot;
  final String? _collectionPath;

  /// Derives an independently baselined file, sharing this store's stable lock.
  /// IDs are lowercase ASCII hyphen-separated segments, at most 64 characters;
  /// reserved device names are rejected. No filesystem access occurs here.
  ConfigurationStore recordFile({
    required String collectionId,
    required String recordId,
  }) {
    _validateSegment(collectionId);
    _validateSegment(recordId);
    return ConfigurationStore._record(
      _configurationRoot,
      lockPath,
      collectionId,
      recordId,
    );
  }

  /// Lists immediate names and non-followed types without reading their content.
  ///
  /// Absence returns an empty list without artifacts. Enumeration is bounded
  /// without an eager `listSync`. Linux scans wait behind an existing writer's
  /// lock so private staging cannot affect public entries or their allowance.
  /// Errors apply to the whole listing; no partial result is returned. Names are
  /// not filtered: the caller owns record declarations and filename diagnostics.
  /// A bounded configuration-root preflight also rejects collection path aliases.
  Future<List<ConfigurationCollectionEntry>> listCollection(
    String collectionId,
  ) async {
    _validateSegment(collectionId);
    if (Platform.isLinux) {
      final locked = _listCollectionLocked(collectionId);
      if (locked != null) return locked;
      // Readers must not create the lock. If a first writer starts during an
      // unlocked scan, redo it under that now-existing lock, even on scan error.
      final List<ConfigurationCollectionEntry> entries;
      try {
        entries = _listCollectionSync(collectionId);
      } on Exception {
        final locked = _listCollectionLocked(collectionId);
        if (locked != null) return locked;
        rethrow;
      }
      return _listCollectionLocked(collectionId) ?? entries;
    }
    final path = p.join(_configurationRoot, collectionId);
    _checkCollectionAliases(
      collectionId,
      await _listEntries(_configurationRoot),
    );
    _checkCollectionDirectory(path);
    final entries = await _listEntries(path);
    _checkCollectionDirectory(path);
    return entries;
  }

  void _checkCollectionAliases(
    String collectionId,
    List<ConfigurationCollectionEntry> entries,
  ) {
    final path = p.join(_configurationRoot, collectionId);
    for (final entry in entries) {
      if (entry.name != collectionId &&
          entry.name.replaceFirst(RegExp(r'[ .]+$'), '').toLowerCase() ==
              collectionId) {
        throw ConfigurationPathAliasException(
          path,
          p.join(_configurationRoot, entry.name),
        );
      }
    }
  }

  List<ConfigurationCollectionEntry> _listCollectionSync(String collectionId) {
    final path = p.join(_configurationRoot, collectionId);
    _checkCollectionAliases(collectionId, _listEntriesSync(_configurationRoot));
    _checkCollectionDirectory(path);
    final entries = _listEntriesSync(path);
    _checkCollectionDirectory(path);
    return entries;
  }

  List<ConfigurationCollectionEntry>? _listCollectionLocked(
    String collectionId,
  ) {
    RandomAccessFile handle;
    try {
      handle = File(lockPath).openSync();
    } on FileSystemException catch (error) {
      if (_isMissing(error, lockPath)) return null;
      // A first writer may have created the stable file after our failed open.
      if (error.osError?.errorCode != 2 ||
          FileSystemEntity.typeSync(lockPath, followLinks: false) !=
              FileSystemEntityType.file) {
        rethrow;
      }
      handle = File(lockPath).openSync();
    }
    try {
      handle.lockSync(FileLock.blockingShared);
      try {
        return _listCollectionSync(collectionId);
      } finally {
        handle.unlockSync();
      }
    } finally {
      handle.closeSync();
    }
  }

  static List<ConfigurationCollectionEntry> _listEntriesSync(String path) {
    final entries = <ConfigurationCollectionEntry>[];
    try {
      for (final name in linuxDirectoryNames(path, maxCollectionEntries)) {
        if (entries.length == maxCollectionEntries) {
          throw ConfigurationLimitException(
            path,
            maxCollectionEntries,
            'entries',
          );
        }
        entries.add(
          ConfigurationCollectionEntry._(
            name,
            FileSystemEntity.typeSync(p.join(path, name), followLinks: false),
          ),
        );
      }
    } on FileSystemException catch (error) {
      if (entries.isNotEmpty || !_isMissing(error, path)) rethrow;
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(entries);
  }

  static Future<List<ConfigurationCollectionEntry>> _listEntries(
    String path,
  ) async {
    final entries = <ConfigurationCollectionEntry>[];
    try {
      await for (final entity in Directory(path).list(followLinks: false)) {
        if (entries.length == maxCollectionEntries) {
          throw ConfigurationLimitException(
            path,
            maxCollectionEntries,
            'entries',
          );
        }
        entries.add(
          ConfigurationCollectionEntry._(
            p.basename(entity.path),
            FileSystemEntity.typeSync(entity.path, followLinks: false),
          ),
        );
      }
    } on FileSystemException catch (error) {
      if (entries.isNotEmpty || !_isMissing(error, path)) rethrow;
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(entries);
  }

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
  /// a symlinked configuration root works, but record collection symlinks do not.
  /// Mode bits are preserved (new files use 0600); ownership, ACLs and extended
  /// attributes are not copied.
  /// There is no directory fsync or unconditional power-loss durability promise.
  ConfigurationSnapshot save(
    ConfigurationSnapshot expected,
    TomlDocument document,
  ) => _save(expected, document);

  /// Creates a record only if absent, without parsing existing destination bytes.
  /// Even an empty document is materialized; an existing empty file conflicts.
  ConfigurationSnapshot create(TomlDocument document) {
    _requireRecord();
    return _save(_absent(), document, create: true);
  }

  /// Deletes a record only if its existence and exact bytes match [expected].
  /// An absent baseline is a checked no-op without creating a lock. Changed
  /// deletes require Linux and hold the same lock as settings and record saves.
  ConfigurationSnapshot delete(ConfigurationSnapshot expected) {
    _requireRecord();
    _checkSnapshotPath(expected);
    if (!expected.exists) {
      _checkBaseline(expected);
      return expected;
    }
    _requireLinux();
    _checkRecordPath();
    return _withLock(() {
      _checkBaseline(expected);
      _checkRecordPath();
      File(filePath).deleteSync();
      return _absent();
    });
  }

  ConfigurationSnapshot _save(
    ConfigurationSnapshot expected,
    TomlDocument document, {
    bool create = false,
  }) {
    _checkSnapshotPath(expected);
    if (!create && document.source == expected.document.source) {
      _checkBaseline(expected);
      return expected;
    }
    _requireLinux();
    _checkRecordPath();
    _rejectFileSymlink();
    _checkSize(document.source.length);
    final bytes = utf8.encode(document.source);
    _checkSize(bytes.length);
    return _withLock(() {
      _rejectFileSymlink();
      _checkBaseline(expected);
      if (_collectionPath != null && !expected.exists) {
        _checkCreateCapacity();
      }
      final file = File(filePath);
      file.parent.createSync(recursive: true);
      _checkRecordPath();
      // A private sibling directory keeps staged contents inaccessible until
      // their final mode has been applied, and keeps rename on one filesystem.
      final staging = file.parent.createTempSync('.${p.basename(filePath)}.');
      try {
        final temporary = File(p.join(staging.path, p.basename(filePath)));
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
    });
  }

  void _checkCreateCapacity() {
    final collection = _collectionPath!;
    final rootEntries = _listEntriesSync(_configurationRoot);
    _checkCollectionAliases(p.basename(collection), rootEntries);
    if (FileSystemEntity.typeSync(collection, followLinks: false) ==
            FileSystemEntityType.notFound &&
        rootEntries.length == maxCollectionEntries) {
      throw ConfigurationLimitException(
        _configurationRoot,
        maxCollectionEntries,
        'entries',
      );
    }
    if (_listEntriesSync(collection).length == maxCollectionEntries) {
      throw ConfigurationLimitException(
        collection,
        maxCollectionEntries,
        'entries',
      );
    }
  }

  T _withLock<T>(T Function() operation) {
    final lock = File(lockPath);
    lock.parent.createSync(recursive: true);
    final handle = lock.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.blockingExclusive);
      try {
        return operation();
      } finally {
        handle.unlockSync();
      }
    } finally {
      handle.closeSync();
    }
  }

  List<int>? _readBytes() {
    _checkRecordPath();
    final type = FileSystemEntity.typeSync(filePath, followLinks: true);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Expected a regular configuration file.',
        filePath,
      );
    }
    try {
      if (_collectionPath != null) {
        final handle = File(filePath).openSync();
        try {
          _checkSize(handle.lengthSync());
          final bytes = BytesBuilder(copy: false);
          while (true) {
            final chunk = handle.readSync(maxRecordBytes + 1 - bytes.length);
            if (chunk.isEmpty) return bytes.takeBytes();
            _checkSize(bytes.length + chunk.length);
            bytes.add(chunk);
          }
        } finally {
          handle.closeSync();
        }
      }
      return File(filePath).readAsBytesSync();
    } on FileSystemException catch (error) {
      if (_isMissing(error, filePath)) return null;
      rethrow;
    }
  }

  static bool _isMissing(FileSystemException error, String path) {
    final code = error.osError?.errorCode;
    return (code == 2 || (Platform.isWindows && code == 3)) &&
        FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.notFound;
  }

  void _checkSize(int length) {
    if (_collectionPath != null && length > maxRecordBytes) {
      throw ConfigurationLimitException(filePath, maxRecordBytes, 'bytes');
    }
  }

  void _checkSnapshotPath(ConfigurationSnapshot expected) {
    if (expected._filePath != filePath) {
      throw ArgumentError(
        'The snapshot belongs to another configuration file.',
      );
    }
  }

  ConfigurationSnapshot _absent() =>
      ConfigurationSnapshot._(filePath, TomlDocument.parse(''), null);

  void _requireRecord() {
    if (_collectionPath == null) {
      throw StateError('Create/delete require a record file.');
    }
  }

  static void _requireLinux() {
    if (!Platform.isLinux) {
      throw UnsupportedError('Configuration writes currently require Linux.');
    }
  }

  static void _validateSegment(String value) {
    if (value.length > 64 ||
        !RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value) ||
        RegExp(r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'id',
        'Unsafe configuration path segment.',
      );
    }
  }

  void _checkRecordPath() {
    final collection = _collectionPath;
    if (collection == null) return;
    _checkCollectionDirectory(collection);
    _rejectFileSymlink();
  }

  static void _checkCollectionDirectory(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw ConfigurationSymlinkException(path);
    }
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Expected a configuration collection directory.',
        path,
      );
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

/// One immediate collection entry, without following symlinks or parsing names.
final class ConfigurationCollectionEntry {
  const ConfigurationCollectionEntry._(this.name, this.type);

  final String name;
  final FileSystemEntityType type;
}

/// A noncanonical collection path would alias its canonical portable identity.
final class ConfigurationPathAliasException implements Exception {
  const ConfigurationPathAliasException(this.path, this.aliasPath);

  final String path;
  final String aliasPath;

  @override
  String toString() => 'Configuration path alias for $path: $aliasPath';
}

/// A record file or whole collection exceeds its bounded persistence surface.
final class ConfigurationLimitException implements Exception {
  const ConfigurationLimitException(this.path, this.limit, this.unit);

  final String path;
  final int limit;
  final String unit;

  @override
  String toString() => 'Configuration exceeds $limit $unit: $path';
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

/// Settings file symlinks are read-only; record and collection symlinks are unsafe.
final class ConfigurationSymlinkException implements Exception {
  const ConfigurationSymlinkException(this.path);

  final String path;

  @override
  String toString() =>
      'Refusing unsafe access to a configuration symlink: $path';
}
