import 'dart:convert';
import 'dart:io';

import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

/// One prepared installation, without activation, configuration, or source data.
final class PreparedPluginInstallation {
  const PreparedPluginInstallation({
    required this.metadata,
    required this.installationDirectory,
    required this.backendArtifactUri,
    this.frontend,
  });

  final PluginMetadata metadata;
  final Directory installationDirectory;
  final Uri? backendArtifactUri;
  final PreparedFrontendComponent? frontend;
}

/// Prepared locations and descriptors, without reading or decoding bytecode.
final class PreparedFrontendComponent {
  PreparedFrontendComponent({
    required this.artifactUri,
    required List<PreparedPresentationDescriptor> presentations,
    List<PreparedFrontendExtension> extensions = const [],
  }) : presentations = List.unmodifiable(presentations),
       extensions = List.unmodifiable(extensions);

  final Uri artifactUri;
  final List<PreparedPresentationDescriptor> presentations;
  final List<PreparedFrontendExtension> extensions;
}

/// Data-only behavioral extension metadata, separate from presentation roles.
sealed class PreparedFrontendExtension {
  const PreparedFrontendExtension({required this.library});

  final String library;

  Map<String, Object?> toJson();
}

final class PreparedProjectSelectorExtension extends PreparedFrontendExtension {
  const PreparedProjectSelectorExtension({
    required this.extensionId,
    required this.displayName,
    required super.library,
    required this.entrypoint,
  });

  final ExtensionId extensionId;
  final String displayName;
  final String entrypoint;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'projectSelector',
    'extensionId': extensionId.value,
    'displayName': displayName,
    'library': library,
    'entrypoint': entrypoint,
  };
}

sealed class PreparedPresentationDescriptor {
  const PreparedPresentationDescriptor({required this.library});

  final String library;
}

final class PreparedSessionPresentation extends PreparedPresentationDescriptor {
  const PreparedSessionPresentation({
    required this.extensionId,
    required this.strategyId,
    required this.entrypoint,
    required this.hostAdapter,
    required super.library,
  });

  final ExtensionId extensionId;
  final OrchestrationStrategyId strategyId;
  final String entrypoint;
  final String hostAdapter;
}

final class PreparedToolActivityPresentation
    extends PreparedPresentationDescriptor {
  const PreparedToolActivityPresentation({
    required this.toolId,
    required this.inspectionExtensionId,
    required this.compactExtensionId,
    required this.inspectionEntrypoint,
    required this.compactEntrypoint,
    required super.library,
  });

  final ToolId toolId;
  final ExtensionId inspectionExtensionId;
  final ExtensionId compactExtensionId;
  final String inspectionEntrypoint;
  final String compactEntrypoint;
}

final class PreparedModelNativeActivityPresentation
    extends PreparedPresentationDescriptor {
  const PreparedModelNativeActivityPresentation({
    required this.presentationKind,
    required this.inspectionExtensionId,
    required this.compactExtensionId,
    required this.inspectionEntrypoint,
    required this.compactEntrypoint,
    required super.library,
  });

  final String presentationKind;
  final ExtensionId inspectionExtensionId;
  final ExtensionId compactExtensionId;
  final String inspectionEntrypoint;
  final String compactEntrypoint;
}

enum PreparedPluginComponent { backend, frontend }

/// An excluded installation or component. Healthy siblings remain discoverable.
final class PreparedPluginCatalogIssue {
  const PreparedPluginCatalogIssue({
    required this.installationDirectory,
    required this.message,
    this.pluginId,
    this.component,
  });

  final Directory installationDirectory;
  final String message;
  final PluginId? pluginId;

