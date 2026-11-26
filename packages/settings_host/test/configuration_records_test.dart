import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_credential_store/credential_reference.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:adele_toml_document/adele_toml_document.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

import '../../../tools/backend_artifacts.dart';
import '../../configuration_store/test/support.dart';

void main() {
  final providers = RecordCollectionId('providers');
  final openai = RecordTypeId('dev.adele.openai.api-key');
  final agents = RecordCollectionId('agents');
  final agent = RecordTypeId('dev.adele.plugin.agent-configuration.agent');
  final presets = RecordCollectionId('model-presets');
  final preset = RecordTypeId('dev.adele.plugin.model-configuration.preset');
  const reference = {
    'model-id': '  Team-A/Research:V2  ',
    'provider-id': 'dev.example.provider.work',
  };
  final work = ConfigurationRecordId('work-openai');
  final personal = ConfigurationRecordId('personal-openai');
  final apiKey = RecordCredentialSlotId('api-key');
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
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: Directory(
        p.join(installations.path, 'agent-configuration'),
      ),
      pluginId: 'dev.adele.plugin.agent-configuration',
      displayName: 'Agent Configuration',
    );
    final modelInstallation = Directory(
      p.join(installations.path, 'model-configuration'),
    );
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: modelInstallation,
      pluginId: 'dev.adele.plugin.model-configuration',
      displayName: 'Model Configuration',
      backend: true,
    );
    // The stock preference-source declaration needs a discoverable backend,
    // but reading and writing records must never execute it.
    await File.fromUri(modelInstallation.uri.resolve('backend.aot')).create();
    final prepared = await PreparedPluginCatalog.discover(installations.path);
    expect(prepared.issues, isEmpty);
    catalog = prepared.records;
    expect(catalog.definition(openai).owner, PluginId('dev.adele.openai'));
    expect(catalog.definition(openai).credentialSlots.single.id, apiKey);
    expect(
      catalog.definition(agent).owner,
      PluginId('dev.adele.plugin.agent-configuration'),
    );
    expect(catalog.definition(agent).credentialSlots, isEmpty);
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

  File file(ConfigurationRecordId id, [RecordCollectionId? collection]) => File(
    p.join(
      roots.configurationRoot,
      (collection ?? providers).value,
      '${id.value}.toml',
    ),
  );

  void seed(
    ConfigurationRecordId id,
    String source, [
    RecordCollectionId? collection,
  ]) {
    final target = file(id, collection);
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(source);
  }

  String source(
    String values, {
    ConfigurationRecordId? id,
    String type = 'dev.adele.openai.api-key',
  }) =>
      'recordVersion = 2\nrecordId = "${id ?? work}"\nrecordType = "$type"\n\n[values]\n$values';

  test('ordinary snapshots do not confer strict startup identity', () async {
    seed(work, source('display-name = "Work"\n'));
    final ordinary = await host.load(providers, work);
    await expectLater(
      host.validateStartupCurrent(ordinary),
      throwsA(isA<ConfigurationStartupIdentityUnavailable>()),
    );
    expect(await host.validateCurrent(ordinary), same(ordinary));
  });

  test(
    'transient identity observation failure is unavailable, not stale',
    () async {
      seed(work, source('display-name = "Work"\n'));
      final startup = (await host.enumerate(
        providers,
        captureStartupIdentity: true,
      )).records.single;
      await expectLater(
        IOOverrides.runZoned(
          () => host.validateStartupCurrent(startup),
          fseGetTypeSync: (path, followLinks) =>
              throw const FileSystemException(
                'injected identity observation failure',
              ),
        ),
        throwsA(isA<ConfigurationStartupIdentityUnavailable>()),
      );
      await host.validateStartupCurrent(startup);
      await expectLater(
        IOOverrides.runZoned(
          () => host.validateStartupCurrent(startup),
          fseGetTypeSync: (path, followLinks) => FileSystemEntityType.notFound,
        ),
        throwsA(isA<ConfigurationStartupIdentityUnavailable>()),
      );
      await host.validateStartupCurrent(startup);
      file(work).deleteSync();
      await expectLater(
        host.validateStartupCurrent(startup),
        throwsA(isA<ConfigurationConflictException>()),
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'startup batch pins each incarnation without changing UI equivalence',
    () async {
      seed(work, source('display-name = "Work"\n'));
      seed(personal, source('display-name = "Personal"\n', id: personal));
      final ordinary = await host.load(providers, work);
      final startup = await host.enumerate(
        providers,
        captureStartupIdentity: true,
      );
      final captured = startup.records.singleWhere(
        (record) => record.id == work,
      );
      final sibling = startup.records.singleWhere(
        (record) => record.id == personal,
      );
      await host.validateStartupCurrent(captured);
      await host.validateStartupCurrent(sibling);
      final bytes = file(work).readAsBytesSync();
      final modified = file(work).lastModifiedSync();
      file(work).deleteSync();
      file(work).writeAsBytesSync(bytes);
      file(work).setLastModifiedSync(modified);
      await expectLater(
        host.validateStartupCurrent(captured),
        throwsA(isA<ConfigurationConflictException>()),
      );
      await host.validateStartupCurrent(sibling);
      expect(await host.validateCurrent(ordinary), same(ordinary));
      expect(file(work).readAsBytesSync(), bytes);
    },
    skip: !Platform.isLinux,
  );

  test('startup identity rejects same-file edit and restore', () async {
    seed(work, source('display-name = "Work"\n'));
    final startup = (await host.enumerate(
      providers,
      captureStartupIdentity: true,
    )).records.single;
    final bytes = file(work).readAsBytesSync();
    final modified = file(work).lastModifiedSync();
    file(work).writeAsStringSync(source('display-name = "Edited"\n'));
    file(work).writeAsBytesSync(bytes);
    file(work).setLastModifiedSync(modified);
    await expectLater(
      host.validateStartupCurrent(startup),
      throwsA(isA<ConfigurationConflictException>()),
    );
    expect(await host.validateCurrent(startup), same(startup));
  }, skip: !Platform.isLinux);

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

  test('empty Agents collection requires no initialization', () async {
    final result = await host.enumerate(agents);
    expect(result.records, isEmpty);
    expect(result.diagnostics, isEmpty);
    expect(temporary.listSync(), isEmpty);
  });

  test(
    'record order and uniqueness use collection-scoped IDs, not basenames',
    () async {
      seed(work, source('display-name = "Personal"\n', id: personal));
      seed(personal, source('display-name = "Work"\n'));
      seed(
        work,
        source('name = "Agent"\ninstructions = ""\n', type: agent.value),
        agents,
      );
      final listing = await host.enumerate(providers);
      expect(listing.diagnostics, isEmpty);
      expect(listing.records.map((row) => (row.id, row.fileName)), [
        (personal, 'work-openai.toml'),
        (work, 'personal-openai.toml'),
      ]);
      expect((await host.load(providers, work)).values['display-name'], 'Work');
      expect((await host.load(agents, work)).values['name'], 'Agent');
    },
  );

  test(
    'a filename never substitutes for a missing or invalid recordId',
    () async {
      for (final header in [
        'recordVersion = 1',
        'recordVersion = 2',
        'recordVersion = 2\nrecordId = 42',
        'recordVersion = 2\nrecordId = ""',
        'recordVersion = 2\nrecordId = "Work"',
        'recordVersion = 2\nrecordId = "../work"',
        'recordVersion = 2\nrecordId = "con"',
        'recordVersion = 2\nrecordId = "${'x' * 1024}"',
      ]) {
        final original =
            '$header\nrecordType = "$openai"\n[values]\ndisplay-name = "Work"\n';
        seed(work, original);
        final listing = await host.enumerate(providers);
        expect(listing.records, isEmpty);
        expect(listing.diagnostics.single.fileName, 'work-openai.toml');
        expect(listing.diagnostics.single.recordId, isNull);
        expect(
          listing.diagnostics.single.error.toString(),
          isNot(contains('x' * 65)),
        );
        await expectLater(
          host.load(providers, work),
          throwsA(isA<ConfigurationRecordNotFound>()),
        );
        expect(file(work).readAsStringSync(), original);
      }
    },
  );

  test('only fresh observations follow an external rename', () async {
    final initial = await host.create(openai, work, {'display-name': 'Work'});
    expect(initial.fileName, 'work-openai.toml');
    expect(initial.document.readScalar(['recordVersion']), 2);
    expect(initial.document.readScalar(['recordId']), work.value);
    expect(initial.document.readScalar(['recordType']), openai.value);
    final original = source(
      'display-name = "Work" # note\nfuture = { nested = true }\n',
    );
    seed(work, original);
    final old = (await host.enumerate(
      providers,
      captureStartupIdentity: true,
    )).records.single;
    final previous = file(work);
    final moved = previous.renameSync(
      p.join(previous.parent.path, 'office.toml'),
    );
    final conflict = throwsA(isA<ConfigurationConflictException>());
    final ref = CredentialReference.generate();
    for (final operation in <Future<Object?> Function()>[
      () => host.create(openai, work, initial.values),
      () => host.validateCurrent(old),
      () => host.validateStartupCurrent(old),
      () => host.update(old, {'display-name': 'Stale'}),
      () => host.setCredentialReference(old, apiKey, ref),
      () => host.delete(old),
    ]) {
      await expectLater(operation(), conflict);
      expect(previous.existsSync(), isFalse);
      expect(moved.readAsStringSync(), original);
    }

    final listing = await host.enumerate(
      providers,
      captureStartupIdentity: true,
    );
    expect(listing.diagnostics, isEmpty);
    final current = listing.records.single;
    expect(current.fileName, 'office.toml');
    expect(current.id, work);
    await host.validateStartupCurrent(current);
    await expectLater(
      host.load(providers, ConfigurationRecordId('office')),
      throwsA(isA<ConfigurationRecordNotFound>()),
    );
    // This ID is free, but its initial filename is physically occupied.
    await expectLater(
      host.create(openai, ConfigurationRecordId('office'), initial.values),
      conflict,
    );
    var fresh = await host.load(providers, work);
    fresh = await host.setCredentialReference(fresh, apiKey, ref);
    fresh = await host.update(fresh, {'display-name': 'Renamed'});
    expect(fresh.fileName, 'office.toml');
    expect(fresh.credentials[apiKey], ref);
    expect(
      moved.readAsStringSync(),
      contains('# note\nfuture = { nested = true }'),
    );
    fresh = await host.setCredentialReference(fresh, apiKey, null);
    await host.delete(fresh);
    expect(moved.existsSync(), isFalse);
    expect(previous.existsSync(), isFalse);
  }, skip: !Platform.isLinux);

  test(
    'every identifiable duplicate is excluded, regardless of validity',
    () async {
      final current = await host.create(openai, work, {'display-name': 'Work'});
      final sibling = await host.create(openai, personal, {
        'display-name': 'Personal',
      });
      final captured = (await host.enumerate(
        providers,
        captureStartupIdentity: true,
      )).records.singleWhere((record) => record.id == work);
      final bytes = file(work).readAsBytesSync();
      final copies = [
        for (final name in ['a.toml', 'z.toml'])
          File(p.join(file(work).parent.path, name)),
      ];
      for (final original in [
        source('display-name = "Copy"\n'),
        source('display-name = true\n'),
        source('', type: 'dev.absent.type'),
        source(
          '',
          type: agent.value,
        ), // A declared type, but in another collection.
        source('display-name = "Copy"\n[credentials]\napi-key = false\n'),
      ]) {
        // An invalid claimant is seen both before and after the healthy one.
        for (final copy in copies) {
          copy.writeAsStringSync(original);
        }
        final listing = await host.enumerate(providers);
        expect(listing.records.single.id, personal);
        expect(listing.diagnostics.map((d) => d.fileName), [
          'a.toml',
          current.fileName,
          'z.toml',
        ]);
        expect(listing.diagnostics.map((d) => d.recordId), everyElement(work));
        final ambiguous = isA<ConfigurationRecordFormatException>().having(
          (e) => e.message,
          'message',
          contains('Multiple files'),
        );
        expect(
          listing.diagnostics.map((d) => d.error),
          everyElement(ambiguous),
        );
        await expectLater(host.load(providers, work), throwsA(ambiguous));
        for (final operation in <Future<Object?> Function()>[
          () => host.create(openai, work, current.values),
          () => host.validateCurrent(current),
          () => host.validateStartupCurrent(captured),
          () => host.update(current, {'display-name': 'Other'}),
          () => host.setCredentialReference(
            current,
            apiKey,
            CredentialReference.generate(),
          ),
          () => host.delete(current),
        ]) {
          await expectLater(
            operation(),
            throwsA(isA<ConfigurationConflictException>()),
          );
        }
        expect(file(work).readAsBytesSync(), bytes);
        for (final copy in copies) {
          expect(copy.readAsStringSync(), original);
        }
        expect(await host.validateCurrent(sibling), same(sibling));
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'an unavailable type still occupies its ID at a different filename',
    () async {
      final original = source('', type: 'dev.absent.type');
      seed(personal, original);
      final diagnostic = (await host.enumerate(providers)).diagnostics.single;
      expect(diagnostic.recordId, work);
      expect(diagnostic.fileName, 'personal-openai.toml');
      await expectLater(
        host.create(openai, work, {'display-name': 'New'}),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file(work).existsSync(), isFalse);
      expect(file(personal).readAsStringSync(), original);
    },
  );

  test(
    'a pinned malformed or missing target still conflicts on raw bytes',
    () async {
      seed(
        personal,
        source('display-name = "Work"\n'),
      ); // work ID at personal's filename
      final record = await host.load(providers, work);
      for (final bytes in <List<int>?>[
        [0xff],
        'malformed = ['.codeUnits,
        null,
      ]) {
        if (bytes == null) {
          file(personal).deleteSync();
        } else {
          file(personal).writeAsBytesSync(bytes);
        }
        for (final operation in <Future<Object?> Function()>[
          () => host.validateCurrent(record),
          () => host.update(record, record.values),
          () => host.update(record, {'display-name': 'Other'}),
          () => host.setCredentialReference(
            record,
            apiKey,
            CredentialReference.generate(),
          ),
          () => host.delete(record),
        ]) {
          await expectLater(
            operation(),
            throwsA(isA<ConfigurationConflictException>()),
          );
        }
        expect(file(work).existsSync(), isFalse);
        expect(file(personal).existsSync(), bytes != null);
        if (bytes != null) expect(file(personal).readAsBytesSync(), bytes);
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'mixed malformed records remain attributable alongside healthy records',
    () async {
      seed(work, source('display-name = "Work"\n'));
      seed(personal, 'not valid TOML = [');
      final invalidUtf8 = ConfigurationRecordId('invalid-utf8');
      file(invalidUtf8).writeAsBytesSync([0xff]);
      final missing = ConfigurationRecordId('missing-name');
      seed(missing, source('endpoint = "old"\n', id: missing));
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
      expect(result.diagnostics[0].recordId, isNull);
      expect(result.diagnostics[1].recordId, missing);
      expect(result.diagnostics[2].recordId, isNull);
      expect((await host.load(providers, work)).values['display-name'], 'Work');
      expect(() => result.records.clear(), throwsUnsupportedError);
      expect(() => result.diagnostics.clear(), throwsUnsupportedError);
      expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    },
  );

  for (final malformed in [
    'recordVersion = 1\nrecordType = "dev.adele.openai.api-key"\n[values]\ndisplay-name = "X"\n',
    'recordVersion = 3\nrecordType = "dev.adele.openai.api-key"\n[values]\ndisplay-name = "X"\n',
    'recordVersion = "2"\nrecordType = "dev.adele.openai.api-key"\n[values]\ndisplay-name = "X"\n',
    'recordType = "dev.adele.openai.api-key"\n[values]\ndisplay-name = "X"\n',
    'recordVersion = 2\nrecordType = true\n[values]\ndisplay-name = "X"\n',
    'recordVersion = 2\nrecordType = "not-a-public-id"\n[values]\n',
    'recordVersion = 2\nrecordType = "dev.absent.type"\n[values]\n',
    'recordVersion = 2\nrecordType = "dev.adele.openai.api-key"\n',
    'recordVersion = 2\nrecordType = "dev.adele.openai.api-key"\nvalues = {}\n',
    'recordVersion = 2\nrecordType = "dev.adele.openai.api-key"\n[[values]]\n',
  ]) {
    test('invalid header/table is explicit: $malformed', () async {
      final original = 'recordId = "$work"\n$malformed';
      seed(work, original);
      await expectLater(
        host.load(providers, work),
        throwsA(isA<ConfigurationRecordFormatException>()),
      );
      final listing = await host.enumerate(providers);
      expect(listing.records, isEmpty);
      expect(listing.diagnostics.single.recordId, work);
      expect(file(work).readAsStringSync(), original);
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
      final large =
          'display-name = "Name"\nunknown = "${'x' * (1000 * 1024)}"\n';
      for (var index = 0; index < 17; index++) {
        final id = ConfigurationRecordId('large-$index');
        seed(id, source(large, id: id));
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

  group('stock Model Preset structured values', () {
    final model = RecordFieldId('model');
    final id = ConfigurationRecordId('sample');
    const values = {'name': '  Preset  ', 'model': reference};
    final invalidModel = isA<InvalidRecordValue>()
        .having((e) => e.collection, 'collection', presets)
        .having((e) => e.fieldId, 'field', model);

    String presetSource(String fields) =>
        source("name = '  Preset  '\n$fields", type: preset.value, id: id);

    test('create writes a regular subtable in declaration order', () async {
      final input = Map.of(reference);
      final created = await host.create(preset, id, {
        ...values,
        'model': input,
      });
      input.clear();
      expect(created.values, values);
      expect((created.values['model'] as Map).clear, throwsUnsupportedError);
      expect(
        file(id, presets).readAsStringSync(),
        contains(
          '[values.model]\nprovider-id = "dev.example.provider.work"\nmodel-id = "  Team-A/Research:V2  "\n',
        ),
      );
      expect((await host.load(presets, id)).values, values);
    });

    test('update changes only known leaves in the original document', () async {
      final original = presetSource('''unknown = 1979-05-27 # outside

[values.model] # keep table
model-id = '  Team-A/Research:V2  ' # model note
future = { enabled = true, ids = [1, 2] } # unknown component
provider-id = 'dev.example.provider.work' # provider note

[values.model.extra.deep]
flag = true # keep nested table

[credentials]
future = ["untouched"]
''');
      seed(id, original, presets);
      final loaded = await host.load(presets, id);
      expect(loaded.values, values);
      expect(loaded.hasCredentialEntries, isTrue);

      final desired = {
        ...values,
        'model': {...reference, 'model-id': '  Custom/Model B:v3  '},
      };
      final updated = await host.update(loaded, desired);
      expect(updated.values, desired);
      expect(
        file(id, presets).readAsStringSync(),
        original.replaceFirst(
          "'  Team-A/Research:V2  '",
          '"  Custom/Model B:v3  "',
        ),
      );
      expect((await host.load(presets, id)).values, desired);
      expect(loaded.values, values);
    });

    test('missing or malformed known components invalidate the record', () async {
      await host.create(preset, personal, values);
      final healthyBytes = file(personal, presets).readAsBytesSync();
      for (final malformed in [
        '',
        'model = "not a table"',
        'model = {provider-id = "dev.example.work", model-id = "manual/A"}',
        '[[values.model]]\nprovider-id = "dev.example.work"\nmodel-id = "manual/A"',
        '[values.model]\nprovider-id = "dev.example.work"',
        '[values.model]\nprovider-id = true\nmodel-id = "manual/A"',
        '[values.model]\nprovider-id = "dev.example.work"\nmodel-id = ["manual/A"]',
        '[values.model]\nprovider-id = "bad provider"\nmodel-id = "manual/A"',
        '[values.model]\nprovider-id = "dev.example.work"\nmodel-id = "  "',
        '[values.model]\nprovider-id = "dev.example.work"\nmodel-id = "A\\tB"',
      ]) {
        final original = presetSource(malformed);
        seed(id, original, presets);
        await expectLater(
          host.load(presets, id),
          throwsA(invalidModel),
          reason: malformed,
        );
        final listing = await host.enumerate(presets);
        expect(listing.records.single.id, personal);
        expect(listing.records.single.values, values);
        expect(listing.diagnostics.single.recordId, id);
        expect(listing.diagnostics.single.error, invalidModel);
        expect(file(id, presets).readAsStringSync(), original);
        expect(file(personal, presets).readAsBytesSync(), healthyBytes);
      }
    });

    test('invalid models cannot create or partially update a preset', () async {
      final original = await host.create(preset, id, values);
      final bytes = file(id, presets).readAsBytesSync();
      for (final invalid in <Object?>[
        null,
        'manual/A',
        {'model-id': 'manual/A'},
        {...reference, 'model-id': 1},
        {...reference, 'unexpected': true},
        {...reference, 'provider-id': 'DEV.example.work'},
        {...reference, 'provider-id': 'dev.${'a' * 1021}'},
        {...reference, 'model-id': '   '},
        {...reference, 'model-id': 'manual/A\u007f'},
        {...reference, 'model-id': 'a${'\u{1f680}' * 512}'},
        {
          ...reference,
          'model-id': {'nested': true},
        },
      ]) {
        final desired = {
          'name': 'Renamed',
          'model': invalid,
          'reasoning-effort': 'low',
        };
        await expectLater(
          host.create(preset, personal, desired),
          throwsA(invalidModel),
        );
        expect(file(personal, presets).existsSync(), isFalse);
        await expectLater(
          host.update(original, desired),
          throwsA(invalidModel),
        );
        expect(file(id, presets).readAsBytesSync(), bytes);
      }
      final corrected = {
        'name': 'Renamed',
        'model': {
          'provider-id': 'dev.${'a' * 1020}',
          'model-id': '\u{1f680}' * 512,
        },
        'reasoning-effort': 'low',
      };
      await host.update(original, corrected);
      expect((await host.load(presets, id)).values, corrected);
    });

    test(
      'no-op preserves exact bytes but still checks the whole baseline',
      () async {
        final original = presetSource(
          "[values.model]\nmodel-id = '  Team-A/Research:V2  '\nprovider-id = 'dev.example.provider.work' # retained\n",
        ).replaceAll('\n', '\r\n');
        seed(id, original, presets);
        final mtime = DateTime.utc(2001);
        file(id, presets).setLastModifiedSync(mtime);
        final loaded = await host.load(presets, id);
        expect(
          await host.update(loaded, {...values, 'model': Map.of(reference)}),
          same(loaded),
        );
        expect(file(id, presets).readAsStringSync(), original);
        expect(file(id, presets).lastModifiedSync().toUtc(), mtime);
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);

        final external = '${original}unknown = 42\r\n';
        seed(id, external, presets);
        for (final desired in [
          reference,
          {...reference, 'model-id': 'new'},
        ]) {
          await expectLater(
            host.update(loaded, {...values, 'model': desired}),
            throwsA(isA<ConfigurationConflictException>()),
          );
          expect(file(id, presets).readAsStringSync(), external);
        }
      },
    );
  }, skip: !Platform.isLinux);

  group('credential associations', () {
    final reference = CredentialReference.parse('cred1_${'0' * 32}');
    final replacement = CredentialReference.parse('cred1_${'1' * 32}');

    test(
      'absent and empty credentials tables are valid without materialization',
      () async {
        for (final suffix in ['', '\n[credentials] # keep empty\n']) {
          final original = source('display-name = "Work"\n') + suffix;
          seed(work, original);
          final loaded = await host.load(providers, work);
          expect(loaded.credentials, isEmpty);
          expect(loaded.hasCredentialEntries, isFalse);
          expect(
            await host.setCredentialReference(loaded, apiKey, null),
            same(loaded),
          );
          expect(await host.validateCurrent(loaded), same(loaded));
          expect(file(work).readAsStringSync(), original);
          expect(Directory(roots.localStateRoot).existsSync(), isFalse);
        }
      },
    );

    test(
      'real OpenAI associations survive rename reload and independent record changes',
      () async {
        final original =
            '# header\n${source('display-name = "Work" # name\nunknown = { keep = [1, 2] } # untouched\n')}\n[future]\nflag = true # future\n';
        seed(work, original);
        var record = await host.load(providers, work);
        final sibling = await host.create(openai, personal, {
          'display-name': 'Personal',
        });
        final siblingBytes = file(personal).readAsBytesSync();
        record = await host.setCredentialReference(record, apiKey, reference);
        expect(record.credentials, {apiKey: reference});
        expect(record.hasCredentialEntries, isTrue);
        expect(record.values, {'display-name': 'Work'});
        expect(() => record.credentials.clear(), throwsUnsupportedError);
        const renamed = {
          'display-name': 'Renamed',
          'endpoint': 'https://work.example/v1',
        };
        record = await host.update(record, renamed);
        expect(record.id, work);
        expect(record.credentials, {apiKey: reference});
        expect(record.hasCredentialEntries, isTrue);
        expect(record.values, renamed);
        var text = file(work).readAsStringSync();
        for (final retained in [
          '# header',
          '# name',
          'unknown = { keep = [1, 2] } # untouched',
          '[future]\nflag = true # future',
        ]) {
          expect(text, contains(retained));
        }
        expect(file(personal).readAsBytesSync(), siblingBytes);
        host = ConfigurationRecordStore(
          store: ConfigurationStore(roots),
          catalog: catalog,
        );
        record = await host.load(providers, work);
        expect(record.credentials, {apiKey: reference});
        final workBytes = file(work).readAsBytesSync();
        await host.update(sibling, {'display-name': 'Other personal'});
        expect(await host.validateCurrent(record), same(record));
        expect(file(work).readAsBytesSync(), workBytes);
        record = await host.setCredentialReference(record, apiKey, replacement);
        expect(record.credentials, {apiKey: replacement});
        record = await host.setCredentialReference(record, apiKey, null);
        expect(record.credentials, isEmpty);
        expect(record.hasCredentialEntries, isFalse);
        record.document.requireTable(['credentials']);
        text = file(work).readAsStringSync();
        expect(text, contains('[credentials]'));
        expect(text, isNot(contains(reference.value)));
        expect(text, isNot(contains(replacement.value)));
        expect((await host.load(providers, work)).credentials, isEmpty);
        expect(record.values, renamed);
        await host.delete(record);
        expect(file(work).existsSync(), isFalse);
      },
    );

    test(
      'known credential entries block whole-record deletion with safe identity',
      () async {
        var record = await host.create(openai, work, {'display-name': 'Work'});
        record = await host.setCredentialReference(record, apiKey, reference);
        final bytes = file(work).readAsBytesSync();
        await expectLater(
          host.delete(record),
          throwsA(
            isA<ConfigurationRecordCredentialsPresent>()
                .having((error) => error.collection, 'collection', providers)
                .having((error) => error.recordId, 'record', work)
                .having(
                  (error) => error.toString(),
                  'safe text',
                  isNot(contains(reference.value)),
                ),
          ),
        );
        expect(file(work).readAsBytesSync(), bytes);
      },
    );

    test(
      'multiple declared slots stay independent from same-named scalar fields',
      () async {
        final nameSlot = RecordCredentialSlotId('display-name');
        final type = RecordTypeDefinition(
          id: RecordTypeId('dev.example.credentials.record'),
          owner: PluginId('dev.example.credentials'),
          collection: providers,
          collectionLabel: 'Providers',
          label: 'Credential fixture',
          fields: catalog.definition(openai).fields,
          credentialSlots: [
            for (final slot in [nameSlot, apiKey])
              RecordCredentialSlotDefinition(
                id: slot,
                label: slot.value,
                kind: RecordCredentialKind.secretText,
              ),
          ],
        );
        final generic = ConfigurationRecordStore(
          store: persistence,
          catalog: RecordCatalog([type]),
        );
        var record = await generic.create(type.id, work, {
          'display-name': 'Public',
        });
        record = await generic.setCredentialReference(
          record,
          nameSlot,
          reference,
        );
        record = await generic.setCredentialReference(
          record,
          apiKey,
          replacement,
        );
        expect(record.credentials, {nameSlot: reference, apiKey: replacement});
        record = await generic.update(record, {'display-name': 'Renamed'});
        expect(record.values, {'display-name': 'Renamed'});
        expect(
          (await generic.load(providers, work)).credentials,
          record.credentials,
        );
        record = await generic.setCredentialReference(record, nameSlot, null);
        expect(record.credentials, {apiKey: replacement});
        expect(record.hasCredentialEntries, isTrue);
        expect(record.values, {'display-name': 'Renamed'});
      },
    );

    for (final unknown in [
      '[credentials]\nfuture = "not-a-reference" # retained\n',
      '[credentials]\nfuture = "${replacement.value}" # retained\n',
      '[credentials]\nfuture = { nested = [1, 2] } # retained\n',
      '[credentials.future] # retained\n',
      '[credentials.future.deep]\nvalue = "not-a-reference" # retained\n',
      '[[credentials.future]] # retained\n',
      '[credentials]\nfuture.nested.value = true # retained\n',
      '[credentials]\n"future.with.dots" = [] # retained\n',
    ]) {
      test(
        'unknown credential content is retained and blocks deletion: $unknown',
        () async {
          seed(work, '${source('display-name = "Work"\n')}\n$unknown');
          var record = await host.load(providers, work);
          expect(record.credentials, isEmpty);
          expect(record.hasCredentialEntries, isTrue);
          record = await host.update(record, {'display-name': 'Renamed'});
          expect(record.credentials, isEmpty);
          expect(record.hasCredentialEntries, isTrue);
          record = await host.setCredentialReference(record, apiKey, reference);
          expect(record.credentials, {apiKey: reference});
          record = await host.setCredentialReference(record, apiKey, null);
          expect(record.credentials, isEmpty);
          expect(record.hasCredentialEntries, isTrue);
          expect(file(work).readAsStringSync(), contains(unknown));
          expect(
            (await host.load(providers, work)).hasCredentialEntries,
            isTrue,
          );
          final bytes = file(work).readAsBytesSync();
          for (final desired in [null, replacement]) {
            await expectLater(
              host.setCredentialReference(
                record,
                RecordCredentialSlotId('future'),
                desired,
              ),
              throwsA(isA<ConfigurationRecordFormatException>()),
            );
          }
          await expectLater(
            host.delete(record),
            throwsA(isA<ConfigurationRecordCredentialsPresent>()),
          );
          expect(file(work).readAsBytesSync(), bytes);
        },
      );
    }

    for (final malformed in [
      'api-key = "secret-canary"',
      'api-key = ""',
      'api-key = "CRED1_${'0' * 32}"',
      'api-key = "cred1_${'0' * 31}"',
      'api-key = "${reference.value}\\n"',
      'api-key = "cred1_${'0' * 31}\\u0000"',
      'api-key = false',
      'api-key = 42',
      'api-key = 1.5',
      'api-key = ["secret-canary"]',
      'api-key = { value = "secret-canary" }',
      '[credentials.api-key]\nvalue = "secret-canary"',
      '[[credentials.api-key]]\nvalue = "secret-canary"',
    ]) {
      test(
        'malformed known association has safe attributable diagnostic: $malformed',
        () async {
          final original =
              '${source('display-name = "Work"\n')}\n[credentials]\n$malformed\n';
          seed(work, original);
          seed(personal, source('display-name = "Personal"\n', id: personal));
          final safe = isA<ConfigurationRecordFormatException>()
              .having((error) => error.collection, 'collection', providers)
              .having((error) => error.recordId, 'record', work)
              .having(
                (error) => error.message,
                'fixed message',
                'Credential slot "api-key" must contain a valid credential reference.',
              );
          await expectLater(host.load(providers, work), throwsA(safe));
          final result = await host.enumerate(providers);
          expect(result.records.single.id, personal);
          expect(result.diagnostics.single.recordId, work);
          expect(result.diagnostics.single.fileName, 'work-openai.toml');
          expect(result.diagnostics.single.error, safe);
          expect(
            result.diagnostics.single.error.toString(),
            isNot(contains('secret-canary')),
          );
          expect(file(work).readAsStringSync(), original);
          expect(Directory(roots.localStateRoot).existsSync(), isFalse);
        },
      );
    }

    for (final malformed in [
      '"secret-canary"',
      'true',
      '42',
      '[]',
      '{}',
      '{ "api-key" = "secret-canary" }',
    ]) {
      test(
        'non-table credentials are unavailable without disclosing supplied content: $malformed',
        () async {
          final original =
              'credentials = $malformed\n${source('display-name = "Work"\n')}';
          seed(work, original);
          final result = await host.enumerate(providers);
          expect(result.records, isEmpty);
          expect(result.diagnostics.single.recordId, work);
          expect(
            result.diagnostics.single.error,
            isA<ConfigurationRecordFormatException>().having(
              (error) => error.message,
              'fixed message',
              'credentials must be a regular table.',
            ),
          );
          expect(file(work).readAsStringSync(), original);
        },
      );
    }

    test('array-of-tables credentials are not a regular table', () async {
      final original =
          '${source('display-name = "Work"\n')}\n[[credentials]]\napi-key = "${reference.value}"\n';
      seed(work, original);
      await expectLater(
        host.load(providers, work),
        throwsA(
          isA<ConfigurationRecordFormatException>().having(
            (error) => error.message,
            'fixed message',
            'credentials must be a regular table.',
          ),
        ),
      );
      expect(file(work).readAsStringSync(), original);
    });

    test(
      'implicit credentials tables remain editable without synthetic text changes',
      () async {
        seed(
          work,
          'credentials.api-key = "${reference.value}" # association\n${source('display-name = "Work"\n')}',
        );
        var record = await host.load(providers, work);
        expect(record.credentials, {apiKey: reference});
        record = await host.setCredentialReference(record, apiKey, replacement);
        expect(
          file(work).readAsStringSync(),
          contains(
            'credentials.api-key = "${replacement.value}" # association',
          ),
        );
        record = await host.setCredentialReference(record, apiKey, null);
        expect(record.credentials, isEmpty);
        expect(record.hasCredentialEntries, isFalse);
        expect((await host.load(providers, work)).credentials, isEmpty);
      },
    );

    test(
      'association and value changes share stale byte baselines including no-ops',
      () async {
        final initial = await host.create(openai, work, {
          'display-name': 'Work',
        });
        final associated = await host.setCredentialReference(
          initial,
          apiKey,
          reference,
        );
        for (final operation in <Future<Object?> Function()>[
          () => host.setCredentialReference(initial, apiKey, reference),
          () => host.setCredentialReference(initial, apiKey, null),
          () => host.validateCurrent(initial),
          () => host.update(initial, initial.values),
          () => host.delete(initial),
        ]) {
          await expectLater(
            operation(),
            throwsA(isA<ConfigurationConflictException>()),
          );
        }
        final renamed = await host.update(associated, {
          'display-name': 'Renamed',
        });
        for (final desired in [reference, replacement, null]) {
          await expectLater(
            host.setCredentialReference(associated, apiKey, desired),
            throwsA(isA<ConfigurationConflictException>()),
          );
        }
        final external = '${file(work).readAsStringSync()}# external bytes\n';
        file(work).writeAsStringSync(external);
        await expectLater(
          host.validateCurrent(renamed),
          throwsA(isA<ConfigurationConflictException>()),
        );
        await expectLater(
          host.setCredentialReference(renamed, apiKey, reference),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file(work).readAsStringSync(), external);
        final reloaded = await host.load(providers, work);
        expect(await host.validateCurrent(reloaded), same(reloaded));
        file(work).deleteSync();
        await expectLater(
          host.validateCurrent(reloaded),
          throwsA(isA<ConfigurationConflictException>()),
        );
        expect(file(work).existsSync(), isFalse);
      },
    );

    test(
      'equal association and validation preserve exact BOM CRLF bytes and mtime',
      () async {
        final original =
            '\uFEFF# header\r\nrecordVersion = 0x2\r\nrecordId = "$work"\r\nrecordType = "dev.adele.openai.api-key"\r\n[values]\r\ndisplay-name = \'Work\'\r\n[credentials]\r\napi-key = \'${reference.value}\' # keep\r\n';
        seed(work, original);
        final bytes = file(work).readAsBytesSync();
        final modified = DateTime.utc(2001);
        file(work).setLastModifiedSync(modified);
        final loaded = await host.load(providers, work);
        expect(
          await host.setCredentialReference(loaded, apiKey, reference),
          same(loaded),
        );
        expect(await host.validateCurrent(loaded), same(loaded));
        expect(file(work).readAsBytesSync(), bytes);
        expect(file(work).lastModifiedSync().toUtc(), modified);
        expect(Directory(roots.localStateRoot).existsSync(), isFalse);
      },
    );
  }, skip: !Platform.isLinux);

  group('conditional record CRUD', () {
    for (final (type, collection, field, values) in [
      (agent, agents, 'name', {'name': '  Reviewer  ', 'instructions': ''}),
      (preset, presets, 'name', {'name': '  Preset  ', 'model': reference}),
      (openai, providers, 'display-name', {'display-name': '  Work  '}),
      // The host enforces string constraints, not a provider's URL policy.
      (
        openai,
        providers,
        'endpoint',
        {'display-name': 'Work', 'endpoint': '  Custom Endpoint  '},
      ),
    ]) {
      test(
        '$type $field rejects invalid writes and diagnoses legacy bytes',
        () async {
          final invalidField = isA<InvalidRecordValue>()
              .having((error) => error.collection, 'collection', collection)
              .having((error) => error.fieldId, 'field', RecordFieldId(field));
          for (final invalid in ['', '   ', 'a\tb', 'a\u007fb']) {
            await expectLater(
              host.create(type, personal, {...values, field: invalid}),
              throwsA(invalidField),
            );
          }
          expect(temporary.listSync(), isEmpty);

          final healthy = await host.create(type, work, values);
          final bytes = file(work, collection).readAsBytesSync();
          await expectLater(
            host.update(healthy, {...values, field: '   '}),
            throwsA(invalidField),
          );
          // Seed parseable legacy TOML directly, bypassing the validating writer.
          final original = healthy.document
              .setScalar(['recordId'], personal.value)
              .setScalar(['values', field], '   ')
              .source;
          seed(personal, original, collection);
          await expectLater(
            host.load(collection, personal),
            throwsA(invalidField),
          );
          final listing = await host.enumerate(collection);
          expect(listing.records.single.id, work);
          expect(listing.records.single.values, values);
          expect(listing.diagnostics.single.recordId, personal);
          expect(listing.diagnostics.single.error, invalidField);
          expect(file(personal, collection).readAsStringSync(), original);
          expect(file(work, collection).readAsBytesSync(), bytes);
        },
      );
    }

    test(
      'real Agent definitions retain Markdown and identity across rename deletion and restart',
      () async {
        final reviewer = ConfigurationRecordId('reviewer');
        final writer = ConfigurationRecordId('writer');
        final reviewerFile = File(
          p.join(roots.configurationRoot, 'agents', 'reviewer.toml'),
        );
        final writerFile = File(
          p.join(roots.configurationRoot, 'agents', 'writer.toml'),
        );
        const reviewValues = {
          'name': 'Reviewer',
          'description':
              '# Review\n\nExplain **risks**, "quotes", and `C:\\repo`.',
          'when-to-use':
              'For a pull request:\n- Review changes.\n- Check tests.\n',
          'instructions': r'''# Instructions

Keep "double quotes", 'single quotes', and backslashes: C:\repo\src.

```dart
final path = r'C:\repo';
print("Review the diff");
```

Return **findings** before the summary.
''',
        };
        const writerValues = {
          'name': 'Writer',
          'instructions':
              'Write a focused patch.\n\nPreserve existing behavior.',
        };
        await host.create(agent, reviewer, reviewValues);
        await host.create(agent, writer, writerValues);
        final writerBytes = writerFile.readAsBytesSync();

        host = ConfigurationRecordStore(
          store: ConfigurationStore(roots),
          catalog: catalog,
        );
        var result = await host.enumerate(agents);
        expect(result.diagnostics, isEmpty);
        expect(result.records.map((record) => record.id), [reviewer, writer]);
        var review = await host.load(agents, reviewer);
        final writing = await host.load(agents, writer);
        expect(review.values, reviewValues);
        expect(writing.values, writerValues);
        expect(review.credentials, isEmpty);
        expect(review.hasCredentialEntries, isFalse);

        review = await host.update(review, {
          ...reviewValues,
          'name': 'Renamed Reviewer',
        });
        expect(review.id, reviewer);
        expect(review.collection, agents);
        expect(review.type.id, agent);
        expect(reviewerFile.existsSync(), isTrue);
        expect(
          reviewerFile.parent.listSync().map((entry) => p.basename(entry.path)),
          unorderedEquals(['reviewer.toml', 'writer.toml']),
        );
        expect(writerFile.readAsBytesSync(), writerBytes);
        final reviewBytes = reviewerFile.readAsBytesSync();

        await host.delete(writing);
        expect(writerFile.existsSync(), isFalse);
        expect(reviewerFile.readAsBytesSync(), reviewBytes);
        host = ConfigurationRecordStore(
          store: ConfigurationStore(roots),
          catalog: catalog,
        );
        result = await host.enumerate(agents);
        expect(result.diagnostics, isEmpty);
        expect(result.records.single.id, reviewer);
        expect(result.records.single.values, {
          ...reviewValues,
          'name': 'Renamed Reviewer',
        });
        await expectLater(
          host.load(agents, writer),
          throwsA(isA<ConfigurationRecordNotFound>()),
        );

        await host.delete(result.records.single);
        host = ConfigurationRecordStore(
          store: ConfigurationStore(roots),
          catalog: catalog,
        );
        result = await host.enumerate(agents);
        expect(result.records, isEmpty);
        expect(result.diagnostics, isEmpty);
        expect(reviewerFile.parent.listSync(), isEmpty);
        expect(File(persistence.filePath).existsSync(), isFalse);
        expect(Directory(roots.localDataRoot).existsSync(), isFalse);
        expect(Directory(roots.cacheRoot).existsSync(), isFalse);
      },
    );

    test(
      'Agent fields distinguish missing values from permitted empty strings',
      () async {
        final id = ConfigurationRecordId('minimal');
        for (final missing in ['name', 'instructions']) {
          await expectLater(
            host.create(agent, id, {
              if (missing != 'name') 'name': 'Agent',
              if (missing != 'instructions') 'instructions': '',
            }),
            throwsA(
              isA<InvalidRecordValue>().having(
                (error) => error.fieldId,
                'missing field',
                RecordFieldId(missing),
              ),
            ),
          );
        }
        expect(temporary.listSync(), isEmpty);

        const requiredValues = {'name': 'Agent', 'instructions': ''};
        var record = await host.create(agent, id, requiredValues);
        expect((await host.load(agents, id)).values, requiredValues);
        record = await host.update(record, {
          ...requiredValues,
          'description': '',
          'when-to-use': '',
        });
        expect((await host.load(agents, id)).values, {
          ...requiredValues,
          'description': '',
          'when-to-use': '',
        });
        await host.update(record, requiredValues);
        expect((await host.load(agents, id)).values, requiredValues);
      },
    );

    group('exact directory capacity', () {
      void fillWithUserFiles(Directory directory, int totalEntries) {
        directory.createSync(recursive: true);
        final fixtures = <File, List<int>>{};
        // Seed directly: only a few entries need native parsing/schema validation.
        for (
          var index = directory.listSync().length;
          index < totalEntries;
          index++
        ) {
          final name = '${index.isEven ? '.' : ''}user-$index.txt';
          final fixture = File(p.join(directory.path, name));
          final bytes = 'malformed user content = [$index\n'.codeUnits;
          fixture.writeAsBytesSync(bytes);
          fixtures[fixture] = bytes;
        }
        expect(directory.listSync(), hasLength(totalEntries));
        addTearDown(() {
          for (final entry in fixtures.entries) {
            expect(
              entry.key.readAsBytesSync(),
              entry.value,
              reason:
                  'Unrelated user file must be preserved: ${entry.key.path}',
            );
          }
          expect(
            Directory(roots.configurationRoot)
                .listSync(recursive: true, followLinks: false)
                .whereType<Directory>()
                .map((entry) => entry.path),
            everyElement(file(work).parent.path),
          );
          expect(File(persistence.filePath).existsSync(), isFalse);
          expect(Directory(roots.localDataRoot).existsSync(), isFalse);
          expect(Directory(roots.cacheRoot).existsSync(), isFalse);
        });
      }

      test('collection grows from 1023 to 1024 usable entries', () async {
        seed(work, source('display-name = "Work"\n'));
        final workBytes = file(work).readAsBytesSync();
        final collection = file(work).parent;
        fillWithUserFiles(collection, 1023);

        final created = await host.create(openai, personal, {
          'display-name': 'Personal',
        });

        expect(collection.listSync(), hasLength(1024));
        expect(Directory(roots.configurationRoot).listSync(), hasLength(1));
        expect(file(work).readAsBytesSync(), workBytes);
        expect((await host.load(providers, personal)).values, created.values);
        final result = await host.enumerate(providers);
        expect(result.records.map((record) => record.id), [personal, work]);
        expect(result.diagnostics, hasLength(1022));
        expect(
          result.diagnostics.map((failure) => failure.error),
          everyElement(isA<FormatException>()),
        );
        expect(
          result.diagnostics.map((failure) => failure.fileName),
          contains('.user-2.txt'),
        );
      });

      test(
        'collection at 1024 rejects the next identity without growth',
        () async {
          seed(work, source('display-name = "Work"\n'));
          final workBytes = file(work).readAsBytesSync();
          final collection = file(work).parent;
          fillWithUserFiles(collection, 1024);

          await expectLater(
            host.create(openai, personal, {'display-name': 'Personal'}),
            throwsA(
              isA<ConfigurationLimitException>()
                  .having((error) => error.path, 'path', collection.path)
                  .having((error) => error.limit, 'bound', 1024)
                  .having((error) => error.unit, 'unit', 'entries'),
            ),
          );

          expect(file(personal).existsSync(), isFalse);
          expect(collection.listSync(), hasLength(1024));
          expect(Directory(roots.configurationRoot).listSync(), hasLength(1));
          expect(file(work).readAsBytesSync(), workBytes);
          expect(
            (await host.load(providers, work)).values['display-name'],
            'Work',
          );
          final result = await host.enumerate(providers);
          expect(result.records.single.id, work);
          expect(result.diagnostics, hasLength(1023));
        },
      );

      test(
        'full root and collection still allow existing updates and deletes',
        () async {
          seed(work, source('display-name = "Work"\n'));
          seed(personal, source('display-name = "Personal"\n', id: personal));
          final personalBytes = file(personal).readAsBytesSync();
          final collection = file(work).parent;
          final root = Directory(roots.configurationRoot);
          fillWithUserFiles(collection, 1024);
          fillWithUserFiles(root, 1024);
          final loadedWork = await host.load(providers, work);
          final loadedPersonal = await host.load(providers, personal);

          final updated = await host.update(loadedWork, {
            'display-name': 'Renamed',
          });

          expect(collection.listSync(), hasLength(1024));
          expect(root.listSync(), hasLength(1024));
          expect(file(personal).readAsBytesSync(), personalBytes);
          expect((await host.load(providers, work)).values, updated.values);
          var result = await host.enumerate(providers);
          expect(result.records.map((record) => record.id), [personal, work]);
          expect(result.diagnostics, hasLength(1022));
          final workBytes = file(work).readAsBytesSync();

          await host.delete(loadedPersonal);

          expect(file(personal).existsSync(), isFalse);
          expect(collection.listSync(), hasLength(1023));
          expect(root.listSync(), hasLength(1024));
          expect(file(work).readAsBytesSync(), workBytes);
          result = await host.enumerate(providers);
          expect(result.records.single.values['display-name'], 'Renamed');
          expect(result.diagnostics, hasLength(1022));
        },
      );

      test('full collection never overwrites an occupied identity', () async {
        seed(work, source('display-name = "Work"\n'));
        seed(personal, 'malformed = [');
        final workBytes = file(work).readAsBytesSync();
        final personalBytes = file(personal).readAsBytesSync();
        final collection = file(work).parent;
        fillWithUserFiles(collection, 1024);

        for (final id in [work, personal]) {
          await expectLater(
            host.create(openai, id, {'display-name': 'Replacement'}),
            throwsA(isA<ConfigurationConflictException>()),
          );
        }

        expect(collection.listSync(), hasLength(1024));
        expect(Directory(roots.configurationRoot).listSync(), hasLength(1));
        expect(file(work).readAsBytesSync(), workBytes);
        expect(file(personal).readAsBytesSync(), personalBytes);
        expect(
          (await host.load(providers, work)).values['display-name'],
          'Work',
        );
        final result = await host.enumerate(providers);
        expect(result.records.single.id, work);
        expect(result.diagnostics, hasLength(1023));
        expect(
          result.diagnostics
              .singleWhere(
                (failure) => failure.fileName == 'personal-openai.toml',
              )
              .error,
          isA<TomlException>(),
        );
      });

      test('root at 1023 admits its first collection as entry 1024', () async {
        final root = Directory(roots.configurationRoot);
        final collection = file(work).parent;
        fillWithUserFiles(root, 1023);
        expect(collection.existsSync(), isFalse);

        final created = await host.create(openai, work, {
          'display-name': 'Work',
        });

        expect(root.listSync(), hasLength(1024));
        expect(collection.listSync().map((entry) => p.basename(entry.path)), [
          'work-openai.toml',
        ]);
        expect((await host.load(providers, work)).values, created.values);
        final result = await host.enumerate(providers);
        expect(result.records.single.id, work);
        expect(result.diagnostics, isEmpty);
      });

      test(
        'root at 1024 rejects a missing collection without creating it',
        () async {
          final root = Directory(roots.configurationRoot);
          final collection = file(work).parent;
          fillWithUserFiles(root, 1024);
          expect(collection.existsSync(), isFalse);

          await expectLater(
            host.create(openai, work, {'display-name': 'Work'}),
            throwsA(
              isA<ConfigurationLimitException>()
                  .having((error) => error.path, 'path', root.path)
                  .having((error) => error.limit, 'bound', 1024)
                  .having((error) => error.unit, 'unit', 'entries'),
            ),
          );

          expect(root.listSync(), hasLength(1024));
          expect(collection.existsSync(), isFalse);
          expect(file(work).existsSync(), isFalse);
          final result = await host.enumerate(providers);
          expect(result.records, isEmpty);
          expect(result.diagnostics, isEmpty);
        },
      );

      test(
        'root at 1024 admits a record into an existing collection at 1023',
        () async {
          seed(work, source('display-name = "Work"\n'));
          final workBytes = file(work).readAsBytesSync();
          final collection = file(work).parent;
          final root = Directory(roots.configurationRoot);
          fillWithUserFiles(collection, 1023);
          fillWithUserFiles(root, 1024);

          final created = await host.create(openai, personal, {
            'display-name': 'Personal',
          });

          expect(root.listSync(), hasLength(1024));
          expect(collection.listSync(), hasLength(1024));
          expect(file(work).readAsBytesSync(), workBytes);
          expect((await host.load(providers, personal)).values, created.values);
          final result = await host.enumerate(providers);
          expect(result.records.map((record) => record.id), [personal, work]);
          expect(result.diagnostics, hasLength(1022));
        },
      );

      group('staged publication readers', () {
        late Directory build;
        late String kernel;

        setUpAll(() async {
          build = Directory.systemTemp.createTempSync('adele-record-readers-');
          kernel = await prepareWriter(
            build,
            source: 'test/fixtures/record_reader.dart',
          );
        });
        tearDownAll(() => build.deleteSync(recursive: true));

        for (final atCapacity in [false, true]) {
          test(
            'enumerate and load exclude staging ${atCapacity ? 'at 1024 root and collection entries' : 'below capacity'}',
            () async {
              seed(work, source('display-name = "Work"\n'));
              seed(
                personal,
                source('display-name = "Personal"\n', id: personal),
              );
              final workBytes = file(work).readAsBytesSync();
              final personalBytes = file(personal).readAsBytesSync();
              final collection = file(work).parent;
              final root = Directory(roots.configurationRoot);
              final collectionCount = atCapacity ? 1024 : 4;
              final rootCount = atCapacity ? 1024 : 3;
              fillWithUserFiles(collection, collectionCount);
              fillWithUserFiles(root, rootCount);
              final before = await host.enumerate(providers);
              expect(before.records.map((record) => record.id), [
                personal,
                work,
              ]);
              expect(before.diagnostics, hasLength(collectionCount - 2));

              final writer = await ConfigurationWriter.start(
                kernel,
                temporary.path,
                'pause',
                '1',
                work.value,
                providers.value,
              );
              await writer.expectLine('loaded');
              writer.process.stdin.writeln('save');
              await writer.expectLine('saving');
              await writer.expectLine('staged');
              expect(file(work).readAsBytesSync(), workBytes);
              expect(collection.listSync(), hasLength(collectionCount + 1));
              expect(
                collection.listSync().whereType<Directory>(),
                hasLength(1),
              );

              final listing = await ConfigurationWriter.start(
                kernel,
                temporary.path,
                'host-list',
                '0',
                personal.value,
                providers.value,
                installations.path,
              );
              await listing.expectLine('listing');
              await listing.expectLine('waiting');
              final loading = await ConfigurationWriter.start(
                kernel,
                temporary.path,
                'host-load',
                '0',
                personal.value,
                providers.value,
                installations.path,
              );
              await loading.expectLine('loading');
              await loading.expectLine('waiting');

              // Both actual host preflights reached the held read-lock boundary.
              // Publishing earlier would let an unlocked reader pass by chance.
              writer.process.stdin.writeln('publish');
              await writer.expectLine('committed');
              await listing.expectLine('listed:2:${collectionCount - 2}');
              await loading.expectLine('loaded:personal-openai:Personal');
              await writer.expectExit();
              await listing.expectExit();
              await loading.expectExit();

              expect(collection.listSync(), hasLength(collectionCount));
              expect(root.listSync(), hasLength(rootCount));
              expect(file(personal).readAsBytesSync(), personalBytes);
              final after = await host.enumerate(providers);
              expect(after.records.map((record) => record.id), [
                personal,
                work,
              ]);
              expect(
                after.diagnostics.map((failure) => failure.fileName),
                before.diagnostics.map((failure) => failure.fileName),
              );
              expect(
                after.diagnostics.map((failure) => failure.error),
                everyElement(isA<FormatException>()),
              );
              final updated = await host.load(providers, work);
              expect(updated.values['display-name'], 'Work');
              expect(updated.document.readScalar(['value']), 1);
            },
            timeout: const Timeout(Duration(minutes: 3)),
          );
        }
      });
    });

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
            '\uFEFF# header\nrecordVersion = 0x2\nrecordId = "$work"\nrecordType = "dev.adele.openai.api-key"\n\n[values]\ndisplay-name = "Work" # comment\n';
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
        const edited = {
          'display-name': '  Work  ',
          'endpoint': '  Custom Endpoint  ',
        };
        loaded = await host.update(loaded, edited);
        expect((await host.load(providers, work)).values, edited);
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
        throwsA(isA<ConfigurationRecordNotFound>()),
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
      final diagnostic = (await host.enumerate(providers)).diagnostics.single;
      expect(diagnostic.recordId, isNull);
      expect(diagnostic.fileName, 'work-openai.toml');
      expect(diagnostic.error, isA<ConfigurationSymlinkException>());
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
        await expectLater(
          otherCatalog.validateCurrent(loaded),
          throwsArgumentError,
        );
        await expectLater(
          otherCatalog.setCredentialReference(
            loaded,
            apiKey,
            CredentialReference.generate(),
          ),
          throwsArgumentError,
        );
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
        await expectLater(
          otherRoot.validateCurrent(loaded),
          throwsArgumentError,
        );
        await expectLater(
          otherRoot.setCredentialReference(
            loaded,
            apiKey,
            CredentialReference.generate(),
          ),
          throwsArgumentError,
        );
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
      seed(personal, source('', type: otherType.id.value));
      final ambiguous = await generic.enumerate(providers);
      expect(ambiguous.records, isEmpty);
      expect(ambiguous.diagnostics.map((d) => d.fileName), [
        'personal-openai.toml',
        'work-openai.toml',
      ]);
      expect(ambiguous.diagnostics.map((d) => d.recordId), everyElement(work));
      await expectLater(
        generic.load(providers, work),
        throwsA(isA<ConfigurationRecordFormatException>()),
      );
      file(personal).deleteSync();
      seed(work, source('', type: otherType.id.value));
      await expectLater(
        generic.update(original, original.values),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect((await generic.load(providers, work)).type.id, otherType.id);
    });

    for (final fieldCount in [1, 2]) {
      test(
        'removing a dotted $fieldCount-field values table is correctable prewrite validation',
        () async {
          final type = RecordTypeDefinition(
            id: RecordTypeId('dev.example.optional.type'),
            owner: PluginId('dev.example.optional'),
            collection: providers,
            collectionLabel: 'Providers',
            label: 'Optional values',
            fields: [
              for (final field in ['a', 'b'].take(fieldCount))
                RecordFieldDefinition(
                  id: RecordFieldId(field),
                  label: field,
                  type: const StringSettingType(),
                  required: false,
                ),
            ],
          );
          final generic = ConfigurationRecordStore(
            store: persistence,
            catalog: RecordCatalog([type]),
          );
          final original =
              'recordVersion = 2\nrecordId = "$work"\nrecordType = "dev.example.optional.type"\nvalues.a = "value"\n';
          seed(work, original);
          final loaded = await generic.load(providers, work);
          await expectLater(
            generic.update(loaded, {}),
            throwsA(isA<InvalidRecordValue>()),
          );
          expect(file(work).readAsStringSync(), original);
          final corrected = await generic.update(loaded, {'a': 'Corrected'});
          expect(corrected.values, {'a': 'Corrected'});
          expect(loaded.values, {'a': 'value'});
          seed(work, source('a = "value"\n', type: type.id.value));
          final explicit = await generic.load(providers, work);
          await generic.update(explicit, {});
          expect((await generic.load(providers, work)).values, isEmpty);
        },
      );
    }
  }, skip: !Platform.isLinux);
}
