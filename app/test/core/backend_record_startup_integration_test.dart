@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
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

import '../support/gated_credential_storage.dart';

const _owner = 'test.records';
const _nested = 'test.records.child';
const _empty = 'test.empty';
const _independent = 'test.independent';

void main() {
  late Directory artifacts;
  late File host;
  late File observer;
  late String runtime;
  var sequence = 0;

  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('record-startup-aot-');
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    runtime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    host = File('${artifacts.path}/host.aot');
    observer = File('${artifacts.path}/observer.aot');
    for (final target in [
      ('packages/plugin_backend_host/bin/adele_backend_host.dart', host),
      ('app/test/fixtures/backend_record_observer.dart', observer),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: target.$1,
        artifact: target.$2,
        stage: 'backend-record-startup',
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
    for (final (index, id) in [_owner, _nested, _empty, _independent].indexed) {
      final installed = await Directory(
        '${installations.path}/$index-$id',
      ).create();
      await observer.copy('${installed.path}/backend.aot');
      final collection = id == _independent ? 'runners' : 'jobs';
      await File('${installed.path}/records.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'recordTypes': [
            for (final suffix in ['record', if (id == _owner) 'private'])
              {
                'id': '$id.$suffix',
                'collection': collection,
                'collectionLabel': collection,
                'label': suffix,
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
              'section': 'Startup',
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
          'settingsSchema': 'settings.json',
          'recordsSchema': 'records.json',
          'components': {
            'backend': {
              'artifact': 'backend.aot',
              if (id != _empty) 'consumesRecordTypes': ['$id.record'],
            },
          },
        }),
      );
    }
    return _Fixture(
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
  }

  test(
    'real AOT startup isolates exact installations and generation snapshots',
    () async {
      final fixture = await prepare();
      GlobalSettingsService? service;
      final loaded = <String>[];
      final saved = <String, RecordView>{};
      final diagnostics = <RecordDiagnosticView>[];
      final bootstrap = fixture.bootstrap((catalog, installation) async {
        loaded.add(installation.metadata.id.value);
        if (service == null) {
          service = fixture.service(catalog);
          for (final id in [_owner, _nested, _independent]) {
            saved[id] = await service!.createRecord(
              RecordTypeId('$id.record'),
              ConfigurationRecordId(
                id == _owner ? 'work' : 'peer-${saved.length}',
              ),
              {'name': id, if (id == _owner) 'enabled': false},
            );
          }
          await service!.createRecord(
            RecordTypeId('$_owner.private'),
            ConfigurationRecordId('unconsumed'),
            {'name': 'Not opted in'},
          );
          await File(
            '${fixture.roots.configurationRoot}/jobs/broken.toml',
          ).writeAsString('not valid TOML = [');
        }
        final result = await service!.loadStartupRecords(catalog, installation);
        diagnostics.addAll(result.diagnostics);
        return result;
      });
      await fixture.start(bootstrap);
      expect(loaded.toSet(), {_owner, _nested, _independent});
      expect(
        diagnostics.any((entry) => entry.fileName == 'broken.toml'),
        isTrue,
      );
      expect(
        bootstrap.backends.every(
          (entry) => entry.connection!.capabilityExposures.isEmpty,
        ),
        isTrue,
      );
      for (final id in [_owner, _nested, _independent]) {
        final records = await _records(bootstrap, id);
        expect(records, hasLength(1));
        expect((records.single as Map)['type'], '$id.record');
        expect((records.single as Map)['id'], saved[id]!.id.value);
        expect((records.single as Map)['values'], saved[id]!.values);
        expect(
          await _backend(bootstrap, id).connection!.request('settings', {}),
          {'$id.count': 7},
        );
      }
      expect(await _records(bootstrap, _empty), isEmpty);
      final first = await _records(bootstrap, _owner);
      // The startup read did not retire this edit handle. Disk mutation cannot
      // mutate the already running isolate's immutable startup data.
      saved[_owner] = await service!.updateRecord(saved[_owner]!, {
        'name': 'New',
      });
      expect(await _records(bootstrap, _owner), first);
      final oldConnection = _backend(bootstrap, _owner).connection!;
      await bootstrap.close();
      GlobalSettingsService? nextService;
      final replacement = fixture.bootstrap((catalog, installation) async {
        nextService ??= fixture.service(catalog);
        return nextService!.loadStartupRecords(catalog, installation);
      });
      await fixture.start(replacement);
      final next = await _records(replacement, _owner);
      expect((next.single as Map)['id'], 'work');
      expect((next.single as Map)['values'], {'name': 'New'});
      expect(oldConnection.isClosed, isTrue);
      await expectLater(
        oldConnection.request('records', {}),
        throwsA(isA<PluginConnectionClosed>()),
      );
    },
  );

  test(
    'live AOT reads observe host CRUD on one connection and retain old snapshots',
    () async {
      final fixture = await prepare();
      GlobalSettingsService? reader;
      late GlobalSettingsService settings;
      late RecordView work;
      final liveLoads = <String>[];
      final bootstrap = fixture.bootstrap(
        (catalog, installation) async {
          if (reader == null) {
            reader = fixture.service(catalog);
            settings = fixture.service(catalog);
            work = await settings.createRecord(
              RecordTypeId('$_owner.record'),
              ConfigurationRecordId('work'),
              {'name': 'Original', 'enabled': false},
            );
            for (final id in [_nested, _empty, _independent]) {
              await settings.createRecord(
                RecordTypeId('$id.record'),
                ConfigurationRecordId('peer-${id.split('.').last}'),
                {'name': id},
              );
            }
            await settings.createRecord(
              RecordTypeId('$_owner.private'),
              ConfigurationRecordId('private'),
              {'name': 'Not consumed'},
            );
          }
          return reader!.loadStartupRecords(catalog, installation);
        },
        currentLoader: (catalog, installation) {
          liveLoads.add(installation.metadata.id.value);
          return reader!.loadCurrentRecords(catalog, installation);
        },
      );
      await fixture.start(bootstrap);
      expect(bootstrap.catalog!.issues, isEmpty);
      expect(liveLoads, isEmpty);
      final connection = _backend(bootstrap, _owner).connection!;
      final unrelated = CapabilityKey(
        id: CapabilityId('test.unrelated'),
        majorVersion: 1,
      );
      const endpoint = _UnrelatedEndpoint();
      final registration = bootstrap.registry.register(
        provider: ProviderDescriptor(
          id: ProviderId('test.unrelated.provider'),
          capability: unrelated,
          pluginId: 'test.unrelated',
          displayName: 'Unrelated native provider',
          serviceId: endpoint.serviceId,
        ),
        endpoint: endpoint,
      );
      addTearDown(registration.close);
      final binding = bootstrap.registry.resolve(unrelated);
      var registryChanges = 0;
      final subscription = bootstrap.registry.changes.listen(
        (_) => registryChanges++,
      );
      addTearDown(subscription.cancel);
      void expectUnrelatedProviderUnchanged() {
        expect(registryChanges, 0);
        expect(registration.isClosed, isFalse);
        expect(binding.endpointAs<_UnrelatedEndpoint>(), same(endpoint));
        expect(
          bootstrap.registry.resolve(unrelated).isSameRegistration(binding),
          isTrue,
        );
        expect(bootstrap.registry.providersFor(unrelated), [binding.provider]);
      }

      final scalarBaseline = await settings.load();
      final original = _record('work', {'name': 'Original', 'enabled': false});
      expect(await _records(bootstrap, _owner), [original]);
      final first = await _request(bootstrap, _owner, 'currentRecords');
      expect(first, {
        'records': [original],
        'isComplete': true,
      });
      expectUnrelatedProviderUnchanged();
      final created = await settings.createRecord(
        RecordTypeId('$_owner.record'),
        ConfigurationRecordId('zulu'),
        {'name': 'Created'},
      );
      final afterCreate = await _request(bootstrap, _owner, 'currentRecords');
      expect(afterCreate, {
        'records': [
          original,
          _record('zulu', {'name': 'Created'}),
        ],
        'isComplete': true,
      });
      expectUnrelatedProviderUnchanged();
      // Reads through a separate owner must not retire Settings edit baselines.
      work = await settings.updateRecord(work, {'name': 'Updated'});
      final updated = _record('work', {'name': 'Updated'});
      final afterUpdate = await _request(bootstrap, _owner, 'currentRecords');
      expect(afterUpdate, {
        'records': [
          updated,
          _record('zulu', {'name': 'Created'}),
        ],
        'isComplete': true,
      });
      expectUnrelatedProviderUnchanged();
      await settings.deleteRecord(created);
      expect(
        File('${fixture.roots.configurationRoot}/jobs/zulu.toml').existsSync(),
        isFalse,
      );
      final afterDelete = await _request(bootstrap, _owner, 'currentRecords');
      expect(afterDelete, {
        'records': [updated],
        'isComplete': true,
      });
      expectUnrelatedProviderUnchanged();
      expect(await _request(bootstrap, _owner, 'retained'), {
        'observations': [first, afterCreate, afterUpdate, afterDelete],
        'immutable': true,
        'exactRequests': true,
      });
      expect(await _records(bootstrap, _owner), [original]);
      expect(
        identical(_backend(bootstrap, _owner).connection, connection),
        isTrue,
      );
      expect(connection.isClosed, isFalse);
      expect(liveLoads, [_owner, _owner, _owner, _owner]);
      for (final id in [_nested, _independent]) {
        expect(await _request(bootstrap, id, 'currentRecords'), {
          'records': [
            _record(
              'peer-${id.split('.').last}',
              {'name': id},
              owner: id,
              collection: id == _independent ? 'runners' : 'jobs',
            ),
          ],
          'isComplete': true,
        });
      }
      _expectFailure(
        await _request(bootstrap, _empty, 'currentRecords'),
        'notAuthorized',
      );
      expect(liveLoads, isNot(contains(_empty)));
      await settings.save(scalarBaseline, SettingId('$_owner.count'), 11);
      expect(await _request(bootstrap, _owner, 'settings'), {
        '$_owner.count': 7,
      });
      for (final backend in bootstrap.backends) {
        expect(backend.state, InstalledBackendState.active);
        expect(backend.connection!.capabilityExposures, isEmpty);
        expect(backend.connection!.extensionExposures, isEmpty);
      }
      expectUnrelatedProviderUnchanged();
    },
  );

  test('live service is absent without a configured loader', () async {
    final fixture = await prepare();
    GlobalSettingsService? reader;
    final bootstrap = fixture.bootstrap((catalog, installation) {
      reader ??= fixture.service(catalog);
      return reader!.loadStartupRecords(catalog, installation);
    });
    await fixture.start(bootstrap);
    for (final id in [_owner, _nested, _empty, _independent]) {
      expect(_backend(bootstrap, id).state, InstalledBackendState.active);
      _expectFailure(
        await _request(bootstrap, id, 'currentRecords'),
        'notAuthorized',
      );
    }
    expect(Directory(fixture.roots.configurationRoot).existsSync(), isFalse);
    expect(
      () => bootstrap.configureCurrentRecordsLoader(reader!.loadCurrentRecords),
      throwsStateError,
    );
  });

  test(
    'live reads distinguish partial and all-invalid from clean empty and unavailable',
    () async {
      final fixture = await prepare();
      GlobalSettingsService? reader;
      final bootstrap = fixture.bootstrap(
        (catalog, installation) {
          reader ??= fixture.service(catalog);
          return reader!.loadStartupRecords(catalog, installation);
        },
        currentLoader: (catalog, installation) =>
            reader!.loadCurrentRecords(catalog, installation),
      );
      await fixture.start(bootstrap);
      expect(await _request(bootstrap, _owner, 'currentRecords'), {
        'records': <Object?>[],
        'isComplete': true,
      });
      expect(Directory(fixture.roots.configurationRoot).existsSync(), isFalse);
      final healthy = await reader!.createRecord(
        RecordTypeId('$_owner.record'),
        ConfigurationRecordId('healthy'),
        {'name': 'Healthy'},
      );
      final jobs = Directory('${fixture.roots.configurationRoot}/jobs');
      final invalidFiles = <File, String>{
        File('${jobs.path}/broken-marker.toml'): 'invalid = [',
        File('${jobs.path}/unknown-marker.toml'):
            'recordVersion = 1\nrecordType = "test.unknown.record"\n'
            '[values]\nname = "Unknown marker"\n',
        File('${jobs.path}/invalid-marker.toml'):
            'recordVersion = 1\nrecordType = "$_owner.record"\n'
            '[values]\nname = 42\n',
      };
      for (final entry in invalidFiles.entries) {
        await entry.key.writeAsString(entry.value);
      }
      expect(await _request(bootstrap, _owner, 'currentRecords'), {
        'records': [
          _record('healthy', {'name': 'Healthy'}),
        ],
        'isComplete': false,
      });
      await reader!.deleteRecord(healthy);
      expect(await _request(bootstrap, _owner, 'currentRecords'), {
        'records': <Object?>[],
        'isComplete': false,
      });
      for (final entry in invalidFiles.entries) {
        expect(await entry.key.readAsString(), entry.value);
        await entry.key.delete();
      }
      expect(await _request(bootstrap, _owner, 'currentRecords'), {
        'records': <Object?>[],
        'isComplete': true,
      });
      await jobs.delete();
      await File(jobs.path).writeAsString('directory-unavailable-marker');
      _expectFailure(
        await _request(bootstrap, _owner, 'currentRecords'),
        'configurationUnavailable',
      );
      expect(await _request(bootstrap, _independent, 'currentRecords'), {
        'records': <Object?>[],
        'isComplete': true,
      });
      expect(await _records(bootstrap, _owner), isEmpty);
      expect(_backend(bootstrap, _owner).state, InstalledBackendState.active);
    },
  );

  test(
    'live raw selectors and mutation methods are rejected before loading',
    () async {
      final fixture = await prepare();
      GlobalSettingsService? reader;
      var liveLoads = 0;
      final bootstrap = fixture.bootstrap((catalog, installation) {
        reader ??= fixture.service(catalog);
        return reader!.loadStartupRecords(catalog, installation);
      });
      bootstrap.configureCurrentRecordsLoader((catalog, installation) {
        liveLoads++;
        return reader!.loadCurrentRecords(catalog, installation);
      });
      await fixture.start(bootstrap);
      for (final selectors in <Map<String, Object?>>[
        {'owner': _nested},
        {'collection': 'jobs'},
        {'recordType': '$_owner.private'},
        {'recordType': '$_nested.record'},
        {'recordId': 'work'},
        {'path': fixture.roots.configurationRoot},
        {'records': []},
        {'selector': null},
      ]) {
        _expectFailure(
          await _request(bootstrap, _owner, 'attack', {'arguments': selectors}),
          'notAuthorized',
        );
      }
      _expectFailure(
        await _request(bootstrap, _owner, 'attack', {
          'method': 'deleteRecord',
          'arguments': <String, Object?>{},
        }),
        'notAuthorized',
      );
      expect(liveLoads, 0);
      expect(await _request(bootstrap, _owner, 'currentRecords'), {
        'records': <Object?>[],
        'isComplete': true,
      });
      expect(liveLoads, 1);
    },
  );

  for (final closeBootstrap in [false, true]) {
    test('retirement settles a pending live observation and suppresses late data '
        '(bootstrap close: $closeBootstrap)', () async {
      final fixture = await prepare();
      GlobalSettingsService? reader;
      late RecordView work;
      final entered = Completer<StartupRecordsView>();
      final release = Completer<void>();
      final returned = Completer<void>();
      var gateNext = false;
      var liveLoads = 0;
      final bootstrap = fixture.bootstrap(
        (catalog, installation) async {
          if (reader == null) {
            reader = fixture.service(catalog);
            work = await reader!.createRecord(
              RecordTypeId('$_owner.record'),
              ConfigurationRecordId('work'),
              {'name': 'Before'},
            );
          }
          return reader!.loadStartupRecords(catalog, installation);
        },
        currentLoader: (catalog, installation) async {
          liveLoads++;
          final observed = await reader!.loadCurrentRecords(
            catalog,
            installation,
          );
          if (gateNext) {
            entered.complete(observed);
            await release.future;
            returned.complete();
          }
          return observed;
        },
      );
      // Unblock even after an assertion failure before bootstrap/worker teardown.
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await fixture.start(bootstrap);
      final first = await _request(bootstrap, _owner, 'currentRecords');
      await reader!.updateRecord(work, {'name': 'Late result'});
      gateNext = true;
      final connection = _backend(bootstrap, _owner).connection!;
      final pending = _request(bootstrap, _owner, 'currentRecords')
          .then<Object?>(
            (result) => result,
            onError: (Object error) {
              expect(error, isA<PluginConnectionClosed>());
              return {'closed': true};
            },
          );
      expect((await entered.future).records, [
        _record('work', {'name': 'Late result'}),
      ]);
      Future<void>? closing;
      if (closeBootstrap) {
        closing = bootstrap.close();
      } else {
        connection.revokeInfrastructureContext();
      }
      final result = await pending.timeout(const Duration(seconds: 10));
      if (closeBootstrap && result is Map && result['closed'] == true) {
        expect(connection.isClosed, isTrue);
      } else {
        _expectFailure(
          Map<String, Object?>.from(result! as Map),
          'generationUnavailable',
        );
      }
      expect(returned.isCompleted, isFalse);
      release.complete();
      await returned.future;
      await closing;
      if (closeBootstrap) {
        expect(connection.isClosed, isTrue);
        expect(bootstrap.state, ApplicationPluginState.closed);
      } else {
        _expectFailure(
          await _request(bootstrap, _owner, 'currentRecords'),
          'generationUnavailable',
        );
        expect(await _request(bootstrap, _owner, 'retained'), {
          'observations': [first],
          'immutable': true,
          'exactRequests': true,
        });
      }
      expect(liveLoads, 2);
    });
  }

  test(
    'directory failure is not empty and unrelated collection still starts',
    () async {
      final fixture = await prepare();
      await Directory(fixture.roots.configurationRoot).create();
      await File(
        '${fixture.roots.configurationRoot}/jobs',
      ).writeAsString('file');
      GlobalSettingsService? service;
      final bootstrap = fixture.bootstrap((catalog, installation) async {
        service ??= fixture.service(catalog);
        return service!.loadStartupRecords(catalog, installation);
      });
      await fixture.start(bootstrap);
      for (final id in [_owner, _nested]) {
        expect(_backend(bootstrap, id).state, InstalledBackendState.failed);
        expect(_backend(bootstrap, id).failure, isNotNull);
        expect(_backend(bootstrap, id).connection, isNull);
      }
      expect(await _records(bootstrap, _empty), isEmpty);
      expect(await _records(bootstrap, _independent), isEmpty);
      expect(
        Directory('${fixture.roots.configurationRoot}/runners').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'closing during record load never starts a late plugin isolate',
    () async {
      final fixture = await prepare();
      final entered = Completer<void>();
      final release = Completer<void>();
      final bootstrap = fixture.bootstrap((catalog, installation) async {
        final service = fixture.service(catalog);
        entered.complete();
        await release.future;
        return service.loadStartupRecords(catalog, installation);
      });
      final starting = fixture.start(bootstrap);
      await entered.future;
      final closing = bootstrap.close();
      release.complete();
      await starting;
      await closing;
      expect(
        bootstrap.backends.every((entry) => entry.connection == null),
        isTrue,
      );
      expect(bootstrap.state, ApplicationPluginState.closed);
      expect(Directory(fixture.roots.configurationRoot).existsSync(), isFalse);
    },
  );

  testWidgets(
    'application default live loader observes separate Settings owner creation',
    (tester) => tester.runAsync(() async {
      final fixture = await prepare();
      final appRuntime = NativeAdeleRuntime();
      final storage = GatedCredentialStorage()..release.complete();
      final credentials = CredentialService(storage);
      late Future<void> starting;
      try {
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => appRuntime,
            createCredentials: () => credentials,
            configurationRoots: fixture.roots,
            readChatGptConfiguration: () => null,
            bootstrapPlugins: (plugins) => starting = fixture.start(plugins),
          ),
        );
        await starting;
        final plugins = appRuntime.plugins;
        expect(plugins.state, ApplicationPluginState.ready);
        expect(plugins.catalog!.issues, isEmpty);
        final connection = _backend(plugins, _owner).connection!;
        final empty = await _request(plugins, _owner, 'currentRecords');
        expect(empty, {'records': <Object?>[], 'isComplete': true});
        expect(
          Directory(fixture.roots.configurationRoot).existsSync(),
          isFalse,
        );
        // This owner uses the app's exact discovered declarations and real worker,
        // while both startup and live reads retain the application's own loaders.
        final settings = fixture.service(plugins.catalog!);
        await settings.createRecord(
          RecordTypeId('$_owner.record'),
          ConfigurationRecordId('created-in-settings'),
          {'name': 'From Settings', 'enabled': false},
        );
        final current = await _request(plugins, _owner, 'currentRecords');
        expect(current, {
          'records': [
            _record('created-in-settings', {
              'name': 'From Settings',
              'enabled': false,
            }),
          ],
          'isComplete': true,
        });
        expect(await _records(plugins, _owner), isEmpty);
        expect(_backend(plugins, _owner).connection, same(connection));
        expect(connection.isClosed, isFalse);
        expect(await _request(plugins, _owner, 'retained'), {
          'observations': [empty, current],
          'immutable': true,
          'exactRequests': true,
        });
        expect(storage.calls, 0);
        expect(storage.entered.isCompleted, isFalse);
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
        expect(plugins.state, ApplicationPluginState.closed);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await appRuntime.close();
        await credentials.close();
      }
    }),
  );

  testWidgets(
    'accepted application exit fences startup before runtime draining',
    (tester) => tester.runAsync(() async {
      final fixture = await prepare();
      final appRuntime = NativeAdeleRuntime();
      final reading = Completer<void>();
      final releaseRead = Completer<void>();
      final draining = Completer<void>();
      final storage = GatedCredentialStorage();
      final credentials = CredentialService(storage);
      Future<void>? starting;
      try {
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => appRuntime,
            createCredentials: () => credentials,
            configurationRoots: fixture.roots,
            readChatGptConfiguration: () => null,
            bootstrapPlugins: (plugins) {
              plugins.configureSettingsLoader(
                (catalog) async => PreparedSettingsSnapshot.resolve(catalog),
              );
              GlobalSettingsService? service;
              plugins.configureRecordsLoader((catalog, installation) async {
                service ??= fixture.service(catalog);
                reading.complete();
                await releaseRead.future;
                return service!.loadStartupRecords(catalog, installation);
              });
              return starting = fixture.start(plugins);
            },
          ),
        );
        appRuntime.extensions
            .discover(commandContributions)
            .singleWhere(
              (binding) => binding.value.id == showCommandPaletteCommandId,
            )
            .onRetire(draining.complete);
        await reading.future;
        final admitted = credentials.contains(CredentialReference.generate());
        await storage.entered.future;
        final exiting = tester.binding.handleRequestAppExit();
        await draining.future;
        // Application drain deliberately keeps the runtime alive. A pending read
        // must not use that interval to start any new generation, even a sibling.
        expect(appRuntime.plugins.state, ApplicationPluginState.starting);
        releaseRead.complete();
        await starting;
        expect(
          appRuntime.plugins.backends.every(
            (entry) => entry.connection == null,
          ),
          isTrue,
        );
        expect(appRuntime.plugins.state, ApplicationPluginState.starting);
        storage.release.complete();
        expect(await admitted, isFalse);
        expect(await exiting, AppExitResponse.exit);
        expect(appRuntime.plugins.state, ApplicationPluginState.closed);
        expect(
          Directory(fixture.roots.configurationRoot).existsSync(),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!releaseRead.isCompleted) releaseRead.complete();
        if (!storage.release.isCompleted) storage.release.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await credentials.close();
        await appRuntime.close();
      }
    }),
  );

  test(
    'another installation snapshot fails closed before spawning its backend',
    () async {
      final fixture = await prepare();
      StartupRecordsView? first;
      final bootstrap = fixture.bootstrap((catalog, installation) async {
        first ??= StartupRecordsView.fromProjection(
          catalog,
          installation,
          records: const [],
        );
        return first!;
      });
      await fixture.start(bootstrap);
      expect(await _records(bootstrap, _owner), isEmpty);
      for (final id in [_nested, _independent]) {
        expect(_backend(bootstrap, id).state, InstalledBackendState.failed);
        expect(_backend(bootstrap, id).connection, isNull);
      }
      expect(await _records(bootstrap, _empty), isEmpty);
      expect(
        () => bootstrap.configureRecordsLoader((_, _) async => first!),
        throwsStateError,
      );
    },
  );

  test(
    'standalone opt-in requires a reader while no opt-in needs none',
    () async {
      final fixture = await prepare();
      final bootstrap = fixture.bootstrap(null);
      await fixture.start(bootstrap);
      for (final id in [_owner, _nested, _independent]) {
        expect(_backend(bootstrap, id).state, InstalledBackendState.failed);
        expect(_backend(bootstrap, id).connection, isNull);
      }
      expect(await _records(bootstrap, _empty), isEmpty);
      expect(Directory(fixture.roots.configurationRoot).existsSync(), isFalse);
    },
  );
}