  /// Null for installation-wide failures, including duplicate identities.
  final PreparedPluginComponent? component;

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
          'frontend',
        });
        Uri? backendArtifactUri;
        PreparedFrontendComponent? frontend;
        for (final component in PreparedPluginComponent.values) {
          if (!components.containsKey(component.name)) continue;
          try {
            switch (component) {
              case PreparedPluginComponent.backend:
                final backend = _object(
                  components['backend'],
                  'components.backend',
                  {'artifact'},
                );
                backendArtifactUri = await _artifact(
                  backend['artifact'],
                  'backend.artifact',
                  resolvedDirectory,
                );
              case PreparedPluginComponent.frontend:
                frontend = await _frontend(
                  components['frontend'],
                  resolvedDirectory,
                );
            }
          } on FormatException catch (error) {
            issues.add(
              PreparedPluginCatalogIssue(
                installationDirectory: directory,
                pluginId: id,
                component: component,
                message: error.message,
              ),
            );
          } on FileSystemException catch (error) {
            issues.add(
              PreparedPluginCatalogIssue(
                installationDirectory: directory,
                pluginId: id,
                component: component,
                message: 'Unable to read ${component.name} component: $error',
              ),
            );
          }
        }
        installations.add(
          PreparedPluginInstallation(
            metadata: pluginMetadata,
            installationDirectory: directory,
            backendArtifactUri: backendArtifactUri,
            frontend: frontend,
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

Future<PreparedFrontendComponent> _frontend(
  Object? value,
  Directory directory,
) async {
  final frontend = _object(value, 'components.frontend', {
    'artifact',
    'presentations',
    'extensions',
  });
  final presentations = frontend['presentations'];
  if (presentations is! List<Object?>) {
    throw const FormatException('frontend.presentations must be an array.');
  }
  final descriptors = <PreparedPresentationDescriptor>[
    for (var index = 0; index < presentations.length; index++)
      _presentation(presentations[index], 'frontend.presentations[$index]'),
  ];
  final extensions = frontend.containsKey('extensions')
      ? frontend['extensions']
      : const <Object?>[];
  if (extensions is! List<Object?>) {
    throw const FormatException('frontend.extensions must be an array.');
  }
  final extensionDescriptors = <PreparedFrontendExtension>[
    for (var index = 0; index < extensions.length; index++)
      _extension(extensions[index], 'frontend.extensions[$index]'),
  ];
  return PreparedFrontendComponent(
    artifactUri: await _artifact(
      frontend['artifact'],
      'frontend.artifact',
      directory,
    ),
    presentations: descriptors,
    extensions: extensionDescriptors,
  );
}

PreparedFrontendExtension _extension(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$label must be an object.');
  }
  String text(String field) => _text(value[field], '$label.$field');
  switch (text('kind')) {
    case 'projectSelector':
      _object(value, label, {
        'kind',
        'extensionId',
        'displayName',
        'library',
        'entrypoint',
      });
      final library = text('library');
      if (!RegExp(
            r'^package:[a-z_][a-z0-9_]*/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.dart$',
          ).hasMatch(library) ||
          library.split('/').any((part) => part == '.' || part == '..')) {
        throw FormatException(
          '$label.library must be a canonical package: URI to a Dart library '
          'without traversal.',
        );
      }
      final entrypoint = text('entrypoint');
      if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(entrypoint)) {
        throw FormatException(
          '$label.entrypoint must be a single top-level Dart identifier.',
        );
      }
      return PreparedProjectSelectorExtension(
        extensionId: ExtensionId(text('extensionId')),
        displayName: text('displayName'),
        library: library,
        entrypoint: entrypoint,
      );
    default:
      throw FormatException('$label.kind is unsupported.');
  }
}

PreparedPresentationDescriptor _presentation(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$label must be an object.');
  }
  String text(String field) => _text(value[field], '$label.$field');
  switch (text('role')) {
    case 'session':
      _object(value, label, {
        'role',
        'library',
        'extensionId',
        'strategyId',
        'entrypoint',
        'hostAdapter',
      });
      return PreparedSessionPresentation(
        extensionId: ExtensionId(text('extensionId')),
        strategyId: OrchestrationStrategyId(text('strategyId')),
        entrypoint: text('entrypoint'),
        hostAdapter: text('hostAdapter'),
        library: text('library'),
      );
    case 'toolActivity':
      _object(value, label, {
        'role',
        'library',
        'toolId',
        'inspectionExtensionId',
        'compactExtensionId',
        'inspectionEntrypoint',
        'compactEntrypoint',
      });
      return PreparedToolActivityPresentation(
        toolId: ToolId(text('toolId')),
        inspectionExtensionId: ExtensionId(text('inspectionExtensionId')),
        compactExtensionId: ExtensionId(text('compactExtensionId')),
        inspectionEntrypoint: text('inspectionEntrypoint'),
        compactEntrypoint: text('compactEntrypoint'),
        library: text('library'),
      );
    case 'modelNativeActivity':
      _object(value, label, {
        'role',
        'library',
        'presentationKind',
        'inspectionExtensionId',
        'compactExtensionId',
        'inspectionEntrypoint',
        'compactEntrypoint',
      });
      return PreparedModelNativeActivityPresentation(
        presentationKind: text('presentationKind'),
        inspectionExtensionId: ExtensionId(text('inspectionExtensionId')),
        compactExtensionId: ExtensionId(text('compactExtensionId')),
        inspectionEntrypoint: text('inspectionEntrypoint'),
        compactEntrypoint: text('compactEntrypoint'),
        library: text('library'),
      );
    default:
      throw FormatException('$label.role is unsupported.');
  }
}

Future<Uri> _artifact(Object? value, String label, Directory directory) async {
  final artifact = _text(value, label);
  // Use a portable relative file path, not URI syntax or platform-dependent
  // separators. Reject dot segments before any normalization.
  if (RegExp(r'[:\\%?#<>"|*\x00-\x1f]').hasMatch(artifact) ||
      artifact
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException(
      '$label must be a relative file path without traversal.',
    );
  }
  return _confinedFile(
    File.fromUri(directory.uri.resolveUri(Uri(path: artifact))),
    directory,
  );
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
