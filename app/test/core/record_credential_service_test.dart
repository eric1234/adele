import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/backend_artifacts.dart';

const _firstSecret = 'test-only-record-first-secret';
const _secondSecret = 'test-only-record-second-secret';
const _replacement = 'test-only-record-replacement-secret';
const _nativeDiagnostic = 'test-only-native-diagnostic';
final _providers = RecordCollectionId('providers');
final _openai = RecordTypeId('dev.adele.openai.api-key');
final _fixtureType = RecordTypeId('dev.example.credentials.account');
final _apiKey = RecordCredentialSlotId('api-key');
final _secondary = RecordCredentialSlotId('secondary');
final _transferred = CredentialReference.parse(
  'cred1_0123456789abcdef0123456789abcdef',
);

void main() {
  late Directory installations;
  late RecordCatalog catalog;
  late Directory temporary;
  late PlatformStorageRoots roots;
  late GlobalSettingsService settings;
  late _Storage storage;
  late CredentialService credentials;
  late RecordCredentialService service;

  setUpAll(() async {
    installations = Directory.systemTemp.createTempSync(
      'adele-record-credential-schemas-',
    );
    var repository = Directory.current;
    while (!File('${repository.path}/tools/adele.dart').existsSync()) {
      if (repository.parent.path == repository.path) {
        throw StateError('Repository root not found.');
      }
      repository = repository.parent;
    }
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: Directory('${installations.path}/openai'),
      pluginId: 'dev.adele.openai',
      displayName: 'OpenAI',
    );
    final prepared = await PreparedPluginCatalog.discover(installations.path);
    expect(prepared.issues, isEmpty);
    final openai = prepared.records.definition(_openai);
    expect(openai.owner, PluginId('dev.adele.openai'));
    expect(openai.credentialSlots.single.id, _apiKey);
    expect(openai.fields.map((field) => field.id.value), [
      'display-name',
      'endpoint',
    ]);
    catalog = RecordCatalog([
      ...prepared.records.definitions,
      RecordTypeDefinition(
        id: _fixtureType,
        owner: PluginId('dev.example.credentials'),
        collection: _providers,
        collectionLabel: openai.collectionLabel,
        label: 'Test account',
        fields: openai.fields,
        credentialSlots: [
          ...openai.credentialSlots,
          RecordCredentialSlotDefinition(
            id: _secondary,
            label: 'Secondary credential',
            kind: RecordCredentialKind.secretText,
          ),
        ],
      ),
    ]);
  });
  tearDownAll(() => installations.deleteSync(recursive: true));

  GlobalSettingsService createOwner() {
    final owner = GlobalSettingsService(
      catalog: SettingsCatalog([]),
      roots: roots,
      records: catalog,
    );
    addTearDown(owner.close);
    return owner;
  }

  RecordCredentialService coordinate(
    GlobalSettingsService owner,
    CredentialService credentialOwner,
  ) {
    final coordinator = RecordCredentialService(
      settings: owner,
      credentials: credentialOwner,
    );
    addTearDown(coordinator.close);
    return coordinator;
  }

  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'adele-record-credentials-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    settings = createOwner();
    storage = _Storage();
    credentials = CredentialService(storage);
    addTearDown(credentials.close);
    service = coordinate(settings, credentials);
  });

  File file(RecordView record) => File(
    '${settings.collectionPath(record.collection)}/${record.id.value}.toml',
  );

  Future<RecordView> create(
    String id, {
    RecordTypeId? type,
    String name = 'Shared display name',
  }) => settings.createRecord(type ?? _openai, ConfigurationRecordId(id), {
    'display-name': name,
    'endpoint': 'https://example.invalid/v1',
  });

  Future<RecordView> reload(RecordView record) async =>
      (await settings.loadRecords(
        record.collection,
      )).records.singleWhere((candidate) => candidate.id == record.id);

  CredentialReference reference(
    RecordView record, [
    RecordCredentialSlotId? slot,
  ]) => CredentialReference.parse(
    ConfigurationStore(roots)
            .recordFile(
              collectionId: record.collection.value,
              recordId: record.id.value,
            )
            .load()
            .document
            .readScalar(['credentials', (slot ?? _apiKey).value])
        as String,
  );

  Future<RecordView> transferredRecord(String id) async {
    final record = await create(id);
    file(record).writeAsStringSync(
      '${file(record).readAsStringSync()}\n[credentials]\n'
      'api-key = "${_transferred.value}"\n',
    );
    return reload(record);
  }

  Future<RecordView> attach(
    RecordView record, [
    String secret = _firstSecret,
  ]) async {
    final result = await service.attach(
      record,
      _apiKey,
      CredentialSecret(secret),
    );
    _expectResult(result, RecordCredentialStatus.stored, record);
    expect(result.record, isNot(same(record)));
    return result.record;
  }

  Future<void> expectRetired(RecordView record) async {
    await _expectFailure(
      () => service.replace(record, _apiKey, CredentialSecret(_replacement)),
      RecordCredentialFailureKind.staleRecord,
    );
    await expectLater(
      settings.updateRecord(record, record.values),
      throwsA(isA<ConfigurationConflictException>()),
    );
  }

  group('record credential associations', () {
    test(
      'construction and inspection without a reference do not access storage',
      () async {
        expect(storage.calls, isEmpty);
        expect(temporary.listSync(), isEmpty);
        final record = await create('work');
        final before = file(record).readAsBytesSync();
        _expectResult(
          await service.inspect(record, _apiKey),
          RecordCredentialStatus.noReference,
          record,
        );
        _expectResult(
          await service.reconcile(record, _apiKey),
          RecordCredentialStatus.noReference,
          record,
        );
        expect(storage.calls, isEmpty);
        expect(file(record).readAsBytesSync(), before);
        await settings.deleteRecord(record);
      },
    );

    test(
      'two OpenAI records retain independent references and protected secrets',
      () async {
        final first = await create('work');
        final second = await create('personal');
        final storedFirst = await attach(first);
        final firstBytes = file(first).readAsBytesSync();
        final storedSecond = await attach(second, _secondSecret);
        final firstRef = reference(storedFirst);
        final secondRef = reference(storedSecond);
        expect(firstRef, isNot(secondRef));
        expect(storage.values.keys.toSet(), {firstRef, secondRef});
        _expectEnvelope(
          storage,
          firstRef,
          storedFirst,
          _apiKey,
          _firstSecret,
          catalog,
        );
        _expectEnvelope(
          storage,
          secondRef,
          storedSecond,
          _apiKey,
          _secondSecret,
          catalog,
        );
        expect(file(first).readAsBytesSync(), firstBytes);
        for (final record in [storedFirst, storedSecond]) {
          _expectResult(
            await service.inspect(record, _apiKey),
            RecordCredentialStatus.stored,
            record,
          );
          expect(record.values.keys, ['display-name', 'endpoint']);
          expect(() => record.values.clear(), throwsUnsupportedError);
          _expectRedacted(file(record).readAsStringSync());
          _expectRedacted('$record ${record.values}');
        }
        await expectRetired(first);
        await expectRetired(second);
        // Rejection of an old revision cannot retire either current record.
        final renamed = await settings.updateRecord(storedFirst, {
          'display-name': 'Renamed',
        });
        expect(reference(renamed), firstRef);
        _expectResult(
          await service.inspect(renamed, _apiKey),
          RecordCredentialStatus.stored,
          renamed,
        );
        _expectResult(
          await service.inspect(storedSecond, _apiKey),
          RecordCredentialStatus.stored,
          storedSecond,
        );
      },
    );

    test(
      'reconstruction uses persisted references, never display names',
      () async {
        final first = await attach(await create('work'));
        final second = await attach(await create('personal'), _secondSecret);
        final references = [reference(first), reference(second)];
        final bytes = [
          file(first).readAsBytesSync(),
          file(second).readAsBytesSync(),
        ];
        await service.close();
        await credentials.close();
        await settings.close();
        final reopenedSettings = createOwner();
        final reopenedStorage = _Storage(values: storage.values);
        final reopenedCredentials = CredentialService(reopenedStorage);
        addTearDown(reopenedCredentials.close);
        final reopened = coordinate(reopenedSettings, reopenedCredentials);
        expect(reopenedStorage.calls, isEmpty);
        final loaded = await reopenedSettings.loadRecords(_providers);
        expect(loaded.diagnostics, isEmpty);
        for (var i = 0; i < 2; i++) {
          final record = loaded.records.singleWhere(
            (candidate) => candidate.id == [first, second][i].id,
          );
          expect(reference(record), references[i]);
          _expectResult(
            await reopened.inspect(record, _apiKey),
            RecordCredentialStatus.stored,
            record,
          );
          expect(file(record).readAsBytesSync(), bytes[i]);
        }
        expect(reopenedStorage.calls.map((call) => call.$1), ['read', 'read']);
      },
    );

    test(
      'replace refreshes the handle but preserves all record bytes and identity',
      () async {
        var record = await create('work');
        file(record).writeAsStringSync(
          '# preserved header\n${file(record).readAsStringSync()}'
          '\n[future]\nunknown = [1, 2] # preserved\n',
        );
        record = await attach(await reload(record));
        final ref = reference(record);
        final before = file(record).readAsBytesSync();
        final modified = DateTime.utc(2001);
        file(record).setLastModifiedSync(modified);
        final replaced = await service.replace(
          record,
          _apiKey,
          CredentialSecret(_replacement),
        );
        _expectResult(replaced, RecordCredentialStatus.stored, record);
        expect(replaced.record, isNot(same(record)));
        expect(reference(replaced.record), ref);
        expect(file(record).readAsBytesSync(), before);
        expect(file(record).lastModifiedSync().toUtc(), modified);
        _expectEnvelope(
          storage,
          ref,
          replaced.record,
          _apiKey,
          _replacement,
          catalog,
        );
        await expectRetired(record);
        _expectResult(
          await service.inspect(replaced.record, _apiKey),
          RecordCredentialStatus.stored,
          replaced.record,
        );
      },
    );

    test(
      'ordinary update preserves refs and deletion requires explicit forget',
      () async {
        final record = await attach(await create('work'));
        final ref = reference(record);
        final updated = await settings.updateRecord(record, {
          'display-name': 'Changed ordinary fields',
        });
        expect(reference(updated), ref);
        final before = file(updated).readAsBytesSync();
        final calls = List.of(storage.calls);
        await expectLater(
          settings.deleteRecord(updated),
          throwsA(isA<ConfigurationRecordCredentialsPresent>()),
        );
        expect(file(updated).readAsBytesSync(), before);
        expect(storage.calls, calls);
        final forgotten = await service.forget(updated, _apiKey);
        _expectResult(forgotten, RecordCredentialStatus.noReference, updated);
        expect(forgotten.record, isNot(same(updated)));
        expect(storage.values, isEmpty);
        expect(file(updated).existsSync(), isTrue);
        expect(file(updated).readAsStringSync(), isNot(contains(ref.value)));
        await expectRetired(updated);
        await settings.deleteRecord(forgotten.record);
        expect(file(updated).existsSync(), isFalse);
      },
    );

    for (final unknown in [
      'future-slot = "opaque-future-value"\n',
      'future-slot = { nested = "unknown" }\n',
      '[credentials.future-slot]\nvalue = "unknown"\n',
      '[[credentials.future-slot]]\nvalue = "unknown"\n',
    ]) {
      test(
        'generic deletion guards unknown persisted credentials: $unknown',
        () async {
          var record = await create('work');
          file(record).writeAsStringSync(
            '${file(record).readAsStringSync()}\n[credentials]\n$unknown',
          );
          record = await reload(record);
          final before = file(record).readAsBytesSync();
          await expectLater(
            settings.deleteRecord(record),
            throwsA(isA<ConfigurationRecordCredentialsPresent>()),
          );
          expect(file(record).readAsBytesSync(), before);
          final updated = await settings.updateRecord(record, {
            'display-name': 'Safe ordinary edit',
          });
          expect(file(record).readAsStringSync(), contains(unknown));
          await expectLater(
            settings.deleteRecord(updated),
            throwsA(isA<ConfigurationRecordCredentialsPresent>()),
          );
          expect(storage.calls, isEmpty);
        },
      );
    }

    test(
      'a transferred reference is missing locally and establishLocal reuses it',
      () async {
        final record = await transferredRecord('transferred');
        final before = file(record).readAsBytesSync();
        _expectResult(
          await service.inspect(record, _apiKey),
          RecordCredentialStatus.missingLocal,
          record,
        );
        await _expectFailure(
          () => service.attach(record, _apiKey, CredentialSecret(_firstSecret)),
          RecordCredentialFailureKind.alreadyAttached,
        );
        await _expectFailure(
          () =>
              service.replace(record, _apiKey, CredentialSecret(_firstSecret)),
          RecordCredentialFailureKind.missingLocal,
        );
        expect(storage.values, isEmpty);
        final established = await service.establishLocal(
          record,
          _apiKey,
          CredentialSecret(_firstSecret),
        );
        _expectResult(established, RecordCredentialStatus.stored, record);
        expect(established.record, isNot(same(record)));
        expect(reference(established.record), _transferred);
        expect(file(record).readAsBytesSync(), before);
        _expectEnvelope(
          storage,
          _transferred,
          established.record,
          _apiKey,
          _firstSecret,
          catalog,
        );
        await expectRetired(record);
        await _expectFailure(
          () => service.establishLocal(
            established.record,
            _apiKey,
            CredentialSecret(_secondSecret),
          ),
          RecordCredentialFailureKind.alreadyAttached,
        );
        _expectEnvelope(
          storage,
          _transferred,
          established.record,
          _apiKey,
          _firstSecret,
          catalog,
        );
      },
    );

    test(
      'forget confirmed local absence detaches without native deletion',
      () async {
        final record = await transferredRecord('transferred');
        final forgotten = await service.forget(record, _apiKey);
        _expectResult(forgotten, RecordCredentialStatus.noReference, record);
        expect(storage.calls.where((call) => call.$1 == 'delete'), isEmpty);
        expect(
          file(record).readAsStringSync(),
          isNot(contains(_transferred.value)),
        );
        await settings.deleteRecord(forgotten.record);
      },
    );

    test(
      'required reference and undeclared slot failures never access storage',
      () async {
        final record = await create('work');
        final before = file(record).readAsBytesSync();
        for (final operation in ['replace', 'establishLocal', 'forget']) {
          await _expectFailure(
            () => _invoke(service, operation, record, _apiKey),
            RecordCredentialFailureKind.noReference,
          );
        }
        for (final operation in _operations) {
          await _expectFailure(
            () => _invoke(service, operation, record, _secondary),
            RecordCredentialFailureKind.invalidSlot,
          );
        }
        expect(storage.calls, isEmpty);
        expect(file(record).readAsBytesSync(), before);
        await attach(record);
      },
    );

    for (final target in ['record', 'plugin', 'slot']) {
      test('a copied reference cannot authorize another $target', () async {
        final source = await attach(
          await create(
            'source',
            type: target == 'slot' ? _fixtureType : _openai,
          ),
        );
        final ref = reference(source);
        var copied = target == 'slot'
            ? source
            : await create(
                'copied',
                type: target == 'plugin' ? _fixtureType : _openai,
              );
        final slot = target == 'slot' ? _secondary : _apiKey;
        file(copied).writeAsStringSync(
          '${file(copied).readAsStringSync()}\n'
          '${target == 'slot' ? '' : '[credentials]\n'}'
          '${slot.value} = "${ref.value}"\n',
        );
        copied = await reload(copied);
        final before = file(copied).readAsBytesSync();
        final protected = storage.values[ref];
        _expectResult(
          await service.inspect(copied, slot),
          RecordCredentialStatus.invalid,
          copied,
        );
        _expectResult(
          await service.reconcile(copied, slot),
          RecordCredentialStatus.invalid,
          copied,
        );
        for (final operation in ['replace', 'establishLocal', 'forget']) {
          await _expectFailure(
            () => _invoke(service, operation, copied, slot),
            RecordCredentialFailureKind.invalid,
          );
        }
        expect(storage.values[ref] == protected, isTrue);
        expect(file(copied).readAsBytesSync(), before);
        expect(storage.calls.where((call) => call.$1 == 'delete'), isEmpty);
        expect(storage.calls.where((call) => call.$1 == 'write'), hasLength(1));
        final legitimate = await reload(source);
        _expectResult(
          await service.inspect(legitimate, _apiKey),
          RecordCredentialStatus.stored,
          legitimate,
        );
      });
    }

    for (final corrupt in _corruptions) {
      test(
        'protected envelope rejects $corrupt without repair or deletion',
        () async {
          final record = await attach(await create('work'));
          final ref = reference(record);
          final original =
              jsonDecode(storage.values[ref]!) as Map<String, dynamic>;
          final invalid = _corruptEnvelope(original, corrupt);
          storage.values[ref] = invalid;
          storage.calls.clear();
          final before = file(record).readAsBytesSync();
          _expectResult(
            await service.inspect(record, _apiKey),
            RecordCredentialStatus.invalid,
            record,
          );
          _expectResult(
            await service.reconcile(record, _apiKey),
            RecordCredentialStatus.invalid,
            record,
          );
          for (final operation in ['replace', 'establishLocal', 'forget']) {
            await _expectFailure(
              () => _invoke(service, operation, record, _apiKey),
              RecordCredentialFailureKind.invalid,
            );
          }
          expect(storage.values[ref] == invalid, isTrue);
          expect(file(record).readAsBytesSync(), before);
          expect(storage.calls.every((call) => call.$1 == 'read'), isTrue);
        },
      );
    }

    for (final unavailable in [false, true]) {
      test(
        'inspection distinguishes unavailable=$unavailable from local absence',
        () async {
          final record = await transferredRecord('transferred');
          final before = file(record).readAsBytesSync();
          storage
              .actions('read')
              .add(_Action(errorBefore: _storageError(unavailable)));
          final result = await service.inspect(record, _apiKey);
          _expectResult(
            result,
            unavailable
                ? RecordCredentialStatus.unavailable
                : RecordCredentialStatus.failed,
            record,
          );
          expect(storage.calls, [('read', _transferred)]);
          expect(storage.values, isEmpty);
          expect(file(record).readAsBytesSync(), before);
          _expectResult(
            await service.inspect(record, _apiKey),
            RecordCredentialStatus.missingLocal,
            record,
          );
        },
      );
    }

    for (final secret in [
      'x' * CredentialSecret.maximumBytes,
      '"' * 1300,
      '\\' * 1300,
      '\u00e9' * 1250,
    ]) {
      test(
        'complete envelope byte limit precedes reference persistence and I/O '
        '(${secret.codeUnitAt(0)}, ${secret.length})',
        () async {
          final record = await create('work');
          final before = file(record).readAsBytesSync();
          final value = CredentialSecret(secret);
          await _expectFailure(
            () => service.attach(record, _apiKey, value),
            RecordCredentialFailureKind.invalidSecret,
            secret: secret,
          );
          expect(file(record).readAsBytesSync(), before);
          expect(storage.calls, isEmpty);
          expect(storage.values, isEmpty);
          await attach(record);
        },
      );
    }

    test(
      'exact full-envelope limit succeeds; one extra byte does not',
      () async {
        final record = await create('work');
        final overhead = utf8
            .encode(
              jsonEncode(_envelope(record, _apiKey, _transferred, '', catalog)),
            )
            .length;
        final secret = 'x' * (CredentialSecret.maximumBytes - overhead);
        await _expectFailure(
          () => service.attach(record, _apiKey, CredentialSecret('${secret}x')),
          RecordCredentialFailureKind.invalidSecret,
          secret: '${secret}x',
        );
        expect(storage.calls, isEmpty);
        final saved = await attach(record, secret);
        final ref = reference(saved);
        expect(utf8.encode(storage.values[ref]!).length, 2560);
        _expectEnvelope(storage, ref, saved, _apiKey, secret, catalog);
      },
    );

    for (final operation in ['replace', 'establishLocal']) {
      test(
        '$operation rejects an oversized envelope without reading storage',
        () async {
          final record = operation == 'replace'
              ? await attach(await create('work'))
              : await transferredRecord('work');
          final ref = reference(record);
          final protected = storage.values[ref];
          final before = file(record).readAsBytesSync();
          storage.calls.clear();
          final secret = CredentialSecret('x' * CredentialSecret.maximumBytes);
          await _expectFailure(
            () => operation == 'replace'
                ? service.replace(record, _apiKey, secret)
                : service.establishLocal(record, _apiKey, secret),
            RecordCredentialFailureKind.invalidSecret,
          );
          expect(storage.calls, isEmpty);
          expect(storage.values[ref] == protected, isTrue);
          expect(file(record).readAsBytesSync(), before);
          await _invoke(service, operation, record, _apiKey);
        },
      );
    }

    for (final operation in ['attach', 'replace', 'establishLocal', 'forget']) {
      test(
        '$operation rejects an external change before any keyring access',
        () async {
          final record = operation == 'establishLocal'
              ? await transferredRecord('work')
              : operation == 'attach'
              ? await create('work')
              : await attach(await create('work'));
          storage.calls.clear();
          final protected = Map.of(storage.values);
          final external =
              '${file(record).readAsStringSync()}# external edit\n';
          file(record).writeAsStringSync(external);
          final failure = await _expectFailure(
            () => _invoke(service, operation, record, _apiKey),
            RecordCredentialFailureKind.staleRecord,
          );
          expect(failure.record, isNull);
          expect(storage.calls, isEmpty);
          expect(storage.values.keys, protected.keys);
          for (final ref in protected.keys) {
            expect(storage.values[ref] == protected[ref], isTrue);
          }
          expect(file(record).readAsStringSync(), external);
          await expectRetired(record);
          final refreshed = await reload(record);
          await _invoke(service, operation, refreshed, _apiKey);
        },
      );
    }

    test(
      'configuration failure is sanitized, performs no keyring I/O, and fences',
      () async {
        final record = await create('work');
        final before = file(record).readAsBytesSync();
        final state = Directory(roots.localStateRoot);
        state.deleteSync(recursive: true);
        File(state.path).writeAsStringSync(_nativeDiagnostic);
        final failure = await _expectFailure(
          () => service.attach(record, _apiKey, CredentialSecret(_firstSecret)),
          RecordCredentialFailureKind.configurationFailure,
        );
        expect(failure.record, isNull);
        expect(file(record).readAsBytesSync(), before);
        expect(storage.calls, isEmpty);
        File(state.path).deleteSync();
        await expectRetired(record);
        await attach(await reload(record));
      },
    );

    for (final unavailable in [false, true]) {
      test(
        'attach pre-write unavailable=$unavailable retains its saved reference',
        () async {
          final record = await create('work');
          storage
              .actions('contains')
              .add(_Action(errorBefore: _storageError(unavailable)));
          final failure = await _expectFailure(
            () =>
                service.attach(record, _apiKey, CredentialSecret(_firstSecret)),
            unavailable
                ? RecordCredentialFailureKind.unavailable
                : RecordCredentialFailureKind.storageFailure,
          );
          expect(failure.record, isNotNull);
          final retained = failure.record!;
          expect(retained, isNot(same(record)));
          final ref = reference(retained);
          expect(storage.calls, [('contains', ref)]);
          expect(storage.values, isEmpty);
          _expectRedacted(file(retained).readAsStringSync());
          await expectRetired(record);
          _expectResult(
            await service.inspect(retained, _apiKey),
            RecordCredentialStatus.missingLocal,
            retained,
          );
          await _expectFailure(
            () => service.attach(
              retained,
              _apiKey,
              CredentialSecret(_secondSecret),
            ),
            RecordCredentialFailureKind.alreadyAttached,
          );
          await expectLater(
            settings.deleteRecord(retained),
            throwsA(isA<ConfigurationRecordCredentialsPresent>()),
          );
          final established = await service.establishLocal(
            retained,
            _apiKey,
            CredentialSecret(_secondSecret),
          );
          expect(reference(established.record), ref);
          _expectEnvelope(
            storage,
            ref,
            established.record,
            _apiKey,
            _secondSecret,
            catalog,
          );
        },
      );
    }

    for (final operation in ['replace', 'establishLocal', 'forget']) {
      for (final unavailable in [false, true]) {
        test(
          '$operation cannot treat unavailable=$unavailable as local absence',
          () async {
            final record = operation == 'establishLocal'
                ? await transferredRecord('work')
                : await attach(await create('work'));
            final ref = reference(record);
            final protected = storage.values[ref];
            final before = file(record).readAsBytesSync();
            storage.calls.clear();
            storage
                .actions('read')
                .add(_Action(errorBefore: _storageError(unavailable)));
            final failure = await _expectFailure(
              () => _invoke(service, operation, record, _apiKey),
              unavailable
                  ? RecordCredentialFailureKind.unavailable
                  : RecordCredentialFailureKind.storageFailure,
            );
            expect(failure.record, same(record));
            expect(storage.calls, [('read', ref)]);
            expect(storage.values[ref] == protected, isTrue);
            expect(file(record).readAsBytesSync(), before);
            await _invoke(service, operation, failure.record!, _apiKey);
          },
        );
      }
    }

    for (final unavailable in [false, true]) {
      test(
        'replace native preflight failure is not uncertain: $unavailable',
        () async {
          final record = await attach(await create('work'));
          final ref = reference(record);
          final before = file(record).readAsBytesSync();
          final protected = storage.values[ref];
          storage.calls.clear();
          storage
              .actions('contains')
              .add(_Action(errorBefore: _storageError(unavailable)));
          final failure = await _expectFailure(
            () => service.replace(
              record,
              _apiKey,
              CredentialSecret(_replacement),
            ),
            unavailable
                ? RecordCredentialFailureKind.unavailable
                : RecordCredentialFailureKind.storageFailure,
          );
          expect(failure.record, same(record));
          expect(storage.calls, [('read', ref), ('contains', ref)]);
          expect(storage.values[ref] == protected, isTrue);
          expect(file(record).readAsBytesSync(), before);
          _expectResult(
            await service.inspect(record, _apiKey),
            RecordCredentialStatus.stored,
            record,
          );
          final replaced = await service.replace(
            record,
            _apiKey,
            CredentialSecret(_replacement),
          );
          _expectEnvelope(
            storage,
            ref,
            replaced.record,
            _apiKey,
            _replacement,
            catalog,
          );
        },
      );
    }

    for (final operation in ['replace', 'establishLocal', 'forget']) {
      test(
        '$operation rechecks TOML after a gated binding read, before mutation',
        () async {
          final record = operation == 'establishLocal'
              ? await transferredRecord('work')
              : await attach(await create('work'));
          final ref = reference(record);
          final protected = storage.values[ref];
          storage.calls.clear();
          final gate = _Gate();
          storage.actions('read').add(_Action(gate: gate));
          final failed = _expectFailure(
            () => _invoke(service, operation, record, _apiKey),
            RecordCredentialFailureKind.staleRecord,
          );
          await gate.entered.future;
          final external =
              '${file(record).readAsStringSync()}# while unlocking\n';
          file(record).writeAsStringSync(external);
          gate.release();
          expect((await failed).record, isNull);
          expect(storage.calls, [('read', ref)]);
          expect(storage.values[ref] == protected, isTrue);
          expect(file(record).readAsStringSync(), external);
        },
      );
    }

    for (final operation in ['attach', 'replace', 'establishLocal', 'forget']) {
      test(
        '$operation rechecks after a gated native preflight before mutation',
        () async {
          final record = operation == 'establishLocal'
              ? await transferredRecord('work')
              : operation == 'attach'
              ? await create('work')
              : await attach(await create('work'));
          final protected = Map.of(storage.values);
          storage.calls.clear();
          final gate = _Gate();
          storage.actions('contains').add(_Action(gate: gate));
          final failed = _expectFailure(
            () => _invoke(service, operation, record, _apiKey),
            RecordCredentialFailureKind.staleRecord,
          );
          await gate.entered.future;
          final ref = reference(record);
          final external =
              '${file(record).readAsStringSync()}# during preflight\n';
          file(record).writeAsStringSync(external);
          gate.release();
          expect((await failed).record, isNull);
          expect(storage.calls, [
            if (operation != 'attach') ('read', ref),
            ('contains', ref),
            if (operation == 'replace' || operation == 'forget') ('read', ref),
          ]);
          expect(storage.values.keys, protected.keys);
          for (final key in protected.keys) {
            expect(storage.values[key] == protected[key], isTrue);
          }
          expect(file(record).readAsStringSync(), external);
          final refreshed = await reload(record);
          _expectResult(
            await service.inspect(refreshed, _apiKey),
            operation == 'attach' || operation == 'establishLocal'
                ? RecordCredentialStatus.missingLocal
                : RecordCredentialStatus.stored,
            refreshed,
          );
        },
      );
    }

    for (final operation in ['replace', 'forget']) {
      for (final corrupt in [
        'owner binding',
        'raw secret',
        'NUL storage value',
      ]) {
        test(
          '$operation revalidates $corrupt after gated native preflight',
          () async {
            final record = await attach(await create('work'));
            final ref = reference(record);
            final before = file(record).readAsBytesSync();
            final changed = _corruptEnvelope(
              jsonDecode(storage.values[ref]!) as Map<String, dynamic>,
              corrupt,
            );
            storage.calls.clear();
            final gate = _Gate();
            storage.actions('contains').add(_Action(gate: gate));
            final failed = _expectFailure(
              () => _invoke(service, operation, record, _apiKey),
              RecordCredentialFailureKind.invalid,
            );
            await gate.entered.future;
            expect(storage.calls, [('read', ref), ('contains', ref)]);
            storage.values[ref] = changed;
            gate.release();
            expect((await failed).record, same(record));
            expect(storage.calls, [
              ('read', ref),
              ('contains', ref),
              ('read', ref),
            ]);
            expect(credentials.requiresReconciliation(ref), isFalse);
            expect(storage.values[ref] == changed, isTrue);
            expect(reference(record), ref);
            expect(file(record).readAsBytesSync(), before);
            _expectResult(
              await service.inspect(record, _apiKey),
              RecordCredentialStatus.invalid,
              record,
            );
            expect(
              storage.calls.where(
                (call) => call.$1 == 'write' || call.$1 == 'delete',
              ),
              isEmpty,
            );
            expect(storage.values[ref] == changed, isTrue);
          },
        );
      }

      test(
        '$operation preserves the reference if its second binding read is missing',
        () async {
          final record = await attach(await create('work'));
          final ref = reference(record);
          final before = file(record).readAsBytesSync();
          storage.calls.clear();
          final preflightGate = _Gate();
          final rereadGate = _Gate();
          storage.actions('contains').add(_Action(gate: preflightGate));
          storage.actions('read').addAll([
            const _Action(),
            _Action(gate: rereadGate),
          ]);
          final failed = _expectFailure(
            () => _invoke(service, operation, record, _apiKey),
            RecordCredentialFailureKind.missingLocal,
          );
          await preflightGate.entered.future;
          expect(storage.calls, [('read', ref), ('contains', ref)]);
          preflightGate.release();
          await rereadGate.entered.future;
          // Contains has confirmed presence; only the mutation-time read is missing.
          storage.values.remove(ref);
          rereadGate.release();
          expect((await failed).record, same(record));
          expect(storage.calls, [
            ('read', ref),
            ('contains', ref),
            ('read', ref),
          ]);
          expect(credentials.requiresReconciliation(ref), isFalse);
          expect(storage.values, isEmpty);
          expect(reference(record), ref);
          expect(file(record).readAsBytesSync(), before);
          _expectResult(
            await service.inspect(record, _apiKey),
            RecordCredentialStatus.missingLocal,
            record,
          );
          await expectLater(
            settings.deleteRecord(record),
            throwsA(isA<ConfigurationRecordCredentialsPresent>()),
          );
          expect(file(record).readAsBytesSync(), before);
          final forgotten = await service.forget(record, _apiKey);
          _expectResult(forgotten, RecordCredentialStatus.noReference, record);
          expect(
            storage.calls.where(
              (call) => call.$1 == 'write' || call.$1 == 'delete',
            ),
            isEmpty,
          );
          expect(file(record).readAsStringSync(), isNot(contains(ref.value)));
          await settings.deleteRecord(forgotten.record);
          expect(file(record).existsSync(), isFalse);
        },
      );
    }

    for (final operation in ['attach', 'replace', 'establishLocal', 'forget']) {
      for (final fault in [
        'drop',
        'throw before',
        'throw after',
        'verification',
      ]) {
        test(
          '$operation $fault requires explicit reconciliation without retry',
          () async {
            final record = operation == 'establishLocal'
                ? await transferredRecord('work')
                : operation == 'attach'
                ? await create('work')
                : await attach(await create('work'));
            storage.calls.clear();
            final nativeOperation = operation == 'forget' ? 'delete' : 'write';
            storage
                .actions(nativeOperation)
                .add(
                  _Action(
                    drop: fault == 'drop',
                    errorBefore: fault == 'throw before'
                        ? _storageError(false)
                        : null,
                    errorAfter: fault == 'throw after'
                        ? _storageError(false)
                        : null,
                  ),
                );
            if (fault == 'verification') {
              final verification = operation == 'forget' ? 'contains' : 'read';
              if (operation != 'attach') {
                storage.actions(verification).add(const _Action());
              }
              if (operation == 'replace') {
                // Pass mutation-time binding validation; fail postwrite readback.
                storage.actions(verification).add(const _Action());
              }
              storage
                  .actions(verification)
                  .add(_Action(errorBefore: _storageError(true)));
            }
            final failure = await _expectFailure(
              () => _invoke(service, operation, record, _apiKey),
              RecordCredentialFailureKind.reconciliationRequired,
            );
            final retained = failure.record!;
            final ref = reference(retained);
            final before = file(record).readAsBytesSync();
            expect(storage.calls.where((call) => call.$1 == nativeOperation), [
              (nativeOperation, ref),
            ]);
            final uncertainCalls = List.of(storage.calls);
            _expectResult(
              await service.inspect(retained, _apiKey),
              RecordCredentialStatus.reconciliationRequired,
              retained,
            );
            // The uncertainty belongs to P1, not to this coordinator instance.
            final other = coordinate(settings, credentials);
            _expectResult(
              await other.inspect(retained, _apiKey),
              RecordCredentialStatus.reconciliationRequired,
              retained,
            );
            for (final blocked in ['replace', 'establishLocal', 'forget']) {
              await _expectFailure(
                () => _invoke(service, blocked, retained, _apiKey),
                RecordCredentialFailureKind.reconciliationRequired,
              );
            }
            expect(storage.calls, uncertainCalls);
            expect(file(record).readAsBytesSync(), before);
            final changed = fault == 'throw after' || fault == 'verification';
            final missing = operation == 'forget'
                ? changed
                : operation == 'replace'
                ? false
                : !changed;
            final reconciled = await service.reconcile(retained, _apiKey);
            _expectResult(
              reconciled,
              missing
                  ? RecordCredentialStatus.missingLocal
                  : RecordCredentialStatus.stored,
              retained,
            );
            expect(reconciled.record, isNot(same(retained)));
            expect(storage.calls.skip(uncertainCalls.length), [('read', ref)]);
            expect(file(record).readAsBytesSync(), before);
            await expectRetired(retained);
            final saved = await _invoke(
              service,
              missing ? 'establishLocal' : 'replace',
              reconciled.record,
              _apiKey,
            );
            expect(reference(saved.record), ref);
            _expectEnvelope(
              storage,
              ref,
              saved.record,
              _apiKey,
              _replacement,
              catalog,
            );
          },
        );
      }
    }

    test(
      'P1 nonreconciling read checks uncertainty after queued standalone mutation',
      () async {
        final record = await attach(await create('work'));
        final ref = reference(record);
        final before = file(record).readAsBytesSync();
        storage.calls.clear();
        final mutationGate = _Gate();
        storage
            .actions('write')
            .add(_Action(gate: mutationGate, errorAfter: _storageError(false)));
        final directMutation = credentials
            .replace(
              ref,
              CredentialSecret(
                jsonEncode(
                  _envelope(record, _apiKey, ref, _secondSecret, catalog),
                ),
              ),
            )
            .then<void>(
              (_) => fail('Expected the standalone P1 mutation to fail.'),
              onError: (Object error, StackTrace stack) {
                _expectRedacted('$error\n$stack');
                expect(error is CredentialFailure, isTrue);
                final failure = error as CredentialFailure;
                expect(failure.kind, CredentialFailureKind.failed);
                expect(failure.outcomeUncertain, isTrue);
              },
            );
        await mutationGate.entered.future;
        var validated = false;
        // Admit directly at P1's queue boundary so the read is definitely queued
        // before uncertainty exists, independently of Settings-worker scheduling.
        final queued = credentials
            .read(ref, reconcile: false, validate: (_) => validated = true)
            .then<void>(
              (_) => fail(
                'A nonreconciling queued read must preserve uncertainty.',
              ),
              onError: (Object error, StackTrace stack) {
                _expectRedacted('$error\n$stack');
                expect(error is CredentialFailure, isTrue);
                final failure = error as CredentialFailure;
                expect(
                  failure.kind,
                  CredentialFailureKind.verificationRequired,
                );
                expect(failure.outcomeUncertain, isTrue);
              },
            );
        final inspecting = service.inspect(record, _apiKey);
        expect(credentials.requiresReconciliation(ref), isFalse);
        expect(storage.calls, [('contains', ref), ('write', ref)]);
        mutationGate.release();
        await directMutation;
        await queued;
        _expectResult(
          await inspecting,
          RecordCredentialStatus.reconciliationRequired,
          record,
        );
        expect(validated, isFalse);
        expect(credentials.requiresReconciliation(ref), isTrue);
        expect(storage.calls, [('contains', ref), ('write', ref)]);
        expect(file(record).readAsBytesSync(), before);
        _expectEnvelope(storage, ref, record, _apiKey, _secondSecret, catalog);
        _expectResult(
          await service.inspect(record, _apiKey),
          RecordCredentialStatus.reconciliationRequired,
          record,
        );
        await _expectFailure(
          () =>
              service.replace(record, _apiKey, CredentialSecret(_replacement)),
          RecordCredentialFailureKind.reconciliationRequired,
        );
        expect(storage.calls, [('contains', ref), ('write', ref)]);
        final reconciled = await service.reconcile(record, _apiKey);
        _expectResult(reconciled, RecordCredentialStatus.stored, record);
        expect(credentials.requiresReconciliation(ref), isFalse);
        expect(storage.calls, [
          ('contains', ref),
          ('write', ref),
          ('read', ref),
        ]);
        expect(file(record).readAsBytesSync(), before);
        final replaced = await service.replace(
          reconciled.record,
          _apiKey,
          CredentialSecret(_replacement),
        );
        _expectEnvelope(
          storage,
          ref,
          replaced.record,
          _apiKey,
          _replacement,
          catalog,
        );
      },
    );

    test(
      'mismatched write verification is uncertain until explicit bound read',
      () async {
        final record = await attach(await create('work'));
        final ref = reference(record);
        final before = file(record).readAsBytesSync();
        storage.calls.clear();
        storage
            .actions('write')
            .add(
              _Action(
                writtenValue: jsonEncode(
                  _envelope(record, _apiKey, ref, _secondSecret, catalog),
                ),
              ),
            );
        final failure = await _expectFailure(
          () =>
              service.replace(record, _apiKey, CredentialSecret(_replacement)),
          RecordCredentialFailureKind.reconciliationRequired,
        );
        expect(failure.record, same(record));
        final calls = List.of(storage.calls);
        _expectResult(
          await service.inspect(record, _apiKey),
          RecordCredentialStatus.reconciliationRequired,
          record,
        );
        expect(storage.calls, calls);
        final reconciled = await service.reconcile(record, _apiKey);
        _expectResult(reconciled, RecordCredentialStatus.stored, record);
        _expectEnvelope(
          storage,
          ref,
          reconciled.record,
          _apiKey,
          _secondSecret,
          catalog,
        );
        expect(file(record).readAsBytesSync(), before);
        expect(storage.calls.where((call) => call.$1 == 'write'), hasLength(1));
        final replaced = await service.replace(
          reconciled.record,
          _apiKey,
          CredentialSecret(_replacement),
        );
        _expectEnvelope(
          storage,
          ref,
          replaced.record,
          _apiKey,
          _replacement,
          catalog,
        );
      },
    );

    test(
      'failed reconciliation cannot clear uncertainty or retry the mutation',
      () async {
        final original = await create('work');
        storage.actions('write').add(_Action(errorAfter: _storageError(false)));
        final failure = await _expectFailure(
          () =>
              service.attach(original, _apiKey, CredentialSecret(_firstSecret)),
          RecordCredentialFailureKind.reconciliationRequired,
        );
        final record = failure.record!;
        final ref = reference(record);
        final protected = storage.values[ref]!;
        for (final corrupt in [false, true]) {
          if (corrupt) {
            storage.values[ref] = '$_firstSecret\x00';
          } else {
            storage
                .actions('read')
                .add(_Action(errorBefore: _storageError(true)));
          }
          _expectResult(
            await service.reconcile(record, _apiKey),
            corrupt
                ? RecordCredentialStatus.invalid
                : RecordCredentialStatus.unavailable,
            record,
          );
          final before = List.of(storage.calls);
          _expectResult(
            await service.inspect(record, _apiKey),
            RecordCredentialStatus.reconciliationRequired,
            record,
          );
          await _expectFailure(
            () => service.forget(record, _apiKey),
            RecordCredentialFailureKind.reconciliationRequired,
          );
          expect(storage.calls, before);
        }
        storage.values[ref] = protected;
        final reconciled = await service.reconcile(record, _apiKey);
        _expectResult(reconciled, RecordCredentialStatus.stored, record);
        expect(storage.calls.where((call) => call.$1 == 'write'), hasLength(1));
        await service.forget(reconciled.record, _apiKey);
      },
    );

    for (final corrupt in ['raw secret', 'owner binding', 'empty secret']) {
      test(
        'failed $corrupt reconciliation retains the shared P1 fence',
        () async {
          final original = await create('work');
          storage
              .actions('write')
              .add(_Action(errorAfter: _storageError(false)));
          final failure = await _expectFailure(
            () => service.attach(
              original,
              _apiKey,
              CredentialSecret(_firstSecret),
            ),
            RecordCredentialFailureKind.reconciliationRequired,
          );
          final record = failure.record!;
          final ref = reference(record);
          final protected = storage.values[ref]!;
          storage.values[ref] = _corruptEnvelope(
            jsonDecode(protected) as Map<String, dynamic>,
            corrupt,
          );
          final before = file(record).readAsBytesSync();
          _expectResult(
            await service.reconcile(record, _apiKey),
            RecordCredentialStatus.invalid,
            record,
          );
          final calls = List.of(storage.calls);
          final other = coordinate(settings, credentials);
          _expectResult(
            await other.inspect(record, _apiKey),
            RecordCredentialStatus.reconciliationRequired,
            record,
          );
          for (final operation in ['replace', 'establishLocal', 'forget']) {
            await _expectFailure(
              () => _invoke(other, operation, record, _apiKey),
              RecordCredentialFailureKind.reconciliationRequired,
            );
          }
          expect(storage.calls, calls);
          expect(file(record).readAsBytesSync(), before);
          storage.values[ref] = protected;
          final reconciled = await service.reconcile(record, _apiKey);
          _expectResult(reconciled, RecordCredentialStatus.stored, record);
          await other.forget(reconciled.record, _apiKey);
        },
      );
    }

    test(
      'confirmed delete followed by detach conflict retains the reference',
      () async {
        final record = await attach(await create('work'));
        final independent = await create('personal');
        final ref = reference(record);
        final external =
            '${file(record).readAsStringSync()}# external after delete\n';
        storage
            .actions('delete')
            .add(
              _Action(after: () => file(record).writeAsStringSync(external)),
            );
        final failure = await _expectFailure(
          () => service.forget(record, _apiKey),
          RecordCredentialFailureKind.staleRecord,
        );
        expect(failure.record, isNull);
        expect(storage.values.containsKey(ref), isFalse);
        expect(reference(record), ref);
        expect(file(record).readAsStringSync(), external);
        await expectRetired(record);
        await settings.updateRecord(independent, {
          'display-name': 'Still usable',
        });
        final refreshed = await reload(record);
        _expectResult(
          await service.inspect(refreshed, _apiKey),
          RecordCredentialStatus.missingLocal,
          refreshed,
        );
        final forgotten = await service.forget(refreshed, _apiKey);
        _expectResult(forgotten, RecordCredentialStatus.noReference, refreshed);
        expect(storage.calls.where((call) => call.$1 == 'delete'), [
          ('delete', ref),
        ]);
        expect(
          file(record).readAsStringSync(),
          contains('# external after delete'),
        );
        await settings.deleteRecord(forgotten.record);
      },
    );

    test(
      'foreign owner views fail without retiring either usable owner handle',
      () async {
        final record = await create('work');
        final otherSettings = createOwner();
        final other = coordinate(otherSettings, credentials);
        final otherRecord = (await otherSettings.loadRecords(
          _providers,
        )).records.single;
        for (final operation in _operations) {
          await _expectFailure(
            () => _invoke(other, operation, record, _apiKey),
            RecordCredentialFailureKind.staleRecord,
          );
          await _expectFailure(
            () => _invoke(service, operation, otherRecord, _apiKey),
            RecordCredentialFailureKind.staleRecord,
          );
        }
        expect(storage.calls, isEmpty);
        _expectResult(
          await other.inspect(otherRecord, _apiKey),
          RecordCredentialStatus.noReference,
          otherRecord,
        );
        await attach(record);
      },
    );

    for (final separateOwner in [false, true]) {
      test(
        'competing coordinator stale handle is rejected: owner=$separateOwner',
        () async {
          final record = await create('work');
          final otherSettings = separateOwner ? createOwner() : settings;
          final other = coordinate(otherSettings, credentials);
          final otherRecord = separateOwner
              ? (await otherSettings.loadRecords(_providers)).records.single
              : record;
          final gate = _Gate();
          storage.actions('write').add(_Action(gate: gate));
          final winning = service.attach(
            record,
            _apiKey,
            CredentialSecret(_firstSecret),
          );
          await gate.entered.future;
          final losing = _expectFailure(
            () => other.attach(
              otherRecord,
              _apiKey,
              CredentialSecret(_secondSecret),
            ),
            RecordCredentialFailureKind.staleRecord,
          );
          gate.release();
          final winner = await winning;
          await losing;
          expect(
            storage.calls.where((call) => call.$1 == 'write'),
            hasLength(1),
          );
          _expectEnvelope(
            storage,
            reference(winner.record),
            winner.record,
            _apiKey,
            _firstSecret,
            catalog,
          );
          _expectResult(
            await service.inspect(winner.record, _apiKey),
            RecordCredentialStatus.stored,
            winner.record,
          );
        },
      );
    }

    test(
      'busy covers every slot on a record, while independent records queue',
      () async {
        final record = await create('work', type: _fixtureType);
        final independent = await create('personal');
        final gate = _Gate();
        storage.actions('write').add(_Action(gate: gate));
        final attaching = service.attach(
          record,
          _apiKey,
          CredentialSecret(_firstSecret),
        );
        await gate.entered.future;
        final admitted = List.of(storage.calls);
        expect(storage.values, isEmpty);
        expect(reference(record), admitted.last.$2);
        _expectRedacted(file(record).readAsStringSync());
        for (final slot in [_apiKey, _secondary]) {
          for (final operation in _operations) {
            await _expectFailure(
              () => _invoke(service, operation, record, slot),
              RecordCredentialFailureKind.busy,
            );
          }
        }
        expect(storage.calls, admitted);
        final second = service.attach(
          independent,
          _apiKey,
          CredentialSecret(_secondSecret),
        );
        gate.release();
        final firstResult = await attaching;
        final secondResult = await second;
        _expectResult(firstResult, RecordCredentialStatus.stored, record);
        _expectResult(secondResult, RecordCredentialStatus.stored, independent);
        final anotherSlot = await service.attach(
          firstResult.record,
          _secondary,
          CredentialSecret(_replacement),
        );
        expect(
          reference(anotherSlot.record, _secondary),
          isNot(reference(anotherSlot.record)),
        );
        _expectResult(
          await service.inspect(secondResult.record, _apiKey),
          RecordCredentialStatus.stored,
          independent,
        );
      },
    );

    test(
      'worker exclusivity queues ordinary edits across owners until workflow ends',
      () async {
        final record = await attach(await create('work'));
        final independent = await create('personal');
        final otherSettings = createOwner();
        final otherRecord = (await otherSettings.loadRecords(
          _providers,
        )).records.singleWhere((candidate) => candidate.id == record.id);
        final gate = _Gate();
        storage.actions('write').add(_Action(gate: gate));
        final replacing = service.replace(
          record,
          _apiKey,
          CredentialSecret(_replacement),
        );
        await gate.entered.future;
        final crossOwnerEdit = otherSettings.updateRecord(otherRecord, {
          'display-name': 'Other owner after workflow',
        });
        final staleEdit = expectLater(
          settings.updateRecord(record, record.values),
          throwsA(isA<ConfigurationConflictException>()),
        );
        final independentEdit = settings.updateRecord(independent, {
          'display-name': 'Independent edit after workflow',
        });
        gate.release();
        final replaced = await replacing;
        _expectResult(replaced, RecordCredentialStatus.stored, record);
        await staleEdit;
        final edited = await crossOwnerEdit;
        expect(edited.values, {'display-name': 'Other owner after workflow'});
        expect((await independentEdit).values, {
          'display-name': 'Independent edit after workflow',
        });
        _expectEnvelope(
          storage,
          reference(edited),
          edited,
          _apiKey,
          _replacement,
          catalog,
        );
      },
    );

    test(
      'idle close is idempotent and does not close either dependency',
      () async {
        final record = await create('work');
        final closing = service.close();
        expect(service.close(), same(closing));
        for (final operation in _operations) {
          await _expectFailure(
            () => _invoke(service, operation, record, _apiKey),
            RecordCredentialFailureKind.closed,
          );
        }
        await closing;
        expect(storage.calls, isEmpty);
        expect(await credentials.read(_transferred), isNull);
        await settings.updateRecord(record, {
          'display-name': 'Dependencies remain open',
        });
        expect(service.close(), same(closing));
      },
    );

    test(
      'coordinator close does not drain unrelated credential-owner work',
      () async {
        final record = await create('work');
        final gate = _Gate();
        storage.actions('write').add(_Action(gate: gate));
        final unrelated = credentials.store(
          _transferred,
          CredentialSecret(_firstSecret),
        );
        await gate.entered.future;
        await service.close();
        expect(storage.values, isEmpty);
        await settings.deleteRecord(record);
        gate.release();
        await unrelated;
        expect(
          (await credentials.read(_transferred))!.reveal() == _firstSecret,
          isTrue,
        );
      },
    );

    for (final failed in [false, true]) {
      test(
        'close fences immediately and drains both gated workflows: failed=$failed',
        () async {
          final firstRecord = await create('work');
          final secondRecord = await create('personal');
          final firstGate = _Gate();
          final secondGate = _Gate();
          storage.actions('write').addAll([
            _Action(
              gate: firstGate,
              errorAfter: failed ? _storageError(false) : null,
            ),
            _Action(gate: secondGate),
          ]);
          final first = failed
              ? _expectFailure(
                  () => service.attach(
                    firstRecord,
                    _apiKey,
                    CredentialSecret(_firstSecret),
                  ),
                  RecordCredentialFailureKind.reconciliationRequired,
                )
              : service.attach(
                  firstRecord,
                  _apiKey,
                  CredentialSecret(_firstSecret),
                );
          final second = service.attach(
            secondRecord,
            _apiKey,
            CredentialSecret(_secondSecret),
          );
          await firstGate.entered.future;
          var closed = false;
          final closing = service.close();
          final observedClose = closing.then((_) => closed = true);
          expect(service.close(), same(closing));
          final before = List.of(storage.calls);
          for (final operation in _operations) {
            await _expectFailure(
              () => _invoke(service, operation, firstRecord, _apiKey),
              RecordCredentialFailureKind.closed,
            );
          }
          expect(storage.calls, before);
          expect(closed, isFalse);
          firstGate.release();
          await secondGate.entered.future;
          await first;
          expect(closed, isFalse);
          secondGate.release();
          final savedSecond = await second;
          await observedClose;
          expect(closed, isTrue);
          final drained = List.of(storage.calls);
          await service.close();
          expect(storage.calls, drained);
          expect(
            storage.calls.where((call) => call.$1 == 'write'),
            hasLength(2),
          );
          final successor = coordinate(settings, credentials);
          _expectResult(
            await successor.inspect(savedSecond.record, _apiKey),
            RecordCredentialStatus.stored,
            savedSecond.record,
          );
          final updated = await settings.updateRecord(savedSecond.record, {
            'display-name': 'Caller still owns settings',
          });
          await successor.forget(updated, _apiKey);
        },
      );
    }
  }, skip: !Platform.isLinux);
}

