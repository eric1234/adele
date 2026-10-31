import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show IsolateNameServer;

import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_backend_support/adele_backend_credentials.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _owner = 'dev.example.startup';
const _type = '$_owner.account';
const _secret = 'startup-authority-secret-marker';
final _collection = RecordCollectionId('accounts');
final _slot = RecordCredentialSlotId('token');

void main() {
  late Directory temporary;
  late PlatformStorageRoots roots;
  late PreparedPluginCatalog catalog;
  late PreparedPluginInstallation installation;
  late GlobalSettingsService settings;
  late CredentialService credentials;
  late RecordCredentialService service;
  late _Storage storage;

  GlobalSettingsService owner({PlatformStorageRoots? storageRoots}) {
    final result = GlobalSettingsService(
      catalog: SettingsCatalog([]),
      records: catalog.records,
      roots: storageRoots ?? roots,
    );
    addTearDown(result.close);
    return result;
  }

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('adele-startup-authority-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final installed = Directory('${temporary.path}/installed/probe')
      ..createSync(recursive: true);
    File('${installed.path}/backend.aot').writeAsStringSync('not executed');
    File('${installed.path}/records.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'recordTypes': [
          for (final type in [_type, '$_owner.other'])
            {
              'id': type,
              'collection': 'accounts',
              'collectionLabel': 'Accounts',
              'label': 'Account',
              'credentialSlots': [
                for (final slot in ['token', 'other'])
                  {'id': slot, 'label': slot, 'kind': 'secret-text'},
              ],
              'fields': [
                {
                  'id': 'name',
                  'label': 'Name',
                  'type': 'string',
                  'required': true,
                },
              ],
            },
        ],
      }),
    );
    File('${installed.path}/adele_plugin.installation.json').writeAsStringSync(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': _owner, 'version': '1', 'displayName': 'Probe'},
        'recordsSchema': 'records.json',
        'components': {
          'backend': {
            'artifact': 'backend.aot',
            'consumesRecordTypes': [_type, '$_owner.other'],
            'consumesCredentialSlots': [
              {
                'recordType': _type,
                'slots': ['token'],
              },
            ],
          },
        },
      }),
    );
    catalog = await PreparedPluginCatalog.discover(installed.parent.path);
    expect(catalog.issues, isEmpty);
    installation = catalog.installations.single;
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    settings = owner();
    storage = _Storage();
    credentials = CredentialService(storage);
    addTearDown(credentials.close);
    service = RecordCredentialService(
      settings: settings,
      credentials: credentials,
    );
    addTearDown(service.close);
  });

  Future<RecordView> create(String id, {bool attach = true}) async {
    final record = await settings.createRecord(
      RecordTypeId(_type),
      ConfigurationRecordId(id),
      {'name': id},
    );
    if (!attach) return record;
    return (await service.attach(
      record,
      _slot,
      CredentialSecret(_secret),
    )).record;
  }

  Future<StartupRecordsView> capture() =>
      settings.loadStartupRecords(catalog, installation);

  Future<String> read(
    StartupRecordsView view, {
    String collection = 'accounts',
    String type = _type,
    String id = 'first',
    String slot = 'token',
    void Function()? validate,
    RecordCredentialService? reader,
  }) => (reader ?? service).readStartupCredential(
    view,
    collection: collection,
    recordType: type,
    recordId: id,
    slot: slot,
    validateGeneration: validate ?? () {},
  );

  File file(String id) => File('${roots.configurationRoot}/accounts/$id.toml');

  PlatformStorageRoots atConfiguration(String path) => PlatformStorageRoots(
    operatingSystem: Platform.operatingSystem,
    configurationRoot: path,
    localStateRoot: roots.localStateRoot,
    localDataRoot: roots.localDataRoot,
    cacheRoot: roots.cacheRoot,
  );

  RecordCredentialService coordinate(GlobalSettingsService owner) {
    final result = RecordCredentialService(
      settings: owner,
      credentials: credentials,
    );
    addTearDown(result.close);
    return result;
  }

  test(
    'exact capture is nonsecret and reads only its opted-in member and slot',
    () async {
      await create('first');
      await create('second');
      final before = storage.calls;
      final view = await capture();
      expect(storage.calls, before);
      expect(jsonEncode(view.records), isNot(contains(_secret)));
      expect(jsonEncode(view.records), isNot(contains('cred1_')));
      expect(await read(view), _secret);
      expect(await read(view, id: 'second'), _secret);
      for (final request in [
        () => read(view, collection: 'other'),
        () => read(view, type: '$_owner.other'),
        () => read(view, id: 'absent'),
        () => read(view, slot: 'other'),
        () => read(view, id: '../first'),
      ]) {
        await expectLater(
          request(),
          _failure(AdeleCredentialFailureKind.notAuthorized),
        );
      }
      final forged = StartupRecordsView.fromProjection(
        catalog,
        installation,
        records: view.records,
      );
      await expectLater(
        read(forged),
        _failure(AdeleCredentialFailureKind.notAuthorized),
      );
      final other = RecordCredentialService(
        settings: owner(),
        credentials: credentials,
      );
      addTearDown(other.close);
      await expectLater(
        read(view, reader: other),
        _failure(AdeleCredentialFailureKind.notAuthorized),
      );
      final after = await capture();
      await service.releaseStartupRecords(view);
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      expect(await read(after), _secret);
    },
    skip: !Platform.isLinux,
  );

  test(
    'missing reference and local absence are distinct and never repaired',
    () async {
      final record = await create('first', attach: false);
      var view = await capture();
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.notConfigured),
      );
      expect(storage.calls, 0);
      await service.attach(record, _slot, CredentialSecret(_secret));
      view = await capture();
      storage.values.clear();
      final bytes = file('first').readAsBytesSync();
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.missingLocally),
      );
      expect(file('first').readAsBytesSync(), bytes);
      expect(storage.writes, 1);
      expect(storage.deletes, 0);
    },
    skip: !Platform.isLinux,
  );

  test(
    'storage and envelope failures are distinct, bounded and redacted',
    () async {
      await create('first');
      final view = await capture();
      storage.readFailure = const CredentialFailure(
        CredentialFailureKind.unavailable,
      );
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.storageUnavailable),
      );
      storage.readFailure = StateError(_secret);
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.credentialAccessFailed),
      );
      storage.readFailure = null;
      final reference = storage.values.keys.single;
      final original = storage.values[reference]!;
      final binding = jsonDecode(original) as Map<String, dynamic>;
      for (final key in [
        'owner',
        'type',
        'collection',
        'record',
        'slot',
        'reference',
        'version',
        'secret',
      ]) {
        storage.values[reference] = jsonEncode({
          ...binding,
          key: key == 'secret' ? '' : 'wrong',
        });
        await expectLater(
          read(view),
          _failure(AdeleCredentialFailureKind.invalidCredentialBinding),
        );
      }
      for (final invalid in [
        'not-json-$_secret',
        jsonEncode({...binding, 'extra': true}),
        jsonEncode({...binding, 'version': 1.0}),
      ]) {
        storage.values[reference] = invalid;
        await expectLater(
          read(view),
          _failure(AdeleCredentialFailureKind.invalidCredentialBinding),
        );
      }
      storage.values[reference] = original;
      expect(await read(view), _secret);
    },
    skip: !Platform.isLinux,
  );

  test(
    'read never clears uncertain mutation and does not access OS for it',
    () async {
      final record = await create('first');
      storage.failWrite = true;
      await expectLater(
        service.replace(record, _slot, CredentialSecret('replacement')),
        throwsA(isA<RecordCredentialFailure>()),
      );
      final reference = storage.values.keys.single;
      expect(credentials.requiresReconciliation(reference), isTrue);
      final view = await capture();
      final calls = storage.calls;
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.reconciliationRequired),
      );
      expect(storage.calls, calls);
      expect(credentials.requiresReconciliation(reference), isTrue);
    },
    skip: !Platform.isLinux,
  );

  test(
    'same-reference replacement through another owner invalidates capture',
    () async {
      await create('first');
      final view = await capture();
      final before = file('first').readAsBytesSync();
      final modified = file('first').lastModifiedSync();
      final otherSettings = owner();
      final other = RecordCredentialService(
        settings: otherSettings,
        credentials: credentials,
      );
      addTearDown(other.close);
      final record = (await otherSettings.loadRecords(
        _collection,
      )).records.single;
      await other.replace(record, _slot, CredentialSecret('replacement'));
      expect(file('first').readAsBytesSync(), before);
      expect(file('first').lastModifiedSync(), modified);
      final calls = storage.calls;
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      expect(storage.calls, calls);
      expect(await read(await capture()), 'replacement');
    },
    skip: !Platform.isLinux,
  );

  test(
    'symlink-root owners share same-reference mutation epochs per record',
    () async {
      await create('first');
      await create('second');
      final snapshot = await capture();
      final before = file('first').readAsBytesSync();
      final alias = Link('${temporary.path}/alias')
        ..createSync(roots.configurationRoot);
      final aliasSettings = owner(storageRoots: atConfiguration(alias.path));
      final aliasService = coordinate(aliasSettings);
      final record = (await aliasSettings.loadRecords(
        _collection,
      )).records.singleWhere((record) => record.id.value == 'first');
      await aliasService.replace(
        record,
        _slot,
        CredentialSecret('alias-replacement'),
      );
      expect(file('first').readAsBytesSync(), before);
      final calls = storage.calls;
      await expectLater(
        read(snapshot),
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      expect(storage.calls, calls);
      expect(await read(snapshot, id: 'second'), _secret);
      expect(await read(await capture()), 'alias-replacement');
    },
    skip: !Platform.isLinux,
  );

  test(
    'retargeted root aliases never reuse a cached canonical mutation key',
    () async {
      await create('first');
      final original = await capture();
      final alias = Link('${temporary.path}/alias')
        ..createSync(roots.configurationRoot);
      final aliasSettings = owner(storageRoots: atConfiguration(alias.path));
      final aliasService = coordinate(aliasSettings);
      final oldAlias = await aliasSettings.loadStartupRecords(
        catalog,
        installation,
      );
      final otherSettings = owner(
        storageRoots: atConfiguration('${temporary.path}/other-config'),
      );
      final otherService = coordinate(otherSettings);
      final otherRecord = await otherSettings.createRecord(
        RecordTypeId(_type),
        ConfigurationRecordId('first'),
        {'name': 'other'},
      );
      await otherService.attach(
        otherRecord,
        _slot,
        CredentialSecret('other-secret'),
      );
      final otherCapture = await otherSettings.loadStartupRecords(
        catalog,
        installation,
      );
      alias.updateSync('${temporary.path}/other-config');
      final record = (await aliasSettings.loadRecords(
        _collection,
      )).records.single;
      await aliasService.replace(
        record,
        _slot,
        CredentialSecret('retargeted-replacement'),
      );
      await expectLater(
        read(oldAlias, reader: aliasService),
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      await expectLater(
        read(otherCapture, reader: otherService),
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      expect(await read(original), _secret);
      expect(
        await read(
          await aliasSettings.loadStartupRecords(catalog, installation),
          reader: aliasService,
        ),
        'retargeted-replacement',
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'external equal-byte recreation and edit-restore retire startup only',
    () async {
      var record = await create('first');
      for (final recreate in [true, false]) {
        final view = await capture();
        final bytes = file('first').readAsBytesSync();
        final modified = file('first').lastModifiedSync();
        if (recreate) {
          file('first').deleteSync();
        } else {
          file('first').writeAsStringSync('temporary edit');
        }
        file('first').writeAsBytesSync(bytes);
        file('first').setLastModifiedSync(modified);
        await expectLater(
          read(view),
          _failure(AdeleCredentialFailureKind.staleConfiguration),
        );
        record = await settings.updateRecord(record, record.values);
        expect(await read(await capture()), _secret);
      }
    },
    skip: !Platform.isLinux,
  );

  test(
    'UI reload/read do not retire startup and startup does not retire UI',
    () async {
      var first = await create('first');
      final second = await create('second');
      final view = await capture();
      expect(await read(view), _secret);
      await settings.updateRecord(second, {'name': 'Updated sibling'});
      expect(await read(view), _secret);
      await service.releaseStartupRecords(await capture());
      first = await settings.updateRecord(first, first.values);
      final fresh = await capture();
      await settings.loadRecords(_collection);
      expect(await read(fresh), _secret);
      expect(first.values, {'name': 'first'});
    },
    skip: !Platform.isLinux,
  );

  test(
    'gated read allows UI work and rejects concurrent edit before publication',
    () async {
      final record = await create('first');
      await create('second');
      final view = await capture();
      storage.blockRead();
      final reading = read(view);
      final rejected = expectLater(
        reading,
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      await storage.entered!.future;
      await settings.load().timeout(const Duration(seconds: 5));
      await settings
          .updateRecord(record, {'name': 'changed'})
          .timeout(const Duration(seconds: 5));
      final unrelated = await capture().timeout(const Duration(seconds: 5));
      expect(unrelated.records, hasLength(2));
      storage.unblockRead();
      await rejected;
      expect(await read(unrelated, id: 'second'), _secret);
    },
    skip: !Platform.isLinux,
  );

  for (final mutation in ['ordinary edit', 'same-reference replacement']) {
    test(
      '$mutation after worker postcheck fences root publication',
      () async {
        final record = await create('first');
        await create('second');
        final view = await capture();
        final parentZone = Zone.current;
        final postchecked = Completer<void>();
        final continuations = <void Function()>[];
        var pause = false;
        var parked = false;
        var checks = 0;
        final reading = runZoned(
          () => read(
            view,
            validate: () {
              // The ninth generation check follows the completed serial postcheck.
              // Pause only the read's continuation, not the worker event listener.
              if (++checks == 9) {
                pause = true;
              }
            },
          ),
          zoneSpecification: ZoneSpecification(
            registerUnaryCallback: <R, T>(self, parent, zone, callback) =>
                parent.registerUnaryCallback(zone, (T value) {
                  if (pause && !parked) {
                    parked = true;
                    continuations.add(() => zone.runUnary(callback, value));
                    parentZone.run(() => postchecked.complete());
                    return null as R;
                  }
                  return callback(value);
                }),
          ),
        );
        final rejected = expectLater(
          reading,
          _failure(AdeleCredentialFailureKind.staleConfiguration),
        );
        try {
          await postchecked.future.timeout(const Duration(seconds: 5));
          if (mutation == 'ordinary edit') {
            await settings
                .updateRecord(record, {'name': 'edited'})
                .timeout(const Duration(seconds: 5));
          } else {
            await service
                .replace(record, _slot, CredentialSecret('replacement'))
                .timeout(const Duration(seconds: 5));
          }
        } finally {
          pause = false;
          for (final continuation in continuations) {
            continuation();
          }
        }
        await rejected;
        expect(await read(view, id: 'second'), _secret);
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'generation validation fences admission and late OS completion',
    () async {
      await create('first');
      final view = await capture();
      var live = false;
      void validate() {
        if (!live) throw StateError(_secret);
      }

      final calls = storage.calls;
      await expectLater(
        read(view, validate: validate),
        _failure(AdeleCredentialFailureKind.generationUnavailable),
      );
      expect(storage.calls, calls);
      live = true;
      storage.blockRead();
      final reading = read(view, validate: validate);
      final rejected = expectLater(
        reading,
        _failure(AdeleCredentialFailureKind.generationUnavailable),
      );
      await storage.entered!.future;
      live = false;
      storage.unblockRead();
      await rejected;
    },
    skip: !Platform.isLinux,
  );

  test(
    'observed ambiguous identity permanently retires only that member',
    () async {
      await create('first');
      await create('second');
      final view = await capture();
      final alias = File('${roots.configurationRoot}/accounts/FIRST.toml');
      alias.writeAsBytesSync(file('first').readAsBytesSync());
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      alias.deleteSync();
      final calls = storage.calls;
      await expectLater(
        read(view),
        _failure(AdeleCredentialFailureKind.staleConfiguration),
      );
      expect(storage.calls, calls);
      expect(await read(view, id: 'second'), _secret);
      expect(await read(await capture()), _secret);
    },
    skip: !Platform.isLinux,
  );

  test(
    'retirement while queued prevents a second native read',
    () async {
      await create('first');
      final view = await capture();
      final reference = storage.values.keys.single;
      storage.blockRead();
      final blocking = credentials.read(reference, reconcile: false);
      await storage.entered!.future;
      final calls = storage.calls;
      final queued = Completer<void>();
      var checks = 0;
      var live = true;
      final reading = read(
        view,
        validate: () {
          if (!live) throw StateError('retired');
          // Entry, pre/post worker guard, caller postcheck, then P1 admission.
          if (++checks == 5) queued.complete();
        },
      );
      final rejected = expectLater(
        reading,
        _failure(AdeleCredentialFailureKind.generationUnavailable),
      );
      await queued.future;
      live = false;
      storage.unblockRead();
      await blocking;
      await rejected;
      expect(storage.calls, calls);
    },
    skip: !Platform.isLinux,
  );

  for (final retiring in ['release', 'coordinator', 'settings', 'both']) {
    test(
      '$retiring fences late reads and drains without blocking unrelated owners',
      () async {
        await create('first');
        final view = await capture();
        storage.blockRead();
        final reading = read(view);
        final kind = retiring == 'release'
            ? AdeleCredentialFailureKind.staleConfiguration
            : AdeleCredentialFailureKind.generationUnavailable;
        final rejected = expectLater(reading, _failure(kind));
        await storage.entered!.future;
        var drained = false;
        final closing = (switch (retiring) {
          'release' => service.releaseStartupRecords(view),
          'coordinator' => service.close(),
          'settings' => settings.close(),
          _ => Future.wait([service.close(), settings.close()]),
        }).then((_) => drained = true);
        await expectLater(read(view), _failure(kind));
        expect(drained, isFalse);
        expect(
          IsolateNameServer.lookupPortByName('dev.adele.global-settings-owner'),
          isNotNull,
        );
        final other = owner();
        await other.load().timeout(const Duration(seconds: 5));
        expect(drained, isFalse);
        storage.unblockRead();
        await rejected;
        await closing;
        expect(drained, isTrue);
      },
      skip: !Platform.isLinux,
    );
  }
}

Matcher _failure(AdeleCredentialFailureKind kind) => throwsA(
  isA<AdeleCredentialFailure>()
      .having((failure) => failure.kind, 'kind', kind)
      .having(
        (failure) => failure.toString().contains(_secret),
        'redacted',
        false,
      ),
);

final class _Storage implements CredentialStorageAdapter {
  final values = <CredentialReference, String>{};
  int calls = 0;
  int writes = 0;
  int deletes = 0;
  Object? readFailure;
  bool failWrite = false;
  Completer<void>? entered;
  Completer<void>? gate;

  void blockRead() {
    entered = Completer<void>();
    gate = Completer<void>();
  }

  void unblockRead() {
    gate!.complete();
    gate = null;
  }

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls++;
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    calls++;
    final value = values[reference];
    if (gate case final waiting?) {
      if (!entered!.isCompleted) entered!.complete();
      await waiting.future;
    }
    if (readFailure case final failure?) throw failure;
    return value;
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    calls++;
    writes++;
    values[reference] = secret.reveal();
    if (failWrite) throw StateError('unconfirmed');
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    calls++;
    deletes++;
    values.remove(reference);
  }
}
