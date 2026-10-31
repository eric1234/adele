@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse, IsolateNameServer;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

const _owner = 'test.credentials';
const _child = 'test.credentials.child';
const _noOptIn = 'test.no-credentials';
const _emptyOptIn = 'test.empty-credentials';
const _type = '$_owner.account';
const _workSecret = 'test-only-work-credential';
const _personalSecret = 'test-only-personal-credential';
const _replacementSecret = 'test-only-replacement-credential';
final _slot = RecordCredentialSlotId('key');

void main() {
  late Directory artifacts;
  late File host;
  late File consumer;
  late String runtime;
  var sequence = 0;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp(
      'backend-credentials-aot-',
    );
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    runtime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    host = File('${artifacts.path}/host.aot');
    consumer = File('${artifacts.path}/consumer.aot');
    for (final target in [
      ('packages/plugin_backend_host/bin/adele_backend_host.dart', host),
      ('app/test/fixtures/backend_credential_consumer.dart', consumer),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.$1,
        artifact: target.$2,
        stage: 'backend-credential-integration',
      );
    }
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  Future<_Fixture> prepare() async {
    final directory = await Directory(
      '${artifacts.path}/case-${sequence++}',
    ).create();
    final installations = await Directory(
      '${directory.path}/installations',
    ).create();
    for (final (index, id) in [_owner, _child, _noOptIn, _emptyOptIn].indexed) {
      final installed = await Directory(
        '${installations.path}/$index-$id',
      ).create();
      await consumer.copy('${installed.path}/backend.aot');
      await File('${installed.path}/records.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'recordTypes': [
            for (final suffix in ['account', if (id == _owner) 'excluded'])
              {
                'id': '$id.$suffix',
                'collection': 'providers',
                'collectionLabel': 'Providers',
                'label': 'Account',
                'fields': [
                  {
                    'id': 'name',
                    'label': 'Name',
                    'type': 'string',
                    'required': true,
                  },
                ],
                'credentialSlots': [
                  for (final slot in ['key', 'secondary'])
                    {'id': slot, 'label': slot, 'kind': 'secret-text'},
                ],
              },
          ],
        }),
      );
      await File('${installed.path}/settings.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'definitions': [
            {
              'id': '$id.count',
              'type': 'integer',
              'default': 7,
              'label': 'Count',
              'category': 'Tests',
              'section': 'Credentials',
            },
          ],
        }),
      );
      await File(
        '${installed.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {'id': id, 'version': '1', 'displayName': id},
          'recordsSchema': 'records.json',
          'settingsSchema': 'settings.json',
          'components': {
            'backend': {
              'artifact': 'backend.aot',
              'consumesRecordTypes': ['$id.account'],
              if (id != _noOptIn)
                'consumesCredentialSlots': [
                  {
                    'recordType': '$id.account',
                    'slots': [if (id != _emptyOptIn) 'key'],
                  },
                ],
            },
          },
        }),
      );
    }
    final fixture = _Fixture(
      installations,
      PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: '${directory.path}/config',
        localStateRoot: '${directory.path}/state',
        localDataRoot: '${directory.path}/data',
        cacheRoot: '${directory.path}/cache',
      ),
      runtime,
      host.path,
    );
    addTearDown(fixture.close);
    return fixture;
  }

  test(
    'real shared host scopes two credentials and denies selectors before storage',
    () async {
      final fixture = await prepare();
      await fixture.start();
      expect(fixture.storage.calls, isEmpty);
      expect(fixture.factoryCalls, 2);
      final snapshot = await fixture.request(_owner, 'snapshot');
      expect(snapshot['settings'], {'$_owner.count': 7});
      expect(
        snapshot['records'],
        unorderedEquals([
          for (final id in ['work', 'personal', 'unconfigured'])
            {
              'collection': 'providers',
              'type': _type,
              'id': id,
              'values': {'name': id},
            },
        ]),
      );
      _expectRedacted(snapshot, fixture);
      for (final backend in fixture.bootstrap.backends) {
        expect(backend.connection!.capabilityExposures, isEmpty);
        expect(backend.connection!.extensionExposures, isEmpty);
      }
      await fixture.expectSecret('work', _workSecret);
      await fixture.expectSecret('personal', _personalSecret);
      expect(fixture.storage.calls, ['read', 'read']);
      expect(
        (await fixture.request(_owner, 'snapshot'))['exactRequests'],
        isTrue,
      );
      fixture.storage.calls.clear();
      expect(await fixture.request(_owner, 'servicePresent'), {
        'servicePresent': true,
      });
      for (final id in [_noOptIn, _emptyOptIn]) {
        expect(await fixture.request(id, 'servicePresent'), {
          'servicePresent': false,
        });
      }

      await fixture.settings.createRecord(
        RecordTypeId(_type),
        ConfigurationRecordId('new-after-startup'),
        {'name': 'New'},
      );
      for (final selectors in [
        _selectors('work', collection: 'wrong'),
        _selectors('work', recordType: 'test.unknown.account'),
        _selectors('child', recordType: '$_child.account'),
        _selectors('unknown'),
        _selectors('malformed'),
        _selectors('excluded', recordType: '$_owner.excluded'),
        _selectors('new-after-startup'),
        _selectors('work', slot: 'secondary'),
        _selectors('work', slot: 'unknown'),
      ]) {
        _expectFailure(
          await fixture.request(_owner, 'read', selectors),
          'notAuthorized',
          fixture,
        );
      }
      _expectFailure(
        await fixture.request(_child, 'read', _selectors('work')),
        'notAuthorized',
        fixture,
      );
      for (final id in [_noOptIn, _emptyOptIn]) {
        _expectFailure(
          await fixture.request(id, 'read', _selectors('work')),
          'notAuthorized',
          fixture,
        );
      }
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('unconfigured')),
        'notConfigured',
        fixture,
      );
      for (final malformed in <Map<String, Object?>>[
        {..._selectors('work'), 'reference': 'not-a-selector'},
        {..._selectors('work')}..remove('slot'),
        {..._selectors('work'), 'recordId': 3},
        {
          ..._selectors('work'),
          'slot': ['key'],
        },
      ]) {
        _expectFailure(
          await fixture.request(_owner, 'attack', {'arguments': malformed}),
          'notAuthorized',
          fixture,
        );
      }
      _expectFailure(
        await fixture.request(_owner, 'attack', {
          'method': 'enumerateCredentials',
          'arguments': _selectors('work'),
        }),
        'notAuthorized',
        fixture,
      );
      final ownerContext = (await fixture.request(
        _owner,
        'context',
      ))['context'];
      _expectFailure(
        await fixture.request(_child, 'attack', {
          'context': ownerContext,
          'arguments': _selectors('work'),
        }),
        'generationUnavailable',
        fixture,
      );
      expect(fixture.storage.calls, isEmpty);

      // Startup capture and reads do not retire ordinary Settings/edit handles.
      var settings = await fixture.settings.load();
      settings = await fixture.settings.save(
        settings,
        SettingId('$_owner.count'),
        11,
      );
      expect(settings.values[SettingId('$_owner.count')]!.value, 11);
      expect((await fixture.request(_owner, 'snapshot'))['settings'], {
        '$_owner.count': 7,
      });
    },
  );

  test(
    'standalone opt-in requires a coordinator but absent and empty opt-ins do not',
    () async {
      final fixture = await prepare();
      await fixture.start(configureCredentials: false);
      for (final id in [_owner, _child]) {
        final backend = fixture.backend(id);
        expect(backend.state, InstalledBackendState.failed);
        expect(backend.connection, isNull);
        _expectRedacted('${backend.failure}', fixture);
      }
      for (final id in [_noOptIn, _emptyOptIn]) {
        expect(fixture.backend(id).state, InstalledBackendState.active);
        _expectFailure(
          await fixture.request(id, 'read', _selectors('work')),
          'notAuthorized',
          fixture,
        );
      }
      expect(fixture.storage.calls, isEmpty);
      expect(fixture.factoryCalls, 0);
    },
  );

  test(
    'ordinary values and reference edits stale only the captured record',
    () async {
      final fixture = await prepare();
      await fixture.start();
      final before = await fixture.request(_owner, 'snapshot');
      fixture.records['work'] = await fixture.settings.updateRecord(
        fixture.records['work']!,
        {'name': 'Changed'},
      );
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'staleConfiguration',
        fixture,
      );
      expect(fixture.storage.calls, isEmpty);
      await fixture.expectSecret('personal', _personalSecret);
      expect(await fixture.request(_owner, 'snapshot'), before);

      await fixture.restart();
      final nextRecords =
          (await fixture.request(_owner, 'snapshot'))['records']! as List;
      expect(
        (nextRecords.singleWhere((record) => (record as Map)['id'] == 'work')
            as Map)['values'],
        {'name': 'Changed'},
      );
      await fixture.expectSecret('work', _workSecret);
      final file = fixture.file('work');
      final text = await file.readAsString();
      await file.writeAsString(
        text.replaceAll(
          fixture.storage.referenceFor('work').value,
          fixture.storage.referenceFor('personal').value,
        ),
      );
      fixture.storage.calls.clear();
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'staleConfiguration',
        fixture,
      );
      expect(fixture.storage.calls, isEmpty);
      await fixture.expectSecret('personal', _personalSecret);
    },
  );

  test(
    'replacement captures fresh credential authority and never revives an old grant',
    () async {
      final fixture = await prepare();
      await fixture.start();
      final old = fixture.backend(_owner).connection!;
      final oldContext = (await fixture.request(_owner, 'context'))['context'];
      final before = await fixture.file('work').readAsBytes();
      final result = await fixture.associations.replace(
        fixture.records['work']!,
        _slot,
        CredentialSecret(_replacementSecret),
      );
      fixture.records['work'] = result.record;
      expect(await fixture.file('work').readAsBytes(), before);
      fixture.storage.calls.clear();
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'staleConfiguration',
        fixture,
      );
      expect(fixture.storage.calls, isEmpty);
      await fixture.expectSecret('personal', _personalSecret);
      await fixture.restart();
      expect(old.isClosed, isTrue);
      await expectLater(
        old.request('read', _selectors('work')),
        throwsA(isA<PluginConnectionClosed>()),
      );
      _expectFailure(
        await fixture.request(_owner, 'attack', {
          'context': oldContext,
          'arguments': _selectors('work'),
        }),
        'generationUnavailable',
        fixture,
      );
      expect(fixture.storage.calls, isEmpty);
      await fixture.expectSecret('work', _replacementSecret);
      await fixture.expectSecret('personal', _personalSecret);
    },
  );

  for (final closeBootstrap in [false, true]) {
    test('retirement settles a pending OS read and discards its late secret '
        '(bootstrap close: $closeBootstrap)', () async {
      final fixture = await prepare();
      await fixture.start();
      final gate = fixture.storage.gate = _ReadGate();
      addTearDown(gate.release);
      final pending = fixture.request(_owner, 'read', _selectors('work'));
      await gate.entered.future;
      final connection = fixture.backend(_owner).connection!;
      var closed = false;
      Future<void>? closing;
      if (closeBootstrap) {
        closing = fixture.bootstrap.close().then((_) => closed = true);
      } else {
        connection.revokeInfrastructureContext();
      }
      _expectFailure(await pending, 'generationUnavailable', fixture);
      expect(gate.returned.isCompleted, isFalse);
      expect(closed, isFalse);
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'generationUnavailable',
        fixture,
      );
      gate.release();
      await gate.returned.future;
      await fixture.associations.close();
      await closing;
      expect(fixture.storage.calls, ['read']);
      if (closeBootstrap) {
        expect(closed, isTrue);
        expect(connection.isClosed, isTrue);
      } else {
        _expectRedacted(await fixture.request(_owner, 'snapshot'), fixture);
      }
    });
  }

  testWidgets(
    'accepted application exit fences backend reads and drains admitted storage',
    (tester) => tester.runAsync(() async {
      final fixture = await prepare();
      await fixture.start();
      await fixture.close();
      final appRuntime = NativeAdeleRuntime();
      final appCredentials = CredentialService(fixture.storage);
      final closeStarted = Completer<void>();
      late Future<void> starting;
      _ReadGate? gate;
      try {
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => appRuntime,
            createCredentials: () => appCredentials,
            configurationRoots: fixture.roots,
            readChatGptConfiguration: () => null,
            attachSessionContext: (_) =>
                () => closeStarted.complete(),
            bootstrapPlugins: (plugins) => starting = plugins.start(
              installationRoot: fixture.installations.path,
              dartaotruntimeExecutable: fixture.runtime,
              hostArtifactPath: fixture.host,
            ),
          ),
        );
        await starting;
        expect(appRuntime.plugins.state, ApplicationPluginState.ready);
        final backend = appRuntime.plugins.backends.singleWhere(
          (entry) => entry.installation.metadata.id.value == _owner,
        );
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
        final connection = backend.connection!;
        expect(fixture.storage.calls, isEmpty);
        expect(
          IsolateNameServer.lookupPortByName('dev.adele.global-settings-owner'),
          isNotNull,
        );
        final pendingGate = gate = fixture.storage.gate = _ReadGate();
        final pending = connection
            .request('read', _selectors('work'))
            .then<Object?>(
              (value) => value,
              onError: (Object error) {
                _expectRedacted(error, fixture);
                return {'closed': error is PluginConnectionClosed};
              },
            );
        await pendingGate.entered.future;
        var exited = false;
        final exiting = tester.binding.handleRequestAppExit().then((result) {
          exited = true;
          return result;
        });
        await closeStarted.future;
        _expectFailure(
          Map<String, Object?>.from(
            await connection.request('read', _selectors('personal')) as Map,
          ),
          'generationUnavailable',
          fixture,
        );
        expect(fixture.storage.calls, ['read']);
        expect(exited, isFalse);
        expect(pendingGate.returned.isCompleted, isFalse);
        pendingGate.release();
        final result = await pending;
        _expectRedacted(result, fixture);
        expect(
          result,
          anyOf(
            {'closed': true},
            {
              'failure': 'generationUnavailable',
              'display': 'Credential access failed (generationUnavailable).',
            },
          ),
        );
        expect(await exiting, AppExitResponse.exit);
        expect(appRuntime.plugins.state, ApplicationPluginState.closed);
        expect(pendingGate.returned.isCompleted, isTrue);
        expect(fixture.storage.calls, ['read']);
        expect(
          IsolateNameServer.lookupPortByName('dev.adele.global-settings-owner'),
          isNull,
        );
        expect(tester.takeException(), isNull);
      } finally {
        gate?.release();
        await tester.pumpWidget(const SizedBox.shrink());
        await appRuntime.close();
        await appCredentials.close();
      }
    }),
  );

  test(
    'pending read rechecks configuration without blocking Settings',
    () async {
      final fixture = await prepare();
      await fixture.start();
      final gate = fixture.storage.gate = _ReadGate();
      addTearDown(gate.release);
      final pending = fixture.request(_owner, 'read', _selectors('work'));
      await gate.entered.future;
      fixture.records['work'] = await fixture.settings.updateRecord(
        fixture.records['work']!,
        {'name': 'While locked'},
      );
      final settings = await fixture.settings.load();
      await fixture.settings.save(settings, SettingId('$_owner.count'), 12);
      expect(gate.returned.isCompleted, isFalse);
      gate.release();
      _expectFailure(await pending, 'staleConfiguration', fixture);
      await fixture.expectSecret('personal', _personalSecret);
      expect(fixture.storage.calls, ['read', 'read']);
    },
  );

  test(
    'storage failures and invalid protected values cross AOT only as safe kinds',
    () async {
      final fixture = await prepare();
      await fixture.start();
      final reference = fixture.storage.referenceFor('work');
      final personalReference = fixture.storage.referenceFor('personal');
      final original = fixture.storage.values[reference]!;
      fixture.storage.values.remove(reference);
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'missingLocally',
        fixture,
      );
      fixture.storage.values[reference] = 'invalid-envelope-$_workSecret';
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'invalidCredentialBinding',
        fixture,
      );
      fixture.storage.values[reference] =
          fixture.storage.values[personalReference]!;
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'invalidCredentialBinding',
        fixture,
      );
      fixture.storage.values[reference] = original;
      fixture.storage.failure = const CredentialFailure(
        CredentialFailureKind.unavailable,
      );
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'storageUnavailable',
        fixture,
      );
      fixture.storage.failure = StateError('native diagnostic $_workSecret');
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'credentialAccessFailed',
        fixture,
      );
      fixture.storage.failure = null;
      fixture.storage.writeFailure = StateError(
        'write diagnostic $_workSecret',
      );
      await expectLater(
        fixture.credentials.replace(reference, CredentialSecret(original)),
        throwsA(isA<CredentialFailure>()),
      );
      fixture.storage.writeFailure = null;
      fixture.storage.calls.clear();
      _expectFailure(
        await fixture.request(_owner, 'read', _selectors('work')),
        'reconciliationRequired',
        fixture,
      );
      expect(fixture.storage.calls, isEmpty);
      expect(fixture.credentials.requiresReconciliation(reference), isTrue);
      await fixture.expectSecret('personal', _personalSecret);
    },
  );
}