InstalledBackendActivation _backend(
  ApplicationPluginBootstrap bootstrap,
  String id,
) => bootstrap.backends.singleWhere(
  (entry) => entry.installation.metadata.id.value == id,
);

Future<List<Object?>> _records(
  ApplicationPluginBootstrap bootstrap,
  String id,
) async {
  final backend = _backend(bootstrap, id);
  expect(
    backend.state,
    InstalledBackendState.active,
    reason: '${backend.failure}',
  );
  final result = await backend.connection!.request('records', {}) as Map;
  return (result['records'] as List).cast<Object?>();
}

Future<Map<String, Object?>> _request(
  ApplicationPluginBootstrap bootstrap,
  String id,
  String method, [
  Map<String, Object?> payload = const {},
]) async => Map<String, Object?>.from(
  await _backend(bootstrap, id).connection!.request(method, payload) as Map,
);

Map<String, Object> _record(
  String id,
  Map<String, Object> values, {
  String owner = _owner,
  String collection = 'jobs',
}) => {
  'collection': collection,
  'type': '$owner.record',
  'id': id,
  'values': values,
};

void _expectFailure(Map<String, Object?> result, String kind) {
  expect(result, {
    'failure': kind,
    'display': 'Configuration access failed ($kind).',
  });
}

final class _UnrelatedEndpoint implements CapabilityEndpoint {
  const _UnrelatedEndpoint();

