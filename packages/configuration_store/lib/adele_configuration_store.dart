import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:path/path.dart' as p;

import 'src/linux_directory.dart';

typedef _CollectionListing = ({
  List<ConfigurationCollectionEntry> entries,
  int rootEntryCount,
});

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
    String fileName,
  ) : _collectionPath = p.join(_configurationRoot, collectionId),
      filePath = p.join(_configurationRoot, collectionId, fileName);

  static const maxRecordBytes = 1024 * 1024;
  static const maxCollectionEntries = 1024;

  final String filePath;
  final String lockPath;
  final String _configurationRoot;
  final String? _collectionPath;

  /// Derives an independently baselined file, sharing this store's stable lock.
  /// The collection and filename stem must be portable lowercase segments;
  /// the complete filename must end in `.toml`. No filesystem access occurs.
  ConfigurationStore recordFile({
    required String collectionId,
    required String fileName,
  }) {
    _validateSegment(collectionId);
    if (!isRecordFileName(fileName)) {
      throw ArgumentError.value(
        fileName,
        'fileName',
        'Unsafe record filename.',
      );
    }
    return ConfigurationStore._record(
      _configurationRoot,
      lockPath,
      collectionId,
      fileName,
    );
  }

  /// Whether an observed basename can be addressed as a record file. This
  /// tests only the storage grammar, not the identity of the document inside.
  static bool isRecordFileName(String name) =>
      name.endsWith('.toml') && _isSegment(name.substring(0, name.length - 5));

  /// Comparison key for an observed basename, not a filename to open.
  static String recordFileNameAlias(String name) =>
      name.toLowerCase().replaceFirst(RegExp(r'[ .]+$'), '');

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
        entries = _listCollectionSync(collectionId).entries;
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
          recordFileNameAlias(entry.name) == collectionId) {
        throw ConfigurationPathAliasException(
          path,
          p.join(_configurationRoot, entry.name),
        );
      }
    }
  }

  _CollectionListing _listCollectionSync(String collectionId) {
    final path = p.join(_configurationRoot, collectionId);
    final rootEntries = _listEntriesSync(_configurationRoot);
    _checkCollectionAliases(collectionId, rootEntries);
    _checkCollectionDirectory(path);
    final entries = _listEntriesSync(path);
    _checkCollectionDirectory(path);
    return (entries: entries, rootEntryCount: rootEntries.length);
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
        return _listCollectionSync(collectionId).entries;
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
  ) {
    _checkSnapshotPath(expected);
    if (document.source == expected.document.source) {
      _checkBaseline(expected);
      return expected;
    }
    _requireLinux();
    _checkRecordPath();
    _rejectFileSymlink();
    return _publish(expected, document, _encode(document));
  }

  /// Creates a record only if absent, without parsing existing destination bytes.
  /// Even an empty document is materialized; an existing empty file conflicts.
  ConfigurationSnapshot create(TomlDocument document) =>
      prepareCreate(document)();

  /// Prepares a bounded record write without touching storage. Invoking the
  /// result checks the live collection and destination and conditionally inserts.
  /// [collectionAllowsCreate] runs synchronously inside that write's exclusive
  /// lock, on the same bounded listing used for capacity. It may load records
  /// but must not re-open the lock (e.g. via [listCollection] or a mutation).
  ConfigurationSnapshot Function() prepareCreate(
    TomlDocument document, {
    bool Function(List<ConfigurationCollectionEntry>)? collectionAllowsCreate,
  }) {
    _requireRecord();
    _requireLinux();
    final bytes = _encode(document);
    final absent = _absent();
    return () {
      _checkRecordPath();
      return _publish(absent, document, bytes, collectionAllowsCreate);
    };
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

  Uint8List _encode(TomlDocument document) {
    _checkSize(document.source.length);
    final bytes = utf8.encode(document.source);
    _checkSize(bytes.length);
    return bytes;
  }

  ConfigurationSnapshot _publish(
    ConfigurationSnapshot expected,
    TomlDocument document,
    Uint8List bytes, [
    bool Function(List<ConfigurationCollectionEntry>)? collectionAllowsCreate,
  ]) {
    return _withLock(() {
      _rejectFileSymlink();
      _CollectionListing? listing;
      if (collectionAllowsCreate != null) {
        listing = _listCollectionSync(p.basename(_collectionPath!));
        if (!collectionAllowsCreate(listing.entries)) {
          throw ConfigurationConflictException(filePath);
        }
      }
      _checkBaseline(expected);
      if (_collectionPath != null && !expected.exists) {
        _checkCreateCapacity(
          listing ?? _listCollectionSync(p.basename(_collectionPath)),
        );
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

  void _checkCreateCapacity(_CollectionListing listing) {
    final collection = _collectionPath!;
    if (FileSystemEntity.typeSync(collection, followLinks: false) ==
            FileSystemEntityType.notFound &&
        listing.rootEntryCount == maxCollectionEntries) {
      throw ConfigurationLimitException(
        _configurationRoot,
        maxCollectionEntries,
        'entries',
      );
    }
    if (listing.entries.length == maxCollectionEntries) {
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

  static bool _isSegment(String value) =>
      value.length <= 64 &&
      RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value) &&
      !RegExp(r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(value);

  static void _validateSegment(String value) {
    if (!_isSegment(value)) {
      throw ArgumentError.value(
        value,
        'collectionId',
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
