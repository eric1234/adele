import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_settings/adele_settings.dart';
import 'package:adele_settings_host/adele_settings_host.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import '../../../configuration_store/test/fixtures/writer.dart' as writer;
import '../../../configuration_store/test/support.dart';

Future<void> main(List<String> arguments) async {
  final mode = arguments[1];
  if (mode != 'host-list' && mode != 'host-load') {
    await writer.main(arguments);
    return;
  }

  final prepared = await PreparedPluginCatalog.discover(arguments[5]);
  if (prepared.issues.isNotEmpty) {
    throw StateError('Invalid prepared record catalog: ${prepared.issues}');
  }
  final host = ConfigurationRecordStore(
    store: ConfigurationStore(rootsAt(arguments[0])),
    catalog: prepared.records,
  );
  final collection = RecordCollectionId(arguments[4]);
  stdout.writeln(mode == 'host-list' ? 'listing' : 'loading');
  await IOOverrides.runWithIOOverrides(() async {
    if (mode == 'host-list') {
      final result = await host.enumerate(collection);
      stdout.writeln(
        'listed:${result.records.length}:${result.diagnostics.length}',
      );
    } else {
      final record = await host.load(
        collection,
        ConfigurationRecordId(arguments[3]),
      );
      stdout.writeln(
        'loaded:${record.id.value}:${record.values['display-name']}',
      );
    }
  }, StagingOverrides(beforeLock: () => stdout.writeln('waiting')));
}
