@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/backend_configuration_host.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/core/project_storage_host.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_desktop/ui/settings/record_collection_panel.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_run_model_preference.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_plugin_backend_support/adele_backend_configuration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/backend_artifacts.dart';
import '../../tool/model_configuration_frontend_compiler.dart';
import '../support/agent_selector_installation.dart';
import '../support/gated_project_storage.dart';
import '../support/project_provider.dart';
import '../support/review_execution_fixture.dart';
import '../support/selection_sessions.dart';

part 'model_preset_run_cases.dart';
part 'model_preset_selector_cases.dart';

const _plugin = 'dev.adele.plugin.model-configuration';
const _extensionId = '$_plugin.run-model-preference';
const _peer = '$_plugin.peer';
final _type = RecordTypeId('$_plugin.preset');
final _strategy = OrchestrationStrategyId('test.preset.strategy');
const _values = {
  'name': 'Same name',
  'provider-id': 'Unregistered/Instance:1',
  'model-id': ' Vendor/MiX:v1.2+custom ',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory installations;
  late File host;
  late File selectorEvc;
  late String aotRuntime;

  setUpAll(() async {
    final repository = Directory.current.parent;
    final artifacts = await _temporary('model-preset-aot-');
    installations = Directory('${artifacts.path}/installations');
    final directory = Directory('${installations.path}/model-configuration');
    host = File('${artifacts.path}/host.aot');
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    aotRuntime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    for (final (entrypoint, artifact) in [
      ('packages/plugin_backend_host/bin/adele_backend_host.dart', host),
      (
        'plugins/model_configuration/packages/backend/bin/model_configuration_backend.dart',
        File('${directory.path}/backend.aot'),
      ),
      (
        'app/test/core/fixtures/remote_run_model_preference_probe.dart',
        File('${artifacts.path}/models.aot'),
      ),
      (
        'app/test/core/fixtures/remote_orchestration_probe.dart',
        File('${artifacts.path}/strategy.aot'),
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entrypoint,
        artifact: artifact,
        stage: 'model-preset-integration',
      );
    }
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: directory,
      pluginId: _plugin,
      displayName: 'Model Configuration',
      backend: true,
    );
    selectorEvc = File('${artifacts.path}/model-selector.evc');
    await selectorEvc.writeAsBytes(
      await Isolate.run(
        () => compileModelConfigurationFrontend(repositoryRoot: repository),
      ),
    );

    // A different owner can contribute the same shape to the same collection.
    final peer = await Directory('${installations.path}/peer').create();
    final schema = await File(
      '${directory.path}/records.schema.json',
    ).readAsString();
    await File(
      '${peer.path}/records.schema.json',
    ).writeAsString(schema.replaceAll(_type.value, '$_peer.preset'));
    await File('${peer.path}/adele_plugin.installation.json').writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': _peer, 'version': '1', 'displayName': 'Peer'},
        'recordsSchema': 'records.schema.json',
        'components': <String, Object?>{},
      }),
    );
  });

  late Directory temporary;
  late PlatformStorageRoots roots;
  setUp(() async {
    temporary = await _temporary('model-preset-settings-');
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
  });

  Future<_Fixture> start({bool gateStorage = false}) async {
    final f = _Fixture(roots);
    addTearDown(f.close);
    await f.start(
      installations.path,
      aotRuntime,
      host.path,
      gateStorage: gateStorage,
    );
    expect(f.bootstrap.state, ApplicationPluginState.ready);
    expect(f.bootstrap.catalog!.issues, isEmpty);
    final backend = f.bootstrap.backends.single;
    expect(
      backend.state,
      InstalledBackendState.active,
      reason: '${backend.failure}',
    );
    expect(backend.installation.frontend, isNull);
    expect(backend.installation.backendConsumedRecordTypes, [_type]);
    expect(backend.installation.backendConsumedCredentialSlots, isEmpty);
    expect(backend.installation.backendConsumedCapabilities, isEmpty);
    expect(backend.installation.backendRecordApplyHandlers, isEmpty);
    expect(backend.installation.runModelPreferenceSource?.value, _extensionId);
    expect(f.connection.capabilityExposures, isEmpty);
    expect(f.connection.extensionExposures.single.toMap(), {
      'extensionPointId': runModelPreferencesExtensionPoint.value,
      'extensionId': _extensionId,
      'serviceId': remoteRunModelPreferenceServiceId,
      'configurationContext': 'default',
      'metadata': <String, Object?>{},
    });
    expect(f.reads, 0);
    return f;
  }

  test(
    'live Settings edits preserve durable Session identity without provider execution',
    () async {
      final f = await start();
      final source = await _temporary('model-preset-project-');
      final graph = await f.sessions(source);
      final session = graph.session.id.value;
      final other = graph.otherSession.id.value;
      final catalog = f.catalog;
      final selections = f.selections;
      final empty = await catalog.readPresets();
      expect(empty.isComplete, isTrue);
      expect(empty.presets, isEmpty);
      expect(
        await Directory('${roots.configurationRoot}/model-presets').exists(),
        isFalse,
      );
      expect(_selection(await selections.readSessionSelection(session)), (
        session,
        null,
        0,
      ));
      expect(_selection(await selections.readSessionSelection(other)), (
        other,
        null,
        0,
      ));
      expect(f.rows(graph.project), isEmpty);
      expect(
        f.reads,
        1,
        reason: 'Reading Session state does not observe Settings.',
      );

      final peer = await f.settings.createRecord(
        RecordTypeId('$_peer.preset'),
        ConfigurationRecordId('private'),
        {..._values, 'description': 'Peer only'},
      );
      await f.create('zulu');
      final alpha = await f.create('alpha', {
        ..._values,
        'reasoning-effort': 'none',
      });
      final before = await catalog.readPresets();
      expect(before.isComplete, isTrue);
      expect(
        before.presets.map(
          (p) =>
              (p.presetId, p.name, p.providerId, p.modelId, p.reasoningEffort),
        ),
        [
          (
            'alpha',
            _values['name'],
            _values['provider-id'],
            _values['model-id'],
            'none',
          ),
          (
            'zulu',
            _values['name'],
            _values['provider-id'],
            _values['model-id'],
            null,
          ),
        ],
      );
      await expectLater(
        selections.updateSessionSelection(session, peer.id.value, 0),
        _failure('preset_not_found'),
      );
      expect(
        _selection(
          await selections.updateSessionSelection(session, 'alpha', 0),
        ),
        (session, 'alpha', 1),
      );
      expect(_selection(await selections.readSessionSelection(other)), (
        other,
        null,
        0,
      ));

      // Keep the original edit baseline across catalog and selection reads.
      final edited = await f.settings.updateRecord(alpha, {
        ..._values,
        'name': 'Renamed',
        'model-id': 'Other:2',
      });
      final updated = (await catalog.readPresets()).presets.first;
      expect(
        (updated.presetId, updated.name, updated.modelId),
        ('alpha', 'Renamed', 'Other:2'),
      );
      expect(_selection(await selections.readSessionSelection(session)), (
        session,
        'alpha',
        1,
      ));
      await f.settings.deleteRecord(edited);
      final deleted = await catalog.readPresets();
      expect(deleted.isComplete, isTrue);
      expect(deleted.presets.single.presetId, 'zulu');
      expect(_selection(await selections.readSessionSelection(session)), (
        session,
        'alpha',
        1,
      ));
      expect(f.rows(graph.project), [
        {'session_id': session, 'selected_preset_id': 'alpha', 'revision': 1},
      ]);
      expect(
        _selection(await selections.updateSessionSelection(session, 'zulu', 1)),
        (session, 'zulu', 2),
      );
      _expectNoInference(f, graph);
      await f.close();
      final reopened = await start();
      await expectLater(
        reopened.selections.readSessionSelection(session),
        _failure('storage_unavailable'),
      );
      expect((await reopened.open(source)).id, graph.project.id);
      expect(
        _selection(await reopened.selections.readSessionSelection(session)),
        (session, 'zulu', 2),
      );
      expect(
        _selection(await reopened.selections.readSessionSelection(other)),
        (other, null, 0),
      );
      _expectNoInference(reopened, graph);
    },
  );

  test(
    'partial observations allow positive evidence; clearing needs no observation',
    () async {
      final f = await start();
      final graph = await f.sessions(temporary, volatile: true);
      final id = graph.session.id.value;
      final record = await f.create('visible');
      final directory = Directory('${roots.configurationRoot}/model-presets');
      await File(
        '${directory.path}/broken.toml',
      ).writeAsString('invalid = [ # private data');
      final partial = await f.catalog.readPresets();
      expect(partial.isComplete, isFalse);
      expect(partial.presets.single.presetId, 'visible');
      await expectLater(
        f.selections.updateSessionSelection(id, 'missing', 0),
        _failure('catalog_incomplete'),
      );
      expect(
        _selection(await f.selections.updateSessionSelection(id, 'visible', 0)),
        (id, 'visible', 1),
      );
      await f.settings.deleteRecord(record);
      final allInvalid = await f.catalog.readPresets();
      expect(allInvalid.presets, isEmpty);
      expect(allInvalid.isComplete, isFalse);
      await f.create('visible', {..._values, 'name': 'Recreated'});
      expect((await f.catalog.readPresets()).presets.single.name, 'Recreated');
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        'visible',
        1,
      ));
      await directory.rename('${directory.path}-saved');
      await File(directory.path).writeAsString('private obstruction');
      await expectLater(
        f.catalog.readPresets(),
        throwsA(
          isA<ModelPresetCatalogFailure>()
              .having((e) => e.code, 'code', 'unavailable')
              .having(
                (e) => e.message,
                'message',
                isNot(contains(directory.path)),
              )
              .having((e) => e.details, 'details', isEmpty),
        ),
      );
      await expectLater(
        f.selections.updateSessionSelection(id, 'visible', 1),
        _failure('catalog_unavailable'),
      );
      final reads = f.reads;
      expect(
        _selection(await f.selections.updateSessionSelection(id, null, 1)),
        (id, null, 2),
      );
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        null,
        2,
      ));
      expect(f.reads, reads);
    },
  );

  test(
    'retirement fences an admitted write and both retained clients',
    () async {
      final f = await start(gateStorage: true);
      final graph = await f.sessions(temporary, volatile: true);
      final id = graph.session.id.value;
      final other = await f.sessions(
        await _temporary('model-preset-other-'),
        volatile: true,
      );
      await f.create('known');
      final catalog = f.catalog;
      final selections = f.selections;
      final gate = f.storage.holdTransaction(afterCommit: true);
      addTearDown(gate.release);
      final pending = expectLater(
        selections.updateSessionSelection(id, 'known', 0),
        _failure('outcome_uncertain'),
      );
      final bound = const Duration(seconds: 10);
      await gate.entered.future.timeout(bound);
      f.connection.revokeInfrastructureContext();
      await pending.timeout(bound);
      gate.release();
      await gate.settled.future.timeout(bound);
      expect(
        f.storage.calls.where(
          (c) => c == projectStorageServiceTransactionForSessionId,
        ),
        hasLength(1),
      );
      await f.bootstrap.close();
      await expectLater(
        selections.readSessionSelection(id),
        throwsA(isA<PluginConnectionClosed>()),
      );
      await expectLater(
        catalog.readPresets(),
        throwsA(isA<PluginConnectionClosed>()),
      );
      await f.start(
        installations.path,
        aotRuntime,
        host.path,
        gateStorage: true,
      );
      expect(_selection(await f.selections.readSessionSelection(id)), (
        id,
        'known',
        1,
      ));
      expect(
        _selection(
          await f.selections.readSessionSelection(other.session.id.value),
        ),
        (other.session.id.value, null, 0),
      );
      expect(f.rows(other.project), isEmpty);
      final path = File(
        f.runtime.lifecycle.existingDatabaseForProject(graph.project)!.path,
      );
      expect(await path.exists(), isTrue);
      await f.close();
      expect(await path.exists(), isFalse);
      final fresh = await start();
      final recreated = await fresh.sessions(temporary, volatile: true);
      expect(recreated.session.id, graph.session.id);
      expect(_selection(await fresh.selections.readSessionSelection(id)), (
        id,
        null,
        0,
      ));
    },
  );

  Future<void> prepareModelSelector(Directory root) async {
    final model = await Directory('${root.path}/model-configuration').create();
    await File(
      '${installations.path}/model-configuration/backend.aot',
    ).copy('${model.path}/backend.aot');
    await _publishModelSelector(model, selectorEvc);
  }

  Future<(_Fixture, SelectionGraph)> startSelectors(Directory root) async {
    final f = _Fixture(roots);
    addTearDown(f.close);
    await f.start(root.path, aotRuntime, host.path, gateStorage: true);
    return (f, await f.sessions(temporary));
  }

  testWidgets(
    'a Session selects a Settings-created Model Preset by name with no provider installed',
    (tester) => tester.runAsync(() async {
      final root = await _temporary('generated-preset-selector-');
      await prepareModelSelector(root);
      final (f, graph) = await startSelectors(root);
      _expectNoInference(f, graph);
      final collection = RecordCollectionId('model-presets');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecordCollectionPanel(
              service: f.settings,
              collection: collection,
            ),
          ),
        ),
      );
      Finder key(String value) => find.byKey(ValueKey(value));
      Future<void> press(Finder control) async {
        await tester.ensureVisible(control);
        await tester.pump();
        await tester.tap(control);
        await tester.pump();
      }

      final add = key('records-add-$collection');
      await _until(
        tester,
        () => tester.widget<FilledButton>(add).onPressed != null,
        'empty Model Presets collection',
      );
      await press(add);
      const name = 'Offline review';
      final values = {..._values, 'name': name};
      for (final field in values.entries) {
        expect(key('record-presence-$collection-${field.key}'), findsNothing);
        final input = key('record-input-$collection-${field.key}');
        expect(tester.widget<TextField>(input).enabled, isTrue);
        await tester.ensureVisible(input);
        await tester.enterText(input, field.value);
        await tester.pump();
      }
      await press(key('record-create-$collection'));
      await _until(
        tester,
        () => find.widgetWithText(ExpansionTile, name).evaluate().isNotEmpty,
        'acknowledged preset row',
      );
      final saved = (await f.settings.loadRecords(collection)).records.single;
      expect(saved.values, values);
      final catalog = await f.catalog.readPresets();
      expect(catalog.isComplete, isTrue);
      final preset = catalog.presets.single;
      expect(
        (
          preset.presetId,
          preset.name,
          preset.providerId,
          preset.modelId,
          preset.reasoningEffort,
        ),
        (saved.id.value, name, values['provider-id'], values['model-id'], null),
      );

      final session = graph.session.id.value;
      expect(_selection(await f.selections.readSessionSelection(session)), (
        session,
        null,
        0,
      ));
      await _startFrontends(f);
      await _SelectorPane(f).present(tester, graph.session);
      await _choose(tester, _noPreset, name, 'Model Preset: $name');
      expect(_selection(await f.selections.readSessionSelection(session)), (
        session,
        saved.id.value,
        1,
      ));
      _expectNoInference(f, graph);
      expect(tester.takeException(), isNull);
    }),
  );

  _registerSelectorCases(
    prepare: (root) async {
      await prepareModelSelector(root);
      final agent = Directory('${root.path}/agent-configuration');
      await compileAotSnapshot(
        dartExecutable: File(
          aotRuntime,
        ).parent.uri.resolve('dart').toFilePath(),
        workingDirectory: Directory.current.parent,
        entrypoint:
            'plugins/agent_configuration/packages/backend/bin/agent_configuration_backend.dart',
        artifact: File('${agent.path}/backend.aot'),
        stage: 'model-preset-mixed-selectors',
      );
      await publishAgentSelector(agent);
    },
    start: startSelectors,
  );

  _registerRunCases(({
    stock = _StockArtifact.healthy,
    restore,
    selector = false,
  }) async {
    final root = await _temporary('model-preset-run-installations-');
    await _prepareRunInstallations(root, installations, stock);
    if (selector) {
      await _publishModelSelector(
        Directory('${root.path}/model-configuration'),
        selectorEvc,
      );
    }
    final f = _Fixture(roots);
    addTearDown(f.close);
    // Establish the canonical graph before installing the executable strategy.
    final Session session;
    if (restore == null) {
      session = (await f.sessions(temporary)).session;
    } else {
      await f.open(temporary);
      session = f.runtime.store.session(restore)!;
    }
    await f.start(
      root.path,
      aotRuntime,
      host.path,
      startupArguments: _runArguments,
    );
    return _StockRuns(f, session);
  });
}

