import 'dart:convert';
import 'dart:io';

import '../../../tools/stock_frontend_descriptors.dart';

/// Prepares frontend-only installations using the launcher's stock metadata.
Future<Directory> prepareFrontendInstallations({
  required Directory root,
  required Map<String, File> artifacts,
}) async {
  await root.create(recursive: true);
  for (final entry in artifacts.entries) {
    final presentations = stockFrontendDescriptors[entry.key];
    final extensions = stockFrontendExtensionDescriptors[entry.key];
    if (presentations == null && extensions == null) {
      throw ArgumentError.value(entry.key, 'artifacts', 'Unknown stock plugin');
    }
    final directory = Directory.fromUri(root.uri.resolve('${entry.key}/'));
    await directory.create();
    await entry.value.copy(
      File.fromUri(directory.uri.resolve('frontend.evc')).path,
    );
    await File.fromUri(
      directory.uri.resolve('adele_plugin.installation.json'),
    ).writeAsString(
      jsonEncode({
        'manifestVersion': 1,
        'metadata': {
          'id': entry.key,
          'version': 'test',
          'displayName': entry.key,
        },
        'components': {
          'frontend': {
            'artifact': 'frontend.evc',
            'presentations': presentations ?? const [],
            'extensions': ?extensions,
          },
        },
      }),
    );
  }
  return root;
}
