import 'dart:convert';
import 'dart:io';
import 'dart:ui' show IsolateNameServer;

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_backend_support/adele_backend_records.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _owner = 'dev.example.records';
const _firstType = '$_owner.first';
const _lastType = '$_owner.last';
const _archiveType = '$_owner.archive';
const _nestedOwner = '$_owner.nested';
const _reference = 'cred1_0123456789abcdef0123456789abcdef';
final _jobs = RecordCollectionId('jobs');

void main() {
  late Directory temporary;
  late Directory installations;
  late PlatformStorageRoots roots;
  late PreparedPluginCatalog catalog;
  late PreparedPluginInstallation installation;
  late GlobalSettingsService service;
  late _NoCredentialStorage storage;
  final enabled = SettingId('dev.example.scalar.enabled');
  final scalars = SettingsCatalog([
    SettingDefinition(
      id: enabled,
      owner: SettingOwnerId('dev.example.scalar'),
      label: 'Enabled',
      category: 'General',
      section: 'Test',
      type: const BooleanSettingType(),
      defaultValue: false,
    ),
  ]);

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('adele-startup-records-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    installations = Directory('${temporary.path}/installed');
    _publish(
      installations,
      _owner,
      {
        _firstType: 'jobs',
        _lastType: 'jobs',
        _archiveType: 'archive',
        '$_owner.hidden': 'jobs',
        '$_owner.unscanned': 'unscanned',
      },
      [_lastType, _firstType, _archiveType],
    );
    _publish(
      installations,
      _nestedOwner,
      {'$_nestedOwner.account': 'jobs'},
      ['$_nestedOwner.account'],
    );
    _publish(
      installations,
      'dev.other.records',
      {'dev.other.records.account': 'jobs'},
      ['dev.other.records.account'],
    );
    _publish(installations, 'dev.example.empty', {}, []);
    catalog = await PreparedPluginCatalog.discover(installations.path);
    expect(catalog.issues, isEmpty);
    installation = catalog.installations.singleWhere(
      (entry) => entry.metadata.id.value == _owner,
    );
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    service = GlobalSettingsService(
      catalog: scalars,
      records: catalog.records,
      roots: roots,
    );
    addTearDown(service.close);
    storage = _NoCredentialStorage();
    final credentials = CredentialService(storage);
    addTearDown(credentials.close);
    final associations = RecordCredentialService(
      settings: service,
      credentials: credentials,
    );
    addTearDown(associations.close);
  });

  File seed(
    String id, {
    String type = _firstType,
    String collection = 'jobs',
    String values = 'name = "Original"\n',
    String suffix = '',
  }) {
    final file = File('${roots.configurationRoot}/$collection/$id.toml');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '# retained\nrecordVersion = 1\nrecordType = "$type"\n\n'
      '[values]\n$values$suffix',
    );
    return file;
  }

  Future<StartupRecordsView> project() =>
      service.loadStartupRecords(catalog, installation);

  void expectNoStorageArtifacts() {
    expect(storage.calls, 0);
    expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    expect(Directory(roots.localDataRoot).existsSync(), isFalse);
    expect(Directory(roots.cacheRoot).existsSync(), isFalse);
    expect(File(service.filePath).existsSync(), isFalse);
  }

  test(
    'projects exact opted-in declarations off UI, without credentials or writes',
    () async {
      final files = [
        seed('alpha', type: _lastType),
        seed(
          'zulu',
          values:
              'name = ""\nenabled = false\ncount = 0\nmode = "brief"\n'
              'unknown = [1, 2]\n',
          suffix:
              '\n[credentials]\n'
              'token = "$_reference"\n'
              '[credentials.future]\nsecret = "not transported"\n'
              '[unknown]\nroot = "not transported"\n',
        ),
        seed('beta'),
        seed('zulu', type: _archiveType, collection: 'archive'),
        seed('hidden', type: '$_owner.hidden'),
        seed('nested', type: '$_nestedOwner.account'),
        seed('foreign', type: 'dev.other.records.account'),
      ];
      final before = {
        for (final file in files) file.path: file.readAsBytesSync(),
      };
      final modified = DateTime.utc(2001);
      for (final file in files) {
        file.setLastModifiedSync(modified);
      }
      File(
        '${roots.configurationRoot}/unscanned',
      ).writeAsStringSync('obstruction');
      final snapshot = await IOOverrides.runZoned(
        project,
        createFile: (_) => throw StateError('UI file access'),
        createDirectory: (_) => throw StateError('UI directory access'),
      );
      expect(snapshot.diagnostics, isEmpty);
      expect(
        snapshot.records.map(
          (record) =>
              '${record['collection']}/${record['type']}/${record['id']}',
        ),
        [
          'archive/$_archiveType/zulu',
          'jobs/$_firstType/beta',
          'jobs/$_firstType/zulu',
          'jobs/$_lastType/alpha',
        ],
      );
      expect(snapshot.records[1]['values'], {'name': 'Original'});
      expect(snapshot.records[2]['values'], {
        'name': '',
        'enabled': false,
        'count': 0,
        'mode': 'brief',
      });
      for (final record in snapshot.records) {
        expect(
          record.keys,
          unorderedEquals(['collection', 'type', 'id', 'values']),
        );
      }
      final encoded = jsonEncode(snapshot.records);
      for (final forbidden in [
        _reference,
        'credentials',
        'not transported',
        roots.configurationRoot,
        'hidden',
        'nested',
        'foreign',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }
      expect(() => snapshot.records.clear(), throwsUnsupportedError);
      expect(() => snapshot.records.first.clear(), throwsUnsupportedError);
      expect(
        () => (snapshot.records.first['values']! as Map).clear(),
        throwsUnsupportedError,
      );
      expect(() => snapshot.diagnostics.clear(), throwsUnsupportedError);
      for (final file in files) {
        expect(file.readAsBytesSync(), before[file.path]);
        expect(file.lastModifiedSync().toUtc(), modified);
      }
      expectNoStorageArtifacts();
    },
  );

  test(
    'malformed siblings are omitted with app-only attributable diagnostics',
    () async {
      seed('healthy', suffix: '\n[credentials]\ntoken = "$_reference"\n');
      final badFiles = [
        seed(
          'bad-reference',
          suffix: '\n[credentials]\ntoken = "bad-ref-marker"\n',
        ),
        seed('invalid-value', values: 'name = true\n'),
        seed('missing-required', values: 'enabled = false\n'),
        seed('unsupported-value', values: 'name = ["not", "scalar"]\n'),
        seed('unknown-type', type: 'dev.uninstalled.record'),
        seed('broken')..writeAsStringSync('invalid = ['),
        seed('invalid-utf8')..writeAsBytesSync([0xff]),
      ];
      final before = {
        for (final file in badFiles) file.path: file.readAsBytesSync(),
      };
      final snapshot = await project();
      expect(snapshot.records.single['id'], 'healthy');
      expect(snapshot.diagnostics.map((item) => item.fileName), [
        'bad-reference.toml',
        'broken.toml',
        'invalid-utf8.toml',
        'invalid-value.toml',
        'missing-required.toml',
        'unknown-type.toml',
        'unsupported-value.toml',
      ]);
      for (final diagnostic in snapshot.diagnostics) {
        expect(diagnostic.collection, _jobs);
        expect('${diagnostic.recordId}.toml', diagnostic.fileName);
        expect(diagnostic.message, isNotEmpty);
      }
      expect(
        snapshot.diagnostics.first.message,
        contains('credential reference'),
      );
      expect(
        snapshot.diagnostics.first.message,
        isNot(contains('bad-ref-marker')),
      );
      expect(snapshot.diagnostics[1].message, contains('TomlException(parse)'));
      expect(snapshot.diagnostics[2].message, contains('FormatException'));
      expect(snapshot.diagnostics[3].message, contains('InvalidRecordValue'));
      for (final file in badFiles) {
        expect(file.readAsBytesSync(), before[file.path]);
      }
      expectNoStorageArtifacts();
    },
  );

  test(
    'zero opt-in returns explicit empty without inspecting obstructed roots',
    () async {
      final obstruction = File(roots.configurationRoot)
        ..writeAsStringSync('blocked');
      final empty = catalog.installations.singleWhere(
        (entry) => entry.metadata.id.value == 'dev.example.empty',
      );
      final snapshot = await service.loadStartupRecords(catalog, empty);
      expect(snapshot.recordsForInstallation(catalog, empty), isEmpty);
      expect(snapshot.diagnostics, isEmpty);
      expect(obstruction.readAsStringSync(), 'blocked');
      expectNoStorageArtifacts();
      await service.close();
      await expectLater(
        service.loadStartupRecords(catalog, empty),
        throwsStateError,
      );
    },
  );

  test(
    'absent opted-in collections return empty without creating directories',
    () async {
      final snapshot = await project();
      expect(snapshot.records, isEmpty);
      expect(snapshot.diagnostics, isEmpty);
      expect(Directory(roots.configurationRoot).existsSync(), isFalse);
      expectNoStorageArtifacts();
    },
  );

  test(
    'rejects foreign catalog references and rediscovered declaration copies',
    () async {
      final rediscovered = await PreparedPluginCatalog.discover(
        installations.path,
      );
      final copied = rediscovered.installations.singleWhere(
        (entry) => entry.metadata.id.value == _owner,
      );
      await expectLater(
        service.loadStartupRecords(catalog, copied),
        throwsArgumentError,
      );
      await expectLater(
        service.loadStartupRecords(rediscovered, installation),
        throwsArgumentError,
      );
      await expectLater(
        service.loadStartupRecords(rediscovered, copied),
        throwsArgumentError,
      );
      // Matching semantic IDs and paths cannot substitute for the captured schema.
      expect(Directory(roots.configurationRoot).existsSync(), isFalse);
      expectNoStorageArtifacts();
    },
  );

  test(
    'projection preserves scalar and record UI baselines and pending edits',
    () async {
      seed('first');
      seed('second');
      final records = await service.loadRecords(_jobs);
      final scalar = await service.load();
      final projecting = project();
      final draft = <String, Object?>{'name': 'Saved draft', 'enabled': false};
      final updating = service.updateRecord(records.records.first, draft);
      draft['name'] = 'Changed after admission';
      final snapshot = await projecting;
      final updated = await updating;
      expect(snapshot.records.first['values'], {'name': 'Original'});
      expect(records.records.first.values, {'name': 'Original'});
      expect(updated.values, {'name': 'Saved draft', 'enabled': false});
      await service.save(scalar, enabled, true);
      await service.deleteRecord(records.records.last);
      final later = await project();
      expect(later.records.single['values'], updated.values);
      final pendingEdit = service.updateRecord(updated, {
        'name': 'Still editable',
      });
      final pendingProjection = project();
      final newest = await pendingEdit;
      expect((await pendingProjection).records.single['values'], newest.values);
      await service.updateRecord(newest, {'name': 'Final edit'});
      expect(snapshot.records.first['values'], {'name': 'Original'});
      expect(storage.calls, 0);
    },
    skip: !Platform.isLinux,
  );

  test(
    'collection failure rejects projection without retiring UI handles',
    () async {
      final file = seed('first');
      seed('healthy', type: _archiveType, collection: 'archive');
      final original = file.readAsStringSync();
      final baseline = (await service.loadRecords(_jobs)).records.single;
      final scalar = await service.load();
      file.parent.deleteSync(recursive: true);
      final obstruction = File(file.parent.path)..writeAsStringSync('blocked');
      await expectLater(project(), throwsA(isA<FileSystemException>()));
      expect(obstruction.readAsStringSync(), 'blocked');
      expect(baseline.values, {'name': 'Original'});
      expectNoStorageArtifacts();
      obstruction.deleteSync();
      file.parent.createSync();
      file.writeAsStringSync(original);
      final saved = await service.updateRecord(baseline, {
        'name': 'Still usable',
      });
      expect(saved.values, {'name': 'Still usable'});
      await service.save(scalar, enabled, true);
    },
    skip: !Platform.isLinux,
  );

  test(
    'projection never adopts an external replacement as an editing baseline',
    () async {
      final file = seed('first');
      final baseline = (await service.loadRecords(_jobs)).records.single;
      seed('first', values: 'name = "External"\n');
      expect((await project()).records.single['values'], {'name': 'External'});
      expectNoStorageArtifacts();
      await expectLater(
        service.updateRecord(baseline, {'name': 'Do not merge'}),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file.readAsStringSync(), contains('name = "External"'));
    },
    skip: !Platform.isLinux,
  );

  test(
    'oversized startup payload fails without retiring an editable record',
    () async {
      final text = 'x' * (AdeleBackendRecords.maxStringLength + 1);
      final file = seed('first', values: 'name = "$text"\n');
      final baseline = (await service.loadRecords(_jobs)).records.single;
      await expectLater(project(), throwsFormatException);
      expectNoStorageArtifacts();
      expect(file.readAsStringSync(), contains(text));
      final saved = await service.updateRecord(baseline, {'name': 'Bounded'});
      expect(saved.values, {'name': 'Bounded'});
    },
    skip: !Platform.isLinux,
  );

  test(
    'source maps are defensively copied and installation binding is exact',
    () async {
      final values = <String, Object?>{'name': 'Captured'};
      final record = <String, Object?>{
        'collection': 'jobs',
        'type': _firstType,
        'id': 'first',
        'values': values,
      };
      final source = [record];
      final diagnostics = <RecordDiagnosticView>[];
      final snapshot = StartupRecordsView.fromProjection(
        catalog,
        installation,
        records: source,
        diagnostics: diagnostics,
      );
      values['name'] = 'Mutated';
      record['id'] = 'changed';
      source.clear();
      diagnostics.add(
        RecordDiagnosticView(
          collection: _jobs,
          fileName: 'fake.toml',
          recordId: null,
          message: 'not retained',
        ),
      );
      expect(snapshot.recordsForInstallation(catalog, installation).single, {
        'collection': 'jobs',
        'type': _firstType,
        'id': 'first',
        'values': {'name': 'Captured'},
      });
      expect(snapshot.diagnostics, isEmpty);
      final nested = catalog.installations.singleWhere(
        (entry) => entry.metadata.id.value == _nestedOwner,
      );
      expect(
        () => snapshot.recordsForInstallation(catalog, nested),
        throwsArgumentError,
      );
      final rediscovered = await PreparedPluginCatalog.discover(
        installations.path,
      );
      expect(
        () => snapshot.recordsForInstallation(rediscovered, installation),
        throwsArgumentError,
      );
      expect(
        () => snapshot.records.single['id'] = 'mutated',
        throwsUnsupportedError,
      );
      expect(
        () => (snapshot.records.single['values']! as Map)['name'] = 'mutated',
        throwsUnsupportedError,
      );
    },
  );

  test(
    'projection wrapper rejects undeclared, unopted and invalid source values',
    () {
      for (final record in <Map<String, Object?>>[
        {
          'collection': 'jobs',
          'type': '$_nestedOwner.account',
          'id': 'first',
          'values': {'name': 'Foreign'},
        },
        {
          'collection': 'jobs',
          'type': '$_owner.hidden',
          'id': 'first',
          'values': {'name': 'Unopted'},
        },
        {
          'collection': 'archive',
          'type': _firstType,
          'id': 'first',
          'values': {'name': 'Wrong collection'},
        },
        {
          'collection': 'jobs',
          'type': _firstType,
          'id': 'first',
          'values': {'name': 'Known', 'unknown': 'Untransportable'},
        },
        {'collection': 'jobs', 'type': _firstType, 'id': 'first', 'values': {}},
        {
          'collection': 'jobs',
          'type': _firstType,
          'id': 'first',
          'values': {'name': true},
        },
        {
          'collection': 'jobs',
          'type': _firstType,
          'id': 'first',
          'values': {'name': 'Known', 'count': 11},
        },
        {
          'collection': 'jobs',
          'type': _firstType,
          'id': 'first',
          'values': {'name': 'Known'},
          'credentials': {'token': _reference},
        },
      ]) {
        expect(
          () => StartupRecordsView.fromProjection(
            catalog,
            installation,
            records: [record],
          ),
          throwsA(isA<Exception>()),
        );
      }
    },
  );

  test(
    'lock-blocked projection shares admission and shutdown drains pending edits',
    () async {
      seed('first');
      final baseline = (await service.loadRecords(_jobs)).records.single;
      final other = GlobalSettingsService(catalog: scalars, roots: roots);
      addTearDown(other.close);
      final scalar = await other.load();
      final lock = File('${roots.localStateRoot}/configuration/settings.lock');
      lock.parent.createSync(recursive: true);
      final helper = File(
        'test/support/settings_lock.dart',
      ).copySync('${temporary.path}/settings_lock.dart');
      final process = await Process.start(
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
        [helper.path, lock.path],
        workingDirectory: temporary.path,
      );
      addTearDown(() async {
        process.kill();
        await process.exitCode;
      });
      final stderr = process.stderr.transform(utf8.decoder).join();
      expect(
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
        'locked',
      );
      var projected = false;
      final projecting = project().then((value) {
        projected = true;
        return value;
      });
      final updating = service.updateRecord(baseline, {'name': 'Drained edit'});
      final saving = other.save(scalar, enabled, true);
      var closed = false;
      final closing = Future.wait([
        service.close(),
        other.close(),
      ]).then((_) => closed = true);
      await expectLater(project(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(projected, isFalse);
      expect(closed, isFalse);
      expect(
        IsolateNameServer.lookupPortByName('dev.adele.global-settings-owner'),
        isNotNull,
      );
      process.stdin.writeln('release');
      await process.stdin.flush();
      expect(await process.exitCode, 0, reason: await stderr);
      expect((await projecting).records.single['values'], {'name': 'Original'});
      expect((await updating).values, {'name': 'Drained edit'});
      expect((await saving).values[enabled]!.value, true);
      await closing;
      expect(closed, isTrue);
      expect(
        IsolateNameServer.lookupPortByName('dev.adele.global-settings-owner'),
        isNull,
      );
      expect(storage.calls, 0);
    },
    skip: !Platform.isLinux,
  );
}

void _publish(
  Directory root,
  String owner,
  Map<String, String> types,
  List<String> consumed,
) {
  final directory = Directory('${root.path}/$owner')
    ..createSync(recursive: true);
  File('${directory.path}/backend.aot').writeAsStringSync('not executed');
  File('${directory.path}/records.schema.json').writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'recordTypes': [
        for (final entry in types.entries)
          {
            'id': entry.key,
            'collection': entry.value,
            'collectionLabel': entry.value,
            'label': 'Record',
            'credentialSlots': [
              {'id': 'token', 'label': 'Token', 'kind': 'secret-text'},
            ],
            'fields': [
              {
                'id': 'name',
                'label': 'Name',
                'type': 'string',
                'required': true,
              },
              {
                'id': 'enabled',
                'label': 'Enabled',
                'type': 'boolean',
                'required': false,
              },
              {
                'id': 'count',
                'label': 'Count',
                'type': 'integer',
                'required': false,
                'minimum': 0,
                'maximum': 10,
              },
              {
                'id': 'mode',
                'label': 'Mode',
                'type': 'enum',
                'required': false,
                'options': [
                  {'value': 'brief'},
                  {'value': 'detailed'},
                ],
              },
            ],
          },
      ],
    }),
  );
  File('${directory.path}/adele_plugin.installation.json').writeAsStringSync(
    jsonEncode({
      'manifestVersion': 1,
      'metadata': {'id': owner, 'version': '1', 'displayName': 'Probe'},
      'recordsSchema': 'records.schema.json',
      'components': {
        'backend': {'artifact': 'backend.aot', 'consumesRecordTypes': consumed},
      },
    }),
  );
}

final class _NoCredentialStorage implements CredentialStorageAdapter {
  int calls = 0;

  Never _unexpected() {
    calls++;
    throw StateError('Startup must not access credential storage.');
  }

  @override
  Future<bool> contains(CredentialReference reference) async => _unexpected();
  @override
  Future<String?> read(CredentialReference reference) async => _unexpected();
  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async => _unexpected();
  @override
  Future<void> delete(CredentialReference reference) async => _unexpected();
}