const _operations = [
  'inspect',
  'reconcile',
  'attach',
  'replace',
  'establishLocal',
  'forget',
];

Future<RecordCredentialResult> _invoke(
  RecordCredentialService service,
  String operation,
  RecordView record,
  RecordCredentialSlotId slot,
) => switch (operation) {
  'inspect' => service.inspect(record, slot),
  'reconcile' => service.reconcile(record, slot),
  'attach' => service.attach(record, slot, CredentialSecret(_replacement)),
  'replace' => service.replace(record, slot, CredentialSecret(_replacement)),
  'establishLocal' => service.establishLocal(
    record,
    slot,
    CredentialSecret(_replacement),
  ),
  'forget' => service.forget(record, slot),
  _ => throw StateError('Unknown test operation.'),
};

Map<String, Object> _envelope(
  RecordView record,
  RecordCredentialSlotId slot,
  CredentialReference reference,
  String secret,
  RecordCatalog catalog,
) => {
  'version': 1,
  'owner': catalog.definition(record.type).owner.value,
  'type': record.type.value,
  'collection': record.collection.value,
  'record': record.id.value,
  'slot': slot.value,
  'reference': reference.value,
  'secret': secret,
};

void _expectEnvelope(
  _Storage storage,
  CredentialReference reference,
  RecordView record,
  RecordCredentialSlotId slot,
  String secret,
  RecordCatalog catalog,
) {
  final actual = jsonDecode(storage.values[reference]!) as Map<String, dynamic>;
  final expected = _envelope(record, slot, reference, secret, catalog);
  expect(actual.keys.toSet(), expected.keys.toSet());
  // Never print a raw secret as the actual/expected value of a failed assertion.
  expect(
    actual.remove('secret') == expected.remove('secret'),
    isTrue,
    reason: 'Protected envelope has a different secret.',
  );
  expect(actual, expected);
  expect(
    utf8.encode(storage.values[reference]!).length,
    lessThanOrEqualTo(2560),
  );
}