Map<String, Object?> _selectors(
  String recordId, {
  String collection = 'providers',
  String recordType = _type,
  String slot = 'key',
}) => {
  'collection': collection,
  'recordType': recordType,
  'recordId': recordId,
  'slot': slot,
};

void _expectFailure(
  Map<String, Object?> result,
  String kind,
  _Fixture fixture,
) {
  _expectRedacted(result, fixture);
  expect(result, {
    'failure': kind,
    'display': 'Credential access failed ($kind).',
  });
}

void _expectRedacted(Object? value, _Fixture fixture) {
  final text = '$value';
  for (final forbidden in [
    _workSecret,
    _personalSecret,
    _replacementSecret,
    'cred1_',
    fixture.roots.configurationRoot,
    'native diagnostic',
  ]) {
    // Assert a boolean so even a failing test does not print the payload.
    expect(
      text.contains(forbidden),
      isFalse,
      reason: 'Credential detail escaped its authorized response.',
    );
  }
}

final class _Fixture {
  _Fixture(this.installations, this.roots, this.runtime, this.host);

  final Directory installations;
  final PlatformStorageRoots roots;
  final String runtime;
  final String host;
  final storage = _Storage();
  final records = <String, RecordView>{};
  final owners = <GlobalSettingsService>[];
  final coordinators = <RecordCredentialService>[];
  late final credentials = CredentialService(storage);
  late GlobalSettingsService settings;
  late RecordCredentialService associations;
  late ApplicationPluginBootstrap bootstrap;
  var factoryCalls = 0;