final class _Fixture {
  _Fixture(this.roots);
  final PlatformStorageRoots roots;
  final runtime = AdeleRuntime(ids: MonotonicProductIdSource(seed: 'preset'));
  late final projectProvider = TestProjectProvider(runtime.registry);
  late ApplicationPluginBootstrap bootstrap = runtime.plugins;
  late GatedProjectStorage storage;
  GlobalSettingsService? _settings;
  GlobalSettingsService get settings => _settings ??= GlobalSettingsService(
    catalog: bootstrap.catalog!.settings,
    records: bootstrap.catalog!.records,
    roots: roots,
  );
  int reads = 0;
  Future<void>? _closing;

  Future<void> start(
    String installations,
    String executable,
    String host, {
    bool gateStorage = false,
    Map<String, List<String>> startupArguments = const {},
  }) async {
    await _settings?.close();
    _settings = null;
    // Storage and selector lifetime tests can hold a committed Model write.
    // Runs must use the production bootstrap captured by runtime.runModelPreferences.
    bootstrap = gateStorage
        ? ApplicationPluginBootstrap(
            runtime.registry,
            runtime.extensions,
            createInfrastructureServices: (connection) {
              final services = projectStorageServices(
                runtime.lifecycle,
                connection,
              );
              if (connection.pluginId != _plugin) return services;
              storage = GatedProjectStorage(services[projectStorageServiceId]!);
              return {projectStorageServiceId: storage};
            },
          )
        : runtime.plugins;
    bootstrap.configureSettingsLoader(
      (catalog) async => PreparedSettingsSnapshot.resolve(catalog),
    );
    bootstrap.configureRecordsLoader(
      (catalog, installation) =>
          settings.loadStartupRecords(catalog, installation),
    );
    bootstrap.configureCurrentRecordsLoader(loadCurrentRecords);
    await bootstrap.start(
      installationRoot: installations,
      dartaotruntimeExecutable: executable,
      hostArtifactPath: host,
      startupArguments: startupArguments,
    );
  }

