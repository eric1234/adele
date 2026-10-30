@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
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
      if (id != _empty) {
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
      }
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
          if (id != _empty) 'recordsSchema': 'records.json',
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
    'accepted application exit fences startup before runtime draining',
    (tester) => tester.runAsync(() async {
      final fixture = await prepare();
      final appRuntime = NativeAdeleRuntime();
      final reading = Completer<void>();
      final releaseRead = Completer<void>();
      final draining = Completer<void>();
      final releaseDrain = Completer<void>();
      Future<void>? starting;
      try {
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => appRuntime,
            configurationRoots: fixture.roots,
            readChatGptConfiguration: () => null,
            attachSessionContext: (_) => () {
              draining.complete();
              return releaseDrain.future;
            },
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
        await reading.future;
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
        releaseDrain.complete();
        expect(await exiting, AppExitResponse.exit);
        expect(appRuntime.plugins.state, ApplicationPluginState.closed);
        expect(
          Directory(fixture.roots.configurationRoot).existsSync(),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!releaseRead.isCompleted) releaseRead.complete();
        if (!releaseDrain.isCompleted) releaseDrain.complete();
        await tester.pumpWidget(const SizedBox.shrink());
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
    loader,
  ) {
    final bootstrap = ApplicationPluginBootstrap(
      CapabilityRegistry(),
      ExtensionRegistry(),
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
      loadRecords: loader,
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
