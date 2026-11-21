@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/adele_runtime.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/remote_inference_context_host.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/execution/session_execution_owners.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_run_model_preference.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../support/selection_sessions.dart';

const _sourcePlugin = 'test.preference.source';
const _extensionId = 'test.preference.registration';
const _direct = 'test.model.direct';
const _selected = 'test.model.selected';
const _directModel = 'launch-default';
const _bound = Duration(seconds: 10);
const _first = {
  'providerId': _selected,
  'modelId': 'Vendor/Chosen:v2',
  'reasoningEffort': 'high',
};
const _edited = {
  'providerId': _direct,
  'modelId': 'Different/Model',
  'reasoningEffort': 'none',
};
final _strategyId = OrchestrationStrategyId('test.preference.strategy');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory artifacts;
  late String aotRuntime;
  setUpAll(() async {
    artifacts = await Directory.systemTemp.createTemp('adele-run-preference-');
    addTearDown(() => artifacts.delete(recursive: true));
    final sdk = Directory(
      '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin',
    );
    aotRuntime = File.fromUri(
      sdk.uri.resolve(
        Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
      ),
    ).path;
    final dart = File.fromUri(
      sdk.uri.resolve(Platform.isWindows ? 'dart.exe' : 'dart'),
    ).path;
    for (final (name, entrypoint) in [
      ('host', 'packages/plugin_backend_host/bin/adele_backend_host.dart'),
      ('strategy', 'app/test/core/fixtures/remote_orchestration_probe.dart'),
      (
        'probe',
        'app/test/core/fixtures/remote_run_model_preference_probe.dart',
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: Directory.current.parent,
        entrypoint: entrypoint,
        artifact: File.fromUri(artifacts.uri.resolve('$name.aot')),
        stage: 'remote-run-model-preference',
      );
    }
  });

  late PluginBackendHost host;
  late AdeleRuntime runtime;
  late SessionExecutionController owner;
  late PluginBackendActivation providers;

  Future<PluginBackendActivation> activate(
    String pluginId,
    String name,
    List<String> arguments,
  ) async {
    final connection = await host.startPlugin(
      pluginId: pluginId,
      artifactUri: artifacts.uri.resolve('$name.aot'),
      arguments: arguments,
    );
    addTearDown(connection.close);
    final activation = await PluginBackendActivation.registerAdvertised(
      connection: connection,
      capabilities: runtime.registry,
      extensions: runtime.extensions,
      adapters: createRemoteExtensionAdapters(),
    );
    addTearDown(activation.close);
    return activation;
  }

  Future<PluginBackendActivation> source({
    bool hold = false,
    String pluginId = _sourcePlugin,
  }) => activate(pluginId, 'probe', [
    jsonEncode({'extensionId': _extensionId, 'hold': hold}),
  ]);

  Future<PluginBackendConnection> installedSource({
    String advertisedId = _extensionId,
    bool hold = false,
  }) async {
    final root = await Directory.systemTemp.createTemp('installed-preference-');
    addTearDown(() => root.delete(recursive: true));
    final plugin = await Directory.fromUri(
      root.uri.resolve('source/'),
    ).create();
    await File.fromUri(
      artifacts.uri.resolve('probe.aot'),
    ).copy(plugin.uri.resolve('backend.aot').toFilePath());
    await File.fromUri(
      plugin.uri.resolve('adele_plugin.installation.json'),
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': _sourcePlugin,
          'version': '1',
          'displayName': 'Test',
        },
        'runModelPreferenceSource': {'extensionId': _extensionId},
        'components': {
          'backend': {'artifact': 'backend.aot'},
        },
      }),
    );
    runtime.plugins.configureSettingsLoader(
      (catalog) async => PreparedSettingsSnapshot.resolve(catalog),
    );
    await runtime.plugins.start(
      installationRoot: root.path,
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: artifacts.uri.resolve('host.aot').toFilePath(),
      startupArguments: {
        _sourcePlugin: [
          jsonEncode({'extensionId': advertisedId, 'hold': hold}),
        ],
      },
    );
    return runtime.plugins.backends.single.connection!;
  }

  Future<PluginBackendActivation> strategy({bool holdTurn = false}) =>
      activate('test.preference.orchestration', 'strategy', [
        'test.preference.orchestration.registration',
        jsonEncode({
          'strategyId': _strategyId.value,
          if (holdTurn) 'hold': 'turn',
        }),
      ]);

  setUp(() async {
    host = await PluginBackendHost.start(
      dartaotruntimeExecutable: aotRuntime,
      hostArtifactPath: File.fromUri(artifacts.uri.resolve('host.aot')).path,
    );
    addTearDown(host.close);
    runtime = AdeleRuntime();
    addTearDown(runtime.close);
    final project = runtime.lifecycle.createProject(
      Uri.parse('file:///run-preference/'),
    );
    final graph = await createSelectionSessions(runtime, project, _strategyId);
    providers = await activate('test.preference.models', 'probe', [
      jsonEncode({
        'providers': [_direct, _selected],
      }),
    ]);
    final owners = SessionExecutionOwners(
      runtime: runtime,
      providerId: ProviderId(_direct),
      model: _directModel,
    );
    addTearDown(owners.close);
    owner = owners.getOrCreate(graph.session);
  });

  Future<RunId> completeRun() async {
    final runId = await owner.startRun();
    await owner.activeRunFuture?.timeout(_bound);
    expect(owner.failure, isNull);
    expect(owner.stateForRun(runId), RunState.completed);
    return runId;
  }

  test(
    'one remote capture fixes both model turns; later Runs use the edit or direct fallback on abstention',
    () async {
      final orchestration = await strategy(holdTurn: true);
      final preferences = await source();
      expect(preferences.connection.capabilityExposures, isEmpty);
      expect(preferences.connection.extensionExposures.single.toMap(), {
        'extensionPointId': 'dev.adele.extension.run-model-preferences',
        'extensionId': _extensionId,
        'serviceId': remoteRunModelPreferenceServiceId,
        'configurationContext': 'preference-route',
        'metadata': <String, Object?>{},
      });
      await _control(preferences, 'setPreference', _first);
      expect(owner.canStart, isTrue);
      expect(await _control(preferences, 'requests'), isEmpty);
      addTearDown(
        () => _control(orchestration, 'release', {'operation': 'turn'}),
      );
      final firstRun = await owner.startRun();
      final firstFinished = owner.activeRunFuture!;
      await _control(orchestration, 'ready', {'operation': 'turn'});
      expect(await _control(providers, 'requests'), [_first]);
      expect(await _control(preferences, 'requests'), [
        _capture(owner.session, firstRun),
      ]);

      await _control(preferences, 'setPreference', _edited);
      await _control(orchestration, 'release', {'operation': 'turn'});
      await firstFinished.timeout(_bound);
      expect(owner.stateForRun(firstRun), RunState.completed);
      expect(await _control(providers, 'requests'), [_first, _first]);

      final changedRun = await completeRun();
      await _control(preferences, 'setPreference');
      final directRun = await completeRun();
      expect({firstRun, changedRun, directRun}, hasLength(3));
      expect(await _control(preferences, 'requests'), [
        for (final id in [firstRun, changedRun, directRun])
          _capture(owner.session, id),
      ]);
      const direct = {
        'providerId': _direct,
        'modelId': _directModel,
        'reasoningEffort': null,
      };
      expect(await _control(providers, 'requests'), [
        _first,
        _first,
        _edited,
        _edited,
        direct,
        direct,
      ]);
    },
  );

  test(
    'a declared source advertising a different ID cannot start inference',
    () async {
      await strategy();
      final connection = await installedSource(
        advertisedId: 'test.preference.other',
      );
      final rejected = await owner.startRun();
      await owner.activeRunFuture?.timeout(_bound);
      expect(owner.stateForRun(rejected), RunState.failed);
      expect(owner.failure, isA<RunModelPreferenceFailure>());
      expect(await _probe(connection, 'requests'), isEmpty);
      expect(await _control(providers, 'requests'), isEmpty);
    },
  );

  for (final pending in [true, false]) {
    test(
      'retiring a declared source ${pending ? 'during' : 'after'} capture',
      () async {
        final orchestration = await strategy(holdTurn: !pending);
        final connection = await installedSource(hold: pending);
        await _probe(connection, 'setPreference', _first);
        final run = await owner.startRun();
        final settled = owner.activeRunFuture!;
        if (pending) {
          await _probe(connection, 'entered');
        } else {
          await _control(orchestration, 'ready', {'operation': 'turn'});
        }
        await connection.close().timeout(_bound);
        if (!pending) {
          await _control(orchestration, 'release', {'operation': 'turn'});
        }
        await settled.timeout(_bound);
        expect(
          owner.stateForRun(run),
          pending ? RunState.failed : RunState.completed,
        );

        // An unmanaged replacement advertising the same ID, even under the same
        // Plugin ID, is not a new prepared activation of this installation.
        final foreign = await source();
        final next = await owner.startRun();
        await owner.activeRunFuture?.timeout(_bound);
        expect(owner.stateForRun(next), RunState.failed);
        expect(owner.failure, isA<RunModelPreferenceFailure>());
        expect(await _control(foreign, 'requests'), isEmpty);
        expect(
          await _control(providers, 'requests'),
          pending ? isEmpty : [_first, _first],
        );
      },
    );
  }

  for (final terminate in [false, true]) {
    test(
      'a pending capture cannot migrate or fall back on ${terminate ? 'backend loss' : 'registration retirement and late success'}',
      () async {
        final orchestration = await strategy();
        final original = await source(hold: true);
        await _control(original, 'setPreference', _first);
        final binding = runtime.extensions
            .discover(runModelPreferencesExtensionPoint)
            .single;
        final rejected = await owner.startRun();
        final settled = owner.activeRunFuture!;
        await _control(original, 'entered');
        expect(await _control(original, 'requests'), [
          _capture(owner.session, rejected),
        ]);
        late PluginBackendActivation replacement;
        if (terminate) {
          final loss = original.connection.terminated.timeout(_bound);
          await expectLater(
            _control(original, 'terminate'),
            throwsA(isA<PluginRemoteFailure>()),
          );
          await loss;
          await original.close();
          replacement = await source();
        } else {
          // Leave the old connection alive and install the same extension ID
          // before releasing the successful but now-stale generated response.
          await original.retire().timeout(_bound);
          replacement = await source(pluginId: '$_sourcePlugin.replacement');
          await _control(original, 'release');
        }
        await settled.timeout(_bound);
        expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
        expect(owner.stateForRun(rejected), RunState.failed);
        expect(
          owner.failure,
          isA<RunModelPreferenceFailure>().having(
            (e) => e.kind,
            'kind',
            RunModelPreferenceFailureKind.unavailable,
          ),
        );
        expect(owner.currentRun, isNull);
        expect(
          (await _control(orchestration, 'snapshot') as Map)['records'],
          isEmpty,
        );
        expect(await _control(providers, 'requests'), isEmpty);
        expect(await _control(replacement, 'requests'), isEmpty);
        expect(host.isClosed, isFalse);

        await _control(replacement, 'setPreference', _edited);
        final fresh = await completeRun();
        expect(fresh, isNot(rejected));
        expect(await _control(replacement, 'requests'), [
          _capture(owner.session, fresh),
        ]);
        expect(await _control(providers, 'requests'), [_edited, _edited]);
      },
    );
  }
}

Map<String, Object?> _capture(Session session, RunId run) => {
  'configurationContext': 'preference-route',
  'method': remoteRunModelPreferenceServiceCaptureRunId,
  'payload': {'sessionId': session.id.value, 'runId': run.value},
  'hostInvocationContext': null,
};

Future<Object?> _control(
  PluginBackendActivation activation,
  String method, [
  Map<String, Object?> payload = const {},
]) => _probe(activation.connection, method, payload);

Future<Object?> _probe(
  PluginBackendConnection connection,
  String method, [
  Map<String, Object?> payload = const {},
]) => connection
    .channelFor(connection.defaultConfigurationContext, 'probe')
    .request(method, payload)
    .timeout(_bound);
