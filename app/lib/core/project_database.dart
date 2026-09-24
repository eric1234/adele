import 'dart:io';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_product/adele_product.dart';
import 'package:sqlite3/sqlite3.dart';

/// Private application persistence for one Project, not a plugin storage API.
final class ProjectDatabase {
  ProjectDatabase._(this._database, this.path, this._root, this._relativePath);

  final Database _database;
  final String path;
  final String _root;
  final String _relativePath;
  bool _closed = false;

  /// Validates the selected backing and initializes its core-owned schema.
  static ProjectDatabase open(ProjectBacking backing) {
    final String root = _sourceDirectory(
      backing.sourceLocation,
    ).resolveSymbolicLinksSync();
    final String path = _backingPath(root, backing.databaseRelativePath);
    final Database database = sqlite3.open(path);
    try {
      database.execute('PRAGMA foreign_keys = ON');
      MigrationCoordinator(database).migrate(
        ownerId: 'dev.adele.product',
        migrations: <void Function(Database)>[
          (Database database) => database.execute('''
            CREATE TABLE adele_product_projects (
              id TEXT PRIMARY KEY,
              source_location TEXT NOT NULL
            )
          '''),
        ],
      );
      return ProjectDatabase._(
        database,
        path,
        root,
        backing.databaseRelativePath,
      );
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  /// Loads or creates the identity, committing any source refresh before return.
  Project openProject({
    required Uri sourceLocation,
    required ProjectId Function() nextProjectId,
  }) {
    if (_closed) throw StateError('The Project database is closed.');
    if (_sourceDirectory(sourceLocation).resolveSymbolicLinksSync() != _root) {
      throw ArgumentError.value(
        sourceLocation,
        'sourceLocation',
        'The selected source must contain this Project database.',
      );
    }
    _backingPath(_root, _relativePath);
    return _transaction(_database, () {
      final ResultSet rows = _database.select(
        'SELECT id, source_location FROM adele_product_projects LIMIT 2',
      );
      if (rows.length > 1) {
        throw StateError('A Project database contains multiple Projects.');
      }
      final ProjectId id;
      if (rows.isEmpty) {
        id = nextProjectId();
        _database.execute(
          'INSERT INTO adele_product_projects (id, source_location) '
          'VALUES (?, ?)',
          <Object?>[id.value, sourceLocation.toString()],
        );
      } else {
        final Object? storedId = rows.single['id'];
        final Object? storedSource = rows.single['source_location'];
        if (storedId is! String || storedSource is! String) {
          throw const FormatException('Invalid persisted Project fields.');
        }
        id = ProjectId(storedId);
        final Uri persistedSource = Uri.parse(storedSource);
        if (persistedSource.toString() != storedSource) {
          throw const FormatException('Invalid persisted Project source URI.');
        }
        // A previous location may no longer exist or use this host's path syntax.
        _validateSourceUri(persistedSource);
        if (storedSource != sourceLocation.toString()) {
          _database.execute(
            'UPDATE adele_product_projects SET source_location = ? WHERE id = ?',
            <Object?>[sourceLocation.toString(), id.value],
          );
        }
      }
      return Project(id: id, sourceLocation: sourceLocation);
    });
  }

  void close() {
    if (_closed) return;
    _database.close();
    _closed = true;
  }
}

/// App-internal schema coordination. Callbacks and connections never reach plugins.
/// Each list entry upgrades its owner's schema by one version, starting at one.
final class MigrationCoordinator {
  MigrationCoordinator(this._database);

  final Database _database;

  void migrate({
    required String ownerId,
    required List<void Function(Database)> migrations,
  }) {
    _transaction(_database, () {
      _database.execute('''
        CREATE TABLE IF NOT EXISTS adele_schema_versions (
          owner_id TEXT PRIMARY KEY,
          version INTEGER NOT NULL
        )
      ''');
      final ResultSet rows = _database.select(
        'SELECT version FROM adele_schema_versions WHERE owner_id = ?',
        <Object?>[ownerId],
      );
      final Object? storedVersion = rows.isEmpty ? 0 : rows.single['version'];
      if (storedVersion is! int || storedVersion < 0) {
        throw FormatException('Invalid schema version for $ownerId.');
      }
      if (storedVersion > migrations.length) {
        throw StateError(
          'The $ownerId schema is newer than this host supports.',
        );
      }
      for (
        int version = storedVersion;
        version < migrations.length;
        version++
      ) {
        migrations[version](_database);
        _database.execute(
          'INSERT INTO adele_schema_versions (owner_id, version) VALUES (?, ?) '
          'ON CONFLICT (owner_id) DO UPDATE SET version = excluded.version',
          <Object?>[ownerId, version + 1],
        );
      }
    });
  }
}

T _transaction<T>(Database database, T Function() operation) {
  database.execute('BEGIN IMMEDIATE');
  try {
    final T result = operation();
    database.execute('COMMIT');
    return result;
  } catch (_) {
    if (!database.autocommit) database.execute('ROLLBACK');
    rethrow;
  }
}

void _validateSourceUri(Uri source) {
  if (source.scheme != 'file' ||
      source.authority.isNotEmpty ||
      source.hasQuery ||
      source.hasFragment ||
      !source.path.startsWith('/') ||
      source.path.startsWith('//') ||
      source.pathSegments.any(
        (String segment) => segment.contains(RegExp(r'[\x00-\x1f\x7f\\/]')),
      )) {
    throw ArgumentError.value(
      source,
      'sourceLocation',
      'A Project backing requires an absolute local file directory URI.',
    );
  }
}

Directory _sourceDirectory(Uri source) {
  _validateSourceUri(source);
  if (!Platform.isWindows && RegExp(r'^/[a-zA-Z]:').hasMatch(source.path)) {
    throw ArgumentError.value(
      source,
      'sourceLocation',
      'Not a local host path.',
    );
  }
  final Directory directory = Directory.fromUri(source);
  if (!directory.isAbsolute) {
    throw ArgumentError.value(
      source,
      'sourceLocation',
      'Not an absolute path.',
    );
  }
  if (!directory.existsSync()) {
    throw FileSystemException(
      'Project source directory does not exist.',
      directory.path,
    );
  }
  return directory;
}

String _backingPath(String root, String relativePath) {
  final List<String> segments = relativePath.split('/');
  if (segments.any(
    (String segment) =>
        segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        segment.contains(RegExp(r'[\\:%?#<>"|*\x00-\x1f\x7f]')) ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(segment),
  )) {
    throw ArgumentError.value(
      relativePath,
      'databaseRelativePath',
      'Expected a confined relative forward-slash file path, not a URI.',
    );
  }

  // Resolve the source once, then reject links in every backing component and
  // SQLite sidecar. This is preflight confinement, not hostile filesystem-race safety.
  String parent = root;
  for (final String segment in segments.take(segments.length - 1)) {
    final Directory directory = Directory.fromUri(
      Directory(parent).uri.resolveUri(Uri(pathSegments: <String>[segment])),
    );
    _requireEntity(directory.path, FileSystemEntityType.directory);
    if (!directory.existsSync()) directory.createSync();
    _requireEntity(directory.path, FileSystemEntityType.directory);
    parent = directory.path;
    if (directory.resolveSymbolicLinksSync() != parent) {
      throw FileSystemException(
        'Project backing parent resolves through a link.',
        parent,
      );
    }
  }
  final String path = File.fromUri(
    Directory(
      parent,
    ).uri.resolveUri(Uri(pathSegments: <String>[segments.last])),
  ).path;
  for (final String suffix in <String>['', '-journal', '-wal', '-shm']) {
    _requireEntity('$path$suffix', FileSystemEntityType.file);
  }
  return path;
}

void _requireEntity(String path, FileSystemEntityType expected) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(
    path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.notFound && type != expected) {
    throw FileSystemException(
      'Project backing rejects links and non-$expected entries.',
      path,
    );
  }
}
