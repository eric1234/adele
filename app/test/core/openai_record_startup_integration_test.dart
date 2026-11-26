@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppExitResponse;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_records.dart'
    show StartupCredentialReader;
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/core/record_apply_coordinator.dart';
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/execution/session_execution_controller.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_desktop/ui/settings/record_credential_controls.dart';
import 'package:adele_desktop/ui/settings/record_field_editor_host.dart';
import 'package:adele_model_provider/adele_model_catalog.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart' show Project;
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:model_configuration_contract/model_configuration_contract.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../tools/backend_artifacts.dart';
import '../../tool/model_configuration_frontend_compiler.dart';
import '../support/project_provider.dart';
import '../support/record_draft_id.dart';
import '../support/review_execution_fixture.dart';
import '../support/selection_sessions.dart';

part 'openai_model_browser_cases.dart';

const _openai = 'dev.adele.openai';
const _recordType = 'dev.adele.openai.api-key';
const _catalogProviderId = 'dev.adele.openai.model-catalog';
const _catalogConsumer = 'test.openai.catalog-consumer';
const _chatGpt = 'dev.adele.openai.chatgpt-experimental';
const _configurationService = 'dev.adele.openai.configuration';

void main() {
  late Directory artifacts;
  late Directory repository;
  late File hostArtifact;
  late File openaiArtifact;
  late File observerArtifact;
  late File consumerArtifact;
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
    consumerArtifact = File('${artifacts.path}/consumer.aot');
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
      (
        entrypoint: 'app/test/fixtures/backend_capability_consumer.dart',
        artifact: consumerArtifact,
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

  Future<_ProviderFixture> prepareProviders({
    bool chatGpt = false,
    bool consumeCatalog = false,
    bool modelBrowser = false,
  }) async {
    final temporary = await Directory.systemTemp.createTemp(
      'adele-configured-openai-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final fixture = _ProviderFixture(temporary, runtime, hostArtifact.path);
    if (modelBrowser) await _publishBrowserInstallations(fixture, repository);
    addTearDown(fixture.close);
    await fixture.prepare(
      repository,
      openaiArtifact,
      chatGpt: chatGpt,
      consumerArtifact: consumeCatalog ? consumerArtifact : null,
      modelBrowser: modelBrowser,
    );
    return fixture;
  }

  void applicationScenario(
    String name,
    Future<void> Function(_ProviderSettings, _ProviderFixture, List<_ReadGate>)
    exercise, {
    int heldCaptures = 0,
    bool holdBeforeScan = false,
  }) {
    testWidgets(
      name,
      (tester) => tester.runAsync(() async {
        final fixture = await prepareProviders();
        final app = NativeAdeleRuntime(
          localStateRoot: () => fixture.roots.localStateRoot,
        );
        await fixture.withApplication(
          tester,
          app,
          (ui, gates) => exercise(ui, fixture, gates),
          heldCaptures: heldCaptures,
          holdBeforeScan: holdBeforeScan,
        );
      }),
    );
  }

  _registerModelBrowserCases(() => prepareProviders(modelBrowser: true));

  applicationScenario(
    'Global Settings automatically publishes, updates and deletes '
    'an OpenAI account and its credential revisions on one AOT connection',
    (ui, fixture, _) async {
      final connection = fixture.connection;
      final host = fixture.bootstrap.host!;
      final personal = fixture.capture('personal');
      final work = fixture.capture('work');
      final id = await ui.draftAccount(
        'Third account',
        '${fixture.origin}/third/responses',
      );
      final file = fixture.providerFile('third-account.toml');
      expect(id, isNot('third-account'));
      expect(file.existsSync(), isFalse);
      expect(() => fixture.client(id), throwsA(isA<ProviderUnavailable>()));

      Future<_ConfiguredBinding> current() async {
        await ui.status(id, 'Applied');
        expect(fixture.connection, same(connection));
        expect(fixture.bootstrap.host, same(host));
        expect(fixture.backend.validate, returnsNormally);
        personal.expectSame(fixture.capture('personal'));
        work.expectSame(fixture.capture('work'));
        _expectCatalogAssociations(
          fixture.bootstrap,
          fixture.registry,
          recordIds: [id],
        );
        return fixture.captureRecord(id);
      }

      await ui.press('record-create-providers');
      await ui.until(
        () => ui.key('record-providers-$id').evaluate().isNotEmpty,
        'create acknowledgement',
      );
      final created = await current();
      expect(created.catalog.provider.displayName, 'Third account');
      final contents = file.readAsStringSync();
      expect(contents, contains('recordId = "$id"'));
      expect(contents, contains('display-name = "Third account"'));
      expect(contents, contains('${fixture.origin}/third/responses'));
      expect(fixture.providerFile('$id.toml').existsSync(), isFalse);
      await fixture.expectFailure('not_configured', recordId: id);
      expect(fixture.requests, isEmpty);
      expect(fixture.storage.calls, isEmpty);

      await ui.expand(id);
      await ui.credential('check', id);
      await ui.store('set', id, 'test-third-key');
      final attached = await current();
      created.expectReplacement(attached);
      final reference = fixture.storage.values.keys.singleWhere(
        (key) => file.readAsStringSync().contains(key.value),
      );
      expect(
        (jsonDecode(fixture.storage.values[reference]!) as Map)['record'],
        id,
      );
      await fixture.expectRoutes(
        attached,
        'third',
        'test-third-key',
        reference,
      );

      await ui.update(
        id,
        'Renamed third',
        '${fixture.origin}/updated/responses',
      );
      final edited = await current();
      attached.expectReplacement(edited);
      await attached.expectRetired(fixture);
      final updatedContents = file.readAsStringSync();
      expect(updatedContents, contains('recordId = "$id"'));
      expect(updatedContents, contains('display-name = "Renamed third"'));
      expect(updatedContents, contains(reference.value));
      expect(fixture.providerFile('renamed-third.toml').existsSync(), isFalse);
      expect(edited.inference.provider.displayName, 'Renamed third');
      expect(edited.catalog.provider.displayName, 'Renamed third');
      await fixture.expectRoutes(
        edited,
        'updated',
        'test-third-key',
        reference,
      );

      // Ordinary record values and the exact protected reference are unchanged.
      final bytes = file.readAsBytesSync();
      await ui.credential('check', id);
      await ui.store('replace', id, 'test-replacement-key');
      final replaced = await current();
      edited.expectReplacement(replaced);
      expect(file.readAsBytesSync(), bytes);
      await edited.expectRetired(fixture);
      await fixture.expectRoutes(
        replaced,
        'updated',
        'test-replacement-key',
        reference,
      );

      await ui.credential('forget', id);
      await ui.credential('forget-confirm', id);
      final forgotten = await current();
      replaced.expectReplacement(forgotten);
      await replaced.expectRetired(fixture);
      final reads = fixture.storage.readReferences.length;
      final requests = fixture.requests.length;
      expect(fixture.storage.values.containsKey(reference), isFalse);
      await fixture.expectFailure('not_configured', recordId: id);
      await expectLater(
        forgotten.catalogClient.listModels(),
        throwsA(
          isA<ModelCatalogFailure>().having(
            (e) => e.code,
            'code',
            'unavailable',
          ),
        ),
      );
      expect(fixture.storage.readReferences, hasLength(reads));
      expect(fixture.requests, hasLength(requests));

      await ui.press('record-delete-providers-$id');
      await ui.press('record-delete-confirm-providers-$id');
      await ui.until(
        () => ui.key('record-providers-$id').evaluate().isEmpty,
        'delete acknowledgement',
      );
      await ui.status(id, 'Applied');
      expect(find.text('Deleted record: OpenAI API'), findsOneWidget);
      expect(file.existsSync(), isFalse);
      await forgotten.expectRetired(fixture);
      for (final (capability, providerId) in [
        (modelProviderCapability, '$_recordType.$id'),
        (modelCatalogCapability, '$_catalogProviderId.$id'),
      ]) {
        expect(
          () => fixture.registry.resolve(
            capability,
            providerId: ProviderId(providerId),
          ),
          throwsA(isA<ProviderUnavailable>()),
        );
      }
      personal.expectSame(fixture.capture('personal'));
      work.expectSame(fixture.capture('work'));
      await fixture.expectRoutes(
        personal,
        'personal',
        'test-personal-key',
        fixture.reference('personal'),
      );
      expect(fixture.connection, same(connection));
      await ui.section('Preferences');
      await ui.section('Providers');
      expect(find.text('Deleted record: OpenAI API'), findsOneWidget);
      await ui.status(id, 'Applied');
    },
  );

  applicationScenario(
    'Global Settings retries a failed AOT capture without re-saving the record or its draft',
    (ui, fixture, gates) async {
      const id = 'work-openai';
      final connection = fixture.connection;
      final old = fixture.capture('work');
      final personal = fixture.capture('personal');
      final file = fixture.workFile;
      final endpoint = '${fixture.origin}/retry/responses';
      await ui.expand(id);
      await ui.update(id, 'Saved work', endpoint);
      final gate = gates.single;
      await gate.entered.future.timeout(const Duration(seconds: 10));
      final saved = file.readAsBytesSync();
      expect(utf8.decode(saved), contains(endpoint));
      // The write was acknowledged. Only now make the next real enumeration
      // ambiguous; neither the record nor its protected association changes.
      final alias = File('${fixture.roots.configurationRoot}/providers.')
        ..createSync(exclusive: true);
      try {
        gate.release();
        await ui.status(id, 'Not applied');
      } finally {
        alias.deleteSync();
      }
      expect(find.text('Saved configuration'), findsOneWidget);
      old.expectSame(fixture.capture('work'));
      personal.expectSame(fixture.capture('personal'));
      expect(file.readAsBytesSync(), saved);
      await ui.press('record-edit-providers-$id');
      final field = 'record-input-providers-$id-display-name';
      final editor = ui.tester.widget<TextField>(ui.key(field)).controller!;
      expect(editor.text, 'Saved work');
      await ui._enter(field, 'Unsaved work');
      final slot = find.descendant(
        of: ui.key('record-providers-$id'),
        matching: find.byType(RecordCredentialControls),
      );
      final savedHandle = ui.tester
          .widget<RecordCredentialControls>(slot)
          .record;
      await ui.press('record-apply-retry-providers-$_recordType-$id');
      await ui.status(id, 'Applied');
      expect(file.readAsBytesSync(), saved);
      expect(
        ui.tester.widget<TextField>(ui.key(field)).controller,
        same(editor),
      );
      expect(editor.text, 'Unsaved work');
      expect(fixture.storage.calls, isEmpty);
      expect(fixture.requests, isEmpty);
      expect(fixture.connection, same(connection));
      final fresh = fixture.capture('work');
      old.expectReplacement(fresh);
      await old.expectRetired(fixture);
      expect(fresh.inference.provider.displayName, 'Saved work');
      expect(fresh.catalog.provider.displayName, 'Saved work');
      _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
      personal.expectSame(fixture.capture('personal'));
      // Even a repeated no-op update would retire the UI's worker revision.
      // Checking this slot uses that same acknowledged revision, without Reload.
      expect(
        ui.tester.widget<RecordCredentialControls>(slot).record,
        same(savedHandle),
      );
      await ui.credential('check', id);
      expect(find.text('Credential stored locally'), findsOneWidget);
      await fixture.expectRoutes(
        fresh,
        'retry',
        'test-work-key',
        fixture.reference('work'),
      );
    },
    heldCaptures: 1,
    holdBeforeScan: true,
  );

  applicationScenario(
    'Global Settings orders overlapping saves and applies the '
    'latest endpoint even after the Settings route is gone',
    (ui, fixture, gates) async {
      const id = 'work-openai';
      final original = fixture.capture('work');
      final personal = fixture.capture('personal');
      await ui.expand(id);
      await ui.update(id, 'First edit', '${fixture.origin}/first/responses');
      await gates[0].entered.future.timeout(const Duration(seconds: 10));
      await ui.status(id, 'Applying...');
      await ui.update(id, 'Latest edit', '${fixture.origin}/latest/responses');
      expect(
        fixture.workFile.readAsStringSync(),
        contains('/latest/responses'),
      );
      original.expectSame(fixture.capture('work'));
      gates[0].release();
      // The backend serialized the calls: the first response has now returned,
      // but it must not mark the second acknowledged edit Applied.
      await gates[1].entered.future.timeout(const Duration(seconds: 10));
      await ui.status(id, 'Applying...');
      final first = fixture.capture('work');
      original.expectReplacement(first);
      expect(first.inference.provider.displayName, 'First edit');
      await ui.dismiss();
      final published = fixture.registry.changes.firstWhere(
        (_) => fixture.registry
            .providersFor(modelProviderCapability)
            .any((p) => p.displayName == 'Latest edit'),
      );
      gates[1].release();
      await published.timeout(const Duration(seconds: 10));
      expect(find.byType(GlobalSettingsDialog), findsNothing);
      final latest = fixture.capture('work');
      first.expectReplacement(latest);
      await first.expectRetired(fixture);
      personal.expectSame(fixture.capture('personal'));
      await fixture.expectRoutes(
        latest,
        'latest',
        'test-work-key',
        fixture.reference('work'),
      );
      await ui.open();
      await ui.status(id, 'Applied');
    },
    heldCaptures: 2,
  );

  applicationScenario(
    'accepted application exit fences a Global Settings apply with a real '
    'worker capture still pending on its AOT connection',
    (ui, fixture, gates) async {
      const id = 'work-openai';
      final application = ui.tester
          .widget<GlobalSettingsDialog>(find.byType(GlobalSettingsDialog))
          .recordApplication!()!;
      final key = (
        collection: RecordCollectionId('providers'),
        type: RecordTypeId(_recordType),
        id: ConfigurationRecordId(id),
      );
      await ui.expand(id);
      await ui.update(
        id,
        'Saved before exit',
        '${fixture.origin}/exit/responses',
      );
      final gate = gates.single;
      await gate.entered.future.timeout(const Duration(seconds: 10));
      await ui.status(id, 'Applying...');
      final exiting = ui.tester.binding.handleRequestAppExit();
      await ui.until(
        () => application.outcome(key)?.status == RecordApplyStatus.unavailable,
        'exit fencing pending application',
      );
      gate.release();
      expect(await exiting, AppExitResponse.exit);
      expect(fixture.bootstrap.state, ApplicationPluginState.closed);
      expect(gate.returned.isCompleted, isTrue);
      expect(application.outcome(key)?.status, RecordApplyStatus.unavailable);
      expect(fixture.workFile.readAsStringSync(), contains('/exit/responses'));
      expect(fixture.requests, isEmpty);
    },
    heldCaptures: 1,
  );

  for (final chatGpt in [false, true]) {
    test('real configured Work and Personal use only their own HTTP authority '
        '(ChatGPT: $chatGpt)', () async {
      final fixture = await prepareProviders(chatGpt: chatGpt);
      await fixture.start();
      final connection = fixture.connection;
      final exposures = connection.capabilityExposures;
      expect(exposures, hasLength(chatGpt ? 5 : 4));
      expect(
        exposures
            .where((entry) => entry.providerId.startsWith('$_recordType.'))
            .map((entry) => entry.providerId),
        ['$_recordType.personal-openai', '$_recordType.work-openai'],
      );
      final contexts = _configuredContexts(connection);
      expect(exposures.map((entry) => entry.configurationContext).toSet(), {
        ...contexts.values,
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

  test('independent AOT catalog consumer keeps exact accounts and fresh models '
      'with explicit and omitted inference effort', () async {
    final fixture = await prepareProviders(chatGpt: true, consumeCatalog: true);
    await fixture.start();
    final connection = fixture.connection;
    expect(connection.capabilityExposures, hasLength(5));
    _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
    expect(await fixture.catalogCall('discover', _catalogQuery), {
      'ok': true,
      'providers': [_catalogProvider('personal'), _catalogProvider('work')],
    });
    for (final id in [_recordType, _chatGpt, '$_catalogProviderId.absent']) {
      expect(
        await fixture.catalogCall('resolve', {
          ..._catalogQuery,
          'providerId': id,
        }),
        {'ok': true, 'provider': null},
      );
    }
    for (final id in ['work', 'personal']) {
      await fixture.selectCatalog(id);
    }
    expect(fixture.storage.calls, isEmpty);
    expect(fixture.requests, isEmpty);

    _expectCompleted(
      await fixture.invoke('work', model: 'gpt-5.4').toList(),
      '/work/responses',
    );
    final inferenceBefore = fixture.requests.single;
    expect(inferenceBefore['authorization'], 'Bearer test-work-key');
    expect((inferenceBefore['body']! as Map)['model'], 'gpt-5.4');
    expect((inferenceBefore['body']! as Map)['reasoning'], {'summary': 'auto'});
    expect(await fixture.listModels('work'), _catalogSnapshot(['work-model']));
    expect(fixture.storage.readReferences, [
      fixture.reference('work'),
      fixture.reference('work'),
    ]);
    expect(
      await fixture.listModels('personal'),
      _catalogSnapshot(['personal-model']),
    );
    fixture.catalogModels['/work/models'] = ['Work/Exact-2026', ' work-alias '];
    expect(
      await fixture.listModels('work'),
      _catalogSnapshot(['Work/Exact-2026', ' work-alias ']),
    );
    fixture.catalogModels['/work/models'] = [];
    expect(await fixture.listModels('work'), _catalogSnapshot([]));
    expect(
      await fixture.listModels('personal'),
      _catalogSnapshot(['personal-model']),
    );
    expect(fixture.storage.readReferences, [
      for (final id in ['work', 'work', 'personal', 'work', 'work', 'personal'])
        fixture.reference(id),
    ]);
    final catalogRequests = fixture.requests.skip(1).toList();
    expect(catalogRequests, hasLength(5));
    for (final (index, id) in [
      'work',
      'personal',
      'work',
      'work',
      'personal',
    ].indexed) {
      expect(catalogRequests[index], {
        'method': 'GET',
        'authority': Uri.parse(
          fixture.records[id]!.values['endpoint']! as String,
        ).authority,
        'path': '/$id/models',
        'query': '',
        'authorization': 'Bearer test-$id-key',
        'account': null,
        'accept': 'application/json',
        'body': '',
      });
    }
    expect(
      catalogRequests.first['authority'],
      isNot(catalogRequests[1]['authority']),
    );
    _expectCompleted(
      await fixture
          .invoke(
            'work',
            model: 'gpt-5.4',
            reasoningEffort: ModelReasoningEffort.high,
          )
          .toList(),
      '/work/responses',
    );
    expect(fixture.requests.last, {
      ...inferenceBefore,
      'body': {
        ...inferenceBefore['body']! as Map,
        'reasoning': {'summary': 'auto', 'effort': 'high'},
      },
    });
    expect(fixture.storage.readReferences.last, fixture.reference('work'));
    _expectCompleted(
      await fixture.invoke('work', model: 'gpt-5.4').toList(),
      '/work/responses',
    );
    expect(fixture.requests.last, inferenceBefore);
    _expectCompleted(
      await fixture
          .invoke('personal', reasoningEffort: ModelReasoningEffort.none)
          .toList(),
      '/personal/responses',
    );
    expect(fixture.requests.last['authorization'], 'Bearer test-personal-key');
    expect((fixture.requests.last['body']! as Map)['model'], 'same-model');
    expect((fixture.requests.last['body']! as Map)['reasoning'], {
      'effort': 'none',
    });
    expect(fixture.storage.readReferences.last, fixture.reference('personal'));
    expect(
      await fixture.listModels('personal'),
      _catalogSnapshot(['personal-model']),
    );
    _expectCompleted(
      await fixture.invokeChatGpt().toList(),
      '/chatgpt/responses',
    );
    expect(fixture.requests.last['authorization'], 'Bearer test-chatgpt-token');
    expect(fixture.requests.last['account'], 'test-chatgpt-account');
    expect(fixture.connection, same(connection));
  });

  test(
    'missing, invalid, unavailable and uncertain credentials never fall back',
    () async {
      final fixture = await prepareProviders(
        chatGpt: true,
        consumeCatalog: true,
      );
      final workReference = fixture.reference('work');
      final original = fixture.storage.values.remove(workReference)!;
      // A missing local key at fresh startup still advertises an independent route.
      await fixture.start();
      expect(fixture.connection.capabilityExposures, hasLength(5));
      await fixture.selectCatalog('work');
      expect(fixture.storage.calls, isEmpty);
      Future<void> expectCredentialFailure(String code) async {
        final requests = fixture.requests.length;
        await fixture.expectFailure(code);
        _expectCatalogFailure(await fixture.listModels('work'), 'unavailable');
        expect(fixture.requests, hasLength(requests));
      }

      await expectCredentialFailure('missing_locally');
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
      await expectCredentialFailure('invalid_binding');
      fixture.storage.values[workReference] =
          fixture.storage.values[fixture.reference('personal')]!;
      await expectCredentialFailure('invalid_binding');
      fixture.storage.values[workReference] = original;
      fixture.storage.failureReference = workReference;
      fixture.storage.failure = const CredentialFailure(
        CredentialFailureKind.unavailable,
      );
      await expectCredentialFailure('storage_unavailable');
      fixture.storage.failure = StateError('native diagnostic test-work-key');
      await expectCredentialFailure('access_failed');
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
      await expectCredentialFailure('reconciliation_required');
      expect(fixture.storage.readReferences, hasLength(reads));
      expect(
        fixture.requests.where((entry) => entry['path'] == '/work/responses'),
        isEmpty,
      );
      expect(
        fixture.requests.where((entry) => entry['path'] == '/work/models'),
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

  test('catalog rejects an invalid delivered API key before HTTP', () async {
    final fixture = await prepareProviders(chatGpt: true, consumeCatalog: true);
    fixture.records['work'] = (await fixture.associations.replace(
      fixture.records['work']!,
      RecordCredentialSlotId('api-key'),
      CredentialSecret('test-work-key\ninvalid-header'),
    )).record;
    fixture.storage.calls.clear();
    fixture.storage.readReferences.clear();
    await fixture.start();
    await fixture.selectCatalog('work');
    expect(fixture.storage.calls, isEmpty);
    _expectCatalogFailure(await fixture.listModels('work'), 'unavailable');
    expect(fixture.requests, isEmpty);
    expect(fixture.storage.readReferences, [fixture.reference('work')]);
    await fixture.selectCatalog('personal');
    expect(
      await fixture.listModels('personal'),
      _catalogSnapshot(['personal-model']),
    );
    expect(fixture.requests.single['path'], '/personal/models');
  });

  for (final suffix in ['custom', 'responses?api-version=private']) {
    test('catalog rejects unsupported $suffix before credentials while '
        'inference keeps its endpoint', () async {
      final fixture = await prepareProviders(consumeCatalog: true);
      fixture.records['work'] = await fixture.settings
          .updateRecord(fixture.records['work']!, {
            ...fixture.records['work']!.values,
            'endpoint': '${fixture.origin}/work/$suffix',
          });
      await fixture.start();
      await fixture.selectCatalog('work');
      _expectCatalogFailure(
        await fixture.listModels('work'),
        'unsupported_discovery',
      );
      expect(fixture.storage.calls, isEmpty);
      expect(fixture.requests, isEmpty);
      _expectCompleted(
        await fixture.invoke('work').toList(),
        '/work/${suffix.split('?').first}',
      );
      expect(fixture.storage.readReferences, [fixture.reference('work')]);
      expect(
        fixture.requests.single['query'],
        suffix.contains('?') ? 'api-version=private' : '',
      );
      expect(fixture.requests.single['authorization'], 'Bearer test-work-key');
    });
  }

  test(
    'real catalog HTTP failures cross the AOT facade safely without fallback',
    () async {
      final fixture = await prepareProviders(
        chatGpt: true,
        consumeCatalog: true,
      );
      await fixture.start();
      await fixture.selectCatalog('work');
      fixture.catalogStatus = HttpStatus.unauthorized;
      fixture.catalogBody = {
        'error': 'test-work-key ${fixture.origin}/work/models cred1_private',
      };
      final rejected = await fixture.listModels('work');
      _expectCatalogFailure(rejected, 'authentication');
      expect(jsonEncode(rejected), isNot(contains(fixture.origin)));
      fixture.catalogStatus = HttpStatus.ok;
      fixture.catalogBody = {
        'object': 'list',
        'data': [
          {'object': 'model', 'id': 123, 'owned_by': 'test-work-key'},
        ],
      };
      _expectCatalogFailure(
        await fixture.listModels('work'),
        'malformed_response',
      );
      fixture.catalogBody = null;
      expect(
        await fixture.listModels('work'),
        _catalogSnapshot(['work-model']),
      );
      expect(fixture.requests.map((request) => request['path']), [
        '/work/models',
        '/work/models',
        '/work/models',
      ]);
      expect(
        fixture.storage.readReferences,
        List.filled(3, fixture.reference('work')),
      );
      _expectCompleted(
        await fixture.invoke('work').toList(),
        '/work/responses',
      );
    },
  );

  test('catalog retirement fences a pending protected credential result before '
      'HTTP', () async {
    final fixture = await prepareProviders(consumeCatalog: true);
    await fixture.start();
    await fixture.selectCatalog('work');
    final gate = fixture.storage.gate = _ReadGate();
    addTearDown(gate.release);
    final pending = fixture.listModels('work');
    await gate.entered.future;
    expect(fixture.requests, isEmpty);
    fixture.connection.revokeInfrastructureContext();
    _expectCatalogFailure(await pending, 'unavailable');
    await fixture.connection.close();
    gate.release();
    await gate.returned.future;
    // Drain the uncancelable read after retirement, not a timer-based guess.
    await fixture.backendAssociations.single.close();
    expect(fixture.requests, isEmpty);
    expect((await fixture.listModels('work'))['ok'], isFalse);
    expect(fixture.storage.readReferences, [fixture.reference('work')]);
    expect(fixture.consumer.isClosed, isFalse);
  });

  test(
    'catalog retirement closes an admitted HTTP connection and retained access',
    () async {
      final fixture = await prepareProviders(consumeCatalog: true);
      await fixture.start();
      await fixture.selectCatalog('work');
      final accepted = fixture.pendingCatalogSocket = Completer<Socket>();
      final pending = fixture.listModels('work');
      final socket = await accepted.future;
      addTearDown(socket.destroy);
      final disconnected = Completer<void>();
      final subscription = socket.listen(
        (_) {},
        onDone: disconnected.complete,
        onError: disconnected.completeError,
      );
      addTearDown(subscription.cancel);
      await fixture.connection.close();
      final result = await pending;
      expect(result['ok'], isFalse);
      _expectProviderRedacted(result);
      await disconnected.future.timeout(const Duration(seconds: 10));
      expect((await fixture.listModels('work'))['ok'], isFalse);
      expect(fixture.requests.single['path'], '/work/models');
      expect(fixture.storage.readReferences, [fixture.reference('work')]);
      expect(fixture.consumer.isClosed, isFalse);
    },
  );

  for (final mutation in ['replace', 'endpoint', 'forget', 'recreate']) {
    test(
      '$mutation stays stale without explicit refresh until a fresh generation',
      () async {
        final fixture = await prepareProviders();
        await fixture.start();
        final oldConnection = fixture.connection;
        final oldClient = fixture.client('work-openai');
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
          'OpenAI Work',
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
    'explicit refresh adds a third record without touching live siblings',
    () async {
      final fixture = await prepareProviders(
        chatGpt: true,
        consumeCatalog: true,
      );
      await fixture.start();
      final work = fixture.capture('work');
      final personal = fixture.capture('personal');
      final chatGpt = fixture.registry.resolve(
        modelProviderCapability,
        providerId: ProviderId(_chatGpt),
      );
      var third = await fixture.settings.createRecord(
        RecordTypeId(_recordType),
        ConfigurationRecordId('third-openai'),
        {
          'display-name': 'Third OpenAI',
          'endpoint': '${fixture.origin}/third/responses',
        },
      );
      third = (await fixture.associations.attach(
        third,
        RecordCredentialSlotId('api-key'),
        CredentialSecret('test-third-key'),
      )).record;
      fixture.records['third'] = third;
      fixture.catalogModels['/third/models'] = ['third-model'];
      final thirdReference = fixture.storage.values.entries
          .singleWhere(
            (entry) =>
                (jsonDecode(entry.value) as Map)['record'] == 'third-openai',
          )
          .key;
      expect(
        () => fixture.client('third-openai'),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(await fixture.catalogCall('discover', _catalogQuery), {
        'ok': true,
        'providers': [_catalogProvider('personal'), _catalogProvider('work')],
      });
      fixture.storage.calls.clear();
      fixture.storage.readReferences.clear();
      expect(
        await fixture.refresh('third-openai'),
        _refreshResult('applied', 'added', cleanupPending: false),
      );
      expect(
        fixture.registry.providersFor(modelProviderCapability),
        hasLength(4),
      );
      expect(
        fixture.registry.providersFor(modelCatalogCapability),
        hasLength(3),
      );
      _expectCatalogAssociations(
        fixture.bootstrap,
        fixture.registry,
        recordIds: ['personal-openai', 'third-openai', 'work-openai'],
      );
      expect(await fixture.catalogCall('discover', _catalogQuery), {
        'ok': true,
        'providers': [
          _catalogProvider('personal'),
          _catalogProvider('third', displayName: 'Third OpenAI'),
          _catalogProvider('work'),
        ],
      });
      work.expectSame(fixture.capture('work'));
      personal.expectSame(fixture.capture('personal'));
      expect(
        chatGpt.isSameRegistration(
          fixture.registry.resolve(
            modelProviderCapability,
            providerId: ProviderId(_chatGpt),
          ),
        ),
        isTrue,
      );
      await fixture.selectCatalog('third');
      expect(fixture.storage.calls, isEmpty);
      expect(fixture.requests, isEmpty);
      _expectCompleted(
        await fixture.invoke('third').toList(),
        '/third/responses',
      );
      expect(
        await fixture.listModels('third'),
        _catalogSnapshot(['third-model']),
      );
      expect(fixture.storage.readReferences, [thirdReference, thirdReference]);
      expect(fixture.requests.map((entry) => entry['authorization']), [
        'Bearer test-third-key',
        'Bearer test-third-key',
      ]);
    },
  );

  test('explicit refresh replaces endpoint and display with exact fresh routes '
      'while Personal and ChatGPT retain their bindings', () async {
    final fixture = await prepareProviders(chatGpt: true, consumeCatalog: true);
    await fixture.start();
    final old = fixture.capture('work');
    final personal = fixture.capture('personal');
    final chatGpt = fixture.registry.resolve(
      modelProviderCapability,
      providerId: ProviderId(_chatGpt),
    );
    final chatGptClient = ModelProviderServiceClient(chatGpt.streamChannel);
    await fixture.selectCatalog('work', slot: 'old-work');
    await fixture.selectCatalog('personal');
    fixture.records['work'] = await fixture.settings
        .updateRecord(fixture.records['work']!, {
          ...fixture.records['work']!.values,
          'display-name': 'Renamed Work',
          'endpoint': '${fixture.origin}/updated/responses',
        });
    fixture.catalogModels['/updated/models'] = ['updated-model'];
    await fixture.expectFailure('stale_configuration');
    _expectCatalogFailure(await fixture.listModels('old-work'), 'unavailable');
    expect(fixture.requests, isEmpty);
    expect(fixture.storage.calls, isEmpty);
    expect(old.inference.provider.displayName, 'OpenAI Work');
    expect(await fixture.refresh(), _refreshResult('applied', 'replaced'));
    final fresh = fixture.capture('work');
    old.expectReplacement(fresh);
    expect(fresh.inference.provider.displayName, 'Renamed Work');
    expect(fresh.catalog.provider.displayName, 'Renamed Work');
    await old.expectRetired(fixture);
    final staleCatalog = await fixture.listModels('old-work');
    expect(staleCatalog['ok'], isFalse);
    _expectProviderRedacted(staleCatalog);
    _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
    expect(await fixture.catalogCall('discover', _catalogQuery), {
      'ok': true,
      'providers': [
        _catalogProvider('personal'),
        _catalogProvider('work', displayName: 'Renamed Work'),
      ],
    });
    await fixture.selectCatalog('work');
    expect(fixture.storage.calls, isEmpty);
    expect(fixture.requests, isEmpty);
    _expectCompleted(
      await fixture.invoke('work').toList(),
      '/updated/responses',
    );
    expect(
      await fixture.listModels('work'),
      _catalogSnapshot(['updated-model']),
    );
    expect(fixture.requests.map((entry) => entry['path']), [
      '/updated/responses',
      '/updated/models',
    ]);
    expect(fixture.requests.map((entry) => entry['authorization']).toSet(), {
      'Bearer test-work-key',
    });
    expect(
      fixture.storage.readReferences,
      List.filled(2, fixture.reference('work')),
    );
    personal.expectSame(fixture.capture('personal'));
    _expectCompleted(
      await personal.inferenceClient
          .invoke(_providerRequest('same-model'))
          .toList(),
      '/personal/responses',
    );
    expect(
      await fixture.listModels('personal'),
      _catalogSnapshot(['personal-model']),
    );
    expect(fixture.requests.last['authorization'], 'Bearer test-personal-key');
    expect(
      chatGpt.isSameRegistration(
        fixture.registry.resolve(
          modelProviderCapability,
          providerId: ProviderId(_chatGpt),
        ),
      ),
      isTrue,
    );
    _expectCompleted(
      await chatGptClient.invoke(_providerRequest('same-model')).toList(),
      '/chatgpt/responses',
    );
    expect(fixture.requests.last['authorization'], 'Bearer test-chatgpt-token');
    expect(fixture.requests.last['account'], 'test-chatgpt-account');
    expect(fixture.storage.readReferences, [
      fixture.reference('work'),
      fixture.reference('work'),
      fixture.reference('personal'),
      fixture.reference('personal'),
    ]);
  });

  test('external rename requires explicit refresh but preserves the configured '
      'provider IDs and protected credential association', () async {
    final fixture = await prepareProviders();
    await fixture.start();
    final old = fixture.capture('work');
    final personal = fixture.capture('personal');
    final reference = fixture.reference('work');
    final protected = fixture.storage.values[reference]!;
    await fixture.expectRoutes(old, 'work', 'test-work-key', reference);

    final file = fixture.workFile;
    final bytes = await file.readAsBytes();
    expect(utf8.decode(bytes), contains('recordId = "work-openai"'));
    final renamed = await file.rename('${file.parent.path}/engineering.toml');

    old.expectSame(fixture.capture('work'));
    await fixture.expectFailure('stale_configuration');
    expect(fixture.storage.calls, ['read', 'read']);
    expect(fixture.requests, hasLength(2));

    expect(
      await fixture.refresh('work-openai'),
      _refreshResult('applied', 'replaced'),
    );
    final fresh = fixture.capture('work');
    old.expectReplacement(fresh);
    await old.expectRetired(fixture);
    personal.expectSame(fixture.capture('personal'));
    _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
    await fixture.expectRoutes(fresh, 'work', 'test-work-key', reference);
    expect(fixture.storage.values[reference] == protected, isTrue);
    expect(await renamed.readAsBytes(), bytes);
    expect(await file.exists(), isFalse);
  });

  test('explicit same-reference Replace refreshes a live credential scope even '
      'when nonsecret record bytes are unchanged', () async {
    final fixture = await prepareProviders(consumeCatalog: true);
    await fixture.start();
    // First refresh obtains a live scope rather than the startup capture.
    expect(await fixture.refresh(), _refreshResult('applied', 'replaced'));
    final old = fixture.capture('work');
    await fixture.selectCatalog('work', slot: 'old-work');
    _expectCompleted(await fixture.invoke('work').toList(), '/work/responses');
    final reference = fixture.reference('work');
    final bytes = await fixture.workFile.readAsBytes();
    final values = fixture.records['work']!.values;
    final protected = fixture.storage.values[reference];
    fixture.records['work'] = (await fixture.associations.replace(
      fixture.records['work']!,
      RecordCredentialSlotId('api-key'),
      CredentialSecret('test-replacement-key'),
    )).record;
    expect(await fixture.workFile.readAsBytes(), bytes);
    expect(fixture.records['work']!.values, values);
    expect(fixture.storage.values.keys, contains(reference));
    expect(fixture.storage.values[reference], isNot(protected));
    fixture.storage.calls.clear();
    fixture.storage.readReferences.clear();
    await fixture.expectFailure('stale_configuration');
    _expectCatalogFailure(await fixture.listModels('old-work'), 'unavailable');
    expect(fixture.storage.calls, isEmpty);
    expect(fixture.requests, hasLength(1));
    expect(await fixture.refresh(), _refreshResult('applied', 'replaced'));
    old.expectReplacement(fixture.capture('work'));
    await old.expectRetired(fixture);
    expect((await fixture.listModels('old-work'))['ok'], isFalse);
    _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
    await fixture.selectCatalog('work');
    _expectCompleted(await fixture.invoke('work').toList(), '/work/responses');
    expect(await fixture.listModels('work'), _catalogSnapshot(['work-model']));
    expect(fixture.storage.readReferences, [reference, reference]);
    expect(fixture.requests.skip(1).map((entry) => entry['authorization']), [
      'Bearer test-replacement-key',
      'Bearer test-replacement-key',
    ]);
  });

  test(
    'explicit Forget refresh keeps a configured route but denies both services '
    'without vault reads or HTTP',
    () async {
      final fixture = await prepareProviders(consumeCatalog: true);
      await fixture.start();
      final old = fixture.capture('work');
      fixture.records['work'] = (await fixture.associations.forget(
        fixture.records['work']!,
        RecordCredentialSlotId('api-key'),
      )).record;
      fixture.storage.calls.clear();
      fixture.storage.readReferences.clear();
      await fixture.expectFailure('stale_configuration');
      expect(await fixture.refresh(), _refreshResult('applied', 'replaced'));
      old.expectReplacement(fixture.capture('work'));
      await old.expectRetired(fixture);
      _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
      await fixture.selectCatalog('work');
      await fixture.expectFailure('not_configured');
      _expectCatalogFailure(await fixture.listModels('work'), 'unavailable');
      expect(fixture.storage.calls, isEmpty);
      expect(fixture.storage.readReferences, isEmpty);
      expect(fixture.requests, isEmpty);
      _expectCompleted(
        await fixture.invoke('personal').toList(),
        '/personal/responses',
      );
      expect(
        fixture.requests.single['authorization'],
        'Bearer test-personal-key',
      );
    },
  );

  test('explicit deletion refresh removes discovery without retargeting held '
      'bindings and repeated absence is a no-op', () async {
    final fixture = await prepareProviders(consumeCatalog: true);
    await fixture.start();
    final old = fixture.capture('work');
    final personal = fixture.capture('personal');
    await fixture.selectCatalog('work');
    fixture.records['work'] = (await fixture.associations.forget(
      fixture.records['work']!,
      RecordCredentialSlotId('api-key'),
    )).record;
    await fixture.settings.deleteRecord(fixture.records['work']!);
    fixture.storage.calls.clear();
    fixture.storage.readReferences.clear();
    old.expectSame(fixture.capture('work'));
    expect(await fixture.refresh(), _refreshResult('applied', 'retired'));
    await old.expectRetired(fixture);
    expect(
      () => fixture.client('work-openai'),
      throwsA(isA<ProviderUnavailable>()),
    );
    expect((await fixture.listModels('work'))['ok'], isFalse);
    expect(
      await fixture.catalogCall('resolve', {
        ..._catalogQuery,
        'providerId': '$_catalogProviderId.work-openai',
      }),
      {'ok': true, 'provider': null},
    );
    expect(await fixture.catalogCall('discover', _catalogQuery), {
      'ok': true,
      'providers': [_catalogProvider('personal')],
    });
    expect(
      fixture.registry
          .providersFor(modelProviderCapability)
          .map((entry) => entry.id.value),
      ['$_recordType.personal-openai'],
    );
    expect(
      await fixture.refresh(),
      _refreshResult('noChange', 'already_absent'),
    );
    personal.expectSame(fixture.capture('personal'));
    _expectCatalogAssociations(
      fixture.bootstrap,
      fixture.registry,
      recordIds: ['personal-openai'],
    );
    expect(fixture.storage.calls, isEmpty);
    expect(fixture.requests, isEmpty);
  });

  test(
    'partial malformed collection cannot be mistaken for target deletion',
    () async {
      final fixture = await prepareProviders(consumeCatalog: true);
      await fixture.start();
      final old = fixture.capture('work');
      final personal = fixture.capture('personal');
      await fixture.selectCatalog('work');
      final malformed = fixture.providerFile('malformed.toml');
      await malformed.writeAsString(
        'invalid = [ # test-work-key ${fixture.origin}',
      );
      expect(
        await fixture.refresh('missing-openai'),
        _refreshResult('failed', 'incomplete_observation'),
      );
      old.expectSame(fixture.capture('work'));
      // Even when the target really disappears, a partial scan is not deletion evidence.
      fixture.records['work'] = (await fixture.associations.forget(
        fixture.records['work']!,
        RecordCredentialSlotId('api-key'),
      )).record;
      await fixture.settings.deleteRecord(fixture.records['work']!);
      fixture.storage.calls.clear();
      fixture.storage.readReferences.clear();
      expect(
        await fixture.refresh(),
        _refreshResult('failed', 'incomplete_observation'),
      );
      old.expectSame(fixture.capture('work'));
      personal.expectSame(fixture.capture('personal'));
      _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
      expect(await fixture.catalogCall('discover', _catalogQuery), {
        'ok': true,
        'providers': [_catalogProvider('personal'), _catalogProvider('work')],
      });
      await fixture.expectFailure('stale_configuration');
      _expectCatalogFailure(await fixture.listModels('work'), 'unavailable');
      expect(fixture.requests, isEmpty);
      expect(fixture.storage.calls, isEmpty);
      await malformed.delete();
      expect(await fixture.refresh(), _refreshResult('applied', 'retired'));
      await old.expectRetired(fixture);
    },
  );

  test(
    'admitted inference and catalog HTTP finish on old routes across refresh '
    'while fresh requests use the replacement',
    () async {
      final fixture = await prepareProviders(consumeCatalog: true);
      await fixture.start();
      // Hold work on a live captured scope, not only the startup authority.
      expect(await fixture.refresh(), _refreshResult('applied', 'replaced'));
      final old = fixture.capture('work');
      await fixture.selectCatalog('work', slot: 'old-work');
      final inferenceGate = _HttpGate();
      final catalogGate = _HttpGate();
      addTearDown(inferenceGate.release);
      addTearDown(catalogGate.release);
      fixture.responseGates['/work/responses'] = inferenceGate;
      fixture.responseGates['/work/models'] = catalogGate;
      var inferenceSettled = false;
      var catalogSettled = false;
      final inference = old.inferenceClient
          .invoke(_providerRequest('old-model'))
          .toList()
          .then((events) {
            inferenceSettled = true;
            return events;
          });
      await inferenceGate.entered.future;
      final catalog = fixture.listModels('old-work').then((result) {
        catalogSettled = true;
        return result;
      });
      await catalogGate.entered.future;
      expect(fixture.requests.map((entry) => entry['authorization']), [
        'Bearer test-work-key',
        'Bearer test-work-key',
      ]);
      fixture.records['work'] = (await fixture.associations.replace(
        fixture.records['work']!,
        RecordCredentialSlotId('api-key'),
        CredentialSecret('test-replacement-key'),
      )).record;
      fixture.records['work'] = await fixture.settings
          .updateRecord(fixture.records['work']!, {
            ...fixture.records['work']!.values,
            'endpoint': '${fixture.origin}/fresh/responses',
          });
      fixture.catalogModels['/fresh/models'] = ['fresh-model'];
      expect(
        await fixture.refresh().timeout(const Duration(seconds: 10)),
        _refreshResult('applied', 'replaced', cleanupPending: true),
      );
      old.expectReplacement(fixture.capture('work'));
      await old.expectRetired(fixture);
      _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
      await fixture.selectCatalog('work', slot: 'fresh-work');
      _expectCompleted(
        await fixture.invoke('work').toList(),
        '/fresh/responses',
      );
      expect(
        await fixture.listModels('fresh-work'),
        _catalogSnapshot(['fresh-model']),
      );
      expect(fixture.requests.map((entry) => entry['path']), [
        '/work/responses',
        '/work/models',
        '/fresh/responses',
        '/fresh/models',
      ]);
      expect(fixture.requests.skip(2).map((entry) => entry['authorization']), [
        'Bearer test-replacement-key',
        'Bearer test-replacement-key',
      ]);
      expect(inferenceSettled, isFalse);
      expect(catalogSettled, isFalse);
      inferenceGate.release();
      catalogGate.release();
      _expectCompleted(await inference, '/work/responses');
      expect(await catalog, _catalogSnapshot(['work-model']));
      expect((await fixture.listModels('old-work'))['ok'], isFalse);
      expect(fixture.requests, hasLength(4));
      await old.expectRetired(fixture);
    },
  );

  test('more than eight explicit replacements release captures for continued '
      'inference and catalog success', () async {
    final fixture = await prepareProviders(chatGpt: true, consumeCatalog: true);
    await fixture.start();
    final personal = fixture.capture('personal');
    final chatGpt = fixture.registry.resolve(
      modelProviderCapability,
      providerId: ProviderId(_chatGpt),
    );
    var previous = fixture.capture('work');
    final reference = fixture.reference('work');
    final bytes = await fixture.workFile.readAsBytes();
    for (var revision = 0; revision < 12; revision++) {
      fixture.records['work'] = (await fixture.associations.replace(
        fixture.records['work']!,
        RecordCredentialSlotId('api-key'),
        CredentialSecret('test-rotation-$revision-key'),
      )).record;
      expect(await fixture.workFile.readAsBytes(), bytes);
      fixture.storage.calls.clear();
      fixture.storage.readReferences.clear();
      expect(await fixture.refresh(), _refreshResult('applied', 'replaced'));
      final current = fixture.capture('work');
      previous.expectReplacement(current);
      await previous.expectRetired(fixture);
      personal.expectSame(fixture.capture('personal'));
      expect(
        chatGpt.isSameRegistration(
          fixture.registry.resolve(
            modelProviderCapability,
            providerId: ProviderId(_chatGpt),
          ),
        ),
        isTrue,
      );
      _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
      await fixture.selectCatalog('work');
      _expectCompleted(
        await fixture.invoke('work').toList(),
        '/work/responses',
      );
      expect(
        await fixture.listModels('work'),
        _catalogSnapshot(['work-model']),
      );
      expect(fixture.storage.readReferences, [reference, reference]);
      expect(
        fixture.requests
            .skip(revision * 2)
            .map((entry) => entry['authorization']),
        [
          'Bearer test-rotation-$revision-key',
          'Bearer test-rotation-$revision-key',
        ],
      );
      expect(
        fixture.registry.providersFor(modelProviderCapability),
        hasLength(3),
      );
      expect(
        fixture.registry.providersFor(modelCatalogCapability),
        hasLength(2),
      );
      previous = current;
    }
    expect(fixture.requests, hasLength(24));
    _expectCompleted(
      await fixture.invokeChatGpt().toList(),
      '/chatgpt/responses',
    );
    expect(fixture.requests.last['authorization'], 'Bearer test-chatgpt-token');
  });

  test('invalid explicit refresh selectors and endpoints fail safely without '
      'replacing valid registrations', () async {
    final fixture = await prepareProviders(consumeCatalog: true);
    await fixture.start();
    final old = fixture.capture('work');
    final personal = fixture.capture('personal');
    // Prepared connections reserve the control service. Keep testing OpenAI's
    // own wire-level validation using the same binary with no prepared grants.
    expect(
      () => fixture.connection.channelFor(
        fixture.connection.defaultConfigurationContext,
        _configurationService,
      ),
      throwsStateError,
    );
    final raw = await fixture.bootstrap.host!.startPlugin(
      pluginId: 'test.openai.raw-control',
      artifactUri: openaiArtifact.uri,
      startupArgumentsOnly: true,
    );
    addTearDown(raw.close);
    final rawControl = raw.channelFor(
      raw.defaultConfigurationContext,
      _configurationService,
    );
    Future<Object?> invalidRequest(Map<String, Object?> payload) async {
      final result = await rawControl.request(
        'refreshConfiguredProvider',
        payload,
      );
      _expectProviderRedacted(result);
      return result;
    }

    for (final payload in <Map<String, Object?>>[
      {},
      {
        'recordId': 'work-openai',
        'endpoint': '${fixture.origin}/test-work-key',
      },
      {'recordId': 'work-openai', 'secret': 'test-work-key'},
    ]) {
      expect(
        await invalidRequest(payload),
        _refreshResult('failed', 'invalid_request'),
      );
    }
    for (final id in <Object?>[
      null,
      42,
      '',
      '../work-openai',
      ' work-openai ',
      'bad\nrecord',
      'a' * 257,
    ]) {
      expect(
        await invalidRequest({'recordId': id}),
        _refreshResult('failed', 'invalid_record_id'),
      );
    }
    old.expectSame(fixture.capture('work'));
    fixture.records['work'] = await fixture.settings.updateRecord(
      fixture.records['work']!,
      {
        ...fixture.records['work']!.values,
        'display-name': 'Unpublished Work',
        'endpoint': 'http://public.example.invalid/test-work-key?private=value',
      },
    );
    expect(
      await fixture.refresh(),
      _refreshResult('failed', 'invalid_configuration'),
    );
    old.expectSame(fixture.capture('work'));
    personal.expectSame(fixture.capture('personal'));
    expect(old.inference.provider.displayName, 'OpenAI Work');
    _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
    expect(fixture.requests, isEmpty);
    expect(fixture.storage.calls, isEmpty);
    await fixture.expectFailure('stale_configuration');
    expect(fixture.requests, isEmpty);
    expect(fixture.storage.calls, isEmpty);
  });

  for (final suffix in ['custom', 'responses?api-version=private']) {
    test(
      'explicit refresh to unsupported catalog endpoint $suffix keeps inference usable',
      () async {
        final fixture = await prepareProviders(consumeCatalog: true);
        await fixture.start();
        final old = fixture.capture('work');
        fixture.records['work'] = await fixture.settings
            .updateRecord(fixture.records['work']!, {
              ...fixture.records['work']!.values,
              'endpoint': '${fixture.origin}/work/$suffix',
            });
        expect(await fixture.refresh(), _refreshResult('applied', 'replaced'));
        old.expectReplacement(fixture.capture('work'));
        await old.expectRetired(fixture);
        _expectCatalogAssociations(fixture.bootstrap, fixture.registry);
        await fixture.selectCatalog('work');
        _expectCatalogFailure(
          await fixture.listModels('work'),
          'unsupported_discovery',
        );
        expect(fixture.requests, isEmpty);
        expect(fixture.storage.calls, isEmpty);
        _expectCompleted(
          await fixture.invoke('work').toList(),
          '/work/${suffix.split('?').first}',
        );
        expect(
          fixture.requests.single['authorization'],
          'Bearer test-work-key',
        );
        expect(
          fixture.requests.single['query'],
          suffix.contains('?') ? 'api-version=private' : '',
        );
        expect(fixture.storage.readReferences, [fixture.reference('work')]);
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
        unorderedEquals([
          '$_recordType.personal-openai',
          '$_catalogProviderId.personal-openai',
          _chatGpt,
        ]),
      );
      expect(
        () => fixture.client('work-openai'),
        throwsA(isA<ProviderUnavailable>()),
      );
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

  test(
    'new records stay invisible without explicit refresh or restart',
    () async {
      final fixture = await prepareProviders();
      await fixture.start();
      await fixture.settings.createRecord(
        RecordTypeId(_recordType),
        ConfigurationRecordId('new-openai'),
        {'display-name': 'New OpenAI'},
      );
      expect(
        () => fixture.client('new-openai'),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(fixture.connection.capabilityExposures, hasLength(4));
      await fixture.restart();
      expect(fixture.connection.capabilityExposures, hasLength(6));
      await fixture.expectFailure('not_configured', recordId: 'new-openai');
      expect(fixture.requests, isEmpty);
    },
  );

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
      File accountFile(String stem) =>
          File('${settings.collectionPath(definition.collection)}/$stem.toml');
      final personalFile = accountFile('personal');
      final personalBytes = await personalFile.readAsBytes();
      records['work'] = await settings.updateRecord(records['work']!, {
        ...records['work']!.values,
        'display-name': 'Work Renamed',
      });
      expect(records['work']!.id, ConfigurationRecordId('work-openai'));
      expect(await personalFile.readAsBytes(), personalBytes);
      final persisted = <String, String>{};
      for (final id in ['work', 'personal']) {
        persisted[id] = await accountFile(id).readAsString();
        expect(persisted[id], contains('recordId = "$id-openai"'));
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
      final contexts = _configuredContexts(connection);
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
              'configurationContext': contexts[id],
              'rank': 0,
            },
          for (final id in ['personal', 'work'])
            {
              'providerId': '$_catalogProviderId.$id-openai',
              'capabilityId': modelCatalogCapability.id.value,
              'capabilityMajorVersion': modelCatalogCapability.majorVersion,
              'serviceId': modelCatalogServiceId,
              'displayName': id == 'work' ? 'Work Renamed' : 'Personal',
              'configurationContext': contexts[id],
              'rank': 0,
              'association': {
                'capabilityId': modelProviderCapability.id.value,
                'capabilityMajorVersion': modelProviderCapability.majorVersion,
                'providerId': '$_recordType.$id-openai',
              },
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
      expect(
        registry
            .providersFor(modelCatalogCapability)
            .map((entry) => entry.id.value),
        [
          '$_catalogProviderId.personal-openai',
          '$_catalogProviderId.work-openai',
        ],
      );
      _expectCatalogAssociations(bootstrap, registry);
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
        expect(await accountFile(id).readAsString(), persisted[id]);
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

final class _HttpGate {
  final entered = Completer<void>();
  final resumed = Completer<void>();

  void release() {
    if (!resumed.isCompleted) resumed.complete();
  }
}

/// Only delays admission or delivery of a genuine worker capture. Nothing holds
/// the Settings writer, fabricates a reply or substitutes for the AOT control.
final class _HeldCaptures implements StartupCredentialReader {
  _HeldCaptures(this.owner, List<_ReadGate> gates, {required this.beforeScan})
    : pending = [...gates];
  final RecordCredentialService owner;
  final List<_ReadGate> pending;
  final bool beforeScan;

  @override
  Future<StartupRecordsView> captureCurrentConfiguration(
    PreparedPluginCatalog catalog,
    PreparedPluginInstallation installation,
  ) async {
    Future<StartupRecordsView> read() =>
        owner.captureCurrentConfiguration(catalog, installation);
    if (pending.isEmpty) return read();
    final gate = pending.removeAt(0);
    final captured = beforeScan ? null : await read();
    gate.entered.complete();
    await gate.resumed.future;
    gate.returned.complete();
    return captured ?? await read();
  }

  @override
  Future<void> releaseStartupRecords(StartupRecordsView snapshot) =>
      owner.releaseStartupRecords(snapshot);

  @override
  Future<String> readStartupCredential(
    StartupRecordsView snapshot, {
    required String collection,
    required String recordType,
    required String recordId,
    required String slot,
    required void Function() validateGeneration,
  }) => owner.readStartupCredential(
    snapshot,
    collection: collection,
    recordType: recordType,
    recordId: recordId,
    slot: slot,
    validateGeneration: validateGeneration,
  );
}

final class _ProviderSettings {
  _ProviderSettings(this.tester);
  final WidgetTester tester;
  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> until(bool Function() ready, String reason) async {
    final clock = Stopwatch()..start();
    await tester.pump();
    while (!ready()) {
      if (clock.elapsed >= const Duration(seconds: 10)) {
        fail('Timed out waiting for $reason.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  bool _enabled(String value) =>
      key(value).evaluate().isNotEmpty &&
      tester.widget<ButtonStyleButton>(key(value)).onPressed != null;

  Future<void> status(String id, String label) => until(
    () => find
        .descendant(
          of: key('record-apply-providers-$_recordType-$id'),
          matching: find.text('Runtime application: $label'),
        )
        .evaluate()
        .isNotEmpty,
    '$id: $label',
  );

  Future<void> _tap(Finder finder) async {
    // A focused field can still be scrolling the form to reveal its caret.
    // Wait before positioning the target; a zero-duration pump is not enough.
    final scroll = Scrollable.maybeOf(
      tester.element(finder),
      axis: Axis.vertical,
    );
    await until(
      () => scroll?.position.isScrollingNotifier.value != true,
      'scroll to settle before tapping $finder',
    );
    await tester.ensureVisible(finder);
    final target = finder.hitTestable();
    await until(() {
      if (target.evaluate().isEmpty) return false;
      final control = tester.widget(target);
      return control is! ButtonStyleButton || control.enabled;
    }, 'enabled, hit-testable $finder');
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> press(String action) => _tap(key(action));

  Future<void> _enter(String field, String value) async {
    await tester.ensureVisible(key(field));
    await tester.enterText(key(field), value);
    await tester.pump();
  }

  Future<void> section(String label) async {
    await press('settings-section');
    await _tap(find.text(label).last);
    if (label == 'Providers') {
      await until(
        () => _enabled('records-add-providers'),
        'Providers collection',
      );
    }
  }

  Future<void> open() async {
    await press('settings-button');
    await until(() => _enabled('settings-reload'), 'Settings load');
    await section('Providers');
  }

  Future<void> dismiss() async {
    await _tap(find.byTooltip('Close Settings'));
    await until(
      () => find.byType(GlobalSettingsDialog).evaluate().isEmpty,
      'Settings dismissal',
    );
  }

  Future<void> expand(String id) => _tap(
    find
        .descendant(
          of: key('record-providers-$id'),
          matching: find.byType(ListTile),
        )
        .first,
  );

  Future<String> draftAccount(String name, String endpoint) async {
    await press('records-add-providers');
    await _enter('record-input-providers-display-name', name);
    await _enter('record-input-providers-endpoint', endpoint);
    return inspectDraftId(tester);
  }

  Future<void> update(String id, String name, String endpoint) async {
    await press('record-edit-providers-$id');
    await _enter('record-input-providers-$id-display-name', name);
    await _enter('record-input-providers-$id-endpoint', endpoint);
    await press('record-save-providers-$id');
    await until(
      () => _enabled('record-edit-providers-$id'),
      'save acknowledgement',
    );
  }

  Future<void> credential(String action, String id) async {
    await press('credential-$action-providers-$id-api-key');
    if (action != 'forget') {
      await until(
        () => _enabled('records-reload-providers'),
        'credential $action',
      );
    }
  }

  Future<void> store(String action, String id, String secret) async {
    await credential(action, id);
    await _enter('credential-input-providers-$id-api-key', secret);
    await credential('submit', id);
    await until(
      () => _enabled('credential-replace-providers-$id-api-key'),
      'credential acknowledgement',
    );
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
  bool proposeReviewTool = false;
  final responseGates = <String, _HttpGate>{};
  final catalogModels = <String, List<String>>{
    '/work/models': ['work-model'],
    '/personal/models': ['personal-model'],
  };
  int catalogStatus = HttpStatus.ok;
  Object? catalogBody;
  Completer<Socket>? pendingCatalogSocket;
  final _standaloneRegistry = CapabilityRegistry();
  CapabilityRegistry get registry => bootstrap.registry;
  final readers = <GlobalSettingsService>[];
  final backendAssociations = <RecordCredentialService>[];
  late final credentials = CredentialService(storage);
  late final PlatformStorageRoots roots;
  late final GlobalSettingsService settings;
  late final RecordCredentialService associations;
  late final HttpServer server;
  late final StreamSubscription<HttpRequest> serverSubscription;
  HttpServer? personalServer;
  StreamSubscription<HttpRequest>? personalServerSubscription;
  final startupArguments = <String, List<String>>{};
  ApplicationPluginBootstrap? _bootstrap;

  ApplicationPluginBootstrap get bootstrap => _bootstrap!;
  InstalledBackendActivation get backend => bootstrap.backends.singleWhere(
    (entry) => entry.installation.metadata.id.value == _openai,
  );
  PluginBackendConnection get connection => backend.connection!;
  PluginBackendConnection get consumer => bootstrap.backends
      .singleWhere(
        (entry) => entry.installation.metadata.id.value == _catalogConsumer,
      )
      .connection!;
  String get origin => 'http://${server.address.address}:${server.port}';
  String get installationRoot => '${directory.path}/installations';

  CredentialReference reference(String id) => references[id]!;

  File providerFile(String fileName) =>
      File('${roots.configurationRoot}/providers/$fileName');
  File get workFile => providerFile('openai-work.toml');

  Future<void> prepare(
    Directory repository,
    File artifact, {
    required bool chatGpt,
    File? consumerArtifact,
    bool modelBrowser = false,
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    void handle(HttpRequest request) {
      unawaited(() async {
        final rawBody = await utf8.decoder.bind(request).join();
        final body = request.method == 'GET' ? rawBody : jsonDecode(rawBody);
        requests.add({
          'method': request.method,
          'authority': request.headers.value(HttpHeaders.hostHeader),
          'path': request.uri.path,
          'query': request.uri.query,
          'authorization': request.headers.value(
            HttpHeaders.authorizationHeader,
          ),
          'account': request.headers.value('ChatGPT-Account-ID'),
          'accept': request.headers.value(HttpHeaders.acceptHeader),
          'body': body,
        });
        final response = request.response;
        final gate = responseGates.remove(request.uri.path);
        if (gate != null) {
          gate.entered.complete();
          await gate.resumed.future;
        }
        if (request.method == 'GET') {
          final pending = pendingCatalogSocket;
          if (pending != null) {
            pendingCatalogSocket = null;
            pending.complete(await response.detachSocket(writeHeaders: false));
            return;
          }
          response.statusCode = catalogStatus;
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode(
              catalogBody ??
                  {
                    'object': 'list',
                    'data': [
                      for (final id in catalogModels[request.uri.path]!)
                        {
                          'object': 'model',
                          'id': id,
                          'created': 123,
                          'owned_by': 'test-work-key',
                        },
                    ],
                  },
            ),
          );
          await response.close();
          return;
        }
        response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        final propose =
            proposeReviewTool && request.uri.path == '/work/responses';
        if (propose) proposeReviewTool = false;
        for (final event in [
          if (propose)
            {
              'type': 'response.output_item.done',
              'item': {
                'type': 'function_call',
                'id': 'fc_review',
                'call_id': 'call_review',
                'status': 'completed',
                'name': 'review_probe',
                'arguments': '{}',
              },
            }
          else ...[
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
          ],
          {
            'type': 'response.completed',
            'response': {'id': 'response', 'model': (body as Map)['model']},
          },
        ]) {
          response.write('data: ${jsonEncode(event)}\n\n');
        }
        await response.close();
      }());
    }

    serverSubscription = server.listen(handle);
    if (consumerArtifact != null || modelBrowser) {
      personalServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      personalServerSubscription = personalServer!.listen(handle);
    }
    if (consumerArtifact != null) {
      final consumerDirectory = await Directory(
        '$installationRoot/catalog-consumer',
      ).create(recursive: true);
      await consumerArtifact.copy('${consumerDirectory.path}/backend.aot');
      await File(
        '${consumerDirectory.path}/adele_plugin.installation.json',
      ).writeAsString(
        jsonEncode({
          'manifestVersion': 1,
          'metadata': {
            'id': _catalogConsumer,
            'version': '1',
            'displayName': 'Catalog consumer',
          },
          'components': {
            'backend': {
              'artifact': 'backend.aot',
              'consumesCapabilities': [
                {
                  'id': modelCatalogCapability.id.value,
                  'majorVersion': modelCatalogCapability.majorVersion,
                },
              ],
            },
          },
        }),
      );
    }
    final installation = await Directory(
      '$installationRoot/openai',
    ).create(recursive: true);
    if (modelBrowser) {
      // _publishBrowserInstallations compiled the stock entrypoint with a
      // transport override. No endpoint other than these listeners is reachable.
      startupArguments[_openai] = [
        origin,
        'http://${personalServer!.address.address}:${personalServer!.port}',
      ];
    } else {
      await artifact.copy('${installation.path}/backend.aot');
    }
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
      final endpointOrigin = id == 'personal' && personalServer != null
          ? 'http://${personalServer!.address.address}:${personalServer!.port}'
          : origin;
      final record = await settings.createRecord(
        RecordTypeId(_recordType),
        ConfigurationRecordId('$id-openai'),
        {
          'display-name': id == 'work' ? 'OpenAI Work' : 'OpenAI Personal',
          'endpoint': modelBrowser && id == 'work'
              ? 'https://api.openai.com/v1/responses'
              : '$endpointOrigin/$id/responses',
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
      _standaloneRegistry,
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
      bootstrap.backends.where(
        (entry) => entry.installation.metadata.id.value == _openai,
      ),
      hasLength(1),
    );
    for (final backend in bootstrap.backends) {
      expect(
        backend.state,
        InstalledBackendState.active,
        reason: '${backend.failure}',
      );
    }
  }

  Future<void> withApplication(
    WidgetTester tester,
    NativeAdeleRuntime app,
    Future<void> Function(_ProviderSettings, List<_ReadGate>) exercise, {
    int heldCaptures = 0,
    bool holdBeforeScan = false,
  }) async {
    _bootstrap = app.plugins;
    final gates = List.generate(heldCaptures, (_) => _ReadGate());
    late StartupCredentialReader reader;
    late Future<void> starting;
    try {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: () => app,
          // Only the simulated protected storage persists between app lifetimes.
          createCredentials: () => CredentialService(storage),
          createCredentialAssociations:
              ({required settings, required credentials}) {
                final owner = RecordCredentialService(
                  settings: settings,
                  credentials: credentials,
                );
                if (gates.isNotEmpty) {
                  reader = _HeldCaptures(
                    owner,
                    gates,
                    beforeScan: holdBeforeScan,
                  );
                }
                return owner;
              },
          configurationRoots: roots,
          readChatGptConfiguration: () => null,
          bootstrapPlugins: (plugins) {
            if (gates.isNotEmpty) {
              plugins.configureCredentialAssociations(() => reader);
            }
            return starting = plugins.start(
              installationRoot: installationRoot,
              dartaotruntimeExecutable: runtime,
              hostArtifactPath: host,
              startupArguments: startupArguments,
            );
          },
        ),
      );
      await starting;
      for (final entry in bootstrap.backends) {
        expect(
          entry.state,
          InstalledBackendState.active,
          reason: '${entry.failure}',
        );
      }
      final ui = _ProviderSettings(tester);
      await ui.open();
      await exercise(ui, gates);
      expect(tester.takeException(), isNull);
    } finally {
      for (final gate in gates) {
        gate.release();
      }
      if (bootstrap.state != ApplicationPluginState.closed) {
        await tester.binding.handleRequestAppExit();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await app.close();
      await tester.binding.setSurfaceSize(null);
    }
  }

  Future<Map<String, Object?>> catalogCall(
    String method, [
    Map<String, Object?> payload = const {},
  ]) async => Map<String, Object?>.from(
    await consumer
            .channelFor(consumer.defaultConfigurationContext, 'test.controller')
            .request(method, payload)
        as Map,
  );

  Future<void> selectCatalog(String id, {String? slot}) async {
    expect(
      await catalogCall('resolve', {
        ..._catalogQuery,
        'providerId': '$_catalogProviderId.$id-openai',
        'slot': slot ?? id,
      }),
      {
        'ok': true,
        'provider': _catalogProvider(
          id,
          displayName: records[id]!.values['display-name']! as String,
        ),
        'requestOnly': true,
      },
    );
  }

  Future<Map<String, Object?>> listModels(String id) =>
      catalogCall('listModels', {'slot': id});

  Future<Map<String, Object?>> refresh([String id = 'work-openai']) async {
    final owner = backend;
    final captured = connection;
    final generation = captured.defaultConfigurationContext;
    final host = bootstrap.host!;
    final processId = host.processId;
    final calls = List<String>.of(storage.calls);
    final reads = List<CredentialReference>.of(storage.readReferences);
    final requestCount = requests.length;
    owner.validate();
    final result = Map<String, Object?>.from(
      await captured.requestRecordApply(
            owner.installation.backendRecordApplyHandlers.single,
            ConfigurationRecordId(id),
          )
          as Map,
    );
    expect(result.keys, unorderedEquals(['status', 'code', 'cleanupPending']));
    expect(
      result['status'],
      isIn(['applied', 'noChange', 'unavailable', 'failed']),
    );
    expect(result['code'], matches(RegExp(r'^[a-z]+(?:_[a-z]+)*$')));
    expect(result['cleanupPending'], isA<bool>());
    _expectProviderRedacted(result);
    for (final forbidden in [
      directory.path,
      origin,
      'recordId',
      'captureHandle',
    ]) {
      expect(jsonEncode(result), isNot(contains(forbidden)));
    }
    expect(storage.calls, calls, reason: 'Refresh must not access the vault.');
    expect(storage.readReferences, reads);
    expect(
      requests,
      hasLength(requestCount),
      reason: 'Refresh must not use HTTP.',
    );
    expect(backend, same(owner));
    expect(connection, same(captured));
    expect(connection.defaultConfigurationContext, same(generation));
    expect(bootstrap.host, same(host));
    expect(host.processId, processId);
    expect(host.isClosed, isFalse);
    expect(owner.validate, returnsNormally);
    expect(connection.validateInfrastructureContext, returnsNormally);
    expect(
      captured.capabilityExposures.map((entry) => entry.serviceId),
      isNot(contains(_configurationService)),
    );
    return result;
  }

  _ConfiguredBinding capture(String account) =>
      captureRecord('$account-openai');

  _ConfiguredBinding captureRecord(String recordId) => _ConfiguredBinding(
    registry.resolve(
      modelProviderCapability,
      providerId: ProviderId('$_recordType.$recordId'),
    ),
    registry.resolve(
      modelCatalogCapability,
      providerId: ProviderId('$_catalogProviderId.$recordId'),
    ),
  );

  ModelProviderServiceClient client(String recordId) =>
      ModelProviderServiceClient(
        registry
            .resolve(
              modelProviderCapability,
              providerId: ProviderId('$_recordType.$recordId'),
            )
            .streamChannel,
      );

  Stream<ModelProviderEvent> invoke(
    String id, {
    String model = 'same-model',
    ModelReasoningEffort? reasoningEffort,
  }) => client(
    '$id-openai',
  ).invoke(_providerRequest(model, reasoningEffort: reasoningEffort));

  Stream<ModelProviderEvent> invokeChatGpt() => ModelProviderServiceClient(
    registry
        .resolve(modelProviderCapability, providerId: ProviderId(_chatGpt))
        .streamChannel,
  ).invoke(_providerRequest('same-model'));

  Future<void> expectRoutes(
    _ConfiguredBinding binding,
    String path,
    String key,
    CredentialReference reference,
  ) async {
    final before = requests.length;
    final reads = storage.readReferences.length;
    final models = catalogModels.putIfAbsent(
      '/$path/models',
      () => ['$path-model'],
    );
    _expectCompleted(
      await binding.inferenceClient
          .invoke(_providerRequest('same-model'))
          .toList(),
      '/$path/responses',
    );
    expect(
      (await binding.catalogClient.listModels()).models.map(
        (model) => model.modelId,
      ),
      models,
    );
    expect(requests.skip(before).map((request) => request['path']), [
      '/$path/responses',
      '/$path/models',
    ]);
    expect(
      requests
          .skip(before)
          .every((request) => request['authorization'] == 'Bearer $key'),
      isTrue,
    );
    expect(storage.readReferences.skip(reads), [reference, reference]);
  }

  Future<void> expectFailure(
    String code, {
    String recordId = 'work-openai',
  }) async {
    final events = await client(
      recordId,
    ).invoke(_providerRequest('same-model')).toList();
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
    for (final gate in responseGates.values) {
      gate.release();
    }
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
    await personalServerSubscription?.cancel();
    await personalServer?.close(force: true);
  }
}

final _catalogQuery = {
  'capabilityId': modelCatalogCapability.id.value,
  'majorVersion': modelCatalogCapability.majorVersion,
  'expectedServiceId': modelCatalogServiceId,
};

Map<String, Object?> _catalogProvider(String id, {String? displayName}) => {
  'capabilityId': modelCatalogCapability.id.value,
  'majorVersion': modelCatalogCapability.majorVersion,
  'providerId': '$_catalogProviderId.$id-openai',
  'pluginId': _openai,
  'displayName':
      displayName ?? (id == 'work' ? 'OpenAI Work' : 'OpenAI Personal'),
  'serviceId': modelCatalogServiceId,
};

Map<String, Object?> _catalogSnapshot(List<String> ids) => {
  'ok': true,
  'models': [
    for (final id in ids)
      {
        'modelId': id,
        'displayName': null,
        'description': null,
        'supportedReasoningEfforts': null,
      },
  ],
};

void _expectCatalogFailure(Map<String, Object?> result, String code) {
  expect(result['ok'], isFalse);
  expect(result['type'], 'declared');
  expect(result['code'], code);
  expect(result['message'], isNotEmpty);
  expect(result['details'], isEmpty);
  _expectProviderRedacted(result);
}

void _expectCatalogAssociations(
  ApplicationPluginBootstrap bootstrap,
  CapabilityRegistry registry, {
  List<String> recordIds = const ['personal-openai', 'work-openai'],
}) {
  for (final id in recordIds) {
    final catalog = registry.resolve(
      modelCatalogCapability,
      providerId: ProviderId('$_catalogProviderId.$id'),
    );
    final inference = registry.resolve(
      modelProviderCapability,
      providerId: ProviderId('$_recordType.$id'),
    );
    final owner = bootstrap.backendForProvider(catalog)!;
    expect(owner.installation.metadata.id, PluginId(_openai));
    expect(bootstrap.backendForProvider(inference), same(owner));
    expect(
      owner.associationFor(catalog)!.isSameRegistration(inference),
      isTrue,
    );
    expect(owner.associationFor(inference), isNull);
  }
}

Map<String, String> _configuredContexts(PluginBackendConnection connection) {
  final contexts = <String, String>{};
  for (final id in ['personal', 'work']) {
    final inference = connection.capabilityExposures.singleWhere(
      (entry) => entry.providerId == '$_recordType.$id-openai',
    );
    final catalog = connection.capabilityExposures.singleWhere(
      (entry) => entry.providerId == '$_catalogProviderId.$id-openai',
    );
    expect(
      inference.configurationContext,
      matches(RegExp(r'^dynamic:[0-9]+$')),
    );
    expect(catalog.configurationContext, inference.configurationContext);
    contexts[id] = inference.configurationContext;
  }
  expect(contexts.values.toSet(), hasLength(contexts.length));
  return contexts;
}

Map<String, Object?> _refreshResult(
  String status,
  String code, {
  bool? cleanupPending,
}) => {
  'status': status,
  'code': code,
  'cleanupPending': cleanupPending ?? isA<bool>(),
};

final class _ConfiguredBinding {
  _ConfiguredBinding(this.inference, this.catalog)
    : inferenceClient = ModelProviderServiceClient(inference.streamChannel),
      catalogClient = ModelCatalogServiceClient(catalog.requestChannel);

  final ProviderBinding inference;
  final ProviderBinding catalog;
  final ModelProviderServiceClient inferenceClient;
  final ModelCatalogServiceClient catalogClient;

  void expectSame(_ConfiguredBinding other) {
    expect(inference.isSameRegistration(other.inference), isTrue);
    expect(catalog.isSameRegistration(other.catalog), isTrue);
  }

  void expectReplacement(_ConfiguredBinding other) {
    expect(inference.provider.id, other.inference.provider.id);
    expect(catalog.provider.id, other.catalog.provider.id);
    expect(inference.isSameRegistration(other.inference), isFalse);
    expect(catalog.isSameRegistration(other.catalog), isFalse);
  }

  Future<void> expectRetired(_ProviderFixture fixture) async {
    final calls = List<String>.of(fixture.storage.calls);
    final requests = fixture.requests.length;
    for (final binding in [inference, catalog]) {
      expect(
        () => binding.requestChannel,
        throwsA(
          isA<ProviderUnavailable>().having((e) => e.stale, 'stale', isTrue),
        ),
      );
    }
    expect(
      () => fixture.backend.associationFor(catalog),
      throwsA(isA<ProviderUnavailable>()),
    );
    await expectLater(
      inferenceClient.invoke(_providerRequest('old-route')).toList(),
      throwsA(isA<AdeleRemoteFailure>()),
    );
    await expectLater(
      catalogClient.listModels(),
      throwsA(isA<AdeleRemoteFailure>()),
    );
    expect(fixture.storage.calls, calls);
    expect(fixture.requests, hasLength(requests));
  }
}

ModelProviderRequest _providerRequest(
  String model, {
  ModelReasoningEffort? reasoningEffort,
}) => ModelProviderRequest(
  model: model,
  reasoningEffort: reasoningEffort,
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
    'test-third-key',
    'test-rotation-',
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