  File file(String id) => File('${roots.configurationRoot}/providers/$id.toml');

  Future<void> start({bool configureCredentials = true}) async {
    bootstrap = ApplicationPluginBootstrap(
      CapabilityRegistry(),
      ExtensionRegistry(),
      loadSettings: (catalog) async {
        expect(catalog.issues, isEmpty);
        settings = GlobalSettingsService(
          catalog: catalog.settings,
          records: catalog.records,
          roots: roots,
        );
        owners.add(settings);
        associations = RecordCredentialService(
          settings: settings,
          credentials: credentials,
        );
        coordinators.add(associations);
        if (records.isEmpty) {
          for (final (id, type, secret) in [
            ('work', _type, _workSecret),
            ('personal', _type, _personalSecret),
            ('unconfigured', _type, null),
            ('excluded', '$_owner.excluded', 'test-only-excluded'),
            ('child', '$_child.account', 'test-only-child'),
          ]) {
            var record = await settings.createRecord(
              RecordTypeId(type),
              ConfigurationRecordId(id),
              {'name': id},
            );
            if (secret != null) {
              record = (await associations.attach(
                record,
                _slot,
                CredentialSecret(secret),
              )).record;
            }
            records[id] = record;
          }
          await file('malformed').writeAsString('not valid TOML = [');
        }
        storage.calls.clear();
        return PreparedSettingsSnapshot.resolve(catalog);
      },
      loadRecords: (catalog, installation) =>
          settings.loadStartupRecords(catalog, installation),
      credentialAssociations: configureCredentials
          ? () {
              factoryCalls++;
              return associations;
            }
          : null,
    );
    await bootstrap.start(
      installationRoot: installations.path,
      dartaotruntimeExecutable: runtime,
      hostArtifactPath: host,
    );
    expect(bootstrap.state, ApplicationPluginState.ready);
    expect(bootstrap.catalog!.issues, isEmpty);
    expect(bootstrap.backends, hasLength(4));
    if (configureCredentials) {
      for (final backend in bootstrap.backends) {
        expect(
          backend.state,
          InstalledBackendState.active,
          reason: '${backend.failure}',
        );
      }
    }
  }

