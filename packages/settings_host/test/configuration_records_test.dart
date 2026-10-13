import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

import '../../../tools/backend_artifacts.dart';

void main() {
  final providers = RecordCollectionId('providers');
  final openai = RecordTypeId('dev.adele.openai.api-key');
  final work = ConfigurationRecordId('work-openai');
  final personal = ConfigurationRecordId('personal-openai');
  late Directory installations;
  late RecordCatalog catalog;
  late Directory temporary;
  late PlatformStorageRoots roots;
  late ConfigurationStore persistence;
  late ConfigurationRecordStore host;

  setUpAll(() async {
    installations = Directory.systemTemp.createTempSync(
      'adele-record-schemas-',
    );
    var repository = Directory.current;
    while (!File(p.join(repository.path, 'tools', 'adele.dart')).existsSync()) {
      if (repository.parent.path == repository.path) {
        throw StateError('Repository root not found.');
      }
      repository = repository.parent;
    }
    // Use the real authored asset and maintained publisher, not a duplicate test
    // schema. No executable artifacts or authentication are necessary.
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: Directory(p.join(installations.path, 'openai')),
      pluginId: 'dev.adele.openai',
      displayName: 'OpenAI',
    );
    final prepared = await PreparedPluginCatalog.discover(installations.path);
    expect(prepared.issues, isEmpty);
    catalog = prepared.records;
    expect(catalog.definition(openai).owner, PluginId('dev.adele.openai'));
  });
  tearDownAll(() => installations.deleteSync(recursive: true));

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('adele-records-');
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: p.join(temporary.path, 'config'),
      localStateRoot: p.join(temporary.path, 'state'),
      localDataRoot: p.join(temporary.path, 'data'),
      cacheRoot: p.join(temporary.path, 'cache'),
    );
    persistence = ConfigurationStore(roots);
    host = ConfigurationRecordStore(store: persistence, catalog: catalog);
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  File file(ConfigurationRecordId id) =>
      File(p.join(roots.configurationRoot, 'providers', '${id.value}.toml'));

  void seed(ConfigurationRecordId id, String source) {
    file(id).parent.createSync(recursive: true);
    file(id).writeAsStringSync(source);
  }

  String source(String values, {String type = 'dev.adele.openai.api-key'}) =>
      'recordVersion = 1\nrecordType = "$type"\n\n[values]\n$values';

  test('absent collection enumerates without creating artifacts', () async {
    final result = await host.enumerate(providers);
    expect(result.records, isEmpty);
    expect(result.diagnostics, isEmpty);
    await expectLater(
      host.load(providers, work),
      throwsA(isA<ConfigurationRecordNotFound>()),
    );
    expect(temporary.listSync(), isEmpty);
  });

  test(
    'mixed malformed records remain attributable alongside healthy records',
    () async {
      seed(work, source('display-name = "Work"\n'));
      seed(personal, 'not valid TOML = [');
      final invalidUtf8 = ConfigurationRecordId('invalid-utf8');
      file(invalidUtf8).writeAsBytesSync([0xff]);
      seed(ConfigurationRecordId('missing-name'), source('endpoint = ""\n'));
      final result = await host.enumerate(providers);
      expect(result.records.single.id, work);
      expect(result.diagnostics.map((failure) => failure.fileName), [
        'invalid-utf8.toml',
        'missing-name.toml',
        'personal-openai.toml',
      ]);
      expect(result.diagnostics[0].error, isA<FormatException>());
      expect(result.diagnostics[1].error, isA<InvalidRecordValue>());
      expect(result.diagnostics[2].error, isA<TomlException>());
      expect(result.diagnostics[2].recordId, personal);
      expect((await host.load(providers, work)).values['display-name'], 'Work');
      expect(() => result.records.clear(), throwsUnsupportedError);
      expect(() => result.diagnostics.clear(), throwsUnsupportedError);
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    },
  );

  for (final malformed in [
    'recordVersion = 2\nrecordType = "dev.adele.openai.api-key"\n[values]\ndisplay-name = "X"\n',
    'recordVersion = "1"\nrecordType = "dev.adele.openai.api-key"\n[values]\ndisplay-name = "X"\n',
    'recordType = "dev.adele.openai.api-key"\n[values]\ndisplay-name = "X"\n',
    'recordVersion = 1\nrecordType = true\n[values]\ndisplay-name = "X"\n',
    'recordVersion = 1\nrecordType = "not-a-public-id"\n[values]\n',
    'recordVersion = 1\nrecordType = "dev.absent.type"\n[values]\n',
    'recordVersion = 1\nrecordType = "dev.adele.openai.api-key"\n',
    'recordVersion = 1\nrecordType = "dev.adele.openai.api-key"\nvalues = {}\n',
    'recordVersion = 1\nrecordType = "dev.adele.openai.api-key"\n[[values]]\n',
  ]) {
    test('invalid header/table is explicit: $malformed', () async {
      seed(work, malformed);
      await expectLater(
        host.load(providers, work),
        throwsA(isA<ConfigurationRecordFormatException>()),
      );
      expect(file(work).readAsStringSync(), malformed);
    });
  }

  for (final unsupported in [
    'true',
    '42',
    '1.5',
    '["X"]',
    '{ x = "X" }',
    '1979-05-27',
  ]) {
    test('unsupported known value $unsupported is never repaired', () async {
      final original = source('display-name = $unsupported # retain\n');
      seed(work, original);
      await expectLater(
        host.load(providers, work),
        throwsA(
          isA<InvalidRecordValue>().having(
            (error) => error.fieldId,
            'field',
            RecordFieldId('display-name'),
          ),
        ),
      );
      expect(file(work).readAsStringSync(), original);
      expect((await host.enumerate(providers)).diagnostics, hasLength(1));
    });
  }

  test('directory-wide failure is not an empty collection', () async {
    Directory(roots.configurationRoot).createSync();
    File(
      p.join(roots.configurationRoot, 'providers'),
    ).writeAsStringSync('file');
    await expectLater(
      host.enumerate(providers),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'oversized files are diagnostics and aggregate retention is bounded',
    () async {
      seed(work, source('display-name = "Work"\n'));
      seed(personal, 'x' * (ConfigurationStore.maxRecordBytes + 1));
      final listing = await host.enumerate(providers);
      expect(listing.records.single.id, work);
      expect(
        listing.diagnostics.single.error,
        isA<ConfigurationLimitException>(),
      );
      file(personal).deleteSync();
      final large = source(
        'display-name = "Name"\nunknown = "${'x' * (1000 * 1024)}"\n',
      );
      for (var index = 0; index < 17; index++) {
        seed(ConfigurationRecordId('large-$index'), large);
      }
      await expectLater(
        host.enumerate(providers),
        throwsA(
          isA<ConfigurationLimitException>().having(
            (error) => error.limit,
            'aggregate limit',
            ConfigurationRecordStore.maxEnumerationBytes,
          ),
        ),
      );
      expect((await host.load(providers, work)).values['display-name'], 'Work');
    },
  );

  test(
    'unexpected entries and portable filename aliases never win',
    () async {
      seed(work, source('display-name = "Work"\n'));
      final parent = file(work).parent;
      File(
        p.join(parent.path, 'Work-openai.toml'),
      ).writeAsStringSync(source('display-name = "Alias"\n'));
      File(p.join(parent.path, 'odd.txt')).writeAsStringSync('unrelated');
      Directory(p.join(parent.path, 'personal-openai.toml')).createSync();
      final result = await host.enumerate(providers);
      expect(result.records, isEmpty);
      expect(result.diagnostics, hasLength(4));
      await expectLater(
        host.load(providers, work),
        throwsA(isA<ConfigurationRecordFormatException>()),
      );
    },
    skip: !Platform.isLinux,
  );

  group('conditional record CRUD', () {
    test(
      'two real OpenAI records retain independent identity and bytes across restart',
      () async {
        expect((await host.enumerate(providers)).records, isEmpty);
        var workRecord = await host.create(openai, work, {
          'display-name': 'Work OpenAI',
        });
        final personalRecord = await host.create(openai, personal, {
          'display-name': 'Personal OpenAI',
          'endpoint': 'https://api.openai.com/v1',
        });
        final personalBytes = file(personal).readAsBytesSync();
        var result = await host.enumerate(providers);
        expect(result.diagnostics, isEmpty);
        expect(result.records.map((record) => record.id), [personal, work]);
        expect((await host.load(providers, work)).values, {
          'display-name': 'Work OpenAI',
        });
        expect(
          (await host.load(providers, personal)).values['endpoint'],
          'https://api.openai.com/v1',
        );
        workRecord = await host.update(workRecord, {
          'display-name': 'Renamed Work',
        });
        expect(workRecord.id, work);
        expect(file(work).existsSync(), isTrue);
        expect(file(personal).readAsBytesSync(), personalBytes);
        final workBytes = file(work).readAsBytesSync();
        await host.delete(personalRecord);
        expect(file(personal).existsSync(), isFalse);
        expect(file(work).readAsBytesSync(), workBytes);
        host = ConfigurationRecordStore(
          store: ConfigurationStore(roots),
          catalog: catalog,
        );
        result = await host.enumerate(providers);
        expect(result.records.single.id, work);
        expect(result.records.single.values, {'display-name': 'Renamed Work'});
        expect(result.diagnostics, isEmpty);
        expect(Directory(roots.localDataRoot).existsSync(), isFalse);
        expect(Directory(roots.cacheRoot).existsSync(), isFalse);
        expect(File(persistence.filePath).existsSync(), isFalse);
      },
    );

    test(
      'duplicate creates reject even malformed or differently typed existing files',
      () async {
        final existing = await host.create(openai, work, {
          'display-name': 'Work',
        });
        await expectLater(
          host.create(openai, work, {'display-name': 'Replacement'}),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect((await host.load(providers, work)).values, existing.values);
        seed(work, 'malformed = [');
        await expectLater(
          host.create(openai, work, {'display-name': 'Replacement'}),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file(work).readAsStringSync(), 'malformed = [');
      },
    );

    test('stale updates deletes and no-ops require explicit reload', () async {
      final initial = await host.create(openai, work, {'display-name': 'Work'});
      final other = ConfigurationRecordStore(
        store: ConfigurationStore(roots),
        catalog: catalog,
      );
      final stale = await other.load(providers, work);
      final latest = await host.update(initial, {'display-name': 'Newer'});
      await expectLater(
        other.update(stale, {'display-name': 'Stale'}),
        throwsA(isA<ConfigurationConflictException>()),
      );
      await expectLater(
        other.update(stale, stale.values),
        throwsA(isA<ConfigurationConflictException>()),
      );
      await expectLater(
        other.delete(stale),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect((await host.load(providers, work)).values, latest.values);
      final external = '${file(work).readAsStringSync()}# external edit\n';
      file(work).writeAsStringSync(external);
      await expectLater(
        host.delete(latest),
        throwsA(isA<ConfigurationConflictException>()),
      );
      await expectLater(
        host.update(latest, latest.values),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file(work).readAsStringSync(), external);
      final reloaded = await host.load(providers, work);
      await host.delete(reloaded);
      await expectLater(
        host.delete(reloaded),
        throwsA(isA<ConfigurationConflictException>()),
      );
    });

    test(
      'no-op retains byte spelling BOM comments and mtime without state artifacts',
      () async {
        final original =
            '\uFEFF# header\nrecordVersion = 0x1\nrecordType = "dev.adele.openai.api-key"\n\n[values]\ndisplay-name = "Work" # comment\n';
        seed(work, original);
        final originalBytes = file(work).readAsBytesSync();
        final modified = DateTime.utc(2001);
        file(work).setLastModifiedSync(modified);
        final loaded = await host.load(providers, work);
        expect(await host.update(loaded, loaded.values), same(loaded));
        expect(file(work).readAsBytesSync(), originalBytes);
        expect(file(work).readAsStringSync(), original.substring(1));
        expect(file(work).lastModifiedSync().toUtc(), modified);
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );

    test(
      'supported edits preserve comments unknown keys and unrelated structures',
      () async {
        seed(
          work,
          '# header\n${source('display-name = "Work" # name note\nendpoint = "old"\nunknown = { nested = [1, 2] } # retained\n')}\n[future]\nflag = true # future\n',
        );
        var loaded = await host.load(providers, work);
        loaded = await host.update(loaded, {'display-name': 'Renamed'});
        expect(loaded.values.containsKey('endpoint'), isFalse);
        final text = file(work).readAsStringSync();
        expect(text, contains('# header'));
        expect(text, contains('# name note'));
        expect(text, contains('unknown = { nested = [1, 2] } # retained'));
        expect(text, contains('[future]\nflag = true # future'));
        expect(text, isNot(contains('endpoint')));
        loaded = await host.update(loaded, {
          'display-name': '',
          'endpoint': '',
        });
        expect(loaded.values, {'display-name': '', 'endpoint': ''});
        expect(() => loaded.values.clear(), throwsUnsupportedError);
      },
    );

    test(
      'failed desired validation and unknown field edits leave content unchanged',
      () async {
        final loaded = await host.create(openai, work, {
          'display-name': 'Work',
        });
        final bytes = file(work).readAsBytesSync();
        for (final values in <Map<String, Object?>>[
          {},
          {'display-name': null},
          {'display-name': false},
          {'display-name': 'Work', 'endpoint': 1},
        ]) {
          await expectLater(
            host.update(loaded, values),
            throwsA(isA<InvalidRecordValue>()),
          );
          expect(file(work).readAsBytesSync(), bytes);
        }
        await expectLater(
          host.update(loaded, {
            'display-name': 'Work',
            'apiKey': 'not-written',
          }),
          throwsA(isA<ConfigurationRecordFormatException>()),
        );
        expect(file(work).readAsBytesSync(), bytes);
      },
    );

    test('file symlinks cannot be loaded overwritten or deleted', () async {
      final loaded = await host.create(openai, work, {'display-name': 'Work'});
      final target = File(p.join(temporary.path, 'outside.toml'));
      file(work).renameSync(target.path);
      Link(file(work).path).createSync(target.path);
      final bytes = target.readAsBytesSync();
      await expectLater(
        host.load(providers, work),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      await expectLater(
        host.update(loaded, {'display-name': 'Other'}),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      await expectLater(
        host.delete(loaded),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      await expectLater(
        host.create(openai, work, {'display-name': 'Other'}),
        throwsA(isA<ConfigurationSymlinkException>()),
      );
      expect(target.readAsBytesSync(), bytes);
      expect(Link(file(work).path).existsSync(), isTrue);
      expect(
        (await host.enumerate(providers)).diagnostics.single.recordId,
        work,
      );
    });

    test(
      'collection symlink is rejected but configuration-root symlink is supported',
      () async {
        final actual = Directory(p.join(temporary.path, 'actual'))
          ..createSync();
        Link(roots.configurationRoot).createSync(actual.path);
        final loaded = await host.create(openai, work, {
          'display-name': 'Work',
        });
        expect((await host.load(providers, work)).values, loaded.values);
        final collection = file(work).parent;
        final moved = collection.renameSync(p.join(temporary.path, 'moved'));
        Link(collection.path).createSync(moved.path);
        await expectLater(
          host.enumerate(providers),
          throwsA(isA<ConfigurationSymlinkException>()),
        );
        await expectLater(
          host.delete(loaded),
          throwsA(isA<ConfigurationSymlinkException>()),
        );
        expect(
          File(p.join(moved.path, '${work.value}.toml')).existsSync(),
          isTrue,
        );
      },
    );

    test(
      'alias added after load blocks update delete and duplicate create',
      () async {
        final loaded = await host.create(openai, work, {
          'display-name': 'Work',
        });
        for (final name in [
          'Work-openai.toml',
          'work-openai.TOML',
          'work-openai.toml. ',
          'work-openai.toml ',
        ]) {
          final alias = File(p.join(file(work).parent.path, name))
            ..writeAsStringSync('untouched');
          await expectLater(
            host.update(loaded, loaded.values),
            throwsA(isA<ConfigurationRecordFormatException>()),
          );
          await expectLater(
            host.delete(loaded),
            throwsA(isA<ConfigurationRecordFormatException>()),
          );
          await expectLater(
            host.create(openai, work, loaded.values),
            throwsA(isA<ConfigurationRecordFormatException>()),
          );
          expect((await host.enumerate(providers)).records, isEmpty);
          alias.deleteSync();
        }
        expect((await host.load(providers, work)).values, loaded.values);
      },
    );

    test(
      'another catalog or root cannot reuse a snapshot as write authority',
      () async {
        final loaded = await host.create(openai, work, {
          'display-name': 'Work',
        });
        final otherCatalog = ConfigurationRecordStore(
          store: persistence,
          catalog: RecordCatalog(catalog.definitions),
        );
        await expectLater(
          otherCatalog.update(loaded, loaded.values),
          throwsArgumentError,
        );
        await expectLater(otherCatalog.delete(loaded), throwsArgumentError);
        final otherRoot = ConfigurationRecordStore(
          store: ConfigurationStore(
            PlatformStorageRoots(
              operatingSystem: Platform.operatingSystem,
              configurationRoot: p.join(temporary.path, 'other-config'),
              localStateRoot: roots.localStateRoot,
              localDataRoot: roots.localDataRoot,
              cacheRoot: roots.cacheRoot,
            ),
          ),
          catalog: catalog,
        );
        await expectLater(
          otherRoot.update(loaded, {'display-name': 'Wrong root'}),
          throwsArgumentError,
        );
        await expectLater(otherRoot.delete(loaded), throwsArgumentError);
        expect(
          Directory(p.join(temporary.path, 'other-config')).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'generic unrelated record supports explicit false zero enum and optional absence',
      () async {
        final jobs = RecordCollectionId('jobs');
        final type = RecordTypeDefinition(
          id: RecordTypeId('dev.example.jobs.local'),
          owner: PluginId('dev.example.jobs'),
          collection: jobs,
          collectionLabel: 'Jobs',
          label: 'Local job',
          fields: [
            RecordFieldDefinition(
              id: RecordFieldId('enabled'),
              label: 'Enabled',
              type: const BooleanSettingType(),
              required: true,
            ),
            RecordFieldDefinition(
              id: RecordFieldId('count'),
              label: 'Count',
              type: IntegerSettingType(minimum: 0, maximum: 10),
              required: true,
            ),
            RecordFieldDefinition(
              id: RecordFieldId('mode'),
              label: 'Mode',
              type: EnumSettingType([
                SettingEnumOption('fast'),
                SettingEnumOption('safe', label: 'Safe'),
              ]),
              required: false,
            ),
          ],
        );
        final generic = ConfigurationRecordStore(
          store: persistence,
          catalog: RecordCatalog([...catalog.definitions, type]),
        );
        final id = ConfigurationRecordId('build');
        var loaded = await generic.create(type.id, id, {
          'enabled': false,
          'count': 0,
        });
        expect((await generic.load(jobs, id)).values, {
          'enabled': false,
          'count': 0,
        });
        loaded = await generic.update(loaded, {
          'enabled': false,
          'count': 0,
          'mode': 'safe',
        });
        final bytes = loaded.document.source;
        for (final invalid in <Map<String, Object?>>[
          {'enabled': false, 'count': 11},
          {'enabled': false, 'count': 0, 'mode': 'other'},
          {'enabled': 'false', 'count': 0},
        ]) {
          await expectLater(
            generic.update(loaded, invalid),
            throwsA(isA<InvalidRecordValue>()),
          );
          expect((await generic.load(jobs, id)).document.source, bytes);
        }
        loaded = await generic.update(loaded, {'enabled': true, 'count': 10});
        expect(loaded.values.containsKey('mode'), isFalse);
        await generic.delete(loaded);
        expect((await generic.enumerate(jobs)).records, isEmpty);
      },
    );

    test('different types cannot claim one collection identity', () async {
      final otherType = RecordTypeDefinition(
        id: RecordTypeId('dev.example.provider.local'),
        owner: PluginId('dev.example.provider'),
        collection: providers,
        collectionLabel: 'Providers',
        label: 'Unrelated provider',
        fields: [],
      );
      final generic = ConfigurationRecordStore(
        store: persistence,
        catalog: RecordCatalog([...catalog.definitions, otherType]),
      );
      final original = await generic.create(openai, work, {
        'display-name': 'Work',
      });
      await expectLater(
        generic.create(otherType.id, work, {}),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect((await generic.load(providers, work)).type.id, openai);
      seed(work, source('', type: otherType.id.value));
      await expectLater(
        generic.update(original, original.values),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect((await generic.load(providers, work)).type.id, otherType.id);
    });

    test(
      'removing an implicit values table never publishes an invalid record',
      () async {
        final type = RecordTypeDefinition(
          id: RecordTypeId('dev.example.optional.type'),
          owner: PluginId('dev.example.optional'),
          collection: providers,
          collectionLabel: 'Providers',
          label: 'Optional values',
          fields: [
            RecordFieldDefinition(
              id: RecordFieldId('text'),
              label: 'Text',
              type: const StringSettingType(),
              required: false,
            ),
          ],
        );
        final generic = ConfigurationRecordStore(
          store: persistence,
          catalog: RecordCatalog([type]),
        );
        const original =
            'recordVersion = 1\nrecordType = "dev.example.optional.type"\nvalues.text = "value"\n';
        seed(work, original);
        final loaded = await generic.load(providers, work);
        await expectLater(
          generic.update(loaded, {}),
          throwsA(isA<InvalidRecordValue>()),
        );
        expect(file(work).readAsStringSync(), original);
        expect((await generic.load(providers, work)).values, loaded.values);
        seed(work, source('text = "value"\n', type: type.id.value));
        final explicit = await generic.load(providers, work);
        await generic.update(explicit, {});
        expect((await generic.load(providers, work)).values, isEmpty);
      },
    );
  }, skip: !Platform.isLinux);
}
