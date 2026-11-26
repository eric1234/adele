import 'dart:io';

import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/prepared_settings.dart';
import 'package:adele_desktop/frontend/application_frontend_bootstrap.dart';
import 'package:adele_desktop/ui/settings/record_collection_panel.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../../../app/tool/model_configuration_frontend_compiler.dart';
import '../../../../../tools/backend_artifacts.dart';

const _plugin = 'dev.adele.plugin.model-configuration';
const _suffix = 'model-presets-work';
const _initial = {'provider-id': 'local.work', 'model-id': 'alpha'};

void main() {
  testWidgets(
    'the prepared editor changes one unsaved pair with no backend; only Save persists it',
    (tester) => tester.runAsync(() async {
      final root = Directory.current.parent.parent.parent.parent;
      final temp = await Directory.systemTemp.createTemp('model-reference-');
      addTearDown(() => temp.delete(recursive: true));
      final installations = Directory('${temp.path}/installed');
      final directory = Directory('${installations.path}/model-configuration');
      await publishStockPluginInstallation(
        repositoryRoot: root,
        installationDirectory: directory,
        pluginId: _plugin,
        displayName: 'Model Configuration',
        frontend: true,
        backend: true,
      );
      await File('${directory.path}/frontend.evc').writeAsBytes(
        await compileModelConfigurationFrontend(repositoryRoot: root),
      );
      // No backend.aot is installed, so there can be no backend lookup or Run.
      final catalog = await PreparedPluginCatalog.discover(installations.path);
      expect(catalog.issues.single.component, PreparedPluginComponent.backend);
      final roots = PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: '${temp.path}/config',
        localStateRoot: '${temp.path}/state',
        localDataRoot: '${temp.path}/data',
        cacheRoot: '${temp.path}/cache',
      );
      final frontends = ApplicationFrontendBootstrap(
        extensions: ExtensionRegistry(),
        loadSettings: (catalog) =>
            PreparedSettingsSnapshot.load(catalog, roots: roots),
      );
      addTearDown(frontends.close);
      await frontends.start(catalog);
      final generation = frontends.generations.single;
      expect(
        generation.state,
        InstalledFrontendState.active,
        reason: '${generation.failure}',
      );
      final collection = RecordCollectionId('model-presets');
      final settings = GlobalSettingsService(
        catalog: catalog.settings,
        records: catalog.records,
        roots: roots,
      );
      addTearDown(settings.close);
      const siblings = {'name': 'Writer', 'reasoning-effort': 'high'};
      await settings.createRecord(
        RecordTypeId('$_plugin.preset'),
        ConfigurationRecordId('work'),
        {...siblings, 'model': _initial},
      );
      final file = File('${roots.configurationRoot}/model-presets/writer.toml');
      final original = file.readAsStringSync();
      expect(original, contains('recordId = "work"'));

      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecordCollectionPanel(
              service: settings,
              collection: collection,
              frontends: frontends,
            ),
          ),
        ),
      );
      final title = find.widgetWithText(ExpansionTile, 'Writer');
      await _waitFor(tester, title);
      await _tap(tester, _key('records-add-model-presets'));
      await _waitFor(tester, _key('record-input-model-presets-name'));
      expect(
        tester
            .widget<TextField>(_key('record-input-model-presets-name'))
            .keyboardType,
        TextInputType.text,
      );
      await tester.enterText(
        _key('record-input-model-presets-name'),
        'Unfinished',
      );
      final create = _key('record-create-model-presets');
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      expect(find.text('No model selected.'), findsOneWidget);
      DropdownButton<String> effort(String suffix) =>
          tester.widget(_key('record-input-$suffix-reasoning-effort'));
      expect(effort('model-presets').onChanged, isNull);
      expect(effort('model-presets').items!.single.value, isNull);
      expect(find.textContaining('Select a model before'), findsOneWidget);
      final dialogInputs = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      final fields = catalog.records.definitions.single.fields;
      final modelField = fields.singleWhere((f) => f.id.value == 'model');
      final nameField = fields.singleWhere((f) => f.id.value == 'name');
      Future<void> author() async {
        await _tap(tester, find.text('Browse models...'));
        await _tap(tester, find.text('Enter manually'));
        await _tap(tester, find.text('Enter provider ID instead'));
      }

      Future<void> reject(String provider, String model) async {
        await tester.enterText(dialogInputs.first, provider);
        await tester.enterText(dialogInputs.last, model);
        await _tap(tester, find.text('Use reference'));
        final error = modelField.valueError({
          'provider-id': provider,
          'model-id': model,
        });
        expect(find.text(error!), findsOneWidget);
        expect(
          tester.widget<TextField>(dialogInputs.first).controller!.text,
          provider,
        );
        expect(
          tester.widget<TextField>(dialogInputs.last).controller!.text,
          model,
        );
        expect(file.readAsStringSync(), original);
      }

      await author();
      await reject('test.offline', '  ');
      await _tap(tester, find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text('No model selected.'), findsOneWidget);
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await _tap(tester, find.text('Back to records'));
      await _tap(tester, title);
      final edit = _key('record-edit-$_suffix');
      await _tap(tester, edit);
      await _waitFor(tester, find.text('Browse models...'));
      final inputs = find.descendant(
        of: _key('record-input-$_suffix-model'),
        matching: find.byType(TextField),
      );
      expect(inputs, findsNothing);
      expect(find.text('Unverified provider: local.work'), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('Model not verified.'), findsOneWidget);
      expect(effort(_suffix).value, 'high');
      expect(effort(_suffix).onChanged, isNotNull);
      expect(effort(_suffix).items!.map((item) => item.value), [
        null,
        'none',
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]);
      expect(find.textContaining('choices are unverified'), findsOneWidget);
      await author();
      await tester.enterText(dialogInputs.first, 'local.other');
      await _tap(tester, find.text('Use reference'));
      expect(find.text('Unverified provider: local.other'), findsOneWidget);
      await _tap(tester, _key('record-cancel-$_suffix'));
      expect(file.readAsStringSync(), original);

      await _tap(tester, edit);
      await _waitFor(tester, find.text('Browse models...'));
      expect(find.text('Unverified provider: local.work'), findsOneWidget);
      const updated = {
        'provider-id': 'offline.account-2',
        'model-id': ' Org/Model:v2+custom ',
      };
      await author();
      await reject('Offline/Account.2', updated['model-id']!);
      await reject(updated['provider-id']!, 'a\u007fb');
      await reject(updated['provider-id']!, 'a' * 1025);
      await tester.enterText(dialogInputs.last, updated['model-id']!);
      await _tap(tester, find.text('Use reference'));
      await tester.pumpAndSettle();
      expect(find.text(updated['model-id']!), findsOneWidget);
      expect(effort(_suffix).value, 'high');
      final name = _key('record-input-$_suffix-name');
      final save = _key('record-save-$_suffix');
      for (final invalid in ['', '  ']) {
        await tester.enterText(name, invalid);
        await tester.pump();
        expect(find.text(nameField.valueError(invalid)!), findsOneWidget);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
      }
      await tester.enterText(name, siblings['name']!);
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(file.readAsStringSync(), original);
      await _tap(tester, save);
      await _waitFor(tester, find.text('Saved Writer.'));
      final saved = (await settings.loadRecords(collection)).records.single;
      expect(saved.values, {...siblings, 'model': updated});
      expect(tester.takeException(), isNull);
    }),
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

Future<void> _waitFor(WidgetTester tester, Finder target) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (target.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) fail('Did not find $target.');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