  InstalledBackendActivation backend(String id) => bootstrap.backends
      .singleWhere((entry) => entry.installation.metadata.id.value == id);

  Future<Map<String, Object?>> request(
    String owner,
    String method, [
    Map<String, Object?> payload = const {},
  ]) async => Map<String, Object?>.from(
    await backend(owner).connection!.request(method, payload) as Map,
  );

  Future<void> expectSecret(String id, String expected) async {
    final result = await request(_owner, 'read', _selectors(id));
    expect(
      result.length == 1 && result['secret'] == expected,
      isTrue,
      reason:
          'Explicit authorized read did not return its exact synthetic credential.',
    );
  }

  Future<void> restart() async {
    await bootstrap.close();
    await start();
    expect(storage.calls, isEmpty);
  }

  Future<void> close() async {
    storage.gate?.release();
    await bootstrap.close();
    for (final coordinator in coordinators.reversed) {
      await coordinator.close();
    }
    for (final owner in owners.reversed) {
      await owner.close();
    }
    await credentials.close();
  }
}

final class _ReadGate {
  final entered = Completer<void>();
  final resumed = Completer<void>();
  final returned = Completer<void>();
  void release() {
    if (!resumed.isCompleted) resumed.complete();
  }
}

final class _Storage implements CredentialStorageAdapter {
  final values = <CredentialReference, String>{};
  final calls = <String>[];
  _ReadGate? gate;
  Object? failure;
  Object? writeFailure;

  CredentialReference referenceFor(String record) => values.entries
      .singleWhere(
        (entry) => (jsonDecode(entry.value) as Map)['record'] == record,
      )
      .key;

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls.add('contains');
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    calls.add('read');
    final captured = values[reference];
    final pending = gate;
    if (pending != null) {
      gate = null;
      pending.entered.complete();
      await pending.resumed.future;
      pending.returned.complete();
    }
    if (failure case final error?) throw error;
    return captured;
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    calls.add('write');
    values[reference] = secret.reveal();
    if (writeFailure case final error?) throw error;
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    calls.add('delete');
    values.remove(reference);
  }
}
