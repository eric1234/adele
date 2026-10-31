@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/backend_artifacts.dart';

const _openai = 'dev.adele.openai';
const _recordType = 'dev.adele.openai.api-key';
const _chatGpt = 'dev.adele.openai.chatgpt-experimental';

void main() {
  late Directory artifacts;
  late Directory repository;
  late File hostArtifact;
  late File openaiArtifact;
  late File observerArtifact;
  late String runtime;

  setUpAll(() async {
    repository = Directory.current.parent;
    artifacts = await Directory.systemTemp.createTemp(
      'adele-openai-record-aot-',
    );
    final dart =
        '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart';
    runtime = File(dart).parent.uri.resolve('dartaotruntime').toFilePath();
    hostArtifact = File('${artifacts.path}/host.aot');
    openaiArtifact = File('${artifacts.path}/openai.aot');
    observerArtifact = File('${artifacts.path}/observer.aot');
    for (final target in [
      (
        entrypoint: 'packages/plugin_backend_host/bin/adele_backend_host.dart',
        artifact: hostArtifact,
      ),
      (
        entrypoint:
            'plugins/openai/packages/backend/bin/openai_model_provider_backend.dart',
        artifact: openaiArtifact,
      ),
      (
        entrypoint: 'app/test/fixtures/backend_credential_consumer.dart',
        artifact: observerArtifact,
      ),
    ]) {
      await compileAotSnapshot(
        dartExecutable: dart,
        workingDirectory: repository,
        entrypoint: target.entrypoint,
        artifact: target.artifact,
        stage: 'openai-record-startup-integration',
      );
    }
  });
  tearDownAll(() => artifacts.delete(recursive: true));

  for (final chatGptConfigured in [false, true]) {
    test('stock OpenAI AOT decodes records without activating API keys '
        '(ChatGPT configured: $chatGptConfigured)', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'adele-openai-record-startup-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final roots = PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: '${temporary.path}/config',
        localStateRoot: '${temporary.path}/state',
        localDataRoot: '${temporary.path}/data',
        cacheRoot: '${temporary.path}/cache',
      );
      final installationRoot = Directory('${temporary.path}/installations');
      final installationDirectory = await Directory(
        '${installationRoot.path}/openai',
      ).create(recursive: true);
      await openaiArtifact.copy('${installationDirectory.path}/backend.aot');
      await publishStockPluginInstallation(
        repositoryRoot: repository,
        installationDirectory: installationDirectory,
        pluginId: _openai,
        displayName: 'OpenAI',
        backend: true,
      );
      final catalog = await PreparedPluginCatalog.discover(
        installationRoot.path,
      );
      expect(catalog.issues, isEmpty);
      final installation = catalog.installations.single;
      expect(installation.backendConsumedRecordTypes, [
        RecordTypeId(_recordType),
      ]);
      expect(installation.backendConsumedCredentialSlotsToJson(), [
        {
          'recordType': _recordType,
          'slots': ['api-key'],
        },
      ]);
      final definition = catalog.records.definition(RecordTypeId(_recordType));
      expect(definition.owner, PluginId(_openai));
      expect(definition.fields.map((field) => field.id.value), [
        'display-name',
        'endpoint',
      ]);
      final slot = definition.credentialSlots.single.id;
      expect(slot, RecordCredentialSlotId('api-key'));

      final settings = GlobalSettingsService(
        catalog: catalog.settings,
        records: catalog.records,
        roots: roots,
      );
      addTearDown(settings.close);
      final storage = _Storage();
      final credentials = CredentialService(storage);
      addTearDown(credentials.close);
      final associations = RecordCredentialService(
        settings: settings,
        credentials: credentials,
      );
      addTearDown(associations.close);
      expect(storage.calls, isEmpty);
      final records = <String, RecordView>{};
      for (final id in ['work', 'personal']) {
        final record = await settings
            .createRecord(definition.id, ConfigurationRecordId('$id-openai'), {
              'display-name': id == 'work' ? 'Work' : 'Personal',
              if (id == 'work') 'endpoint': 'https://work.example.invalid/v1',
            });
        final attached = await associations.attach(
          record,
          slot,
          CredentialSecret('test-only-$id-api-key'),
        );
        expect(attached.status, RecordCredentialStatus.stored);
        records[id] = attached.record;
      }
      expect(storage.values, hasLength(2));
      final personalFile = File(
        '${settings.collectionPath(definition.collection)}/personal-openai.toml',
      );
      final personalBytes = await personalFile.readAsBytes();
      records['work'] = await settings.updateRecord(records['work']!, {
        ...records['work']!.values,
        'display-name': 'Work Renamed',
      });
      expect(records['work']!.id, ConfigurationRecordId('work-openai'));
      expect(await personalFile.readAsBytes(), personalBytes);
      final persisted = <String, String>{};
      for (final id in ['work', 'personal']) {
        final file = File(
          '${settings.collectionPath(definition.collection)}/$id-openai.toml',
        );
        persisted[id] = await file.readAsString();
        expect(persisted[id], contains('[credentials]'));
        expect(persisted[id], isNot(contains('test-only-')));
      }
      for (final reference in storage.values.keys) {
        expect(
          persisted.values.where((text) => text.contains(reference.value)),
          hasLength(1),
        );
      }

      // Explicit association writes above may verify the keyring. Projection and
      // backend startup must not read it; only controlled requests below may do so.
      storage.calls.clear();
      final projected = await settings.loadStartupRecords(
        catalog,
        installation,
      );
      final expectedRecords = <Map<String, Object?>>[
        {
          'collection': 'providers',
          'type': _recordType,
          'id': 'personal-openai',
          'values': {'display-name': 'Personal'},
        },
        {
          'collection': 'providers',
          'type': _recordType,
          'id': 'work-openai',
          'values': {
            'display-name': 'Work Renamed',
            'endpoint': 'https://work.example.invalid/v1',
          },
        },
      ];
      expect(projected.diagnostics, isEmpty);
      expect(projected.records, unorderedEquals(expectedRecords));
      final serialized = jsonEncode(projected.records);
      for (final forbidden in [
        'credentials',
        'cred1_',
        'test-only-',
        roots.configurationRoot,
        'revision',
      ]) {
        expect(serialized, isNot(contains(forbidden)));
      }
      expect(storage.calls, isEmpty);

      final registry = CapabilityRegistry();
      final extensions = ExtensionRegistry();
      var loads = 0;
      late StartupRecordsView startupRecords;
      GlobalSettingsService? reader;
      RecordCredentialService? backendAssociations;
      final bootstrap = ApplicationPluginBootstrap(
        registry,
        extensions,
        loadSettings: (prepared) async =>
            PreparedSettingsSnapshot.resolve(prepared),
        loadRecords: (prepared, owner) async {
          loads++;
          reader = GlobalSettingsService(
            catalog: prepared.settings,
            records: prepared.records,
            roots: roots,
          );
          backendAssociations = RecordCredentialService(
            settings: reader!,
            credentials: credentials,
          );
          return startupRecords = await reader!.loadStartupRecords(
            prepared,
            owner,
          );
        },
        credentialAssociations: () => backendAssociations!,
      );
      addTearDown(() async {
        await bootstrap.close();
        await backendAssociations?.close();
        await reader?.close();
      });
      final chatGptFile = File(
        '${temporary.path}/absent-chatgpt-credentials.json',
      );
      await bootstrap.start(
        installationRoot: installationRoot.path,
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
        startupArguments: {
          if (chatGptConfigured)
            _openai: [
              '--chatgpt-only',
              jsonEncode({
                'credentialFile': chatGptFile.path,
                'clientId': 'test-only-public-client',
                'instanceId': 'record-startup-test',
                'issuer': 'https://oauth.example.invalid',
                'endpoint': 'https://chatgpt.example.invalid/responses',
              }),
            ],
        },
      );
      expect(loads, 1);
      expect(bootstrap.state, ApplicationPluginState.ready);
      final backend = bootstrap.backends.single;
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
      expect(startupRecords.records, projected.records);
      final connection = backend.connection!;
      expect(connection.extensionExposures, isEmpty);
      expect(connection.capabilityExposures.map((entry) => entry.toMap()), [
        if (chatGptConfigured)
          {
            'providerId': _chatGpt,
            'capabilityId': modelProviderCapability.id.value,
            'capabilityMajorVersion': modelProviderCapability.majorVersion,
            'serviceId': modelProviderServiceId,
            'displayName': 'Experimental ChatGPT',
            'configurationContext': 'chatgpt-experimental',
            'rank': 0,
          },
      ]);
      expect(
        registry
            .providersFor(modelProviderCapability)
            .map((entry) => entry.id.value),
        [if (chatGptConfigured) _chatGpt],
      );
      expect(await chatGptFile.exists(), isFalse);
      expect(storage.calls, isEmpty);

      // Exact decoded contents are observed in an independent generic fixture,
      // not through an observation API or instrumentation in stock OpenAI.
      final observer = await bootstrap.host!.startPlugin(
        pluginId: 'dev.adele.test.record-observer',
        artifactUri: observerArtifact.uri,
        records: startupRecords.records,
      );
      addTearDown(observer.close);
      expect(observer.capabilityExposures, isEmpty);
      expect(observer.extensionExposures, isEmpty);
      expect(await observer.request('records', {}), {
        'records': projected.records,
      });
      final denied = await observer.request('read', {
        'collection': 'providers',
        'recordType': _recordType,
        'recordId': 'work-openai',
        'slot': 'api-key',
      });
      _expectCredentialRedacted(denied);
      expect(denied, {
        'failure': 'notAuthorized',
        'display': 'Credential access failed (notAuthorized).',
      });
      expect(storage.calls, isEmpty);
      for (final id in ['work', 'personal']) {
        expect(
          await File(
            '${settings.collectionPath(definition.collection)}/$id-openai.toml',
          ).readAsString(),
          persisted[id],
        );
      }

      // Read-only projection did not retire this owner's existing edit handle,
      // and later CRUD cannot mutate the already-running generation's copy.
      await settings.updateRecord(records['work']!, {
        ...records['work']!.values,
        'display-name': 'Work After Startup',
      });
      expect(await observer.request('records', {}), {
        'records': projected.records,
      });
      expect(storage.calls, isEmpty);

      // Keep the exact stock declaration/schema, replacing only executable test
      // code. Stock OpenAI itself intentionally does not read these credentials.
      await bootstrap.close();
      await observerArtifact.copy('${installationDirectory.path}/backend.aot');
      GlobalSettingsService? controlledReader;
      RecordCredentialService? controlledAssociations;
      final controlled = ApplicationPluginBootstrap(
        CapabilityRegistry(),
        ExtensionRegistry(),
        loadSettings: (prepared) async =>
            PreparedSettingsSnapshot.resolve(prepared),
        loadRecords: (prepared, owner) async {
          controlledReader = GlobalSettingsService(
            catalog: prepared.settings,
            records: prepared.records,
            roots: roots,
          );
          controlledAssociations = RecordCredentialService(
            settings: controlledReader!,
            credentials: credentials,
          );
          return controlledReader!.loadStartupRecords(prepared, owner);
        },
        credentialAssociations: () => controlledAssociations!,
      );
      addTearDown(() async {
        await controlled.close();
        await controlledAssociations?.close();
        await controlledReader?.close();
      });
      await controlled.start(
        installationRoot: installationRoot.path,
        dartaotruntimeExecutable: runtime,
        hostArtifactPath: hostArtifact.path,
      );
      final controlledBackend = controlled.backends.single;
      expect(
        controlledBackend.state,
        InstalledBackendState.active,
        reason: '${controlledBackend.failure}',
      );
      expect(
        controlledBackend.installation.backendConsumedCredentialSlotsToJson(),
        installation.backendConsumedCredentialSlotsToJson(),
      );
      expect(storage.calls, isEmpty);
      final credentialConsumer = controlledBackend.connection!;
      expect(credentialConsumer.capabilityExposures, isEmpty);
      expect(credentialConsumer.extensionExposures, isEmpty);
      final snapshot = await credentialConsumer.request('snapshot', {}) as Map;
      _expectCredentialRedacted(snapshot);
      expect(
        snapshot['records'],
        unorderedEquals([
          expectedRecords.first,
          {
            ...expectedRecords.last,
            'values': {
              ...expectedRecords.last['values']! as Map,
              'display-name': 'Work After Startup',
            },
          },
        ]),
      );
      for (final id in ['work', 'personal']) {
        final result =
            await credentialConsumer.request('read', {
                  'collection': 'providers',
                  'recordType': _recordType,
                  'recordId': '$id-openai',
                  'slot': 'api-key',
                })
                as Map;
        expect(
          result.length == 1 && result['secret'] == 'test-only-$id-api-key',
          isTrue,
          reason: 'The stock declaration must authorize its exact association.',
        );
      }
      expect(storage.calls, ['read', 'read']);
      final foreign = await controlled.host!.startPlugin(
        pluginId: 'dev.adele.test.credential-consumer',
        artifactUri: observerArtifact.uri,
      );
      addTearDown(foreign.close);
      final foreignResult = await foreign.request('read', {
        'collection': 'providers',
        'recordType': _recordType,
        'recordId': 'personal-openai',
        'slot': 'api-key',
      });
      _expectCredentialRedacted(foreignResult);
      expect(foreignResult, {
        'failure': 'notAuthorized',
        'display': 'Credential access failed (notAuthorized).',
      });
      expect(storage.calls, ['read', 'read']);
    });
  }
}

void _expectCredentialRedacted(Object? result) {
  final text = '$result';
  for (final forbidden in ['test-only-', 'cred1_', '"secret"', '"reference"']) {
    expect(
      text.contains(forbidden),
      isFalse,
      reason: 'Credential content escaped its explicit authorized response.',
    );
  }
}

final class _Storage implements CredentialStorageAdapter {
  final values = <CredentialReference, String>{};
  final calls = <String>[];

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls.add('contains');
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    calls.add('read');
    return values[reference];
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    calls.add('write');
    values[reference] = secret.reveal();
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    calls.add('delete');
    values.remove(reference);
  }
}