void _expectResult(
  RecordCredentialResult result,
  RecordCredentialStatus status,
  RecordView expected,
) {
  expect(result.status, status);
  expect(result.record.id, expected.id);
  expect(result.record.type, expected.type);
  expect(result.record.collection, expected.collection);
  expect(result.record.values, expected.values);
  _expectRedacted('$result ${result.status} ${result.record}');
}

void _expectRedacted(String diagnostics, {String? secret}) {
  for (final value in [
    _firstSecret,
    _secondSecret,
    _replacement,
    _nativeDiagnostic,
    if (secret != null && secret.isNotEmpty) secret,
  ]) {
    expect(
      diagnostics.contains(value),
      isFalse,
      reason: 'Sensitive content leaked through diagnostics.',
    );
  }
}

Future<RecordCredentialFailure> _expectFailure(
  FutureOr<Object?> Function() operation,
  RecordCredentialFailureKind kind, {
  String? secret,
}) async {
  Object? caught;
  StackTrace? caughtStack;
  try {
    await operation();
  } on Object catch (error, stack) {
    caught = error;
    caughtStack = stack;
  }
  _expectRedacted('$caught\n$caughtStack', secret: secret);
  expect(
    caught is RecordCredentialFailure,
    isTrue,
    reason: 'Expected a typed, sanitized record credential failure.',
  );
  final failure = caught as RecordCredentialFailure;
  expect(failure.kind, kind);
  expect(failure.toString(), 'RecordCredentialFailure(${kind.name})');
  return failure;
}

