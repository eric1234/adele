import 'dart:io';

import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/global_settings_service.dart';
import 'package:adele_desktop/core/native_credential_storage_adapter.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../tools/backend_artifacts.dart';
import '../tool/credential_storage_probe.dart' show isCredentialSmokeFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final phase = Platform.environment['ADELE_CREDENTIAL_ASSOCIATION_PHASE'];
  test(
    'real record association $phase across process and daemon reconstruction',
    () async {
      final fixture = Platform.environment['ADELE_CREDENTIAL_STORAGE_FIXTURE']!;
      final installations = Directory('$fixture/association-plugins');
      await publishStockPluginInstallation(
        repositoryRoot: Directory.current.parent,
        installationDirectory: Directory('${installations.path}/openai'),
        pluginId: 'dev.adele.openai',
        displayName: 'OpenAI',
      );
      final prepared = await PreparedPluginCatalog.discover(installations.path);
      expect(prepared.issues, isEmpty);
      final roots = PlatformStorageRoots(
        operatingSystem: Platform.operatingSystem,
        configurationRoot: '$fixture/association-config',
        localStateRoot: '$fixture/association-state',
        localDataRoot: '$fixture/association-data',
        cacheRoot: '$fixture/association-cache',
      );
      final settings = GlobalSettingsService(
        catalog: prepared.settings,
        records: prepared.records,
        roots: roots,
      );
      final credentials = createNativeCredentialService();
      final associations = RecordCredentialService(
        settings: settings,
        credentials: credentials,
      );
      final collection = RecordCollectionId('providers');
      final slot = RecordCredentialSlotId('api-key');
      final file = File('${roots.configurationRoot}/providers/smoke.toml');
      const value = 'disposable-association-fixture-not-an-api-key';
      try {
        if (phase == 'attach') {
          final record = await settings.createRecord(
            RecordTypeId('dev.adele.openai.api-key'),
            ConfigurationRecordId('smoke'),
            {'display-name': 'Disposable Linux association'},
          );
          final result = await associations.attach(
            record,
            slot,
            CredentialSecret(value),
          );
          expect(result.status, RecordCredentialStatus.stored);
          expect(
            (await associations.inspect(result.record, slot)).status,
            RecordCredentialStatus.stored,
          );
          expect(file.readAsStringSync().contains(value), isFalse);
        } else {
          final record = (await settings.loadRecords(
            collection,
          )).records.single;
          expect(record.id, ConfigurationRecordId('smoke'));
          expect(
            (await associations.inspect(record, slot)).status,
            RecordCredentialStatus.stored,
          );
          final original = file.readAsStringSync();
          final replaced = await associations.replace(
            record,
            slot,
            CredentialSecret('$value-replaced'),
          );
          expect(replaced.status, RecordCredentialStatus.stored);
          expect(file.readAsStringSync(), original);
          final forgotten = await associations.forget(replaced.record, slot);
          expect(forgotten.status, RecordCredentialStatus.noReference);
          await settings.deleteRecord(forgotten.record);
          expect(file.existsSync(), isFalse);
        }
      } finally {
        await associations.close();
        await settings.close();
        await credentials.close();
      }
      File('$fixture/association-$phase.completed').writeAsStringSync('passed');
    },
    skip: !isCredentialSmokeFixture || !['attach', 'reopen'].contains(phase),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
