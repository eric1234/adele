import 'dart:convert';
import 'dart:io';

import 'package:adele_plugin_api/adele_plugin_api.dart';

/// One prepared installation, without activation, configuration, or source data.
final class PreparedPluginInstallation {
  const PreparedPluginInstallation({
    required this.metadata,
    required this.installationDirectory,
    required this.backendArtifactUri,
  });

  final PluginMetadata metadata;
  final Directory installationDirectory;
  final Uri? backendArtifactUri;
}

/// An excluded installation. Other, unrelated installations remain discoverable.
final class PreparedPluginCatalogIssue {
  const PreparedPluginCatalogIssue({
    required this.installationDirectory,
    required this.message,
    this.pluginId,
  });

  final Directory installationDirectory;
  final String message;
  final PluginId? pluginId;

  @override
  String toString() => '${installationDirectory.path}: $message';
}

/// Reads prepared installation manifests, never the source adele_plugin.yaml.
final class PreparedPluginCatalog {
  PreparedPluginCatalog._({
    required List<PreparedPluginInstallation> installations,
    required List<PreparedPluginCatalogIssue> issues,
  }) : installations = List.unmodifiable(installations),
       issues = List.unmodifiable(issues);

  final List<PreparedPluginInstallation> installations;
  final List<PreparedPluginCatalogIssue> issues;

  /// Empty/unconfigured and missing roots are empty catalogs. Root I/O failures
  /// propagate; individual malformed installations are reported in [issues].
  static Future<PreparedPluginCatalog> discover(String rootPath) async {
    final installations = <PreparedPluginInstallation>[];
    final issues = <PreparedPluginCatalogIssue>[];
    final identities = <PluginId, List<Directory>>{};
    final root = Directory(rootPath).absolute;
    List<FileSystemEntity> children = [];
    if (rootPath.isNotEmpty) {
      try {
        // Unlike exists/stat, listing preserves permission and other I/O errors.
        children = await root.list(followLinks: false).toList();
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        final missing = code == 2 || (Platform.isWindows && code == 3);
        if (!missing ||
            await FileSystemEntity.type(root.path, followLinks: false) !=
                FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    children.sort((left, right) => left.path.compareTo(right.path));
    for (final child in children) {
      if (child is! Directory && child is! Link) continue;
      final directory = Directory(child.path);
      PluginId? id;
      try {
        if (child is Link) {
          throw const FormatException('Installation must not be a symlink.');
        }
        final resolvedDirectory = Directory(
          await directory.resolveSymbolicLinks(),
        );
        final manifest = File.fromUri(
          resolvedDirectory.uri.resolve('adele_plugin.installation.json'),
        );
        final manifestUri = await _confinedFile(manifest, resolvedDirectory);
        final Object? decoded = jsonDecode(
          await File.fromUri(manifestUri).readAsString(),
        );
        // Reserve a readable, valid identity before validating the rest, so a
        // malformed duplicate cannot let another installation win by ordering.
        if (decoded case {'metadata': {'id': final String value}}) {
          id = PluginId(value);
          identities.putIfAbsent(id, () => []).add(directory);
        }
        final document = _object(decoded, 'manifest', {
          'manifestVersion',
          'metadata',
          'components',
        });
        if (document['manifestVersion'] is! int ||
            document['manifestVersion'] != 1) {
          throw const FormatException('manifestVersion must be integer 1.');
        }
        final metadata = _object(document['metadata'], 'metadata', {
          'id',
          'version',
          'displayName',
          'description',
        });
        final pluginMetadata = PluginMetadata(
          id: id ?? PluginId(_text(metadata['id'], 'metadata.id')),
          version: _text(metadata['version'], 'metadata.version'),
          displayName: _text(metadata['displayName'], 'metadata.displayName'),
          description: metadata.containsKey('description')
              ? _text(
                  metadata['description'],
                  'metadata.description',
                  blank: true,
                )
              : null,
        );
        final components = _object(document['components'], 'components', {
          'backend',
        });
        Uri? backendArtifactUri;
        if (components.containsKey('backend')) {
          final backend = _object(components['backend'], 'components.backend', {
            'artifact',
          });
          final artifact = _text(backend['artifact'], 'backend.artifact');
          // Use a portable relative file path, not URI syntax or platform-
          // dependent separators. Reject dot segments before any normalization.
          if (RegExp(r'[:\\%?#<>"|*\x00-\x1f]').hasMatch(artifact) ||
              artifact
                  .split('/')
                  .any((part) => part.isEmpty || part == '.' || part == '..')) {
            throw const FormatException(
              'backend.artifact must be a relative file path without traversal.',
            );
          }
          backendArtifactUri = await _confinedFile(
            File.fromUri(resolvedDirectory.uri.resolveUri(Uri(path: artifact))),
            resolvedDirectory,
          );
        }
        installations.add(
          PreparedPluginInstallation(
            metadata: pluginMetadata,
            installationDirectory: directory,
            backendArtifactUri: backendArtifactUri,
          ),
        );
      } on FormatException catch (error) {
        issues.add(
          PreparedPluginCatalogIssue(
            installationDirectory: directory,
            pluginId: id,
            message: error.message,
          ),
        );
      } on FileSystemException catch (error) {
        issues.add(
          PreparedPluginCatalogIssue(
            installationDirectory: directory,
            pluginId: id,
            message: 'Unable to read installation: $error',
          ),
        );
      }
    }
    for (final entry in identities.entries) {
      if (entry.value.length < 2) continue;
      installations.removeWhere((item) => item.metadata.id == entry.key);
      for (final directory in entry.value) {
        issues.add(
          PreparedPluginCatalogIssue(
            installationDirectory: directory,
            pluginId: entry.key,
            message:
                'Duplicate PluginId ${entry.key}: '
                '${entry.value.map((item) => item.path).join(', ')}. '
                'All conflicting installations are excluded.',
          ),
        );
      }
    }
    return PreparedPluginCatalog._(
      installations: installations,
      issues: issues,
    );
  }
}

Map<String, Object?> _object(Object? value, String label, Set<String> fields) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$label must be an object.');
  }
  if (value.keys.any((key) => !fields.contains(key))) {
    throw FormatException('$label contains unsupported fields.');
  }
  return value;
}

String _text(Object? value, String label, {bool blank = false}) {
  if (value is! String || (!blank && value.trim().isEmpty)) {
    throw FormatException(
      '$label must be ${blank ? 'a' : 'a nonblank'} string.',
    );
  }
  return value;
}

Future<Uri> _confinedFile(File file, Directory directory) async {
  final resolved = File(await file.resolveSymbolicLinks());
  if (!resolved.uri.toString().startsWith(directory.uri.toString())) {
    throw const FormatException('File resolves outside the installation.');
  }
  if (await FileSystemEntity.type(resolved.path) != FileSystemEntityType.file) {
    throw const FormatException('Installation file must be a regular file.');
  }
  return resolved.uri;
}