const _corruptions = [
  'raw secret',
  'empty storage value',
  'NUL storage value',
  'JSON list',
  'unknown version',
  'string version',
  'owner binding',
  'type binding',
  'collection binding',
  'record binding',
  'slot binding',
  'reference binding',
  'extra key',
  'missing version',
  'missing owner',
  'missing type',
  'missing collection',
  'missing record',
  'missing slot',
  'missing reference',
  'missing secret',
  'nonstring secret',
  'empty secret',
  'NUL secret',
  'unpaired surrogate secret',
];

String _corruptEnvelope(Map<String, dynamic> envelope, String corruption) {
  switch (corruption) {
    case 'raw secret':
      return _firstSecret;
    case 'empty storage value':
      return '';
    case 'NUL storage value':
      return '$_firstSecret\x00';
    case 'JSON list':
      return jsonEncode([envelope]);
    case 'unknown version':
      envelope['version'] = 2;
    case 'string version':
      envelope['version'] = '1';
    case 'owner binding':
      envelope['owner'] = 'dev.example.foreign';
    case 'type binding':
      envelope['type'] = 'dev.adele.openai.foreign';
    case 'collection binding':
      envelope['collection'] = 'archive';
    case 'record binding':
      envelope['record'] = 'foreign-record';
    case 'slot binding':
      envelope['slot'] = 'foreign-slot';
    case 'reference binding':
      envelope['reference'] = _transferred.value;
    case 'extra key':
      envelope['unexpected'] = 'not an extension point';
    case 'nonstring secret':
      envelope['secret'] = 42;
    case 'empty secret':
      envelope['secret'] = '';
    case 'NUL secret':
      envelope['secret'] = '$_firstSecret\x00';
    case 'unpaired surrogate secret':
      envelope['secret'] = String.fromCharCode(0xd800);
    default:
      if (!corruption.startsWith('missing ')) {
        throw StateError('Unknown test corruption.');
      }
      envelope.remove(corruption.substring('missing '.length));
  }
  return jsonEncode(envelope);
}