  Future<StartupRecordsView> loadCurrentRecords(
    PreparedPluginCatalog catalog,
    PreparedPluginInstallation installation,
  ) {
    reads++;
    return settings.loadCurrentRecords(catalog, installation);
  }

  PluginBackendConnection get connection => bootstrap.backends
      .singleWhere((b) => b.installation.metadata.id.value == _plugin)
      .connection!;
  ModelPresetSelectionServiceClient get selections =>
      ModelPresetSelectionServiceClient(
        connection.channelFor(
          connection.defaultConfigurationContext,
          modelPresetSelectionServiceId,
        ),
      );
  ModelPresetCatalogServiceClient get catalog =>
      ModelPresetCatalogServiceClient(
        connection.channelFor(
          connection.defaultConfigurationContext,
          modelPresetCatalogServiceId,
        ),
      );
  Future<RecordView> create(
    String id, [
    Map<String, Object?> values = _values,
  ]) => settings.createRecord(_type, ConfigurationRecordId(id), values);
  Future<Project> open(Directory source) => runtime.lifecycle.openProject(
    sourceLocation: source.uri,
    provider: runtime.lifecycle.resolveProjectProvider(
      projectProvider.providerId,
    ),
  );
  Future<SelectionGraph> sessions(
    Directory source, {
    bool volatile = false,
  }) async => createSelectionSessions(
    runtime,
    volatile ? runtime.lifecycle.createProject(source.uri) : await open(source),
    _strategy,
  );
  List<Map<String, Object?>> rows(Project project) => [
    for (final row
        in runtime.lifecycle
            .existingDatabaseForProject(project)!
            .queryPluginRows(
              'SELECT * FROM adele_model_preset_selections ORDER BY session_id',
              {},
            ))
      row.values,
  ];

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await bootstrap.close();
    await projectProvider.close();
    await runtime.close();
    await _settings?.close();
  }
}

(String, String?, int) _selection(ModelPresetSelectionSnapshot s) =>
    (s.sessionId, s.selectedPresetId, s.revision);
Matcher _failure(String code) => throwsA(
  isA<ModelPresetSelectionFailure>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.details, 'details', isEmpty),
);
void _expectNoInference(_Fixture f, SelectionGraph graph) {
  expect(f.runtime.registry.providersFor(modelProviderCapability), isEmpty);
  for (final session in [graph.session, graph.otherSession]) {
    expect(f.runtime.store.runsForSession(session.id), isEmpty);
    expect(f.runtime.lifecycle.runActivitiesForSession(session.id), isEmpty);
  }
}

Future<Directory> _temporary(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}
