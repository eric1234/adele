@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:agent_configuration_contract/agent_configuration_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/backend_artifacts.dart';

const _plugin = 'dev.adele.plugin.agent-configuration';
const _foreign = '$_plugin.peer';
final _type = RecordTypeId('$_plugin.agent');

void main() {
  late Directory installations;
  late File host;
  late String runtime;
  setUpAll(() async {
    final repository = Directory.current.parent;
    final artifacts = await Directory.systemTemp.createTemp(
      'agent-catalog-aot-',
    );
    addTearDown(() => artifacts.delete(recursive: true));
    installations = Directory('${artifacts.path}/installations');
    host = File('${artifacts.path}/host.aot');
    final backend = File(
      '${installations.path}/agent-configuration/backend.aot',
    );
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    runtime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    for (final (entrypoint, artifact) in [
      ('packages/plugin_backend_host/bin/adele_backend_host.dart', host),
      (
        'plugins/agent_configuration/packages/backend/bin/agent_configuration_backend.dart',
        backend,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: entrypoint,
        artifact: artifact,
        stage: 'agent-catalog-integration',
      );
    }
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: backend.parent,
      pluginId: _plugin,
      displayName: 'Agent Configuration',
      backend: true,
    );

    // Same collection and fields, even a nested owner ID, but no grant to Agent.
    final peer = await Directory('${installations.path}/peer').create();
    final schema = await File(
      '${backend.parent.path}/records.schema.json',
    ).readAsString();
    await File(
      '${peer.path}/records.schema.json',
    ).writeAsString(schema.replaceAll('$_plugin.agent', '$_foreign.agent'));
    await File('${peer.path}/adele_plugin.installation.json').writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {'id': _foreign, 'version': '1', 'displayName': 'Peer'},
        'recordsSchema': 'records.schema.json',
        'components': <String, Object?>{},
      }),
    );
  });

  late Directory agents;
  late GlobalSettingsService settings;
  late ApplicationPluginBootstrap bootstrap;
  late PluginBackendConnection connection;
  late AgentCatalogServiceClient client;
  var reads = 0;
  Future<void> Function()? afterObservation;
  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp(
      'agent-catalog-settings-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${temporary.path}/config',
      localStateRoot: '${temporary.path}/state',
      localDataRoot: '${temporary.path}/data',
      cacheRoot: '${temporary.path}/cache',
    );
    agents = Directory('${roots.configurationRoot}/agents');
    reads = 0;
    afterObservation = null;
    GlobalSettingsService? owner;
    addTearDown(() async {
      await owner?.close();
    });
    bootstrap = ApplicationPluginBootstrap(
      CapabilityRegistry(),
      ExtensionRegistry(),
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
      loadRecords: (catalog, installation) {
        settings = owner = GlobalSettingsService(
          catalog: catalog.settings,
          records: catalog.records,
          roots: roots,
        );
        return settings.loadStartupRecords(catalog, installation);
      },
      loadCurrentRecords: (catalog, installation) async {
        reads++;
        final view = await settings.loadCurrentRecords(catalog, installation);
        await afterObservation?.call();
        return view;
      },
    );
    addTearDown(bootstrap.close);
    await bootstrap.start(
      installationRoot: installations.path,
      dartaotruntimeExecutable: runtime,
      hostArtifactPath: host.path,
      startupArguments: const {},
    );
    expect(bootstrap.catalog!.issues, isEmpty);
    final backend = bootstrap.backends.single;
    expect(
      backend.state,
      InstalledBackendState.active,
      reason: '${backend.failure}',
    );
    expect(backend.installation.backendConsumedRecordTypes, [_type]);
    expect(backend.installation.backendConsumedCredentialSlots, isEmpty);
    connection = backend.connection!;
    expect(connection.capabilityExposures, isEmpty);
    expect(connection.extensionExposures.single.toMap(), {
      'extensionPointId': inferenceContextSources.value,
      'extensionId': '$_plugin.instructions',
      'serviceId': remoteRunBoundInferenceContextSourceServiceId,
      'configurationContext': 'default',
      'metadata': {'failureMode': 'required'},
    });
    client = AgentCatalogServiceClient(
      connection.channelFor(
        connection.defaultConfigurationContext,
        agentCatalogServiceId,
      ),
    );
    expect(reads, 0, reason: 'Startup is not an explicit catalog read.');
  });

  Future<RecordView> create(String id, Map<String, Object?> values) =>
      settings.createRecord(_type, ConfigurationRecordId(id), values);
  File recordFile(String id) => File('${agents.path}/$id.toml');

  test(
    'same client re-reads trusted Settings CRUD without broadening scope or writing',
    () async {
      final empty = await client.readAgents();
      expect(empty.agents, isEmpty);
      expect(empty.isComplete, isTrue);
      expect(await agents.exists(), isFalse);

      await settings.createRecord(
        RecordTypeId('$_foreign.agent'),
        ConfigurationRecordId('peer'),
        {'name': 'Private peer', 'instructions': 'Not an Agent service record'},
      );
      final zulu = await create('zulu', {
        'name': 'A',
        'when-to-use': '',
        'instructions': '',
      });
      const markdown =
          '\n# Review\n\n- Check the diff.\n\n```dart\nreturn true;\n```\n';
      final alpha = await create('alpha', {
        'name': 'Z',
        'description': '',
        'instructions': markdown,
      });
      final file = recordFile('alpha');
      final bytes = await file.readAsBytes();
      final modified = DateTime.utc(2001);
      await file.setLastModified(modified);
      final created = await client.readAgents();
      expect(created.isComplete, isTrue);
      expect(
        created.agents.map(
          (agent) => (
            agent.id,
            agent.name,
            agent.description,
            agent.whenToUse,
            agent.instructions,
          ),
        ),
        [('alpha', 'Z', '', null, markdown), ('zulu', 'A', null, '', '')],
      );

      final channel = connection.channelFor(
        connection.defaultConfigurationContext,
        agentCatalogServiceId,
      );
      for (final (method, payload, code) in [
        (
          agentCatalogServiceReadAgentsId,
          {'recordType': '$_foreign.agent'},
          'invalid_request',
        ),
        ('deleteRecord', {'id': 'alpha'}, 'unknown_method'),
      ]) {
        await expectLater(
          channel.request(method, payload),
          throwsA(
            isA<PluginRemoteFailure>().having((e) => e.code, 'code', code),
          ),
        );
      }
      expect(reads, 2, reason: 'Neither rejected request may access Settings.');
      expect(await file.readAsBytes(), bytes);
      expect((await file.lastModified()).toUtc(), modified);

      // Service reads did not replace the original Settings edit handles.
      final edited = await settings.updateRecord(alpha, {
        'name': 'Renamed',
        'when-to-use': 'On review',
        'instructions': 'Updated',
      });
      final updated = (await client.readAgents()).agents.first;
      expect(
        (
          updated.id,
          updated.name,
          updated.description,
          updated.whenToUse,
          updated.instructions,
        ),
        ('alpha', 'Renamed', null, 'On review', 'Updated'),
      );
      expect(created.agents.first.instructions, markdown);
      await settings.deleteRecord(edited);
      expect((await client.readAgents()).agents.map((agent) => agent.id), [
        'zulu',
      ]);
      await settings.deleteRecord(zulu);
      final deleted = await client.readAgents();
      expect(deleted.isComplete, isTrue);
      expect(deleted.agents, isEmpty);
      expect(
        (await settings.loadRecords(
          RecordCollectionId('agents'),
        )).records.map((record) => record.id.value),
        ['peer'],
      );
      expect(reads, 5);
    },
  );

  test(
    'partial and unavailable observations are not clean empty or a cached success',
    () async {
      final healthy = await create('healthy', {
        'name': '',
        'instructions': 'Retain me',
      });
      final broken = recordFile('broken');
      const invalid = 'invalid = [ # private diagnostic';
      await broken.writeAsString(invalid);
      final partial = await client.readAgents();
      expect(partial.isComplete, isFalse);
      expect(partial.agents.single.id, 'healthy');
      await settings.deleteRecord(healthy);
      final allInvalid = await client.readAgents();
      expect(allInvalid.isComplete, isFalse);
      expect(allInvalid.agents, isEmpty);
      expect(await broken.readAsString(), invalid);

      final saved = await agents.rename('${agents.path}-saved');
      final obstruction = await File(
        agents.path,
      ).writeAsString('private obstruction');
      await expectLater(
        client.readAgents(),
        throwsA(
          isA<AgentCatalogFailure>()
              .having((e) => e.code, 'code', 'unavailable')
              .having((e) => e.message, 'message', isNot(contains(agents.path)))
              .having((e) => e.details, 'details', isEmpty),
        ),
      );
      expect(await obstruction.readAsString(), 'private obstruction');
      await obstruction.delete();
      await saved.rename(agents.path);
      await broken.delete();
      final recovered = await client.readAgents();
      expect(recovered.isComplete, isTrue);
      expect(recovered.agents, isEmpty);
    },
  );

  test(
    'retiring the grant fences a pending observation and a retained client',
    () async {
      await create('held', {
        'name': 'Held',
        'instructions': 'Do not publish late',
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      afterObservation = () {
        entered.complete();
        return release.future;
      };
      final unavailable = throwsA(
        isA<AgentCatalogFailure>().having((e) => e.code, 'code', 'unavailable'),
      );
      final pending = expectLater(client.readAgents(), unavailable);
      await entered.future.timeout(const Duration(seconds: 10));
      connection.revokeInfrastructureContext();
      await pending.timeout(const Duration(seconds: 10));
      release.complete();
      await expectLater(client.readAgents(), unavailable);
      expect(reads, 1);
      await bootstrap.close();
      await expectLater(
        client.readAgents(),
        throwsA(isA<PluginConnectionClosed>()),
      );
    },
  );
}
