import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse, IsolateNameServer;

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/adele_core_extensions.dart';
import 'package:adele_desktop/application.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/main.dart' as application;
import 'package:adele_desktop/terminal/native_adele_runtime.dart';
import 'package:adele_desktop/ui/commands/command_palette.dart';
import 'package:adele_desktop/ui/console/workbench_console.dart';
import 'package:adele_desktop/ui/main_content/main_content_host.dart';
import 'package:adele_desktop/ui/settings/global_settings_dialog.dart';
import 'package:adele_desktop/ui/shell/adele_shell.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_provider/adele_model_provider.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/backend_artifacts.dart';
import '../../tools/stock_frontend_descriptors.dart';
import '../tool/development_main.dart' as development;
import '../tool/task_browser_frontend_compiler.dart';
import 'fixtures/window_session_command.dart';
import 'support/command_palette_shortcut.dart';
import 'support/prepared_frontend_installations.dart';
import 'support/project_provider.dart';

void main() {
  testWidgets(
    'Global Settings persists independent stock OpenAI credentials without provider activation',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const openai = 'dev.adele.openai';
      const source = 'dev.adele.source-editor';
      const folding = '$source.enable-folding';
      const workSecret = 'application-work-test-secret';
      const personalSecret = 'application-personal-test-secret';
      const replacement = 'application-work-replacement';
      final directory = await Directory.systemTemp.createTemp(
        'adele-provider-credentials-application-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final roots = _configurationRoots(directory);
      for (final (id, label) in [(source, 'Source'), (openai, 'OpenAI')]) {
        await publishStockPluginInstallation(
          repositoryRoot: Directory.current.parent,
          installationDirectory: Directory('${directory.path}/installed/$id'),
          pluginId: id,
          displayName: label,
        );
      }
      final storage = _CredentialStorage();
      var credentials = CredentialService(storage);
      var runtime = NativeAdeleRuntime();
      GlobalSettingsService? settingsOwner;
      RecordCredentialService? associations;

      Future<void> mount() async {
        late Future<void> starting;
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            createCredentials: () => credentials,
            createCredentialAssociations:
                ({required settings, required credentials}) {
                  settingsOwner = settings;
                  final owner = RecordCredentialService(
                    settings: settings,
                    credentials: credentials,
                  );
                  associations = owner;
                  return owner;
                },
            configurationRoots: roots,
            readChatGptConfiguration: () => null,
            bootstrapPlugins: (plugins) => starting = plugins.start(
              installationRoot: '${directory.path}/installed',
              dartaotruntimeExecutable: '${directory.path}/absent-runtime',
              hostArtifactPath: '${directory.path}/absent-host.aot',
            ),
          ),
        );
        await starting;
        await tester.pumpAndSettle();
        expect(runtime.plugins.catalog!.issues, isEmpty);
        expect(find.text('No Project is open'), findsOneWidget);
        expect(runtime.plugins.host, isNull);
        expect(runtime.plugins.backends, isEmpty);
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      }

      Future<void> openProviders() async {
        await tester.tap(find.byKey(const ValueKey('settings-button')));
        await _settingsUntil(
          tester,
          () => find
              .byKey(const ValueKey('setting-input-$folding'))
              .evaluate()
              .isNotEmpty,
        );
        final dialog = tester.widget<GlobalSettingsDialog>(
          find.byType(GlobalSettingsDialog),
        );
        expect(await dialog.service(), same(settingsOwner));
        expect(dialog.credentialAssociations!(), same(associations));
        await _settingsSection(tester, 'Providers');
      }

      Finder action(String action, [String id = 'work-openai']) =>
          find.byKey(ValueKey('credential-$action-providers-$id-api-key'));

      bool enabled(String name, String id) =>
          action(name, id).evaluate().isNotEmpty &&
          tester.widget<ButtonStyleButton>(action(name, id)).onPressed != null;

      Finder status(String label, String id) => find.descendant(
        of: find.byKey(ValueKey('credential-slot-providers-$id-api-key')),
        matching: find.text(label),
      );

      Future<void> press(String name, [String id = 'work-openai']) =>
          _settingsAction(tester, 'credential-$name-providers-$id-api-key');

      Future<void> store(String name, String secret, String id) async {
        await press(name, id);
        final input = action('input', id);
        final field = tester.widget<TextField>(input);
        expect(field.obscureText, isTrue);
        expect(field.controller!.text, isEmpty);
        await tester.enterText(input, secret);
        await press('submit', id);
        await _settingsUntil(tester, () => enabled('replace', id));
        expect(input, findsNothing);
        expect(action('replace', id), findsOneWidget);
        expect(status('Credential stored locally', id), findsOneWidget);
      }

      final work = File(
        '${roots.configurationRoot}/providers/work-openai.toml',
      );
      final personal = File(
        '${roots.configurationRoot}/providers/personal-openai.toml',
      );
      final settingsFile = File('${roots.configurationRoot}/settings.toml');
      CredentialReference reference(String id) => CredentialReference.parse(
        ConfigurationStore(roots)
                .recordFile(collectionId: 'providers', recordId: id)
                .load()
                .document
                .readScalar(['credentials', 'api-key'])
            as String,
      );

      void expectEnvelope(
        CredentialReference reference,
        String id,
        String secret,
      ) {
        expect(jsonDecode(storage.values[reference]!), {
          'version': 1,
          'owner': openai,
          'type': '$openai.api-key',
          'collection': 'providers',
          'record': id,
          'slot': 'api-key',
          'reference': reference.value,
          'secret': secret,
        });
      }

      Future<void> closeApplication() async {
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          IsolateNameServer.lookupPortByName('dev.adele.global-settings-owner'),
          isNull,
        );
      }

      try {
        await mount();
        await openProviders();
        await _createProviderRecord(tester, 'work-openai', 'Work OpenAI');
        await _createProviderRecord(
          tester,
          'personal-openai',
          'Personal OpenAI',
        );
        for (final id in ['work-openai', 'personal-openai']) {
          await _expandProviderRecord(tester, id);
          expect(
            find.byKey(ValueKey('credential-slot-providers-$id-api-key')),
            findsOneWidget,
          );
          expect(action('check', id), findsOneWidget);
          expect(status('Credential status not checked', id), findsOneWidget);
          for (final name in ['set', 'replace', 'establish', 'forget']) {
            expect(enabled(name, id), isFalse);
          }
        }
        expect(
          storage.calls,
          isEmpty,
          reason:
              'Startup, record creation and expansion must not read storage.',
        );
        for (final (id, secret) in [
          ('work-openai', workSecret),
          ('personal-openai', personalSecret),
        ]) {
          final callsBeforeCheck = storage.calls.length;
          await press('check', id);
          await _settingsUntil(tester, () => enabled('set', id));
          expect(status('No credential configured', id), findsOneWidget);
          expect(storage.calls, hasLength(callsBeforeCheck));
          await store('set', secret, id);
        }
        final workReference = reference('work-openai');
        final personalReference = reference('personal-openai');
        expect(workReference, isNot(personalReference));
        expectEnvelope(workReference, 'work-openai', workSecret);
        expectEnvelope(personalReference, 'personal-openai', personalSecret);
        for (final file in [work, personal]) {
          final contents = await file.readAsString();
          expect(contents, contains('[credentials]'));
          expect(contents, contains('api-key = "cred1_'));
          expect(contents, isNot(contains(workSecret)));
          expect(contents, isNot(contains(personalSecret)));
        }
        expect(await settingsFile.exists(), isFalse);
        final personalBytes = await personal.readAsBytes();
        final personalEnvelope = storage.values[personalReference];
        final workBeforeReplace = await work.readAsBytes();

        await store('replace', replacement, 'work-openai');
        expect(reference('work-openai'), workReference);
        expect(await work.readAsBytes(), workBeforeReplace);
        expectEnvelope(workReference, 'work-openai', replacement);
        expect(storage.values, hasLength(2));

        // Replace retires the old record handle even though TOML bytes do not
        // change. The ordinary editor must use the acknowledged fresh handle.
        await _editProviderRecord(tester, 'work-openai');
        final name = find.byKey(
          const ValueKey('record-input-providers-work-openai-display-name'),
        );
        await tester.enterText(name, 'Work renamed after replacement');
        await _settingsAction(
          tester,
          'record-presence-providers-work-openai-endpoint',
        );
        await tester.enterText(
          find.byKey(
            const ValueKey('record-input-providers-work-openai-endpoint'),
          ),
          'https://example.invalid/work/v1',
        );
        await _settingsAction(tester, 'record-save-providers-work-openai');
        await _settingsUntil(tester, () => name.evaluate().isEmpty);
        expect(
          await work.readAsString(),
          contains('display-name = "Work renamed after replacement"'),
        );
        expect(reference('work-openai'), workReference);
        expect(
          await work.readAsString(),
          contains('endpoint = "https://example.invalid/work/v1"'),
        );
        expect(await work.readAsString(), isNot(contains(replacement)));
        expect(await personal.readAsBytes(), personalBytes);
        expect(storage.values[personalReference], personalEnvelope);
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(runtime.plugins.backends, isEmpty);
        expect(runtime.plugins.host, isNull);

        final callsBeforeReopen = storage.calls.length;
        await closeApplication();
        credentials = CredentialService(storage);
        runtime = NativeAdeleRuntime();
        await mount();
        await openProviders();
        await _expandProviderRecord(tester, 'work-openai');
        await _expandProviderRecord(tester, 'personal-openai');
        expect(find.text('Work renamed after replacement'), findsOneWidget);
        expect(find.text('Personal OpenAI'), findsOneWidget);
        expect(
          storage.calls,
          hasLength(callsBeforeReopen),
          reason:
              'Reconstruction and reopening must not inspect saved references.',
        );
        expect(reference('work-openai'), workReference);
        expect(reference('personal-openai'), personalReference);
        for (final id in ['work-openai', 'personal-openai']) {
          expect(status('Credential status not checked', id), findsOneWidget);
          await press('check', id);
          await _settingsUntil(tester, () => enabled('forget', id));
          expect(status('Credential stored locally', id), findsOneWidget);
        }
        expect(storage.calls.skip(callsBeforeReopen), [
          ('read', workReference),
          ('read', personalReference),
        ]);

        final beforeForget = await work.readAsBytes();
        final callsBeforeForget = storage.calls.length;
        await press('forget');
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.textContaining('work-openai'), findsWidgets);
        expect(find.textContaining('API key'), findsWidgets);
        await press('forget-cancel');
        expect(find.byType(AlertDialog), findsNothing);
        expect(storage.calls, hasLength(callsBeforeForget));
        expect(await work.readAsBytes(), beforeForget);
        expectEnvelope(workReference, 'work-openai', replacement);
        await press('forget');
        await press('forget-confirm');
        await _settingsUntil(tester, () => enabled('set', 'work-openai'));
        expect(
          status('No credential configured', 'work-openai'),
          findsOneWidget,
        );
        expect(storage.values.containsKey(workReference), isFalse);
        expect(await work.readAsString(), isNot(contains(workReference.value)));
        expect(
          await work.readAsString(),
          contains('display-name = "Work renamed after replacement"'),
        );
        expect(
          await work.readAsString(),
          contains('endpoint = "https://example.invalid/work/v1"'),
        );
        expect(await personal.readAsBytes(), personalBytes);
        expect(storage.values[personalReference], personalEnvelope);

        // Forget also replaces the revision. Delete must use that fresh handle,
        // not require a Reload that could discard independent record drafts.
        await _settingsAction(tester, 'record-delete-providers-work-openai');
        await _settingsAction(
          tester,
          'record-delete-confirm-providers-work-openai',
        );
        await _settingsUntil(
          tester,
          () => find
              .byKey(const ValueKey('record-providers-work-openai'))
              .evaluate()
              .isEmpty,
        );
        expect(await work.exists(), isFalse);
        expect(await personal.readAsBytes(), personalBytes);
        expect(storage.values, {personalReference: personalEnvelope});

        final callsBeforePreferences = storage.calls.length;
        await _settingsSection(tester, 'Preferences');
        await _settingsAction(tester, 'setting-input-$folding');
        await _settingsAction(tester, 'setting-save-$folding');
        await _settingsUntil(
          tester,
          () => find.text('Effective value: true').evaluate().isNotEmpty,
        );
        expect(
          await settingsFile.readAsString(),
          contains('"$folding" = true'),
        );
        expect(await personal.readAsBytes(), personalBytes);
        expect(storage.values, {personalReference: personalEnvelope});
        expect(storage.calls, hasLength(callsBeforePreferences));
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(runtime.plugins.backends, isEmpty);
        expect(runtime.plugins.host, isNull);
        expect(find.text('No Project is open'), findsOneWidget);
        expect(find.byType(MainContentHost), findsNothing);
        expect(await Directory(roots.localDataRoot).exists(), isFalse);
        expect(await Directory(roots.cacheRoot).exists(), isFalse);
        expect(tester.takeException(), isNull);
        await closeApplication();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await associations?.close();
        await settingsOwner?.close();
        await credentials.close();
        await runtime.close();
      }
    }),
    skip: !Platform.isLinux,
  );

  testWidgets(
    'Global Settings creates edits deletes and reloads stock provider records before a Project without runtime activation',
    (tester) => tester.runAsync(() async {
      await tester.binding.setSurfaceSize(const Size(1100, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const sourceId = 'dev.adele.source-editor';
      const folding = '$sourceId.enable-folding';
      const openai = 'dev.adele.openai';
      final directory = await Directory.systemTemp.createTemp(
        'adele-provider-settings-application-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final roots = _configurationRoots(directory);
      for (final (id, label) in [(sourceId, 'Source'), (openai, 'OpenAI')]) {
        await publishStockPluginInstallation(
          repositoryRoot: Directory.current.parent,
          installationDirectory: Directory('${directory.path}/installed/$id'),
          pluginId: id,
          displayName: label,
        );
      }
      final settingsFile = File('${roots.configurationRoot}/settings.toml');
      await settingsFile.parent.create(recursive: true);
      const originalSettings =
          '# Ordinary Source preferences remain separate from records.\n'
          '"$folding" = true # retain\n'
          '"dev.unavailable.preference" = [1, 2]\n';
      await settingsFile.writeAsString(originalSettings);
      final runtime = NativeAdeleRuntime();
      addTearDown(runtime.close);
      try {
        late Future<void> starting;
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            configurationRoots: roots,
            readChatGptConfiguration: () => null,
            bootstrapPlugins: (plugins) => starting = plugins.start(
              installationRoot: '${directory.path}/installed',
              dartaotruntimeExecutable: '${directory.path}/absent-runtime',
              hostArtifactPath: '${directory.path}/absent-host.aot',
            ),
          ),
        );
        await starting;
        await tester.pumpAndSettle();
        final catalog = runtime.plugins.catalog!;
        expect(catalog.issues, isEmpty);
        expect(catalog.settings.definitions.single.id.value, folding);
        expect(catalog.records.definitions.single.id.value, '$openai.api-key');
        for (final installation in catalog.installations) {
          expect(installation.backendArtifactUri, isNull);
          expect(installation.frontend, isNull);
        }
        final shell = tester.element(find.byType(AdeleShell));
        expect(find.text('No Project is open'), findsOneWidget);
        expect(runtime.plugins.host, isNull);
        expect(runtime.plugins.backends, isEmpty);
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(runtime.extensions.discover(mainContentContributions), isEmpty);

        Future<void> openSettings() async {
          await tester.tap(find.byKey(const ValueKey('settings-button')));
          await _settingsUntil(
            tester,
            () => find
                .byKey(const ValueKey('setting-input-$folding'))
                .evaluate()
                .isNotEmpty,
          );
          expect(
            tester
                .widget<Switch>(
                  find.byKey(const ValueKey('setting-input-$folding')),
                )
                .value,
            isTrue,
          );
          expect(find.text('Effective value: true'), findsOneWidget);
          await _settingsSection(tester, 'Providers');
          await _settingsUntil(
            tester,
            () => find
                .byKey(const ValueKey('records-add-providers'))
                .evaluate()
                .isNotEmpty,
          );
        }

        await openSettings();
        expect(
          find.text('${roots.configurationRoot}/providers'),
          findsOneWidget,
        );
        expect(
          await Directory('${roots.configurationRoot}/providers').exists(),
          isFalse,
        );
        for (final (id, name) in [
          ('work-openai', 'Work OpenAI'),
          ('personal-openai', 'Personal OpenAI'),
        ]) {
          await _createProviderRecord(tester, id, name);
          final contents = await File(
            '${roots.configurationRoot}/providers/$id.toml',
          ).readAsString();
          expect(contents, contains('recordVersion = 1'));
          expect(contents, contains('recordType = "$openai.api-key"'));
          expect(contents, contains('[values]'));
          expect(contents, contains('display-name = "$name"'));
          expect(contents, isNot(contains('endpoint')));
          expect(contents, isNot(contains('credential')));
          expect(await settingsFile.readAsString(), originalSettings);
        }
        expect(
          find.byKey(const ValueKey('record-providers-work-openai')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('record-providers-personal-openai')),
          findsOneWidget,
        );
        final work = File(
          '${roots.configurationRoot}/providers/work-openai.toml',
        );
        final personal = File(
          '${roots.configurationRoot}/providers/personal-openai.toml',
        );
        final personalBytes = await personal.readAsBytes();
        final providers = await work.parent.list().toList();
        expect(
          providers.map((file) => file.uri.pathSegments.last),
          unorderedEquals(['work-openai.toml', 'personal-openai.toml']),
        );
        // Retain unrecognized content instead of adopting it into the form.
        const unknown =
            '# Retain this comment and unknown field.\nfuture = [1, 2]\n';
        await work.writeAsString('${await work.readAsString()}$unknown');
        await _settingsAction(tester, 'records-reload-providers');
        await _settingsUntil(tester, () => true);
        await _editProviderRecord(tester, 'work-openai');
        expect(find.text('Record ID: work-openai'), findsOneWidget);
        expect(find.text('Record type: $openai.api-key'), findsOneWidget);
        expect(find.text('Collection: providers'), findsOneWidget);
        final workName = find.byKey(
          const ValueKey('record-input-providers-work-openai-display-name'),
        );
        expect(
          tester.widget<TextField>(workName).controller!.text,
          'Work OpenAI',
        );
        await tester.enterText(workName, 'Work OpenAI renamed');
        await _settingsAction(tester, 'record-save-providers-work-openai');
        await _settingsUntil(tester, () => workName.evaluate().isEmpty);
        expect(find.text('Work OpenAI renamed'), findsOneWidget);
        expect(
          await work.readAsString(),
          contains('display-name = "Work OpenAI renamed"'),
        );
        expect(await work.readAsString(), contains(unknown));
        expect(await personal.readAsBytes(), personalBytes);
        expect(
          (await work.parent.list().toList()).map(
            (file) => file.uri.pathSegments.last,
          ),
          unorderedEquals(['work-openai.toml', 'personal-openai.toml']),
        );

        await _editProviderRecord(tester, 'work-openai');
        await _settingsAction(
          tester,
          'record-presence-providers-work-openai-endpoint',
        );
        await tester.enterText(
          find.byKey(
            const ValueKey('record-input-providers-work-openai-endpoint'),
          ),
          'https://example.invalid/v1',
        );
        await _settingsAction(tester, 'record-save-providers-work-openai');
        await _settingsUntil(tester, () => workName.evaluate().isEmpty);
        expect(
          await work.readAsString(),
          contains('endpoint = "https://example.invalid/v1"'),
        );
        await _editProviderRecord(tester, 'work-openai');
        expect(
          tester
              .widget<TextField>(
                find.byKey(
                  const ValueKey('record-input-providers-work-openai-endpoint'),
                ),
              )
              .controller!
              .text,
          'https://example.invalid/v1',
        );
        await _settingsAction(
          tester,
          'record-presence-providers-work-openai-endpoint',
        );
        await _settingsAction(tester, 'record-save-providers-work-openai');
        await _settingsUntil(tester, () => workName.evaluate().isEmpty);
        expect(await work.readAsString(), isNot(contains('endpoint')));
        expect(await work.readAsString(), contains(unknown));
        expect(await personal.readAsBytes(), personalBytes);
        final firstDialog = tester.element(find.byType(GlobalSettingsDialog));
        await tester.tap(find.byTooltip('Close Settings'));
        await tester.pumpAndSettle();
        expect(firstDialog.mounted, isFalse);
        expect(tester.element(find.byType(AdeleShell)), same(shell));

        await openSettings();
        await _settingsUntil(
          tester,
          () => find.text('Work OpenAI renamed').evaluate().isNotEmpty,
        );
        await _editProviderRecord(tester, 'work-openai');
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(
                  const ValueKey(
                    'record-presence-providers-work-openai-endpoint',
                  ),
                ),
              )
              .value,
          isFalse,
        );
        await _settingsAction(tester, 'record-cancel-providers-work-openai');

        // A manual edit distinguishes deliberate Reload from a cached UI list.
        final edited = (await work.readAsString()).replaceFirst(
          'Work OpenAI renamed',
          'Work OpenAI from disk',
        );
        await work.writeAsString(edited);
        await _settingsAction(tester, 'records-reload-providers');
        await _settingsUntil(
          tester,
          () => find.text('Work OpenAI from disk').evaluate().isNotEmpty,
        );
        expect(find.text('Personal OpenAI'), findsOneWidget);
        expect(
          tester.element(find.byType(GlobalSettingsDialog)),
          isNot(same(firstDialog)),
        );
        final reloaded = edited.replaceFirst(
          'Work OpenAI from disk',
          'Work OpenAI reloaded',
        );
        await work.writeAsString(reloaded);
        await tester.pump();
        expect(find.text('Work OpenAI from disk'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('records-reload-providers')),
        );
        await _settingsUntil(
          tester,
          () => find.text('Work OpenAI reloaded').evaluate().isNotEmpty,
        );
        expect(await work.readAsString(), reloaded);
        expect(await personal.readAsBytes(), personalBytes);

        await _expandProviderRecord(tester, 'personal-openai');
        await _settingsAction(
          tester,
          'record-delete-providers-personal-openai',
        );
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.textContaining('Personal OpenAI'), findsWidgets);
        expect(find.textContaining('personal-openai'), findsWidgets);
        expect(find.textContaining('$openai.api-key'), findsWidgets);
        await _settingsAction(
          tester,
          'record-delete-cancel-providers-personal-openai',
        );
        expect(find.byType(GlobalSettingsDialog), findsOneWidget);
        expect(await personal.readAsBytes(), personalBytes);
        await _settingsAction(
          tester,
          'record-delete-providers-personal-openai',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(GlobalSettingsDialog), findsOneWidget);
        expect(await personal.readAsBytes(), personalBytes);
        await _settingsAction(
          tester,
          'record-delete-providers-personal-openai',
        );
        await _settingsAction(
          tester,
          'record-delete-confirm-providers-personal-openai',
        );
        await _settingsUntil(
          tester,
          () => find
              .byKey(const ValueKey('record-providers-personal-openai'))
              .evaluate()
              .isEmpty,
        );
        expect(await personal.exists(), isFalse);
        expect(await work.readAsString(), reloaded);
        await tester.tap(find.byTooltip('Close Settings'));
        await tester.pumpAndSettle();
        await openSettings();
        await _settingsUntil(
          tester,
          () => find.text('Work OpenAI reloaded').evaluate().isNotEmpty,
        );
        expect(
          find.byKey(const ValueKey('record-providers-personal-openai')),
          findsNothing,
        );
        await _settingsSection(tester, 'Preferences');
        expect(
          tester
              .widget<Switch>(
                find.byKey(const ValueKey('setting-input-$folding')),
              )
              .value,
          isTrue,
        );
        expect(find.text('Effective value: true'), findsOneWidget);
        expect(await settingsFile.readAsString(), originalSettings);
        await _settingsAction(tester, 'setting-input-$folding');
        await _settingsAction(tester, 'setting-save-$folding');
        await _settingsUntil(
          tester,
          () => find.text('Effective value: false').evaluate().isNotEmpty,
        );
        expect(
          await settingsFile.readAsString(),
          originalSettings.replaceFirst('true', 'false'),
        );
        expect(await work.readAsString(), reloaded);
        expect(await personal.exists(), isFalse);
        await tester.tap(find.byTooltip('Close Settings'));
        await tester.pumpAndSettle();
        expect(find.text('No Project is open'), findsOneWidget);
        expect(find.byType(MainContentHost), findsNothing);
        expect(runtime.plugins.host, isNull);
        expect(runtime.plugins.backends, isEmpty);
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(await Directory(roots.localDataRoot).exists(), isFalse);
        expect(await Directory(roots.cacheRoot).exists(), isFalse);
        expect(tester.takeException(), isNull);
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
      }
    }),
    skip: !Platform.isLinux,
  );

  for (final deleting in [false, true]) {
    testWidgets(
      'accepted application exit drains an admitted record ${deleting ? 'delete' : 'update'}',
      (tester) => tester.runAsync(() async {
        await tester.binding.setSurfaceSize(const Size(1100, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final directory = await Directory.systemTemp.createTemp(
          'adele-record-exit-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final roots = _configurationRoots(directory);
        await publishStockPluginInstallation(
          repositoryRoot: Directory.current.parent,
          installationDirectory: Directory(
            '${directory.path}/installed/openai',
          ),
          pluginId: 'dev.adele.openai',
          displayName: 'OpenAI',
        );
        final runtime = NativeAdeleRuntime();
        addTearDown(runtime.close);
        final fenced = Completer<void>();
        late Future<void> starting;
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            configurationRoots: roots,
            readChatGptConfiguration: () => null,
            attachSessionContext: (_) =>
                () => fenced.complete(),
            bootstrapPlugins: (plugins) => starting = plugins.start(
              installationRoot: '${directory.path}/installed',
              dartaotruntimeExecutable: '${directory.path}/absent-runtime',
              hostArtifactPath: '${directory.path}/absent-host.aot',
            ),
          ),
        );
        await starting;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-button')));
        await _settingsUntil(
          tester,
          () => find
              .text('No settings are available from installed plugins.')
              .evaluate()
              .isNotEmpty,
        );
        final service = await tester
            .widget<GlobalSettingsDialog>(find.byType(GlobalSettingsDialog))
            .service();
        final initial = await service.createRecord(
          RecordTypeId('dev.adele.openai.api-key'),
          ConfigurationRecordId('work-openai'),
          {'display-name': 'Work'},
        );
        await _settingsSection(tester, 'Providers');
        if (deleting) {
          await _expandProviderRecord(tester, 'work-openai');
          await _settingsAction(tester, 'record-delete-providers-work-openai');
        } else {
          await _editProviderRecord(tester, 'work-openai');
          await tester.enterText(
            find.byKey(
              const ValueKey('record-input-providers-work-openai-display-name'),
            ),
            'Saved while exiting',
          );
          await tester.pump();
        }
        final action = tester
            .widget<ButtonStyleButton>(
              find.byKey(
                ValueKey(
                  deleting
                      ? 'record-delete-confirm-providers-work-openai'
                      : 'record-save-providers-work-openai',
                ),
              ),
            )
            .onPressed!;
        final file = File(
          '${roots.configurationRoot}/providers/work-openai.toml',
        );
        final original = await file.readAsBytes();
        final lock = File(ConfigurationStore(roots).lockPath);
        await lock.parent.create(recursive: true);
        final helper = await File(
          'test/support/settings_lock.dart',
        ).copy('${directory.path}/settings_lock.dart');
        final process = await Process.start(
          '${Platform.environment['FLUTTER_ROOT']!}/bin/cache/dart-sdk/bin/dart',
          [helper.path, lock.path],
          workingDirectory: directory.path,
        );
        final lines = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        final errors = process.stderr.transform(utf8.decoder).join();
        try {
          expect(
            await lines.moveNext().timeout(const Duration(seconds: 15)),
            isTrue,
          );
          expect(lines.current, 'locked');
          action();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await _settingsUntil(
            tester,
            () =>
                find.byType(LinearProgressIndicator).evaluate().isNotEmpty &&
                find.byType(AlertDialog).evaluate().isEmpty,
            waitForOperation: false,
          );
          var exited = false;
          final exiting = tester.binding.handleRequestAppExit().then((value) {
            exited = true;
            return value;
          });
          await fenced.future.timeout(const Duration(seconds: 10));
          expect(exited, isFalse);
          expect(await file.readAsBytes(), original);
          await expectLater(service.deleteRecord(initial), throwsStateError);
          await expectLater(
            service.updateRecord(initial, {'display-name': 'Too late'}),
            throwsStateError,
          );
          expect(find.byType(GlobalSettingsDialog), findsOneWidget);
          process.stdin.writeln('release');
          await process.stdin.close();
          expect(
            await process.exitCode.timeout(const Duration(seconds: 10)),
            0,
            reason: await errors,
          );
          expect(
            await exiting.timeout(const Duration(seconds: 10)),
            AppExitResponse.exit,
          );
          await tester.pumpAndSettle();
          expect(find.byType(GlobalSettingsDialog), findsNothing);
          expect(
            IsolateNameServer.lookupPortByName(
              'dev.adele.global-settings-owner',
            ),
            isNull,
          );
          if (deleting) {
            expect(await file.exists(), isFalse);
          } else {
            expect(
              await file.readAsString(),
              contains('display-name = "Saved while exiting"'),
            );
          }
          expect(tester.takeException(), isNull);
        } finally {
          process.kill();
          await process.exitCode;
          await lines.cancel();
          await tester.pumpWidget(const SizedBox.shrink());
          await service.close();
          await runtime.close();
        }
      }),
      skip: !Platform.isLinux,
    );
  }

  testWidgets(
    'Global Settings opens before a Project with no plugins and fences the Command Palette shortcut',
    (tester) => tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'adele-empty-settings-application-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final roots = _configurationRoots(directory);
      final runtime = NativeAdeleRuntime();
      addTearDown(runtime.close);
      try {
        late Future<void> starting;
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            configurationRoots: roots,
            bootstrapPlugins: (plugins) => starting = plugins.start(
              installationRoot: '${directory.path}/missing',
            ),
          ),
        );
        await starting;
        await tester.pumpAndSettle();
        final shell = tester.element(find.byType(AdeleShell));
        expect(find.text('No Project is open'), findsOneWidget);
        expect(runtime.plugins.catalog!.installations, isEmpty);
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            configurationRoots: _configurationRoots(
              Directory('${directory.path}/unused'),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('settings-button')));
        await _settingsUntil(
          tester,
          () => find
              .text('No settings are available from installed plugins.')
              .evaluate()
              .isNotEmpty,
        );
        expect(find.byType(GlobalSettingsDialog), findsOneWidget);
        expect(find.text('Global Settings'), findsOneWidget);
        expect(find.byKey(const ValueKey('settings-reload')), findsOneWidget);
        expect(
          find.text('${roots.configurationRoot}/settings.toml'),
          findsOneWidget,
          reason:
              'Even lazy Settings uses the roots selected at application mount.',
        );
        expect(find.text('Enable Code Folding'), findsNothing);
        final settings = tester.element(find.byType(GlobalSettingsDialog));
        final search = find.byKey(const ValueKey('settings-search'));
        await tester.enterText(search, 'keep this search');
        await tester.pumpAndSettle();
        final editable = tester.widget<EditableText>(
          find.descendant(of: search, matching: find.byType(EditableText)),
        );
        expect(await sendPaletteShortcut(tester), isFalse);
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsNothing);
        expect(
          tester.element(find.byType(GlobalSettingsDialog)),
          same(settings),
        );
        expect(editable.focusNode.hasPrimaryFocus, isTrue);
        expect(editable.controller.text, 'keep this search');
        await tester.tap(find.byTooltip('Close Settings'));
        await tester.pumpAndSettle();
        expect(find.byType(GlobalSettingsDialog), findsNothing);
        expect(tester.element(find.byType(AdeleShell)), same(shell));
        expect(find.text('No Project is open'), findsOneWidget);
        expect(find.byType(MainContentHost), findsNothing);
        expect(await sendPaletteShortcut(tester), isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsOneWidget);
        expect(find.byType(GlobalSettingsDialog), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(CommandPalette), findsNothing);
        for (final root in [
          roots.configurationRoot,
          roots.localStateRoot,
          roots.localDataRoot,
          roots.cacheRoot,
        ]) {
          expect(await Directory(root).exists(), isFalse);
        }
        expect(tester.takeException(), isNull);
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
      }
    }),
  );

  testWidgets(
    'Global Settings repairs an invalid stock value with its frontend unavailable',
    (tester) => tester.runAsync(() async {
      const sourceId = 'dev.adele.source-editor';
      const folding = '$sourceId.enable-folding';
      final directory = await Directory.systemTemp.createTemp(
        'adele-unavailable-settings-application-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final roots = _configurationRoots(directory);
      final installed = Directory('${directory.path}/installed/source');
      await publishStockPluginInstallation(
        repositoryRoot: Directory.current.parent,
        installationDirectory: installed,
        pluginId: sourceId,
        displayName: 'Source',
        frontend: true,
      );
      await File('${installed.path}/frontend.evc').writeAsBytes([0]);
      final file = File('${roots.configurationRoot}/settings.toml');
      await file.parent.create(recursive: true);
      const unknown = '"dev.unavailable.plugin.value" = [1, 2] # keep\n';
      const original = '# user settings\n"$folding" = "invalid"\n$unknown';
      await file.writeAsString(original);
      final runtime = NativeAdeleRuntime();
      addTearDown(runtime.close);
      try {
        late Future<void> starting;
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            configurationRoots: roots,
            bootstrapPlugins: (plugins) => starting = plugins.start(
              installationRoot: '${directory.path}/installed',
            ),
          ),
        );
        await starting;
        await tester.pumpAndSettle();
        expect(runtime.plugins.catalog!.issues, isEmpty);
        expect(
          runtime.plugins.catalog!.settings.definitions.single.id.value,
          folding,
        );
        expect(runtime.extensions.discover(mainContentContributions), isEmpty);
        expect(find.text('No Project is open'), findsOneWidget);
        final applicationState = tester.state(find.byType(AdeleApplication));
        final replacementRoots = _configurationRoots(
          Directory('${directory.path}/unused'),
        );
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            configurationRoots: replacementRoots,
          ),
        );
        expect(
          tester.state(find.byType(AdeleApplication)),
          same(applicationState),
        );
        await tester.tap(find.byKey(const ValueKey('settings-button')));
        final reset = find.byKey(const ValueKey('setting-reset-$folding'));
        await _settingsUntil(tester, () => reset.evaluate().isNotEmpty);
        expect(find.text('Global Settings'), findsOneWidget);
        expect(find.text('Enable Code Folding'), findsOneWidget);
        expect(
          find.text('Global override is invalid; no effective value.'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('setting-input-$folding')),
          findsNothing,
        );
        expect(await file.readAsString(), original);
        await tester.ensureVisible(reset);
        await tester.tap(reset);
        await _settingsUntil(
          tester,
          () => find
              .byKey(const ValueKey('setting-input-$folding'))
              .evaluate()
              .isNotEmpty,
        );
        expect(
          tester
              .widget<Switch>(
                find.byKey(const ValueKey('setting-input-$folding')),
              )
              .value,
          isFalse,
        );
        expect(await file.readAsString(), isNot(contains(folding)));
        expect(await file.readAsString(), contains(unknown));
        expect(
          await Directory(replacementRoots.configurationRoot).exists(),
          isFalse,
          reason: 'Rebuilds must not replace the startup configuration roots.',
        );
        expect(
          find.text('Restart ADELE to apply configuration changes.'),
          findsOneWidget,
        );
        expect(runtime.extensions.discover(mainContentContributions), isEmpty);
        expect(
          runtime.extensions.discover(displaySourceFileContributions),
          isEmpty,
        );
        await tester.tap(find.byTooltip('Close Settings'));
        await tester.pumpAndSettle();
        expect(find.byType(GlobalSettingsDialog), findsNothing);
        expect(find.text('No Project is open'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await runtime.close();
      }
    }),
    skip: !Platform.isLinux,
  );

  for (final failure in [
    'malformed records',
    'missing records',
    'scalar settings',
    'installation',
    'frontend',
    'backend',
  ]) {
    testWidgets(
      'Global Settings routes $failure discovery diagnostics independently',
      (tester) => tester.runAsync(() async {
        const owner = 'dev.adele.source-editor';
        const setting = '$owner.enable-folding';
        final recordFailure = failure.endsWith('records');
        final scalarFailure = failure == 'scalar settings';
        final installationFailure = failure == 'installation';
        final componentFailure = failure == 'frontend' || failure == 'backend';
        final hasSettings = !scalarFailure && !installationFailure;
        final directory = await Directory.systemTemp.createTemp(
          'adele-settings-diagnostics-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final roots = _configurationRoots(directory);
        final installed = Directory('${directory.path}/installed/source');
        final openai = Directory('${directory.path}/installed/openai');
        await publishStockPluginInstallation(
          repositoryRoot: Directory.current.parent,
          installationDirectory: installed,
          pluginId: owner,
          displayName: 'Source',
        );
        await publishStockPluginInstallation(
          repositoryRoot: Directory.current.parent,
          installationDirectory: openai,
          pluginId: 'dev.adele.openai',
          displayName: 'OpenAI',
        );
        final affected = recordFailure ? openai : installed;
        final manifestFile = File(
          '${affected.path}/adele_plugin.installation.json',
        );
        final manifest =
            jsonDecode(await manifestFile.readAsString())
                as Map<String, dynamic>;
        if (recordFailure) {
          final schema = File('${openai.path}/records.schema.json');
          if (failure == 'malformed records') {
            await schema.writeAsString('{}');
          } else {
            await schema.delete();
          }
        } else if (scalarFailure) {
          await File(
            '${installed.path}/settings.schema.json',
          ).writeAsString('{}');
        } else if (installationFailure) {
          manifest['manifestVersion'] = 2;
        } else {
          manifest['components'] = {
            failure: {
              'artifact': 'missing.${failure == 'frontend' ? 'evc' : 'aot'}',
            },
          };
        }
        await manifestFile.writeAsString(jsonEncode(manifest));

        final runtime = NativeAdeleRuntime();
        addTearDown(runtime.close);
        try {
          late Future<void> starting;
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              configurationRoots: roots,
              readChatGptConfiguration: () => null,
              bootstrapPlugins: (plugins) => starting = plugins.start(
                installationRoot: '${directory.path}/installed',
              ),
            ),
          );
          await starting;
          await tester.pumpAndSettle();
          final catalog = runtime.plugins.catalog!;
          final issue = catalog.issues.single;
          expect(issue.installationDirectory.path, affected.path);
          expect(issue.isRecordsSchemaIssue, recordFailure);
          expect(issue.isSettingsSchemaIssue, scalarFailure);
          expect(
            issue.component,
            componentFailure
                ? failure == 'frontend'
                      ? PreparedPluginComponent.frontend
                      : PreparedPluginComponent.backend
                : isNull,
          );
          expect(catalog.installations, hasLength(installationFailure ? 1 : 2));
          expect(
            catalog.settings.definitions.map((value) => value.id.value),
            hasSettings ? [setting] : isEmpty,
          );
          if (!installationFailure) {
            final source = catalog.installations.singleWhere(
              (value) => value.metadata.id.value == owner,
            );
            expect(source.recordsSchema, isNull);
            expect(source.backendArtifactUri, isNull);
            expect(source.frontend, isNull);
          }
          expect(
            catalog.records.definitions.map((value) => value.id.value),
            recordFailure ? isEmpty : ['dev.adele.openai.api-key'],
          );
          expect(runtime.plugins.state, ApplicationPluginState.ready);
          expect(runtime.plugins.host, isNull);
          expect(runtime.plugins.backends, isEmpty);

          await tester.tap(find.byKey(const ValueKey('settings-button')));
          await _settingsUntil(
            tester,
            () => hasSettings
                ? find.text('Enable Code Folding').evaluate().isNotEmpty
                : find
                      .text('No settings are available from installed plugins.')
                      .evaluate()
                      .isNotEmpty,
          );
          expect(find.byType(GlobalSettingsDialog), findsOneWidget);
          final warning = find.textContaining(
            'Setting declarations unavailable',
          );
          expect(
            warning,
            scalarFailure || installationFailure
                ? findsOneWidget
                : findsNothing,
          );
          final dialog = tester.widget<GlobalSettingsDialog>(
            find.byType(GlobalSettingsDialog),
          );
          expect(
            dialog.declarationIssues!(),
            scalarFailure || installationFailure
                ? ['${issue.installationDirectory.path}: ${issue.message}']
                : isEmpty,
          );
          expect(
            dialog.recordDeclarationIssues!(),
            recordFailure || installationFailure
                ? ['${issue.installationDirectory.path}: ${issue.message}']
                : isEmpty,
          );
          expect(
            find.textContaining('Record declarations unavailable'),
            findsNothing,
            reason:
                'Record diagnostics belong to record management, not Preferences.',
          );

          if (hasSettings) {
            final input = find.byKey(const ValueKey('setting-input-$setting'));
            expect(tester.widget<Switch>(input).value, isFalse);
            if (Platform.isLinux) {
              await tester.ensureVisible(input);
              await tester.tap(input);
              final save = find.byKey(const ValueKey('setting-save-$setting'));
              await tester.ensureVisible(save);
              await tester.tap(save);
              await _settingsUntil(
                tester,
                () => find.text('Effective value: true').evaluate().isNotEmpty,
              );
              expect(tester.widget<Switch>(input).value, isTrue);
              expect(
                await File(
                  '${roots.configurationRoot}/settings.toml',
                ).readAsString(),
                contains('"$setting" = true'),
              );
            }
          }
          if (recordFailure || installationFailure) {
            await _settingsSection(tester, 'Record diagnostics');
            expect(
              find.textContaining('Record declarations unavailable'),
              findsOneWidget,
            );
            expect(find.textContaining(issue.message), findsOneWidget);
            expect(
              find.textContaining('Setting declarations unavailable'),
              findsNothing,
            );
          }
          if (!recordFailure) {
            await _settingsSection(tester, 'Providers');
            await _settingsUntil(
              tester,
              () => find
                  .byKey(const ValueKey('records-add-providers'))
                  .evaluate()
                  .isNotEmpty,
            );
            if (Platform.isLinux) {
              await _createProviderRecord(tester, 'work-openai', 'Work OpenAI');
              expect(
                await File(
                  '${roots.configurationRoot}/providers/work-openai.toml',
                ).readAsString(),
                contains('display-name = "Work OpenAI"'),
              );
            }
          } else {
            expect(
              await Directory('${roots.configurationRoot}/providers').exists(),
              isFalse,
            );
          }
          // Routing never consumes or deletes the original catalog diagnostic.
          expect(runtime.plugins.catalog, same(catalog));
          expect(catalog.issues.single, same(issue));
          expect(tester.takeException(), isNull);
          expect(
            await tester.binding.handleRequestAppExit(),
            AppExitResponse.exit,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await runtime.close();
        }
      }),
    );
  }

  for (final recordsConflict in [false, true]) {
    testWidgets(
      'Global Settings isolates ${recordsConflict ? 'record collection label' : 'scalar ID'} aggregation conflicts',
      (tester) => tester.runAsync(() async {
        await tester.binding.setSurfaceSize(const Size(1100, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const sourceId = 'dev.adele.source-editor';
        const folding = '$sourceId.enable-folding';
        final directory = await Directory.systemTemp.createTemp(
          'adele-settings-aggregation-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final roots = _configurationRoots(directory);
        final source = Directory('${directory.path}/installed/source');
        final openai = Directory('${directory.path}/installed/openai');
        for (final (installed, id, label) in [
          (source, sourceId, 'Source'),
          (openai, 'dev.adele.openai', 'OpenAI'),
        ]) {
          await publishStockPluginInstallation(
            repositoryRoot: Directory.current.parent,
            installationDirectory: installed,
            pluginId: id,
            displayName: label,
          );
        }
        if (recordsConflict) {
          final manifestFile = File(
            '${source.path}/adele_plugin.installation.json',
          );
          final manifest =
              jsonDecode(await manifestFile.readAsString())
                  as Map<String, dynamic>;
          manifest['recordsSchema'] = 'records.schema.json';
          final schema =
              jsonDecode(
                    await File(
                      '${openai.path}/records.schema.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          final type =
              (schema['recordTypes'] as List).single as Map<String, dynamic>;
          type['id'] = '$sourceId.provider';
          type['collectionLabel'] = 'Conflicting provider label';
          await File(
            '${source.path}/records.schema.json',
          ).writeAsString(jsonEncode(schema));
          await manifestFile.writeAsString(jsonEncode(manifest));
        } else {
          // The stock setting is legal beneath either owner namespace. Both
          // installations remain valid; only cross-installation aggregation fails.
          final duplicate = await Directory(
            '${directory.path}/installed/duplicate',
          ).create();
          final manifest =
              jsonDecode(
                    await File(
                      '${source.path}/adele_plugin.installation.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          (manifest['metadata'] as Map<String, dynamic>)['id'] = 'dev.adele';
          await File(
            '${duplicate.path}/adele_plugin.installation.json',
          ).writeAsString(jsonEncode(manifest));
          await File(
            '${source.path}/settings.schema.json',
          ).copy('${duplicate.path}/settings.schema.json');
        }
        final runtime = NativeAdeleRuntime();
        addTearDown(runtime.close);
        try {
          late Future<void> starting;
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              configurationRoots: roots,
              readChatGptConfiguration: () => null,
              bootstrapPlugins: (plugins) => starting = plugins.start(
                installationRoot: '${directory.path}/installed',
              ),
            ),
          );
          await starting;
          await tester.pumpAndSettle();
          final catalog = runtime.plugins.catalog!;
          expect(catalog.issues, isEmpty);
          if (recordsConflict) {
            expect(
              () => catalog.records,
              throwsA(isA<ConflictingRecordCollectionLabel>()),
            );
            expect(catalog.settings.definitions.single.id.value, folding);
          } else {
            expect(() => catalog.settings, throwsA(isA<DuplicateSettingId>()));
            expect(
              catalog.records.definitions.single.id.value,
              'dev.adele.openai.api-key',
            );
          }
          expect(runtime.plugins.state, ApplicationPluginState.ready);
          expect(runtime.plugins.host, isNull);
          await tester.tap(find.byKey(const ValueKey('settings-button')));
          await _settingsUntil(
            tester,
            () => find
                .byKey(const ValueKey('settings-section'))
                .evaluate()
                .isNotEmpty,
          );
          final dialog = tester.widget<GlobalSettingsDialog>(
            find.byType(GlobalSettingsDialog),
          );
          expect(
            dialog.declarationIssues!(),
            recordsConflict ? isEmpty : hasLength(1),
          );
          expect(
            dialog.recordDeclarationIssues!(),
            recordsConflict ? hasLength(1) : isEmpty,
          );
          if (recordsConflict) {
            expect(
              find.textContaining('ConflictingRecordCollectionLabel'),
              findsNothing,
            );
            await _settingsSection(tester, 'Record diagnostics');
            expect(
              find.textContaining('ConflictingRecordCollectionLabel'),
              findsOneWidget,
            );
            await _settingsSection(tester, 'Preferences');
            final input = find.byKey(const ValueKey('setting-input-$folding'));
            await _settingsUntil(tester, () => input.evaluate().isNotEmpty);
            expect(tester.widget<Switch>(input).value, isFalse);
            await tester.ensureVisible(input);
            await tester.tap(input);
            final save = find.byKey(const ValueKey('setting-save-$folding'));
            await tester.ensureVisible(save);
            await tester.tap(save);
            await _settingsUntil(
              tester,
              () => find.text('Effective value: true').evaluate().isNotEmpty,
            );
            expect(
              await File(
                '${roots.configurationRoot}/settings.toml',
              ).readAsString(),
              contains('"$folding" = true'),
            );
            expect(
              await Directory('${roots.configurationRoot}/providers').exists(),
              isFalse,
            );
          } else {
            expect(find.textContaining('DuplicateSettingId'), findsOneWidget);
            expect(
              find.byKey(const ValueKey('setting-input-$folding')),
              findsNothing,
            );
            await _settingsSection(tester, 'Providers');
            await _settingsUntil(
              tester,
              () => find
                  .byKey(const ValueKey('records-add-providers'))
                  .evaluate()
                  .isNotEmpty,
            );
            await _createProviderRecord(tester, 'work-openai', 'Work OpenAI');
            expect(
              await File('${roots.configurationRoot}/settings.toml').exists(),
              isFalse,
            );
            expect(
              await File(
                '${roots.configurationRoot}/providers/work-openai.toml',
              ).readAsString(),
              contains('display-name = "Work OpenAI"'),
            );
          }
          expect(find.text('No Project is open'), findsOneWidget);
          expect(
            runtime.registry.providersFor(modelProviderCapability),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
          expect(
            await tester.binding.handleRequestAppExit(),
            AppExitResponse.exit,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await runtime.close();
        }
      }),
      skip: !Platform.isLinux,
    );
  }

  for (final bool missing in [false, true]) {
    testWidgets(
      '${missing ? 'missing' : 'empty'} installation root boots without plugins and accepts a later selector',
      (WidgetTester tester) async {
        final Directory directory = Directory.systemTemp.createTempSync(
          'adele-empty-application-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final NativeAdeleRuntime runtime = NativeAdeleRuntime();
        addTearDown(runtime.close);
        final Uri source = directory.uri;
        late Future<void> starting;
        await tester.runAsync(() async {
          await tester.pumpWidget(
            AdeleApplication(
              createRuntime: () => runtime,
              bootstrapPlugins: (plugins) => starting = plugins.start(
                installationRoot: missing
                    ? '${directory.path}/missing'
                    : directory.path,
                dartaotruntimeExecutable: '${directory.path}/missing-runtime',
                hostArtifactPath: '${directory.path}/missing-host.aot',
              ),
            ),
          );
          await starting;
        });
        await tester.pumpAndSettle();
        expect(runtime.plugins.state, ApplicationPluginState.ready);
        expect(runtime.plugins.failure, isNull);
        expect(runtime.plugins.host, isNull);
        expect(runtime.plugins.catalog!.installations, isEmpty);
        expect(runtime.plugins.catalog!.issues, isEmpty);
        expect(runtime.plugins.backends, isEmpty);
        expect(runtime.extensions.discover(mainContentContributions), isEmpty);
        expect(
          runtime.extensions.discover(toolActivityInspectionContributions),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(
            toolActivityCompactPresentationContributions,
          ),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(
            modelNativeActivityPresentationContributions,
          ),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(
            modelNativeActivityCompactPresentationContributions,
          ),
          isEmpty,
        );
        expect(find.text('ADELE'), findsOneWidget);
        expect(find.text('No Project is open'), findsOneWidget);
        expect(find.text('Open Local Directory...'), findsNothing);
        expect(
          runtime.registry.providersFor(environmentProviderCapability),
          isEmpty,
        );
        expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
        expect(runtime.extensions.discover(modelToolContributions), isEmpty);
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);

        expect(
          runtime.extensions.discover(orchestrationStrategyContributions),
          isEmpty,
        );
        expect(
          runtime.extensions.discover(projectSelectorContributions),
          isEmpty,
        );
        expect(
          find.text('No Project selectors are available.'),
          findsOneWidget,
        );
        expect(find.byType(FilledButton), findsNothing);
        expect(tester.takeException(), isNull);

        final provider = TestProjectProvider(runtime.registry);
        addTearDown(provider.close);
        final ExtensionRegistration selector = runtime.extensions.register(
          point: projectSelectorContributions,
          id: ExtensionId('dev.adele.test.empty-root-selector'),
          value: ProjectSelectorContribution(
            displayName: 'Open Test Project',
            projectProviderId: provider.providerId,
            selectProject: () async => source,
          ),
        );
        addTearDown(selector.close);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open Test Project'));
        await tester.pumpAndSettle();
        final Project project = tester
            .widget<AdeleShell>(find.byType(AdeleShell))
            .project!;
        expect(project.sourceLocation, source);
        expect(runtime.store.project(project.id), same(project));
        expect(provider.calls, [source]);
        expect(
          File.fromUri(
            source.resolve(TestProjectProvider.databaseRelativePath),
          ).existsSync(),
          isTrue,
        );
        expect(runtime.store.tasksFor(project.id), isEmpty);
        expect(
          find.byKey(const ValueKey('project-breadcrumb')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Task Browser is unavailable'),
          findsOneWidget,
        );
        expect(tester.widget<AdeleShell>(find.byType(AdeleShell)).task, isNull);
        expect(find.text('New Task'), findsNothing);
        expect(
          find.textContaining('Task Environment support is unavailable.'),
          findsNothing,
        );
        expect(find.textContaining('Starting Task Environment'), findsNothing);
        expect(tester.takeException(), isNull);

        expect(
          await tester.runAsync(tester.binding.handleRequestAppExit),
          AppExitResponse.exit,
        );
        expect(runtime.plugins.state, ApplicationPluginState.closed);
        expect(runtime.extensions.discover(modelToolContributions), isEmpty);
        expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
        await selector.close();
        expect(
          runtime.extensions.discover(projectSelectorContributions),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(runtime.store.project(project.id), same(project));
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }

  for (final bool backendFailure in [false, true]) {
    testWidgets(
      'owns discovered presentation with ${backendFailure ? 'failed' : 'absent'} backend',
      (WidgetTester tester) async {
        final Directory directory = Directory.systemTemp.createTempSync(
          'openai-activation-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        // Loading prepared bytes is independent of per-view decoding and backend work.
        final installation = Directory('${directory.path}/openai')
          ..createSync();
        File('${installation.path}/frontend.evc').writeAsBytesSync([1, 2, 3]);
        if (backendFailure) {
          File('${installation.path}/backend.aot').writeAsBytesSync([0]);
        }
        File(
          '${installation.path}/adele_plugin.installation.json',
        ).writeAsStringSync(
          jsonEncode({
            'manifestVersion': 1,
            'metadata': {
              'id': 'dev.adele.openai',
              'version': '0.1.0',
              'displayName': 'OpenAI',
            },
            'components': {
              if (backendFailure) 'backend': {'artifact': 'backend.aot'},
              'frontend': {
                'artifact': 'frontend.evc',
                'presentations': stockFrontendDescriptors['dev.adele.openai'],
              },
            },
          }),
        );
        final NativeAdeleRuntime runtime = NativeAdeleRuntime();
        addTearDown(runtime.close);
        try {
          late Future<void> backendSettled;
          await tester.runAsync(() async {
            final activated = runtime.extensions.changes.firstWhere(
              (_) => runtime.extensions
                  .discover(modelNativeActivityPresentationContributions)
                  .isNotEmpty,
            );
            await tester.pumpWidget(
              AdeleApplication(
                createRuntime: () => runtime,
                bootstrapPlugins: (plugins) {
                  final starting = plugins.start(
                    installationRoot: directory.path,
                    dartaotruntimeExecutable:
                        '${directory.path}/missing-runtime',
                    hostArtifactPath: '${directory.path}/missing-host.aot',
                  );
                  backendSettled = backendFailure
                      ? expectLater(starting, throwsA(isA<ProcessException>()))
                      : starting;
                  return starting;
                },
              ),
            );
            await activated.timeout(const Duration(seconds: 10));
            await backendSettled;
          });
          await tester.pumpAndSettle();
          final binding = runtime.extensions
              .discover(modelNativeActivityPresentationContributions)
              .single;
          final compactBinding = runtime.extensions
              .discover(modelNativeActivityCompactPresentationContributions)
              .single;
          expect(binding.validate, returnsNormally);
          expect(compactBinding.validate, returnsNormally);
          expect(runtime.plugins.catalog!.installations, hasLength(1));
          expect(runtime.plugins.host, isNull);
          expect(
            runtime.plugins.state,
            backendFailure
                ? ApplicationPluginState.failed
                : ApplicationPluginState.ready,
          );
          expect(
            compactBinding.value.presentationKind,
            binding.value.presentationKind,
          );
          expect(runtime.extensions.discover(modelToolContributions), isEmpty);
          expect(find.text('No Project is open'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final retired = runtime.extensions.changes.firstWhere(
              (_) =>
                  runtime.extensions
                      .discover(modelNativeActivityPresentationContributions)
                      .isEmpty &&
                  runtime.extensions
                      .discover(
                        modelNativeActivityCompactPresentationContributions,
                      )
                      .isEmpty,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await retired.timeout(const Duration(seconds: 10));
          });
          await tester.pumpAndSettle();
          expect(binding.validate, throwsA(isA<StaleExtensionBinding>()));
          expect(
            compactBinding.validate,
            throwsA(isA<StaleExtensionBinding>()),
          );
        } finally {
          // Settle failed bootstrap/frontend ownership before leaving the test zone.
          await tester.runAsync(() async {
            try {
              if (find.byType(AdeleApplication).evaluate().isNotEmpty) {
                await tester.binding.handleRequestAppExit();
              }
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await runtime.close();
            }
          });
          await tester.pumpAndSettle();
        }
      },
    );
  }

  for (final (name, launch) in [
    ('normal', application.main),
    ('development', development.main),
  ]) {
    testWidgets('$name entrypoint renders the pre-Project shell', (
      WidgetTester tester,
    ) async {
      launch();
      await tester.pumpAndSettle();

      final theme = Theme.of(tester.element(find.byType(Scaffold)));
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.light);
      expect(find.text('ADELE'), findsOneWidget);
      expect(find.text('No Project is open'), findsOneWidget);
      expect(find.text('Open Local Directory...'), findsNothing);
      expect(find.text('No Project selectors are available.'), findsOneWidget);
      expect(find.text('No workspace is open'), findsNothing);
      expect(find.text('No plugins are loaded'), findsNothing);
      expect(find.text('Phase 0'), findsNothing);

      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('owns one provider-free runtime across rebuilds and disposal', (
    WidgetTester tester,
  ) async {
    final NativeAdeleRuntime runtime = NativeAdeleRuntime();
    int creations = 0;
    final navigator = GlobalKey<NavigatorState>();
    final contexts = <WindowSessionContext>[];
    var detachments = 0;
    void Function() attach(WindowSessionContext context) {
      contexts.add(context);
      final detach = context.observe((_) => fail('No Session was selected.'));
      return () {
        expect(context.isActive, isFalse);
        detach();
        detachments++;
      };
    }

    NativeAdeleRuntime createRuntime() {
      creations++;
      return runtime;
    }

    expect(
      runtime.extensions.discover(modelToolContributions),
      isEmpty,
      reason: 'A bare runtime has no model tools before plugin bootstrap.',
    );
    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: createRuntime,
        attachSessionContext: attach,
        navigatorKey: navigator,
      ),
    );
    final mountedNavigator = navigator.currentState;
    expect(mountedNavigator, isNotNull);
    final context = contexts.single;
    expect(context.snapshot.session, isNull);
    expect(context.snapshot.revision, 0);
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(
      runtime.registry.providersFor(environmentProviderCapability),
      isEmpty,
    );
    expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
    expect(find.text('No Project selectors are available.'), findsOneWidget);
    expect(find.text('No Project is open'), findsOneWidget);

    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: createRuntime,
        attachSessionContext: attach,
        navigatorKey: GlobalKey<NavigatorState>(),
      ),
    );
    expect(navigator.currentState, same(mountedNavigator));
    expect(creations, 1);
    expect(contexts, [same(context)]);
    expect(detachments, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(context.isActive, isFalse);
    expect(() => context.snapshot, throwsStateError);
    expect(() => context.observe((_) {}), throwsStateError);
    expect(detachments, 1);
    expect(navigator.currentState, isNull);
    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
    await tester.pumpWidget(AdeleApplication(attachSessionContext: attach));
    expect(contexts, hasLength(2));
    expect(contexts.last, isNot(same(context)));
    expect(contexts.last.snapshot.revision, 0);
    expect(context.isActive, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(detachments, 2);
  });

  testWidgets('graceful application exit awaits runtime retirement', (
    WidgetTester tester,
  ) async {
    late NativeAdeleRuntime runtime;
    late WindowSessionContext context;
    final cleanup = Completer<void>();
    var detachments = 0;
    bool? activeAtDetach;
    await tester.pumpWidget(
      AdeleApplication(
        createRuntime: () => runtime = NativeAdeleRuntime(),
        attachSessionContext: (value) {
          context = value;
          return () {
            activeAtDetach = context.isActive;
            detachments++;
            return cleanup.future;
          };
        },
      ),
    );

    final exiting = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(context.isActive, isFalse);
    expect(() => context.snapshot, throwsStateError);
    expect(detachments, 1);
    expect(activeAtDetach, isFalse);
    expect(runtime.plugins.state, isNot(ApplicationPluginState.closed));
    cleanup.complete();
    expect(await exiting, AppExitResponse.exit);

    expect(
      runtime.extensions.discover(orchestrationStrategyContributions),
      isEmpty,
    );
    expect(runtime.extensions.discover(inferenceContextSources), isEmpty);
    expect(runtime.extensions.discover(modelToolContributions), isEmpty);
    expect(runtime.extensions.discover(projectSelectorContributions), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(detachments, 1);
    expect(tester.takeException(), isNull);
  });

  for (final cleanup in ['throws', 'pending', 'late failure']) {
    testWidgets('application exit bounds $cleanup cleanup and joins repeats', (
      tester,
    ) async {
      final runtime = NativeAdeleRuntime();
      final credentials = CredentialService(_CredentialStorage());
      final gate = Completer<void>();
      late WindowSessionContext context;
      var detachments = 0;
      var exited = false;
      await tester.pumpWidget(
        AdeleApplication(
          createRuntime: () => runtime,
          createCredentials: () => credentials,
          bootstrapPlugins: (_) async {},
          exitTimeout: const Duration(milliseconds: 100),
          attachSessionContext: (value) {
            context = value;
            return () {
              detachments++;
              if (cleanup == 'throws') throw StateError('cleanup fixture');
              return gate.future;
            };
          },
        ),
      );
      final exiting = tester.binding.handleRequestAppExit().then((response) {
        exited = true;
        return response;
      });
      await tester.pump();
      expect(find.text('Exit with active work?'), findsNothing);
      expect(find.text('Exiting ADELE...'), findsOneWidget);
      expect(context.isActive, isFalse);
      expect(detachments, 1);
      // This independent owner fences immediately even if native detach stalls.
      await expectLater(
        credentials.contains(CredentialReference.generate()),
        throwsA(isA<CredentialFailure>()),
      );
      final repeated = tester.binding.handleRequestAppExit();
      if (cleanup != 'throws') {
        expect(exited, isFalse);
        await tester.pump(const Duration(milliseconds: 99));
        expect(exited, isFalse);
        expect(runtime.plugins.state, isNot(ApplicationPluginState.closed));
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(await exiting, AppExitResponse.exit);
      expect(await repeated, AppExitResponse.exit);
      expect(
        tester.takeException(),
        cleanup == 'throws' ? isA<StateError>() : isA<TimeoutException>(),
      );
      await tester.pump();
      expect(runtime.plugins.state, ApplicationPluginState.closed);
      expect(detachments, 1);
      if (cleanup == 'late failure') {
        gate.completeError(StateError('late cleanup fixture'));
        await tester.pump();
      }
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(detachments, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Session choices are explicit, usable and revalidated before publication',
    (tester) async {
      final runtime = NativeAdeleRuntime();
      final source = Directory.systemTemp.createTempSync(
        'adele-session-project-',
      );
      final projectProvider = TestProjectProvider(runtime.registry);
      addTearDown(() async {
        if (runtime.plugins.state != ApplicationPluginState.closed) {
          await runtime.close();
        }
        await projectProvider.close();
        source.deleteSync(recursive: true);
      });
      final registrations = <ExtensionRegistration>[];
      addTearDown(() async {
        for (final registration in registrations) {
          await registration.close();
        }
      });
      final environment = runtime.registry.register(
        provider: ProviderDescriptor(
          id: ProviderId('dev.example.environment'),
          capability: environmentProviderCapability,
          pluginId: 'dev.example.environment',
          displayName: 'Test environment',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: AdeleRequestChannelEndpoint(
          channel: _EnvironmentChannel(),
          serviceId: environmentProviderServiceId,
          isAvailable: () => true,
        ),
      );
      addTearDown(environment.close);
      registrations.add(
        runtime.extensions.register(
          point: projectSelectorContributions,
          id: ExtensionId('dev.example.selector'),
          value: ProjectSelectorContribution(
            displayName: 'Open fixture',
            projectProviderId: projectProvider.providerId,
            selectProject: () async => source.uri,
          ),
        ),
      );
      final presented = <Session>[];
      final commandGate = Completer<void>();
      late WindowSessionCommandFixture consumer;
      var consumerDetachments = 0;
      ExtensionRegistration? contribution(String name, {bool strategy = true}) {
        final key = name.toLowerCase();
        final id = OrchestrationStrategyId('dev.example.$key');
        ExtensionRegistration? strategyRegistration;
        if (strategy) {
          strategyRegistration = runtime.extensions.register(
            point: orchestrationStrategyContributions,
            id: ExtensionId('dev.example.$key.strategy'),
            value: OrchestrationStrategyContribution(
              strategyId: id,
              displayName: name,
              materialize: (_) => throw StateError('No Run should start.'),
            ),
          );
          registrations.add(strategyRegistration);
        }
        registrations.add(
          runtime.extensions.register(
            point: mainContentContributions,
            id: ExtensionId('dev.example.$key.presentation'),
            value: MainContentContribution(
              order: 100,
              attach: (access) {
                if (access.session.strategyId != id) return;
                access.open(
                  MainContentPane(
                    id: 'fixture',
                    title: name,
                    createPresentation: () {
                      presented.add(access.session);
                      return Column(
                        children: [
                          Text('$name presentation'),
                          const TextField(key: ValueKey('session-input')),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
        return strategyRegistration;
      }

      await tester.runAsync(() async {
        final artifact = await File('${source.path}/browser.evc').writeAsBytes(
          await compileTaskBrowserFrontend(
            repositoryRoot: Directory.current.parent,
          ),
        );
        final installations = await prepareFrontendInstallations(
          root: Directory('${source.path}/installed'),
          artifacts: {'dev.adele.plugin.task-browser': artifact},
        );
        final registered = runtime.extensions.changes.firstWhere(
          (_) =>
              runtime.extensions.discover(taskBrowserContributions).isNotEmpty,
        );
        await tester.pumpWidget(
          AdeleApplication(
            createRuntime: () => runtime,
            attachSessionContext: (context) {
              consumer = WindowSessionCommandFixture(
                context: context,
                registry: runtime.extensions,
                gate: commandGate,
              );
              return () {
                consumerDetachments++;
                return consumer.close();
              };
            },
            bootstrapPlugins: (plugins) =>
                plugins.start(installationRoot: installations.path),
          ),
        );
        await registered.timeout(const Duration(seconds: 10));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open fixture'));
      await tester.pumpAndSettle();
      final commands = CommandResolver(runtime.extensions);
      final toggleConsole = commands.resolve(toggleConsoleCommandId);
      expect(consumer.initialSnapshot.session, isNull);
      expect(consumer.initialSnapshot.revision, 0);
      expect(consumer.command.availability, CommandAvailability.hidden);
      expect(toggleConsole.availability, CommandAvailability.hidden);
      await sendPaletteShortcut(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsOneWidget);
      expect(find.text('Toggle Console'), findsNothing);
      expect(find.text(WindowSessionCommandFixture.label), findsNothing);
      await tester.tap(find.byTooltip('Close Command Palette'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Generic task');
      await sendPaletteShortcut(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('command-palette-search')),
            )
            .focusNode!
            .hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Generic task'), findsOneWidget);
      await tester.tap(find.text('Create Task'));
      await tester.pumpAndSettle();
      final task = tester.widget<AdeleShell>(find.byType(AdeleShell)).task!;
      expect(runtime.store.sessionsForTask(task.id), isEmpty);
      expect(
        find.text('No Session creation strategy is available.'),
        findsOneWidget,
      );
      contribution('Unavailable', strategy: false);
      final first = contribution('First')!;
      contribution('Second');
      await tester.pumpAndSettle();
      expect(find.text('Unavailable'), findsNothing);
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      final stale = tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'First'))
          .onTap!;
      await first.close();
      stale();
      await tester.pumpAndSettle();
      expect(find.byType(MainContentHost), findsNothing);
      expect(presented, isEmpty);
      expect(runtime.store.sessionsForTask(task.id), isEmpty);
      await tester.tap(find.text('New Second Session'));
      await tester.pumpAndSettle();
      expect(presented.single.strategyId.value, 'dev.example.second');
      expect(
        runtime.store.session(presented.single.id),
        same(presented.single),
      );
      expect(runtime.store.sessionsForTask(task.id), [same(presented.single)]);
      final sessionA = presented.single;
      final selectionA = consumer.context.snapshot;
      expect(selectionA.session, same(sessionA));
      expect(selectionA.revision, 1);
      expect(consumer.changes, [same(selectionA)]);
      expect(
        tester.widget<MainContentHost>(find.byType(MainContentHost)).session,
        same(selectionA.session),
      );
      expect(consumer.command.availability, CommandAvailability.enabled);
      expect(find.text('Second presentation'), findsOneWidget);
      expect(runtime.registry.providersFor(modelProviderCapability), isEmpty);
      final console = tester
          .widget<WorkbenchConsole>(find.byType(WorkbenchConsole))
          .controller;
      expect(console.session, same(selectionA.session));
      expect(toggleConsole.availability, CommandAvailability.enabled);
      expect(console.visible, isTrue);
      final input = find.byKey(const ValueKey('session-input'));
      await tester.enterText(input, 'ordinary text');
      final editable = tester.widget<EditableText>(
        find.descendant(of: input, matching: find.byType(EditableText)),
      );
      expect(await sendPaletteShortcut(tester), isTrue);
      await tester.pumpAndSettle();
      expect(editable.controller.text, 'ordinary text');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(editable.focusNode.hasPrimaryFocus, isTrue);
      await tester.enterText(input, 'ordinary text after dismissal');
      expect(editable.controller.text, 'ordinary text after dismissal');
      await sendPaletteShortcut(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Toggle Console'));
      await tester.pumpAndSettle();
      expect(console.visible, isFalse);
      expect(find.byTooltip('Show console'), findsOneWidget);
      await toggleConsole.invoke();
      await tester.pumpAndSettle();
      expect(console.visible, isTrue);
      expect(consumer.changes, [same(selectionA)]);
      await sendPaletteShortcut(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text(WindowSessionCommandFixture.label));
      await tester.pumpAndSettle();
      expect(consumer.captured, [same(selectionA)]);
      expect(consumer.completed, isEmpty);
      // Start departure on the trigger key, after both modifiers are down, to
      // exercise the synchronous interaction fence before settlement/rebuild.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      tester.widget<AdeleShell>(find.byType(AdeleShell)).onTask!();
      expect(consumer.context.snapshot, same(selectionA));
      expect(console.session, same(sessionA));
      expect(toggleConsole.availability, CommandAvailability.disabled);
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await expectLater(
        toggleConsole.invoke(),
        throwsA(isA<CommandUnavailable>()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CommandPalette), findsNothing);
      expect(toggleConsole.availability, CommandAvailability.hidden);
      expect(console.visible, isTrue);
      expect(find.byType(WorkbenchConsole), findsNothing);
      expect(consumer.context.snapshot.session, isNull);
      expect(consumer.context.snapshot.revision, 2);
      expect(consumer.changes, hasLength(2));
      expect(console.session, isNull);
      expect(console.isClosed, isFalse);
      expect(consumer.command.availability, CommandAvailability.hidden);

      await tester.tap(find.text('New Second Session'));
      await tester.pumpAndSettle();
      final sessionB = consumer.context.snapshot.session!;
      expect(sessionB, isNot(same(sessionA)));
      expect(consumer.context.snapshot.revision, 3);
      expect(console.session, same(sessionB));
      expect(
        tester
            .widget<WorkbenchConsole>(find.byType(WorkbenchConsole))
            .controller,
        same(console),
      );
      commandGate.complete();
      await tester.pumpAndSettle();
      expect(consumer.completed, [same(selectionA)]);

      tester.widget<AdeleShell>(find.byType(AdeleShell)).onTask!();
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.textContaining('Session: ${sessionA.id.value}\n'),
          matching: find.byType(ListTile),
        ),
      );
      await tester.pumpAndSettle();
      expect(consumer.context.snapshot.session, same(sessionA));
      expect(consumer.context.snapshot.revision, 5);
      expect(console.session, same(sessionA));
      expect(consumer.changes.map((value) => value.revision), [1, 2, 3, 4, 5]);
      await tester.runAsync(tester.binding.handleRequestAppExit);
      expect(consumer.context.isActive, isFalse);
      expect(() => consumer.context.snapshot, throwsStateError);
      expect(consumerDetachments, 1);
      expect(console.isClosed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

PlatformStorageRoots _configurationRoots(Directory directory) =>
    PlatformStorageRoots(
      operatingSystem: Platform.operatingSystem,
      configurationRoot: '${directory.path}/config',
      localStateRoot: '${directory.path}/state',
      localDataRoot: '${directory.path}/data',
      cacheRoot: '${directory.path}/cache',
    );

Future<void> _settingsUntil(
  WidgetTester tester,
  bool Function() ready, {
  bool waitForOperation = true,
}) async {
  final clock = Stopwatch()..start();
  await tester.pump();
  while (!ready() ||
      (waitForOperation &&
          find.byType(LinearProgressIndicator).evaluate().isNotEmpty)) {
    if (clock.elapsed >= const Duration(seconds: 10)) {
      fail('Timed out waiting for Global Settings.');
    }
    await Future<void>.delayed(Duration.zero);
    await tester.pump();
  }
  if (waitForOperation) await tester.pumpAndSettle();
}

Future<void> _settingsSection(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('settings-section')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await _settingsUntil(tester, () => true);
}

Future<void> _settingsAction(WidgetTester tester, String key) async {
  final action = find.byKey(ValueKey(key));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _expandProviderRecord(WidgetTester tester, String id) async {
  if (find.byKey(ValueKey('record-edit-providers-$id')).evaluate().isNotEmpty) {
    return;
  }
  final row = find.descendant(
    of: find.byKey(ValueKey('record-providers-$id')),
    matching: find.byType(ExpansionTile),
  );
  final title = find.descendant(of: row, matching: find.byType(Text)).first;
  await tester.ensureVisible(title);
  await tester.tap(title);
  await tester.pumpAndSettle();
}

Future<void> _editProviderRecord(WidgetTester tester, String id) async {
  await _expandProviderRecord(tester, id);
  await _settingsAction(tester, 'record-edit-providers-$id');
}

Future<void> _createProviderRecord(
  WidgetTester tester,
  String id,
  String name,
) async {
  final add = find.byKey(const ValueKey('records-add-providers'));
  await _settingsUntil(
    tester,
    () => tester.widget<FilledButton>(add).onPressed != null,
  );
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('record-id-providers')), id);
  final presence = find.byKey(
    const ValueKey('record-presence-providers-display-name'),
  );
  await tester.ensureVisible(presence);
  await tester.tap(presence);
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('record-input-providers-display-name')),
    name,
  );
  await tester.pump();
  final create = find.byKey(const ValueKey('record-create-providers'));
  await tester.ensureVisible(create);
  await tester.tap(create);
  await _settingsUntil(
    tester,
    () => find.byKey(ValueKey('record-providers-$id')).evaluate().isNotEmpty,
  );
  expect(find.text(name), findsOneWidget);
}

final class _CredentialStorage implements CredentialStorageAdapter {
  final values = <CredentialReference, String>{};
  final calls = <(String, CredentialReference)>[];

  @override
  Future<bool> contains(CredentialReference reference) async {
    calls.add(('contains', reference));
    return values.containsKey(reference);
  }

  @override
  Future<String?> read(CredentialReference reference) async {
    calls.add(('read', reference));
    return values[reference];
  }

  @override
  Future<void> write(
    CredentialReference reference,
    CredentialSecret secret,
  ) async {
    calls.add(('write', reference));
    values[reference] = secret.reveal();
  }

  @override
  Future<void> delete(CredentialReference reference) async {
    calls.add(('delete', reference));
    values.remove(reference);
  }
}

final class _EnvironmentChannel implements AdeleRequestChannel {
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      {'providerState': <String, Object?>{}, 'initialState': null};
}
