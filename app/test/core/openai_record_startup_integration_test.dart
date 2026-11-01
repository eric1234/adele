@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
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

  Future<_ProviderFixture> prepareProviders({bool chatGpt = false}) async {
    final temporary = await Directory.systemTemp.createTemp(
      'adele-configured-openai-',
    );
    final fixture = _ProviderFixture(temporary, runtime, hostArtifact.path);
    addTearDown(fixture.close);
    await fixture.prepare(repository, openaiArtifact, chatGpt: chatGpt);
    return fixture;
  }

  for (final chatGpt in [false, true]) {
    test('real configured Work and Personal use only their own HTTP authority '
        '(ChatGPT: $chatGpt)', () async {
      final fixture = await prepareProviders(chatGpt: chatGpt);
      await fixture.start();
      final connection = fixture.connection;
      final exposures = connection.capabilityExposures;
      expect(exposures, hasLength(chatGpt ? 3 : 2));
      expect(
        exposures
            .where((entry) => entry.providerId.startsWith('$_recordType.'))
            .map((entry) => entry.providerId),
        ['$_recordType.personal-openai', '$_recordType.work-openai'],
      );
      expect(exposures.map((entry) => entry.configurationContext).toSet(), {
        'api-key-record:personal-openai',
        'api-key-record:work-openai',
        if (chatGpt) 'chatgpt-experimental',
      });
      expect(fixture.bootstrap.backends, hasLength(1));
      expect(fixture.storage.calls, isEmpty);
      _expectProviderRedacted(exposures.map((entry) => entry.toMap()));

      // Creating the generated invocation does not perform a credential read.
      final work = fixture.invoke('work', model: 'personal-openai');
      expect(fixture.storage.calls, isEmpty);
      final workEvents = await work.toList();
      _expectCompleted(workEvents, '/work/responses');
      expect(fixture.storage.readReferences, [fixture.reference('work')]);
      expect(fixture.requests.single['path'], '/work/responses');
      expect(
        fixture.requests.single['authorization'] == 'Bearer test-work-key',
        isTrue,
      );
      expect(fixture.requests.single['account'], isNull);

      _expectCompleted(
        await fixture.invoke('personal', model: 'work-openai').toList(),
        '/personal/responses',
      );
      expect(fixture.storage.readReferences, [
        fixture.reference('work'),
        fixture.reference('personal'),
      ]);
      expect(fixture.requests.last['path'], '/personal/responses');
      expect(
        fixture.requests.last['authorization'] == 'Bearer test-personal-key',
        isTrue,
      );
      expect(fixture.requests.last['account'], isNull);
      expect(
        (fixture.requests.first['body']! as Map)['model'],
        'personal-openai',
      );
      expect((fixture.requests.last['body']! as Map)['model'], 'work-openai');
      for (final request in fixture.requests) {
        _expectProviderRedacted(jsonEncode(request['body']));
        expect(
          (request['body']! as Map).keys,
          isNot(
            anyElement(
              isIn([
                'recordId',
                'configurationContext',
                'providerId',
                'accountId',
              ]),
            ),
          ),
        );
      }
      if (chatGpt) {
        _expectCompleted(
          await fixture.invokeChatGpt().toList(),
          '/chatgpt/responses',
        );
        expect(
          fixture.requests.last['authorization'] == 'Bearer test-chatgpt-token',
          isTrue,
        );
        expect(fixture.requests.last['account'], 'test-chatgpt-account');
        expect(fixture.storage.calls, ['read', 'read']);
      }
      _expectCompleted(
        await fixture.invoke('work').toList(),
        '/work/responses',
      );
      expect(
        fixture.requests.last['authorization'] == 'Bearer test-work-key',
        isTrue,
      );
      expect(fixture.storage.calls, ['read', 'read', 'read']);
      expect(connection.capabilityExposures, exposures);
    });
  }

  test(
    'missing, invalid, unavailable and uncertain credentials never fall back',
    () async {
      final fixture = await prepareProviders(chatGpt: true);
      final workReference = fixture.reference('work');
      final original = fixture.storage.values.remove(workReference)!;
      // A missing local key at fresh startup still advertises an independent route.
      await fixture.start();
      expect(fixture.connection.capabilityExposures, hasLength(3));
      expect(fixture.storage.calls, isEmpty);
      await fixture.expectFailure('missing_locally');
      expect(fixture.requests, isEmpty);
      _expectCompleted(
        await fixture.invoke('personal').toList(),
        '/personal/responses',
      );
      _expectCompleted(
        await fixture.invokeChatGpt().toList(),
        '/chatgpt/responses',
      );

      fixture.storage.values[workReference] = 'invalid-protected-test-work-key';
      await fixture.expectFailure('invalid_binding');
      fixture.storage.values[workReference] =
          fixture.storage.values[fixture.reference('personal')]!;
      await fixture.expectFailure('invalid_binding');
      fixture.storage.values[workReference] = original;
      fixture.storage.failureReference = workReference;
      fixture.storage.failure = const CredentialFailure(
        CredentialFailureKind.unavailable,
      );
      await fixture.expectFailure('storage_unavailable');
      fixture.storage.failure = StateError('native diagnostic test-work-key');
      await fixture.expectFailure('access_failed');
      fixture.storage.failure = null;
      fixture.storage.writeFailure = StateError(
        'uncertain write test-work-key',
      );
      await expectLater(
        fixture.credentials.replace(workReference, CredentialSecret(original)),
        throwsA(isA<CredentialFailure>()),
      );
      fixture.storage.writeFailure = null;
      final reads = fixture.storage.readReferences.length;
      await fixture.expectFailure('reconciliation_required');
      expect(fixture.storage.readReferences, hasLength(reads));
      expect(
        fixture.requests.where((entry) => entry['path'] == '/work/responses'),
        isEmpty,
      );
      _expectCompleted(
        await fixture.invoke('personal').toList(),
        '/personal/responses',
      );
      _expectCompleted(
        await fixture.invokeChatGpt().toList(),
        '/chatgpt/responses',
      );
    },
  );

  for (final mutation in ['replace', 'endpoint', 'forget', 'recreate']) {
    test(
      '$mutation requires a fresh generation without retargeting old bindings',
      () async {
        final fixture = await prepareProviders();
        await fixture.start();
        final oldConnection = fixture.connection;
        final oldClient = fixture.client('work');
        _expectCompleted(
          await fixture.invoke('work').toList(),
          '/work/responses',
        );
        final slot = RecordCredentialSlotId('api-key');
        var record = fixture.records['work']!;
        switch (mutation) {
          case 'replace':
            record = (await fixture.associations.replace(
              record,
              slot,
              CredentialSecret('test-replacement-key'),
            )).record;
          case 'endpoint':
            record = await fixture.settings.updateRecord(record, {
              ...record.values,
              'display-name': 'Work Renamed',
              'endpoint': '${fixture.origin}/updated/responses',
            });
          case 'forget':
            record = (await fixture.associations.forget(record, slot)).record;
          case 'recreate':
            record = (await fixture.associations.forget(record, slot)).record;
            await fixture.settings.deleteRecord(record);
            record = await fixture.settings.createRecord(
              RecordTypeId(_recordType),
              ConfigurationRecordId('work-openai'),
              {
                'display-name': 'Recreated',
                'endpoint': '${fixture.origin}/updated/responses',
              },
            );
            record = (await fixture.associations.attach(
              record,
              slot,
              CredentialSecret('test-replacement-key'),
            )).record;
        }
        fixture.records['work'] = record;
        fixture.storage.calls.clear();
        await fixture.expectFailure('stale_configuration');
        expect(fixture.storage.calls, isEmpty);
        expect(fixture.requests, hasLength(1));
        _expectCompleted(
          await fixture.invoke('personal').toList(),
          '/personal/responses',
        );
        expect(
          oldConnection.capabilityExposures
              .singleWhere(
                (entry) => entry.providerId == '$_recordType.work-openai',
              )
              .displayName,
          'Work OpenAI',
        );

        await fixture.restart();
        expect(fixture.storage.calls, isEmpty);
        expect(oldConnection.isClosed, isTrue);
        await expectLater(
          oldClient.invoke(_providerRequest('same-model')).toList(),
          throwsA(isA<PluginConnectionClosed>()),
        );
        if (mutation == 'forget') {
          await fixture.expectFailure('not_configured');
        } else {
          final updated = mutation == 'endpoint' || mutation == 'recreate';
          _expectCompleted(
            await fixture.invoke('work').toList(),
            updated ? '/updated/responses' : '/work/responses',
          );
          final key = mutation == 'replace' || mutation == 'recreate'
              ? 'test-replacement-key'
              : 'test-work-key';
          expect(
            fixture.requests.last['authorization'] == 'Bearer $key',
            isTrue,
          );
        }
      },
    );
  }

  test(
    'invalid configured endpoint isolates only that record from siblings',
    () async {
      final fixture = await prepareProviders(chatGpt: true);
      fixture.records['work'] = await fixture.settings
          .updateRecord(fixture.records['work']!, {
            'display-name': 'Invalid Work',
            'endpoint': 'http://public.example.invalid/private',
          });
      await fixture.start();
      expect(
        fixture.connection.capabilityExposures.map((entry) => entry.providerId),
        unorderedEquals(['$_recordType.personal-openai', _chatGpt]),
      );
      expect(() => fixture.client('work'), throwsA(isA<ProviderUnavailable>()));
      expect(fixture.storage.calls, isEmpty);
      _expectCompleted(
        await fixture.invoke('personal').toList(),
        '/personal/responses',
      );
      _expectCompleted(
        await fixture.invokeChatGpt().toList(),
        '/chatgpt/responses',
      );
      expect(fixture.storage.readReferences, [fixture.reference('personal')]);
    },
  );

  test('new records are invisible to the captured generation', () async {
    final fixture = await prepareProviders();
    await fixture.start();
    await fixture.settings.createRecord(
      RecordTypeId(_recordType),
      ConfigurationRecordId('new-openai'),
      {'display-name': 'New OpenAI'},
    );
    expect(() => fixture.client('new'), throwsA(isA<ProviderUnavailable>()));
    expect(fixture.connection.capabilityExposures, hasLength(2));
    await fixture.restart();
    expect(fixture.connection.capabilityExposures, hasLength(3));
    await fixture.expectFailure('not_configured', id: 'new');
    expect(fixture.requests, isEmpty);
  });

  for (final retire in [false, true]) {
    test('pending OS credential result cannot start HTTP after '
        '${retire ? 'retirement' : 'cancellation'}', () async {
      final fixture = await prepareProviders();
      await fixture.start();
      final gate = fixture.storage.gate = _ReadGate();
      addTearDown(gate.release);
      final events = <ModelProviderEvent>[];
      final settled = Completer<void>();
      final subscription = fixture
          .invoke('work')
          .listen(
            events.add,
            onError: (Object error) {
              expect(error, isA<PluginConnectionClosed>());
              _expectProviderRedacted(error);
              if (!settled.isCompleted) settled.complete();
            },
            onDone: () {
              if (!settled.isCompleted) settled.complete();
            },
          );
      await gate.entered.future;
      expect(fixture.requests, isEmpty);
      // Settings I/O remains usable while protected storage is awaiting unlock.
      await fixture.settings.load();
      expect(gate.returned.isCompleted, isFalse);
      Future<void>? closing;
      if (retire) {
        fixture.connection.revokeInfrastructureContext();
        await settled.future;
        expect(
          events.single.terminal!.failure!.providerCode,
          'openai_credential_generation_unavailable',
        );
        closing = fixture.bootstrap.close();
      } else {
        await subscription.cancel();
        expect(events, isEmpty);
      }
      gate.release();
      await gate.returned.future;
      if (retire) {
        await closing;
      } else {
        // The next completed reverse read is a deterministic late-result barrier.
        _expectCompleted(
          await fixture.invoke('personal').toList(),
          '/personal/responses',
        );
        await fixture.bootstrap.close();
      }
      expect(
        fixture.requests.where((entry) => entry['path'] == '/work/responses'),
        isEmpty,
      );
    });
  }

  for (final chatGptConfigured in [false, true]) {
    test('stock OpenAI AOT advertises records without reading API keys '
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
      expect(
        connection.capabilityExposures.map((entry) => entry.toMap()),
        unorderedEquals([
          for (final id in ['personal', 'work'])
            {
              'providerId': '$_recordType.$id-openai',
              'capabilityId': modelProviderCapability.id.value,
              'capabilityMajorVersion': modelProviderCapability.majorVersion,
              'serviceId': modelProviderServiceId,
              'displayName': id == 'work' ? 'Work Renamed' : 'Personal',
              'configurationContext': 'api-key-record:$id-openai',
              'rank': 0,
            },
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
        ]),
      );
      expect(
        registry
            .providersFor(modelProviderCapability)
            .map((entry) => entry.id.value),
        unorderedEquals([
          '$_recordType.personal-openai',
          '$_recordType.work-openai',
          if (chatGptConfigured) _chatGpt,
        ]),
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
      // code to retain P3b's direct selector/authorization regression coverage.
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
  final readReferences = <CredentialReference>[];
  _ReadGate? gate;
  CredentialReference? failureReference;
  Object? failure;
  Object? writeFailure;

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls.add('contains');
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    calls.add('read');
    readReferences.add(reference);
    final captured = values[reference];
    final pending = gate;
    if (pending != null) {
      gate = null;
      pending.entered.complete();
      await pending.resumed.future;
      pending.returned.complete();
    }
    if (reference == failureReference && failure != null) throw failure!;
    return captured;
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    calls.add('write');
    values[reference] = secret.reveal();
    if (writeFailure != null) throw writeFailure!;
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    calls.add('delete');
    values.remove(reference);
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

final class _ProviderFixture {
  _ProviderFixture(this.directory, this.runtime, this.host);

  final Directory directory;
  final String runtime;
  final String host;
  final storage = _Storage();
  final records = <String, RecordView>{};
  final references = <String, CredentialReference>{};
  final requests = <Map<String, Object?>>[];
  final registry = CapabilityRegistry();
  final readers = <GlobalSettingsService>[];
  final backendAssociations = <RecordCredentialService>[];
  late final credentials = CredentialService(storage);
  late final PlatformStorageRoots roots;
  late final GlobalSettingsService settings;
  late final RecordCredentialService associations;
  late final HttpServer server;
  late final StreamSubscription<HttpRequest> serverSubscription;
  late final Map<String, List<String>> startupArguments;
  ApplicationPluginBootstrap? _bootstrap;

  ApplicationPluginBootstrap get bootstrap => _bootstrap!;
  PluginBackendConnection get connection =>
      bootstrap.backends.single.connection!;
  String get origin => 'http://${server.address.address}:${server.port}';
  String get installationRoot => '${directory.path}/installations';

  CredentialReference reference(String id) => references[id]!;

  Future<void> prepare(
    Directory repository,
    File artifact, {
    required bool chatGpt,
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverSubscription = server.listen((request) {
      unawaited(() async {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        requests.add({
          'path': request.uri.path,
          'authorization': request.headers.value(
            HttpHeaders.authorizationHeader,
          ),
          'account': request.headers.value('ChatGPT-Account-ID'),
          'body': body,
        });
        final response = request.response;
        response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        for (final event in [
          {
            'type': 'response.output_text.delta',
            'item_id': 'message',
            'delta': request.uri.path,
          },
          {
            'type': 'response.output_item.done',
            'item': {
              'type': 'message',
              'id': 'message',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {
                  'type': 'output_text',
                  'text': request.uri.path,
                  'annotations': <Object?>[],
                },
              ],
            },
          },
          {
            'type': 'response.completed',
            'response': {'id': 'response', 'model': (body as Map)['model']},
          },
        ]) {
          response.write('data: ${jsonEncode(event)}\n\n');
        }
        await response.close();
      }());
    });
    final installation = await Directory(
      '$installationRoot/openai',
    ).create(recursive: true);
    await artifact.copy('${installation.path}/backend.aot');
    await publishStockPluginInstallation(
      repositoryRoot: repository,
      installationDirectory: installation,
      pluginId: _openai,
      displayName: 'OpenAI',
      backend: true,
    );
    final catalog = await PreparedPluginCatalog.discover(installationRoot);
    expect(catalog.issues, isEmpty);
    roots = PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${directory.path}/config',
      localStateRoot: '${directory.path}/state',
      localDataRoot: '${directory.path}/data',
      cacheRoot: '${directory.path}/cache',
    );
    settings = GlobalSettingsService(
      catalog: catalog.settings,
      records: catalog.records,
      roots: roots,
    );
    associations = RecordCredentialService(
      settings: settings,
      credentials: credentials,
    );
    for (final id in ['work', 'personal']) {
      final record = await settings.createRecord(
        RecordTypeId(_recordType),
        ConfigurationRecordId('$id-openai'),
        {
          'display-name': id == 'work' ? 'Work OpenAI' : 'Personal OpenAI',
          'endpoint': '$origin/$id/responses',
        },
      );
      records[id] = (await associations.attach(
        record,
        RecordCredentialSlotId('api-key'),
        CredentialSecret('test-$id-key'),
      )).record;
      references[id] = storage.values.entries
          .singleWhere(
            (entry) =>
                (jsonDecode(entry.value) as Map)['record'] == '$id-openai',
          )
          .key;
    }
    startupArguments = {};
    if (chatGpt) {
      final credentialFile = File('${directory.path}/chatgpt.json');
      String encode(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final idToken =
          '${encode({'alg': 'none'})}.${encode({
            'https://api.openai.com/auth': {'chatgpt_account_id': 'test-chatgpt-account'},
          })}.';
      await credentialFile.writeAsString(
        jsonEncode({
          'version': 1,
          'instances': {
            'configured-integration': {
              'revision': 1,
              'credential': {
                'idToken': idToken,
                'accessToken': 'test-chatgpt-token',
                'refreshToken': 'test-chatgpt-refresh',
                'accountId': 'test-chatgpt-account',
                'fedRamp': false,
              },
            },
          },
        }),
      );
      startupArguments[_openai] = [
        '--chatgpt-only',
        jsonEncode({
          'credentialFile': credentialFile.path,
          'clientId': 'test-public-client',
          'instanceId': 'configured-integration',
          'issuer': origin,
          'endpoint': '$origin/chatgpt/responses',
        }),
      ];
    }
    storage.calls.clear();
    storage.readReferences.clear();
  }

  Future<void> start() async {
    _bootstrap = ApplicationPluginBootstrap(
      registry,
      ExtensionRegistry(),
      loadSettings: (catalog) async =>
          PreparedSettingsSnapshot.resolve(catalog),
      loadRecords: (catalog, installation) async {
        // P3a authority belongs to this exact discovered declaration snapshot.
        final reader = GlobalSettingsService(
          catalog: catalog.settings,
          records: catalog.records,
          roots: roots,
        );
        readers.add(reader);
        backendAssociations.add(
          RecordCredentialService(settings: reader, credentials: credentials),
        );
        return reader.loadStartupRecords(catalog, installation);
      },
      credentialAssociations: () => backendAssociations.last,
    );
    await bootstrap.start(
      installationRoot: installationRoot,
      dartaotruntimeExecutable: runtime,
      hostArtifactPath: host,
      startupArguments: startupArguments,
    );
    expect(bootstrap.state, ApplicationPluginState.ready);
    expect(
      bootstrap.backends.single.state,
      InstalledBackendState.active,
      reason: '${bootstrap.backends.single.failure}',
    );
  }

  ModelProviderServiceClient client(String id) => ModelProviderServiceClient(
    registry
        .resolve(
          modelProviderCapability,
          providerId: ProviderId('$_recordType.$id-openai'),
        )
        .streamChannel,
  );

  Stream<ModelProviderEvent> invoke(String id, {String model = 'same-model'}) =>
      client(id).invoke(_providerRequest(model));

  Stream<ModelProviderEvent> invokeChatGpt() => ModelProviderServiceClient(
    registry
        .resolve(modelProviderCapability, providerId: ProviderId(_chatGpt))
        .streamChannel,
  ).invoke(_providerRequest('same-model'));

  Future<void> expectFailure(String code, {String id = 'work'}) async {
    final events = await invoke(id).toList();
    expect(events, hasLength(1));
    final terminal = events.single.terminal!;
    expect(terminal.settlement, ModelProviderSettlement.failed);
    expect(terminal.failure!.providerCode, 'openai_credential_$code');
    expect(
      terminal.failure!.kind,
      isNot(ModelProviderFailureKind.authentication),
    );
    _expectProviderRedacted([
      terminal.failure!.providerCode,
      terminal.failure!.providerMessage,
      terminal.failure!.providerDetails,
      terminal.nativeState,
      terminal.affinityState,
    ]);
  }

  Future<void> restart() async {
    await bootstrap.close();
    storage.calls.clear();
    storage.readReferences.clear();
    await start();
  }

  Future<void> close() async {
    storage.gate?.release();
    await _bootstrap?.close();
    for (final coordinator in backendAssociations.reversed) {
      await coordinator.close();
    }
    for (final reader in readers.reversed) {
      await reader.close();
    }
    await associations.close();
    await settings.close();
    await credentials.close();
    await serverSubscription.cancel();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}

ModelProviderRequest _providerRequest(String model) => ModelProviderRequest(
  model: model,
  instructions: 'Use only the exact capability binding.',
  input: [
    ModelProviderInput(
      kind: ModelProviderInputKind.message,
      message: ModelProviderMessage(
        role: ModelProviderMessageRole.user,
        content: [
          ModelProviderContent(
            kind: ModelProviderContentKind.text,
            text: 'Synthetic request',
          ),
        ],
      ),
      toolProposal: null,
      toolOutcome: null,
      itemId: null,
      nativeMetadata: null,
    ),
  ],
  tools: const [],
  toolChoice: ModelProviderToolChoice.none,
  maxOutputTokens: null,
  providerOptions: const {},
  nativeState: null,
  affinity: null,
);

void _expectCompleted(List<ModelProviderEvent> events, String path) {
  expect(
    events.where((event) => event.kind == ModelProviderEventKind.observation),
    isNotEmpty,
  );
  expect(
    events
        .where((event) => event.kind == ModelProviderEventKind.output)
        .single
        .output!
        .text,
    path,
  );
  expect(
    events.where((event) => event.kind == ModelProviderEventKind.terminal),
    hasLength(1),
  );
  expect(events.last.terminal!.settlement, ModelProviderSettlement.completed);
}

void _expectProviderRedacted(Object? value) {
  final text = '$value';
  for (final forbidden in [
    'test-work-key',
    'test-personal-key',
    'test-replacement-key',
    'test-chatgpt-token',
    'test-chatgpt-refresh',
    'cred1_',
    'native diagnostic',
    'AdeleCredentialFailure',
    'hostResponse',
    '"secret"',
    '"reference"',
  ]) {
    expect(
      text.contains(forbidden),
      isFalse,
      reason:
          'Credential detail escaped into a descriptor, payload, or failure.',
    );
  }
}
