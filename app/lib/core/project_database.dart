import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

/// Private application persistence for one Project. The connection stays here.
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
          // The current pre-release v1 baseline, not product migration history.
          (Database database) => database.execute('''
            CREATE TABLE adele_product_projects (
              id TEXT PRIMARY KEY,
              source_location TEXT NOT NULL
            );
            CREATE TABLE adele_product_tasks (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              title TEXT NOT NULL,
              FOREIGN KEY (project_id) REFERENCES adele_product_projects(id)
            );
            CREATE TABLE adele_product_environments (
              id TEXT PRIMARY KEY,
              task_id TEXT NOT NULL,
              role TEXT NOT NULL,
              provider_id TEXT NOT NULL,
              provider_state_json TEXT NOT NULL,
              FOREIGN KEY (task_id) REFERENCES adele_product_tasks(id)
            );
            CREATE UNIQUE INDEX adele_product_primary_environment
              ON adele_product_environments(task_id) WHERE role = 'primary';
            CREATE TABLE adele_product_sessions (
              id TEXT PRIMARY KEY,
              task_id TEXT NOT NULL,
              strategy_id TEXT NOT NULL,
              FOREIGN KEY (task_id) REFERENCES adele_product_tasks(id)
            );
            CREATE TABLE adele_product_session_environment_authority (
              session_id TEXT PRIMARY KEY,
              environment_id TEXT NOT NULL,
              FOREIGN KEY (session_id) REFERENCES adele_product_sessions(id),
              FOREIGN KEY (environment_id) REFERENCES adele_product_environments(id)
            );
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
    _requireOpen();
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

  /// Parses a complete semantic snapshot without consulting providers or strategies.
  /// The store validates graph relationships and conflicts before publication.
  ({
    List<Task> tasks,
    List<Environment> environments,
    List<Session> sessions,
    List<(SessionId, EnvironmentId)> authorities,
  })
  loadProductGraph() {
    _requireOpen();
    return _transaction(_database, () {
      final tasks = <Task>[
        for (final row in _database.select('SELECT * FROM adele_product_tasks'))
          Task(
            id: TaskId(_text(row, 'id')),
            projectId: ProjectId(_text(row, 'project_id')),
            title: _text(row, 'title'),
          ),
      ];
      final environments = <Environment>[];
      for (final row in _database.select(
        'SELECT * FROM adele_product_environments',
      )) {
        final Object? state = jsonDecode(_text(row, 'provider_state_json'));
        if (state is! Map<String, Object?>) {
          throw const FormatException(
            'Environment provider state must be a JSON object.',
          );
        }
        environments.add(
          Environment(
            id: EnvironmentId(_text(row, 'id')),
            taskId: TaskId(_text(row, 'task_id')),
            role: EnvironmentRole.values.byName(_text(row, 'role')),
            providerId: ProviderId(_text(row, 'provider_id')),
            providerState: state,
          ),
        );
      }
      final sessions = <Session>[
        for (final row in _database.select(
          'SELECT * FROM adele_product_sessions',
        ))
          Session(
            id: SessionId(_text(row, 'id')),
            taskId: TaskId(_text(row, 'task_id')),
            strategyId: OrchestrationStrategyId(_text(row, 'strategy_id')),
          ),
      ];
      final authorities = <(SessionId, EnvironmentId)>[
        for (final row in _database.select(
          'SELECT * FROM adele_product_session_environment_authority',
        ))
          (
            SessionId(_text(row, 'session_id')),
            EnvironmentId(_text(row, 'environment_id')),
          ),
      ];
      return (
        tasks: tasks,
        environments: environments,
        sessions: sessions,
        authorities: authorities,
      );
    });
  }

  /// Task and finalized primary Environment form one durable publication unit.
  void insertTaskWithPrimaryEnvironment(Task task, Environment environment) {
    _requireOpen();
    if (environment.taskId != task.id ||
        environment.role != EnvironmentRole.primary ||
        environment.providerState == null) {
      throw StateError(
        'A durable Task requires its finalized primary Environment.',
      );
    }
    final state = jsonEncode(environment.providerState);
    _backingPath(_root, _relativePath);
    _transaction(_database, () {
      _database.execute(
        'INSERT INTO adele_product_tasks (id, project_id, title) VALUES (?, ?, ?)',
        [task.id.value, task.projectId.value, task.title],
      );
      _database.execute(
        'INSERT INTO adele_product_environments '
        '(id, task_id, role, provider_id, provider_state_json) VALUES (?, ?, ?, ?, ?)',
        [
          environment.id.value,
          environment.taskId.value,
          environment.role.name,
          environment.providerId.value,
          state,
        ],
      );
    });
  }

  /// Session identity and its same-Task Environment association commit together.
  void insertSessionWithAuthority(
    Session session,
    EnvironmentId environmentId,
  ) {
    _requireOpen();
    _backingPath(_root, _relativePath);
    _transaction(_database, () {
      final environments = _database.select(
        'SELECT task_id FROM adele_product_environments WHERE id = ?',
        [environmentId.value],
      );
      if (environments.isEmpty ||
          environments.single['task_id'] != session.taskId.value) {
        throw StateError('A durable Session requires a same-Task Environment.');
      }
      _database.execute(
        'INSERT INTO adele_product_sessions (id, task_id, strategy_id) '
        'VALUES (?, ?, ?)',
        [session.id.value, session.taskId.value, session.strategyId.value],
      );
      _database.execute(
        'INSERT INTO adele_product_session_environment_authority '
        '(session_id, environment_id) VALUES (?, ?)',
        [session.id.value, environmentId.value],
      );
    });
  }

  /// Refreshes only opaque provider state, never semantic identity/relationships.
  void updateEnvironmentState(Environment environment) {
    _requireOpen();
    if (environment.providerState == null) {
      throw StateError('A durable Environment requires provider state.');
    }
    _backingPath(_root, _relativePath);
    _transaction(_database, () {
      _database.execute(
        'UPDATE adele_product_environments SET provider_state_json = ? '
        'WHERE id = ? AND task_id = ? AND role = ? AND provider_id = ?',
        [
          jsonEncode(environment.providerState),
          environment.id.value,
          environment.taskId.value,
          environment.role.name,
          environment.providerId.value,
        ],
      );
      if (_database.updatedRows != 1) {
        throw StateError('The durable Environment identity does not match.');
      }
    });
  }

  /// The calling host service supplies the connection-owned PluginId as owner.
  void ensurePluginSchema(String ownerId, List<String> migrations) {
    _requireOpen();
    if (migrations.isEmpty) {
      throw ArgumentError('A plugin schema requires its current baseline.');
    }
    _backingPath(_root, _relativePath);
    MigrationCoordinator(_database).migrate(
      ownerId: ownerId,
      migrations: [
        for (final sql in migrations) (database) => database.execute(sql),
      ],
    );
  }

  List<RelationalRow> queryPluginRows(
    String sql,
    Map<String, Object?> parameters,
  ) {
    _requireOpen();
    validateRelationalParameters(parameters.values);
    final statement = _database.prepare(sql, checkNoTail: true);
    try {
      if (!statement.isReadOnly) {
        throw ArgumentError('Storage queries must be read-only.');
      }
      final cursor = statement.iterateWith(
        StatementParameters.named(parameters),
      );
      final rows = <RelationalRow>[];
      var bytes = 2;
      while (cursor.moveNext()) {
        if (rows.length == relationalQueryRowLimit) {
          throw StateError('Relational query exceeds its row limit.');
        }
        if (cursor.columnNames.toSet().length != cursor.columnNames.length) {
          throw const FormatException(
            'Relational query column names must be unique.',
          );
        }
        final row = RelationalRow(
          values: Map<String, Object?>.of(cursor.current),
        );
        bytes += utf8.encode(jsonEncode({'values': row.values})).length + 1;
        if (bytes > relationalQueryByteLimit) {
          throw StateError('Relational query exceeds its byte limit.');
        }
        rows.add(row);
      }
      return List<RelationalRow>.unmodifiable(rows);
    } finally {
      statement.close();
    }
  }

  void executePluginTransaction(List<RelationalStatement> statements) {
    _requireOpen();
    _backingPath(_root, _relativePath);
    _transaction(_database, () {
      for (final operation in statements) {
        final statement = _database.prepare(operation.sql, checkNoTail: true);
        try {
          statement.executeWith(
            StatementParameters.named(operation.parameters),
          );
          if (operation.expectedRows case final expected?) {
            if (_database.updatedRows != expected) {
              throw StateError(
                'Relational mutation affected an unexpected row count.',
              );
            }
          }
        } finally {
          statement.close();
        }
      }
    });
  }

  void _requireOpen() {
    if (_closed) throw StateError('The Project database is closed.');
  }

  void close() {
    if (_closed) return;
    _database.close();
    _closed = true;
  }
}

String _text(Row row, String column) {
  final value = row[column];
  if (value is! String) throw FormatException('Invalid persisted $column.');
  return value;
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