  @override
  bool get isAvailable => true;

  @override
  String get serviceId => 'test.unrelated.service';
}

final class _Fixture {
  _Fixture(this.installations, this.roots, this.runtime, this.host);

  final Directory installations;
  final PlatformStorageRoots roots;
  final String runtime;
  final String host;

  GlobalSettingsService service(PreparedPluginCatalog catalog) {
    final service = GlobalSettingsService(
      catalog: catalog.settings,
      records: catalog.records,
      roots: roots,
    );
    addTearDown(service.close);
    return service;
  }

  ApplicationPluginBootstrap bootstrap(
    Future<StartupRecordsView> Function(
      PreparedPluginCatalog,
      PreparedPluginInstallation,
    )?
    loader, {
    Future<StartupRecordsView> Function(
      PreparedPluginCatalog,
      PreparedPluginInstallation,
    )?
    currentLoader,
  }) {
    final bootstrap = ApplicationPluginBootstrap(
      CapabilityRegistry(),
      ExtensionRegistry(),
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
      loadRecords: loader,
      loadCurrentRecords: currentLoader,
    );
    addTearDown(bootstrap.close);
    return bootstrap;
  }

  Future<void> start(ApplicationPluginBootstrap bootstrap) => bootstrap.start(
    installationRoot: installations.path,
    dartaotruntimeExecutable: runtime,
    hostArtifactPath: host,
  );
}
