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
    final prepared = await PreparedPluginCatalog.discover(installations.path);
    expect(prepared.issues, isEmpty);
    catalog = prepared.records;
    expect(catalog.definition(openai).owner, PluginId('dev.adele.openai'));
    expect(catalog.definition(openai).credentialSlots.single.id, apiKey);
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
      seed(personal, source('display-name = "Personal"\n'));
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
        record = await host.update(record, {
          'display-name': 'Renamed',
          'endpoint': '',
        });
        expect(record.id, work);
        expect(record.credentials, {apiKey: reference});
        expect(record.hasCredentialEntries, isTrue);
        expect(record.values, {'display-name': 'Renamed', 'endpoint': ''});
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
        expect(record.values, {'display-name': 'Renamed', 'endpoint': ''});
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
          seed(personal, source('display-name = "Personal"\n'));
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
            '\uFEFF# header\r\nrecordVersion = 0x1\r\nrecordType = "dev.adele.openai.api-key"\r\n[values]\r\ndisplay-name = \'Work\'\r\n[credentials]\r\napi-key = \'${reference.value}\' # keep\r\n';
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
          seed(personal, source('display-name = "Personal"\n'));
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
              .singleWhere((failure) => failure.recordId == personal)
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
              seed(personal, source('display-name = "Personal"\n'));
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
          const original =
              'recordVersion = 1\nrecordType = "dev.example.optional.type"\nvalues.a = "value"\n';
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
