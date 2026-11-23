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
const _initial = {'provider-id': 'Local/Work', 'model-id': 'alpha'};

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
      final file = File('${roots.configurationRoot}/model-presets/work.toml');
      final original = file.readAsStringSync();

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
      await tester.enterText(
        _key('record-input-model-presets-name'),
        'Unfinished',
      );
      final create = _key('record-create-model-presets');
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      expect(find.text('No model selected.'), findsOneWidget);
      final dialogInputs = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      Future<void> author() async {
        await _tap(tester, find.text('Browse models...'));
        await _tap(tester, find.text('Enter manually'));
        await _tap(tester, find.text('Enter provider ID instead'));
      }

      await author();
      await tester.enterText(dialogInputs.first, 'Offline');
      await tester.enterText(dialogInputs.last, '  ');
      await tester.pump();
      expect(find.text('Use reference'), findsNothing);
      await _tap(tester, find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text('No model selected.'), findsOneWidget);
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await _tap(tester, find.text('Back to records'));
      await _tap(tester, title);
      final edit = _key('record-edit-$_suffix');
      await _tap(tester, edit);
      final inputs = find.descendant(
        of: _key('record-input-$_suffix-model'),
        matching: find.byType(TextField),
      );
      expect(inputs, findsNothing);
      expect(find.text('Configured provider: Local/Work'), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
      await author();
      await tester.enterText(dialogInputs.first, 'other');
      await _tap(tester, find.text('Use reference'));
      expect(find.text('Configured provider: other'), findsOneWidget);
      await _tap(tester, _key('record-cancel-$_suffix'));
      expect(file.readAsStringSync(), original);

      await _tap(tester, edit);
      expect(find.text('Configured provider: Local/Work'), findsOneWidget);
      const updated = {
        'provider-id': 'Offline/Account.2',
        'model-id': ' Org/Model:v2+custom ',
      };
      await author();
      await tester.enterText(dialogInputs.last, updated['model-id']!);
      await tester.pump();
      await tester.enterText(dialogInputs.first, updated['provider-id']!);
      await tester.pump();
      await _tap(tester, find.text('Use reference'));
      await tester.pumpAndSettle();
      expect(find.text(updated['model-id']!), findsOneWidget);
      expect(file.readAsStringSync(), original);
      await _tap(tester, _key('record-save-$_suffix'));
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
