import 'dart:io';
import 'dart:typed_data';

import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/project_database.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temporary;
  late Directory source;
  late ProjectBacking backing;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('adele-project-db-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    source = Directory.fromUri(temporary.uri.resolve('source/'))..createSync();
    backing = ProjectBacking(
      sourceLocation: source.uri,
      databaseRelativePath: 'custom/state/project.sqlite',
    );
  });

  test('initializes only metadata and Project v1 in ordinary SQLite', () {
    final ProjectDatabase database = _open(backing);
    expect(
      database.path,
      File.fromUri(
        Directory(
          source.resolveSymbolicLinksSync(),
        ).uri.resolve('custom/state/project.sqlite'),
      ).path,
    );
    final Database inspection = _connect(database.path);
    expect(
      inspection
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((Row row) => row['name']),
      unorderedEquals(<String>[
        'adele_schema_versions',
        'adele_product_projects',
      ]),
    );
    expect(inspection.select('SELECT * FROM adele_schema_versions'), <Object?>[
      <String, Object?>{'owner_id': 'dev.adele.product', 'version': 1},
    ]);
    expect(
      inspection
          .select('PRAGMA table_info(adele_product_projects)')
          .map((Row row) => row['name']),
      <String>['id', 'source_location'],
    );
    expect(inspection.select('SELECT * FROM adele_product_projects'), isEmpty);
    expect(
      File(database.path).readAsBytesSync().take(16),
      'SQLite format 3\x00'.codeUnits,
    );
    expect(
      Directory.fromUri(source.uri.resolve('.adele/')).existsSync(),
      isFalse,
    );
  });

  test(
    'allocates once and commits before return, then reopens the identity',
    () {
      int allocations = 0;
      ProjectId nextId() => ProjectId('project-${++allocations}');
      final ProjectDatabase database = _open(backing);
      final Project first = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: nextId,
      );
      final Database inspection = _connect(database.path);
      expect(
        inspection.select('SELECT * FROM adele_product_projects'),
        <Object?>[
          <String, Object?>{
            'id': first.id.value,
            'source_location': source.uri.toString(),
          },
        ],
      );
      expect(
        database
            .openProject(sourceLocation: source.uri, nextProjectId: nextId)
            .id,
        first.id,
      );
      database.close();
      final Project second = _open(
        backing,
      ).openProject(sourceLocation: source.uri, nextProjectId: nextId);
      expect(second.id, first.id);
      expect(second.sourceLocation, source.uri);
      expect(allocations, 1);
    },
  );

  test('moved backing keeps identity and commits the newly selected URI', () {
    final ProjectDatabase original = _open(backing);
    final Project first = original.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('stable-project'),
    );
    original.close();
    final Directory moved = source.renameSync(
      Directory.fromUri(temporary.uri.resolve('moved/')).path,
    );
    final ProjectDatabase reopened = _open(
      ProjectBacking(
        sourceLocation: moved.uri,
        databaseRelativePath: backing.databaseRelativePath,
      ),
    );
    final Project restored = reopened.openProject(
      sourceLocation: moved.uri,
      nextProjectId: _unexpectedAllocation,
    );
    expect(restored.id, first.id);
    expect(restored.sourceLocation, moved.uri);
    expect(
      _connect(reopened.path)
          .select('SELECT source_location FROM adele_product_projects')
          .single['source_location'],
      moved.uri.toString(),
    );
  });

  test('unchanged source does not execute an update', () {
    final ProjectDatabase database = _open(backing);
    database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('p'),
    );
    _connect(database.path).execute('''
      CREATE TRIGGER reject_refresh BEFORE UPDATE ON adele_product_projects
      BEGIN SELECT RAISE(ABORT, 'unexpected refresh'); END;
    ''');
    expect(
      database
          .openProject(
            sourceLocation: source.uri,
            nextProjectId: _unexpectedAllocation,
          )
          .id,
      ProjectId('p'),
    );
  });

  for (final historicalSource in [
    'file:///C:/work/project/',
    'file:///home/user/project/',
  ]) {
    test(
      'historical source can use another platform path: $historicalSource',
      () {
        final database = _open(backing);
        final inspection = _connect(database.path);
        inspection.execute('INSERT INTO adele_product_projects VALUES (?, ?)', [
          'moved-project',
          historicalSource,
        ]);
        final project = database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        );
        expect(project.id, ProjectId('moved-project'));
        expect(project.sourceLocation, source.uri);
        expect(
          inspection
              .select('SELECT source_location FROM adele_product_projects')
              .single['source_location'],
          source.uri.toString(),
        );
      },
    );
  }

  test('separate backings do not share a Project', () {
    final Project first = _open(backing).openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('first'),
    );
    final Project second =
        _open(
          ProjectBacking(
            sourceLocation: source.uri,
            databaseRelativePath: 'other.sqlite',
          ),
        ).openProject(
          sourceLocation: source.uri,
          nextProjectId: () => ProjectId('second'),
        );
    expect(first.id, isNot(second.id));
  });

  test('close is idempotent and subsequent operations fail', () {
    final ProjectDatabase database = _open(backing);
    database.close();
    database.close();
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsStateError,
    );
    _open(backing);
  });

  test('schema initialization preserves unknown owners and their data', () {
    final String path = File.fromUri(source.uri.resolve('shared.sqlite')).path;
    final Database inspection = _connect(path);
    inspection.execute('''
      CREATE TABLE adele_schema_versions (owner_id TEXT PRIMARY KEY, version INTEGER NOT NULL);
      INSERT INTO adele_schema_versions VALUES ('unknown.owner', 900);
      CREATE TABLE unknown_data (value TEXT);
      INSERT INTO unknown_data VALUES ('untouched');
    ''');
    final ProjectBacking shared = ProjectBacking(
      sourceLocation: source.uri,
      databaseRelativePath: 'shared.sqlite',
    );
    _open(shared).close();
    _open(shared).close();
    expect(
      inspection.select(
        'SELECT * FROM adele_schema_versions ORDER BY owner_id',
      ),
      <Object?>[
        <String, Object?>{'owner_id': 'dev.adele.product', 'version': 1},
        <String, Object?>{'owner_id': 'unknown.owner', 'version': 900},
      ],
    );
    expect(
      inspection.select('SELECT value FROM unknown_data').single['value'],
      'untouched',
    );
  });

  test('future core schema is rejected without changing existing bytes', () {
    final ProjectDatabase database = _open(backing);
    database.openProject(
      sourceLocation: source.uri,
      nextProjectId: () => ProjectId('p'),
    );
    database.close();
    final Database inspection = _connect(database.path);
    inspection.execute(
      "UPDATE adele_schema_versions SET version = 2 WHERE owner_id = 'dev.adele.product'",
    );
    inspection.close();
    final List<int> before = File(database.path).readAsBytesSync();
    expect(() => ProjectDatabase.open(backing), throwsStateError);
    expect(File(database.path).readAsBytesSync(), before);
  });

  test('schema conflicts do not leave migration metadata behind', () {
    final String path = File.fromUri(
      source.uri.resolve('conflict.sqlite'),
    ).path;
    final Database inspection = _connect(path);
    inspection.execute('CREATE TABLE adele_product_projects (untouched TEXT)');
    expect(
      () => ProjectDatabase.open(
        ProjectBacking(
          sourceLocation: source.uri,
          databaseRelativePath: 'conflict.sqlite',
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      inspection
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((Row row) => row['name']),
      <String>['adele_product_projects'],
    );
  });

  test('sequential migrations roll back schema, data, and owner versions', () {
    final Database database = _connect(
      File.fromUri(source.uri.resolve('migration.sqlite')).path,
    );
    final MigrationCoordinator coordinator = MigrationCoordinator(database);
    final List<void Function(Database)> migrations = <void Function(Database)>[
      (Database db) => db.execute('CREATE TABLE synthetic (value TEXT)'),
      (Database db) {
        db.execute("INSERT INTO synthetic VALUES ('not committed')");
        throw StateError('synthetic migration failure');
      },
    ];
    expect(
      () => coordinator.migrate(ownerId: 'test.owner', migrations: migrations),
      throwsStateError,
    );
    expect(database.autocommit, isTrue);
    expect(
      database.select("SELECT name FROM sqlite_master WHERE type = 'table'"),
      isEmpty,
    );

    migrations[1] = (Database db) =>
        db.execute("INSERT INTO synthetic VALUES ('committed')");
    coordinator.migrate(ownerId: 'test.owner', migrations: migrations);
    expect(
      database
          .select('SELECT version FROM adele_schema_versions')
          .single['version'],
      2,
    );
    expect(
      database.select('SELECT value FROM synthetic').single['value'],
      'committed',
    );
    coordinator.migrate(ownerId: 'test.owner', migrations: migrations);
    expect(database.select('SELECT * FROM synthetic'), hasLength(1));

    migrations.add((Database db) {
      db.execute('ALTER TABLE synthetic ADD COLUMN rolled_back TEXT');
      db.execute("UPDATE synthetic SET value = 'changed'");
      throw StateError('upgrade failure');
    });
    expect(
      () => coordinator.migrate(ownerId: 'test.owner', migrations: migrations),
      throwsStateError,
    );
    expect(
      database
          .select('SELECT version FROM adele_schema_versions')
          .single['version'],
      2,
    );
    expect(
      database.select('SELECT value FROM synthetic').single['value'],
      'committed',
    );
    expect(database.select('PRAGMA table_info(synthetic)'), hasLength(1));
  });

  for (final Object? invalidVersion in <Object?>[-1, 'invalid', 1.5]) {
    test('rejects malformed owner version $invalidVersion', () {
      final ProjectDatabase database = _open(backing)..close();
      final Database inspection = _connect(database.path);
      inspection.execute(
        'UPDATE adele_schema_versions SET version = ?',
        <Object?>[invalidVersion],
      );
      expect(() => ProjectDatabase.open(backing), throwsFormatException);
      expect(
        inspection
            .select('SELECT version FROM adele_schema_versions')
            .single['version'],
        invalidVersion,
      );
    });
  }

  for (final Object? invalidId in <Object?>[
    '',
    ' leading',
    'trailing ',
    null,
    Uint8List.fromList(<int>[1, 2]),
  ]) {
    test('rejects malformed persisted Project ID $invalidId', () {
      final ProjectDatabase database = _open(backing);
      final Database inspection = _connect(database.path);
      inspection.execute(
        'INSERT INTO adele_product_projects VALUES (?, ?)',
        <Object?>[invalidId, source.uri.toString()],
      );
      expect(
        () => database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        ),
        throwsFormatException,
      );
      expect(
        inspection.select('SELECT * FROM adele_product_projects'),
        hasLength(1),
      );
    });
  }

  for (final String invalidSource in <String>[
    '',
    'relative/path',
    'https://example.com/source/',
    'file://remote/source/',
    'file:////server/share/source/',
    'file:///source/?query',
    'file:///source/#fragment',
    'file:///source/%00',
    'file:///source/%2Fescape',
    'file:///source/%5Cescape',
    'file:///invalid%escape',
    ' file:///source/',
  ]) {
    test('rejects persisted source $invalidSource instead of repairing it', () {
      final ProjectDatabase database = _open(backing);
      final Database inspection = _connect(database.path);
      inspection.execute(
        'INSERT INTO adele_product_projects VALUES (?, ?)',
        <Object?>['p', invalidSource],
      );
      expect(
        () => database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        ),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
      expect(
        inspection
            .select('SELECT source_location FROM adele_product_projects')
            .single['source_location'],
        invalidSource,
      );
    });
  }

  test('rejects multiple Projects without allocating or modifying data', () {
    final ProjectDatabase database = _open(backing);
    final Database inspection = _connect(database.path);
    for (final String id in <String>['first', 'second']) {
      inspection.execute(
        'INSERT INTO adele_product_projects VALUES (?, ?)',
        <Object?>[id, source.uri.toString()],
      );
    }
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsStateError,
    );
    expect(
      inspection.select('SELECT * FROM adele_product_projects'),
      hasLength(2),
    );
  });

  test('failed allocation rolls back and allows a later attempt', () {
    final ProjectDatabase database = _open(backing);
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => throw StateError('allocation failure'),
      ),
      throwsStateError,
    );
    expect(
      _connect(database.path).select('SELECT * FROM adele_product_projects'),
      isEmpty,
    );
    expect(
      database
          .openProject(
            sourceLocation: source.uri,
            nextProjectId: () => ProjectId('retry'),
          )
          .id,
      ProjectId('retry'),
    );
  });

  test('foreign keys are enabled and failed commit returns no Project', () {
    final ProjectDatabase database = _open(backing);
    final Database inspection = _connect(database.path);
    inspection.execute('''
      CREATE TABLE deferred_check (
        project_id TEXT REFERENCES adele_product_projects(id) DEFERRABLE INITIALLY DEFERRED
      );
      CREATE TRIGGER fail_commit AFTER INSERT ON adele_product_projects
      BEGIN INSERT INTO deferred_check VALUES ('missing'); END;
    ''');
    Project? result;
    expect(
      () => result = database.openProject(
        sourceLocation: source.uri,
        nextProjectId: () => ProjectId('p'),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(result, isNull);
    expect(inspection.select('SELECT * FROM adele_product_projects'), isEmpty);
    expect(inspection.select('SELECT * FROM deferred_check'), isEmpty);
    inspection.execute('DROP TRIGGER fail_commit');
    expect(
      database
          .openProject(
            sourceLocation: source.uri,
            nextProjectId: () => ProjectId('retry'),
          )
          .id,
      ProjectId('retry'),
    );
  });

  test('failed source refresh rolls back instead of returning a Project', () {
    final ProjectDatabase database = _open(backing);
    final Database inspection = _connect(database.path);
    final String previousSource = temporary.uri.resolve('previous/').toString();
    inspection.execute(
      'INSERT INTO adele_product_projects VALUES (?, ?)',
      <Object?>['p', previousSource],
    );
    inspection.execute('''
      CREATE TRIGGER reject_refresh BEFORE UPDATE ON adele_product_projects
      BEGIN SELECT RAISE(ABORT, 'refresh failure'); END;
    ''');
    expect(
      () => database.openProject(
        sourceLocation: source.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(
      inspection
          .select('SELECT source_location FROM adele_product_projects')
          .single['source_location'],
      previousSource,
    );
  });

  for (final String invalidPath in <String>[
    '',
    '/',
    '/absolute.sqlite',
    '../escape.sqlite',
    'state/../../escape.sqlite',
    './db.sqlite',
    'state/./db.sqlite',
    'state//db.sqlite',
    'state/',
    r'..\escape.sqlite',
    r'state\..\escape.sqlite',
    r'C:\escape.sqlite',
    'C:/escape.sqlite',
    'C:escape.sqlite',
    '//server/share/db.sqlite',
    r'\\server\share\db.sqlite',
    r'\\?\C:\escape.sqlite',
    'file:///escape.sqlite',
    'state/%2e%2e/escape.sqlite',
    'state/%2fescape.sqlite',
    'state/%252e%252e/db.sqlite',
    'state/db.sqlite?mode=ro',
    'state/db.sqlite#part',
    'state/db.sqlite:stream',
    'state/.. /escape.sqlite',
    'state/.../escape.sqlite',
    'state/db.sqlite.',
    'state/db.sqlite ',
    'state/\x00db.sqlite',
    'NUL',
    'CON.sqlite',
  ]) {
    test('rejects non-confined or nonportable placement $invalidPath', () {
      expect(
        () => ProjectDatabase.open(
          ProjectBacking(
            sourceLocation: source.uri,
            databaseRelativePath: invalidPath,
          ),
        ),
        throwsArgumentError,
      );
      expect(source.listSync(), isEmpty);
    });
  }

  test('supports spaces and a source URI without a trailing slash', () {
    final Directory spaced = Directory.fromUri(
      temporary.uri.resolve('source%20space/'),
    )..createSync();
    final Uri selected = Uri.file(spaced.path);
    final ProjectDatabase database = _open(
      ProjectBacking(
        sourceLocation: selected,
        databaseRelativePath: 'state space/database.sqlite',
      ),
    );
    final Project project = database.openProject(
      sourceLocation: selected,
      nextProjectId: () => ProjectId('p'),
    );
    expect(project.sourceLocation, selected);
    expect(File(database.path).existsSync(), isTrue);
  });

  test('rejects invalid, nonexistent, and non-directory source locations', () {
    final File file = File.fromUri(temporary.uri.resolve('not-a-directory'))
      ..writeAsStringSync('unchanged');
    for (final Uri uri in <Uri>[
      Uri.parse('relative/'),
      Uri.parse('https://example.com/source/'),
      Uri.parse('file://remote/source/'),
      source.uri.replace(query: 'query'),
      source.uri.replace(fragment: 'fragment'),
      temporary.uri.resolve('missing/'),
      file.uri,
      if (!Platform.isWindows) Uri.parse('file:///C:/Windows/'),
    ]) {
      expect(
        () => ProjectDatabase.open(
          ProjectBacking(
            sourceLocation: uri,
            databaseRelativePath: 'db.sqlite',
          ),
        ),
        throwsA(anyOf(isA<ArgumentError>(), isA<FileSystemException>())),
      );
    }
    expect(file.readAsStringSync(), 'unchanged');
    expect(source.listSync(), isEmpty);
  });

  test('empty-authority UNC syntax fails before filesystem access', () {
    final uri = Uri.parse('file:////server/share/source/');
    expect(uri.authority, isEmpty);
    expect(
      () => ProjectDatabase.open(
        ProjectBacking(sourceLocation: uri, databaseRelativePath: 'db.sqlite'),
      ),
      throwsArgumentError,
    );
    expect(source.listSync(), isEmpty);
  });

  test('does not refresh to an unrelated directory', () {
    final ProjectDatabase database = _open(backing);
    expect(
      () => database.openProject(
        sourceLocation: temporary.uri,
        nextProjectId: _unexpectedAllocation,
      ),
      throwsArgumentError,
    );
    expect(
      _connect(database.path).select('SELECT * FROM adele_product_projects'),
      isEmpty,
    );
  });

  test('rejects a file in place of a parent or database directory', () {
    File.fromUri(source.uri.resolve('parent')).writeAsStringSync('unchanged');
    Directory.fromUri(source.uri.resolve('directory.sqlite/')).createSync();
    for (final String relative in <String>[
      'parent/db.sqlite',
      'directory.sqlite',
    ]) {
      expect(
        () => ProjectDatabase.open(
          ProjectBacking(
            sourceLocation: source.uri,
            databaseRelativePath: relative,
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
    }
  });

  for (final bool outside in <bool>[false, true]) {
    test(
      'rejects ${outside ? 'escaping' : 'in-root'} backing parent symlinks',
      () {
        final Directory target = Directory.fromUri(
          (outside ? temporary : source).uri.resolve('target/'),
        )..createSync();
        Link.fromUri(source.uri.resolve('link')).createSync(target.path);
        expect(
          () => ProjectDatabase.open(
            ProjectBacking(
              sourceLocation: source.uri,
              databaseRelativePath: 'link/nested/db.sqlite',
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(target.listSync(), isEmpty);
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires Windows privileges.'
          : false,
    );
  }

  for (final String suffix in <String>['', '-journal', '-wal', '-shm']) {
    test(
      'rejects database or sidecar symlink "$suffix" without writing outside',
      () {
        final File outside = File.fromUri(temporary.uri.resolve('outside'))
          ..writeAsStringSync('untouched');
        Link.fromUri(
          source.uri.resolve('db.sqlite$suffix'),
        ).createSync(outside.path);
        expect(
          () => ProjectDatabase.open(
            ProjectBacking(
              sourceLocation: source.uri,
              databaseRelativePath: 'db.sqlite',
            ),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(outside.readAsStringSync(), 'untouched');
      },
      skip: Platform.isWindows
          ? 'Symlink creation requires Windows privileges.'
          : false,
    );
  }

  test(
    'rejects dangling links and rechecks sidecars before writes',
    () {
      final ProjectDatabase database = _open(backing);
      final String missing = File.fromUri(
        temporary.uri.resolve('missing'),
      ).path;
      final Link sidecar = Link('${database.path}-wal')..createSync(missing);
      expect(
        () => database.openProject(
          sourceLocation: source.uri,
          nextProjectId: _unexpectedAllocation,
        ),
        throwsA(isA<FileSystemException>()),
      );
      database.close();
      expect(
        () => ProjectDatabase.open(backing),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(missing).existsSync(), isFalse);
      sidecar.deleteSync();
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires Windows privileges.'
        : false,
  );

  test(
    'source aliases resolve to the same physical database path',
    () {
      final Link alias = Link.fromUri(temporary.uri.resolve('alias'))
        ..createSync(source.path);
      final ProjectDatabase first = _open(backing);
      final ProjectDatabase second = _open(
        ProjectBacking(
          sourceLocation: Directory(alias.path).uri,
          databaseRelativePath: backing.databaseRelativePath,
        ),
      );
      expect(second.path, first.path);
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires Windows privileges.'
        : false,
  );
}

ProjectDatabase _open(ProjectBacking backing) {
  final ProjectDatabase database = ProjectDatabase.open(backing);
  addTearDown(database.close);
  return database;
}

Database _connect(String path) {
  final Database database = sqlite3.open(path);
  addTearDown(database.close);
  return database;
}

ProjectId _unexpectedAllocation() =>
    throw TestFailure('Unexpected Project ID allocation.');
