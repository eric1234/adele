import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/frontend/contribution_bridge.dart';
import 'package:adele_desktop/frontend/main_content_bridge.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_eval/flutter_eval.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/backend_artifacts.dart';
import '../tool/source_editor_frontend_compiler.dart';

const _sourcePlugin = 'dev.adele.source-editor';
const _folding = '$_sourcePlugin.enable-folding';
const _healthyPlugin = 'dev.example.healthy';
const _otherPlugin = 'dev.example.other';
const _nestedPlugin = '$_sourcePlugin.child';
const _probeLibrary = 'package:settings_probe/main.dart';

void main() {
  late Uint8List sourceBytes;
  late Uint8List probeBytes;
  late Directory temporary;
  late Directory installations;
  late PlatformStorageRoots roots;
  late PreparedPluginCatalog catalog;
  late PreparedPluginInstallation source;
  late ConfigurationStore persistence;
  late GlobalSettingsStore settings;
  late File file;

  setUpAll(() async {
    sourceBytes = await compileSourceEditorFrontend(
      repositoryRoot: Directory.current.parent,
    );
    probeBytes = (Compiler()..entrypoints.add(_probeLibrary)).compile({
      'settings_probe': {'main.dart': 'void healthyCommand() {}'},
    }).write();
  });

  Future<void> installProbe(
    String id, {
    bool declaresSetting = false,
    Uint8List? artifactBytes,
    List<Map<String, Object?>> presentations = const [],
  }) async {
    final directory = await Directory('${installations.path}/$id').create();
    await File(
      '${directory.path}/frontend.evc',
    ).writeAsBytes(artifactBytes ?? probeBytes);
    if (declaresSetting) {
      await File('${directory.path}/settings.schema.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'definitions': [
            {
              'id': '$id.enabled',
              'type': 'boolean',
              'default': true,
              'label': 'Enabled',
              'category': 'General',
              'section': 'Testing',
            },
          ],
        }),
      );
    }
    await File(
      '${directory.path}/adele_plugin.installation.json',
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': id, 'version': '1', 'displayName': id},
        if (declaresSetting) 'settingsSchema': 'settings.schema.json',
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': presentations,
            'extensions': [
              {
                'kind': 'command',
                'extensionId': '$id.command',
                'commandId': '$id.run',
                'label': 'Healthy command',
                'library': _probeLibrary,
                'entrypoint': 'healthyCommand',
              },
            ],
          },
        },
      }),
    );
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'adele-prepared-settings-',
    );
    installations = await Directory('${temporary.path}/installed').create();
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/global/config',
      localStateRoot: '${temporary.path}/global/state',
      localDataRoot: '${temporary.path}/global/data',
      cacheRoot: '${temporary.path}/global/cache',
    );
    final installed = await Directory('${installations.path}/source').create();
    await File('${installed.path}/frontend.evc').writeAsBytes(sourceBytes);
    await publishStockPluginInstallation(
      repositoryRoot: Directory.current.parent,
      installationDirectory: installed,
      pluginId: _sourcePlugin,
      displayName: 'Source',
      frontend: true,
    );
    await installProbe(_healthyPlugin);
    await installProbe(_otherPlugin, declaresSetting: true);
    await installProbe(_nestedPlugin, declaresSetting: true);
    catalog = await PreparedPluginCatalog.discover(installations.path);
    expect(catalog.issues, isEmpty);
    source = catalog.installations.singleWhere(
      (entry) => entry.metadata.id.value == _sourcePlugin,
    );
    persistence = ConfigurationStore(roots);
    settings = GlobalSettingsStore(
      store: persistence,
      catalog: catalog.settings,
    );
    file = File(persistence.filePath);
  });
  tearDown(() => temporary.delete(recursive: true));

  Future<PreparedSettingsSnapshot> load() =>
      PreparedSettingsSnapshot.load(catalog, roots: roots);

  void seed(String content) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void expectValue(
    PreparedSettingsSnapshot snapshot,
    bool value,
    SettingValueSource provenance,
  ) {
    final result = snapshot.read(source, _folding);
    expect(result.value, value);
    expect(result.source, provenance);
    expect(result.hasGlobalOverride, provenance == SettingValueSource.global);
  }

  void expectNoWriteArtifacts() {
    expect(Directory(roots.localStateRoot).existsSync(), isFalse);
    expect(Directory(roots.localDataRoot).existsSync(), isFalse);
    expect(Directory(roots.cacheRoot).existsSync(), isFalse);
  }

  test(
    'real stock schema supplies the default without startup artifacts',
    () async {
      final definition = source.settingsSchema!.definitions.single;
      expect(definition.id, SettingId(_folding));
      expect(definition.owner, SettingOwnerId(_sourcePlugin));
      expect(definition.type, isA<BooleanSettingType>());
      expect(definition.defaultValue, false);
      expect(definition.label, 'Enable Code Folding');
      expect(definition.category, 'Editor');
      expect(definition.section, 'Display');
      expect(source.backendArtifactUri, isNull);
      expect(
        File.fromUri(source.settingsSchema!.artifactUri).readAsBytesSync(),
        File('../plugins/source_editor/settings.schema.json').readAsBytesSync(),
      );

      final snapshot = await load();
      expectValue(snapshot, false, SettingValueSource.defaultValue);
      snapshot.validateInstallation(source);
      final extensions = ExtensionRegistry();
      var loads = 0;
      final frontends = ApplicationFrontendBootstrap(
        extensions: extensions,
        loadSettings: (actual) {
          expect(actual, same(catalog));
          loads++;
          return PreparedSettingsSnapshot.load(actual, roots: roots);
        },
      );
      addTearDown(frontends.close);
      await frontends.start(catalog);
      expect(loads, 1);
      expect(frontends.state, ApplicationFrontendState.ready);
      expect(
        frontends.generations.map((generation) => generation.state),
        everyElement(InstalledFrontendState.active),
      );
      expect(extensions.discover(mainContentContributions), hasLength(1));
      expect(extensions.discover(displaySourceFileContributions), hasLength(1));
      expect(Directory('${temporary.path}/global').existsSync(), isFalse);
      expect(file.existsSync(), isFalse);
      expectNoWriteArtifacts();
    },
  );

  test(
    'global save and reload retain true, explicit false and reset provenance',
    () async {
      final initial = await load();
      expectValue(initial, false, SettingValueSource.defaultValue);
      var saved = settings.save(
        settings.load().setOverride(SettingId(_folding), true),
      );
      final enabled = await load();
      expectValue(enabled, true, SettingValueSource.global);
      expect(file.readAsStringSync(), contains('"$_folding" = true'));
      expectValue(initial, false, SettingValueSource.defaultValue);

      final reconstructed = GlobalSettingsStore(
        store: ConfigurationStore(roots),
        catalog: catalog.settings,
      );
      final restored = reconstructed.load().resolve<bool>(SettingId(_folding));
      expect(restored.value, true);
      expect(restored.source, SettingValueSource.global);
      expect(restored.hasGlobalOverride, isTrue);

      saved = settings.save(saved.setOverride(SettingId(_folding), false));
      expectValue(await load(), false, SettingValueSource.global);
      expectValue(enabled, true, SettingValueSource.global);
      saved = settings.save(saved.resetOverride(SettingId(_folding)));
      expectValue(await load(), false, SettingValueSource.defaultValue);
      expect(saved.resolve(SettingId(_folding)).hasGlobalOverride, isFalse);
      expect(file.readAsStringSync(), isNot(contains(_folding)));
      expect(Directory(roots.localDataRoot).existsSync(), isFalse);
      expect(Directory(roots.cacheRoot).existsSync(), isFalse);
      expect(
        Directory('${temporary.path}/global')
            .listSync(recursive: true)
            .whereType<File>()
            .map((entry) => entry.path),
        unorderedEquals([persistence.filePath, persistence.lockPath]),
      );
    },
    skip: !Platform.isLinux,
  );

  test('closing during settings load publishes no late frontend', () async {
    final snapshot = await load();
    final loading = Completer<PreparedSettingsSnapshot>();
    final extensions = ExtensionRegistry();
    final frontends = ApplicationFrontendBootstrap(
      extensions: extensions,
      loadSettings: (_) => loading.future,
    );
    final starting = frontends.start(catalog);
    expect(frontends.state, ApplicationFrontendState.starting);
    final closing = frontends.close();
    loading.complete(snapshot);
    await starting;
    await closing;
    expect(frontends.state, ApplicationFrontendState.closed);
    expect(extensions.discover(mainContentContributions), isEmpty);
    expect(extensions.discover(commandContributions), isEmpty);
    expect(
      frontends.generations.map((generation) => generation.state),
      everyElement(InstalledFrontendState.closed),
    );
    expect(Directory('${temporary.path}/global').existsSync(), isFalse);
  });

  test('valid declarations survive an executable startup failure', () async {
    seed('"$_folding" = true\n');
    await File.fromUri(source.frontend!.artifactUri).writeAsBytes([0]);
    final snapshot = await load();
    final frontends = ApplicationFrontendBootstrap(
      extensions: ExtensionRegistry(),
      loadSettings: (_) async => snapshot,
    );
    addTearDown(frontends.close);
    await frontends.start(catalog);
    expect(
      frontends.generations
          .singleWhere(
            (generation) => identical(generation.installation, source),
          )
          .state,
      InstalledFrontendState.failed,
    );
    expectValue(snapshot, true, SettingValueSource.global);
    expect(
      frontends.generations
          .where((generation) => !identical(generation.installation, source))
          .map((generation) => generation.state),
      everyElement(InstalledFrontendState.active),
    );
    expectNoWriteArtifacts();
  });

  test(
    'a rejected schema does not disable valid executable components',
    () async {
      await File.fromUri(
        source.settingsSchema!.artifactUri,
      ).writeAsString('{}');
      catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues.single.isSettingsSchemaIssue, isTrue);
      source = catalog.installations.singleWhere(
        (entry) => entry.metadata.id.value == _sourcePlugin,
      );
      final snapshot = await load();
      final frontends = ApplicationFrontendBootstrap(
        extensions: ExtensionRegistry(),
        loadSettings: (_) async => snapshot,
      );
      addTearDown(frontends.close);
      await frontends.start(catalog);
      expect(
        frontends.generations.map((generation) => generation.state),
        everyElement(InstalledFrontendState.active),
      );
      expect(() => snapshot.read(source, _folding), throwsStateError);
      expect(Directory('${temporary.path}/global').existsSync(), isFalse);
    },
  );

  test(
    'stock setting edits preserve comments and unavailable-owner content',
    () async {
      const unknown =
          '"dev.unavailable.plugin.value" = [1, 2] # keep unknown\n'
          'unrelated = 0x10\n'
          "[other] # keep table\nname  = 'literal'\n";
      const original =
          '# shared header\n'
          '"$_folding" = false # keep folding comment\n'
          '$unknown';
      seed(original);
      expectValue(await load(), false, SettingValueSource.global);
      expectNoWriteArtifacts();
      var saved = settings.save(
        settings.load().setOverride(SettingId(_folding), true),
      );
      expect(
        file.readAsStringSync(),
        original.replaceFirst('= false', '= true'),
      );
      expectValue(await load(), true, SettingValueSource.global);
      saved = settings.save(saved.setOverride(SettingId(_folding), false));
      expect(file.readAsStringSync(), original);
      settings.save(saved.resetOverride(SettingId(_folding)));
      expect(file.readAsStringSync(), contains(unknown));
      expectValue(await load(), false, SettingValueSource.defaultValue);
    },
    skip: !Platform.isLinux,
  );

  test(
    'stale stock setting saves keep CFG2 conflicts instead of merging',
    () async {
      final stale = settings.load();
      final winner = settings.save(
        settings.load().setOverride(SettingId(_folding), true),
      );
      expect(
        () => settings.save(stale.setOverride(SettingId(_folding), false)),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file.readAsStringSync(), winner.document.source);
      expectValue(await load(), true, SettingValueSource.global);
      final external = '${winner.document.source}external = 1 # keep\n';
      file.writeAsStringSync(external);
      expect(
        () => settings.save(winner.resetOverride(SettingId(_folding))),
        throwsA(isA<ConfigurationConflictException>()),
      );
      expect(file.readAsStringSync(), external);
      expectValue(await load(), true, SettingValueSource.global);
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'prepared initializer and pane read their setting without retained-data grants',
    (tester) => tester.runAsync(() async {
      final compiler = Compiler()
        ..addPlugin(flutterEvalPlugin)
        ..addPlugin(const MainContentDeclarations())
        ..addPlugin(const ContributionDeclarations())
        ..entrypoints.add(_probeLibrary);
      final bytes = compiler.compile({
        'settings_probe': {
          'main.dart':
              '''
import 'package:flutter/material.dart';
import 'package:adele_ui/contribution_bridge.dart';
import 'package:adele_ui/main_content_bridge.dart';
void healthyCommand() {}
void initializeSettings() {
  final enabled = readPluginSetting('$_otherPlugin.enabled') as bool;
  openMainContentPane('settings', enabled ? 'Default initializer' : 'Global initializer', false);
}
Widget settingsPane() {
  final enabled = readPluginSetting('$_otherPlugin.enabled') as bool;
  return Text(enabled ? 'Default pane' : 'Global pane');
}
''',
        },
        'adele_ui': {
          for (final name in [
            'contribution_bridge.dart',
            'main_content_bridge.dart',
          ])
            name: await File('../packages/ui/lib/$name').readAsString(),
        },
      }).write();
      installations = await Directory(
        '${temporary.path}/pane-installed',
      ).create();
      await installProbe(
        _otherPlugin,
        declaresSetting: true,
        artifactBytes: bytes,
        presentations: [
          {
            'role': 'mainContent',
            'extensionId': '$_otherPlugin.main-content',
            'order': 100,
            'library': _probeLibrary,
            'initialize': 'initializeSettings',
            'entrypoint': 'settingsPane',
          },
        ],
      );
      final panes = await PreparedPluginCatalog.discover(installations.path);
      expect(panes.issues, isEmpty);
      final descriptor =
          panes.installations.single.frontend!.presentations.single
              as PreparedMainContentPresentation;
      expect(descriptor.retainedData, isFalse);
      expect(descriptor.nativeCodeEditor, isFalse);
      expect(descriptor.operations, isEmpty);
      expect(descriptor.actions, isEmpty);
      seed('"$_otherPlugin.enabled" = false\n');
      final extensions = ExtensionRegistry();
      final frontends = ApplicationFrontendBootstrap(
        extensions: extensions,
        loadSettings: (actual) =>
            PreparedSettingsSnapshot.load(actual, roots: roots),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await frontends.close();
      });
      await frontends.start(panes);
      expect(frontends.generations.single.state, InstalledFrontendState.active);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainContentHost(
              session: Session(
                id: SessionId('settings-session'),
                taskId: TaskId('settings-task'),
                strategyId: OrchestrationStrategyId('test.unavailable'),
              ),
              extensions: extensions,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Global initializer'), findsOneWidget);
      expect(find.text('Global pane'), findsOneWidget);
      expect(find.text('Default initializer'), findsNothing);
      expect(find.text('Default pane'), findsNothing);
      expect(tester.takeException(), isNull);
      expectNoWriteArtifacts();
    }),
  );

  test(
    'setting reads require exact declared owner, not a namespace prefix',
    () async {
      final snapshot = await load();
      final ownValues = snapshot.valuesForInstallation(source);
      expect(ownValues, {_folding: false});
      expect(() => ownValues[_folding] = true, throwsUnsupportedError);
      for (final id in [_healthyPlugin, _otherPlugin, _nestedPlugin]) {
        final foreign = catalog.installations.singleWhere(
          (entry) => entry.metadata.id.value == id,
        );
        snapshot.validateInstallation(foreign);
        expect(
          snapshot.valuesForInstallation(foreign),
          id == _healthyPlugin ? <String, Object>{} : {'$id.enabled': true},
        );
        expect(() => snapshot.read(foreign, _folding), throwsStateError);
        if (id != _healthyPlugin) {
          expect(snapshot.read(foreign, '$id.enabled').value, true);
          expect(() => snapshot.read(source, '$id.enabled'), throwsStateError);
        }
      }
      expect(
        () => snapshot.read(source, '$_sourcePlugin.unknown'),
        throwsStateError,
      );
      expect(
        () => snapshot.read(source, 'not a setting ID'),
        throwsFormatException,
      );
      expectNoWriteArtifacts();
    },
  );

  test(
    'equal installation metadata cannot cross catalog snapshot identity',
    () async {
      final snapshot = await load();
      final rediscovered = await PreparedPluginCatalog.discover(
        installations.path,
      );
      final replacement = rediscovered.installations.singleWhere(
        (entry) => entry.metadata.id == source.metadata.id,
      );
      final clone = PreparedPluginInstallation(
        metadata: source.metadata,
        installationDirectory: source.installationDirectory,
        backendArtifactUri: source.backendArtifactUri,
        frontend: source.frontend,
        settingsSchema: source.settingsSchema,
      );
      for (final foreign in [replacement, clone]) {
        expect(() => snapshot.valuesForInstallation(foreign), throwsStateError);
        expect(() => snapshot.read(foreign, _folding), throwsStateError);
        expect(() => snapshot.validateInstallation(foreign), throwsStateError);
      }
      final next = await PreparedSettingsSnapshot.load(
        rediscovered,
        roots: roots,
      );
      expect(next.read(replacement, _folding).value, false);
      expect(() => next.read(source, _folding), throwsStateError);
      expectValue(snapshot, false, SettingValueSource.defaultValue);
    },
  );

  for (final invalid in ['"true"', '1', '[true]', '{ enabled = true }']) {
    test(
      'invalid $invalid override fails only its owning prepared frontend',
      () async {
        final content = '"$_folding" = $invalid # untouched\n';
        seed(content);
        final snapshot = await load();
        final failure = isA<InvalidSettingOverride>().having(
          (error) => error.id,
          'setting ID',
          SettingId(_folding),
        );
        expect(() => snapshot.read(source, _folding), throwsA(failure));
        expect(() => snapshot.validateInstallation(source), throwsA(failure));
        final extensions = ExtensionRegistry();
        final frontends = ApplicationFrontendBootstrap(
          extensions: extensions,
          loadSettings: (actual) =>
              PreparedSettingsSnapshot.load(actual, roots: roots),
        );
        addTearDown(frontends.close);
        await frontends.start(catalog);
        expect(frontends.state, ApplicationFrontendState.ready);
        final failed = frontends.generations.singleWhere(
          (generation) => identical(generation.installation, source),
        );
        expect(failed.state, InstalledFrontendState.failed);
        expect(failed.failure, failure);
        expect(failed.registrations, isEmpty);
        for (final healthy in frontends.generations.where(
          (generation) => !identical(generation, failed),
        )) {
          expect(healthy.state, InstalledFrontendState.active);
          expect(healthy.failure, isNull);
        }
        expect(extensions.discover(mainContentContributions), isEmpty);
        expect(extensions.discover(displaySourceFileContributions), isEmpty);
        final command = CommandResolver(
          extensions,
        ).resolve(CommandId('$_healthyPlugin.run'));
        expect(command.availability, CommandAvailability.enabled);
        await command.invoke();
        expect(file.readAsStringSync(), content);
        expectNoWriteArtifacts();
      },
    );
  }

  test(
    'unreadable UTF-8 is retained while a settings-free frontend activates',
    () async {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([0xff]);
      final snapshot = await load();
      expect(() => snapshot.read(source, _folding), throwsFormatException);
      final frontends = ApplicationFrontendBootstrap(
        extensions: ExtensionRegistry(),
        loadSettings: (actual) =>
            PreparedSettingsSnapshot.load(actual, roots: roots),
      );
      addTearDown(frontends.close);
      await frontends.start(catalog);
      for (final generation in frontends.generations) {
        if (generation.installation.settingsSchema == null) {
          expect(generation.state, InstalledFrontendState.active);
        } else {
          expect(generation.state, InstalledFrontendState.failed);
          expect(generation.failure, isA<FormatException>());
        }
      }
      expect(file.readAsBytesSync(), [0xff]);
      expectNoWriteArtifacts();
    },
  );
}