Object _storageError(bool unavailable) => unavailable
    ? const CredentialFailure(CredentialFailureKind.unavailable)
    : StateError('$_nativeDiagnostic: $_firstSecret / $_replacement');

final class _Gate {
  _Gate() {
    addTearDown(release);
  }
  final entered = Completer<void>();
  final _released = Completer<void>();
  Future<void> wait() {
    entered.complete();
    return _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

final class _Action {
  const _Action({
    this.gate,
    this.errorBefore,
    this.errorAfter,
    this.after,
    this.drop = false,
    this.writtenValue,
  });
  final _Gate? gate;
  final Object? errorBefore;
  final Object? errorAfter;
  final void Function()? after;
  final bool drop;
  final String? writtenValue;
  void finish() {
    after?.call();
    final error = errorAfter;
    if (error != null) throw error;
  }
}

final class _Storage implements CredentialStorageAdapter {
  _Storage({Map<CredentialReference, String>? values}) : values = values ?? {};
  final Map<CredentialReference, String> values;
  final calls = <(String, CredentialReference)>[];
  final _actions = <String, Queue<_Action>>{};
  Queue<_Action> actions(String operation) =>
      _actions.putIfAbsent(operation, Queue<_Action>.new);
  Future<_Action> _begin(
    String operation,
    CredentialReference reference,
  ) async {
    calls.add((operation, reference));
    final pending = actions(operation);
    final action = pending.isEmpty ? const _Action() : pending.removeFirst();
    await action.gate?.wait();
    final error = action.errorBefore;
    if (error != null) throw error;
    return action;
  }

  @override
  Future<bool> contains(CredentialReference reference) async {
    final action = await _begin('contains', reference);
    action.finish();
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    final action = await _begin('read', reference);
    action.finish();
    return values[reference];
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    final action = await _begin('write', reference);
    if (!action.drop) {
      values[reference] = action.writtenValue ?? secret.reveal();
    }
    action.finish();
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    final action = await _begin('delete', reference);
    if (!action.drop) values.remove(reference);
    action.finish();
  }
}
