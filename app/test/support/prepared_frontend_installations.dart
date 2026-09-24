import 'dart:convert';
import 'dart:io';

import '../../../tools/stock_frontend_descriptors.dart';

/// Prepares frontends and optional backends using the launcher's stock metadata.
Future<Directory> prepareFrontendInstallations({
  required Directory root,
  required Map<String, File> artifacts,
  Map<String, File> backendArtifacts = const {},
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
    final backend = backendArtifacts[entry.key];
    if (backend != null) {
      await backend.copy(
        File.fromUri(directory.uri.resolve('backend.aot')).path,
      );
    }
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
          if (backend != null) 'backend': {'artifact': 'backend.aot'},
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
