import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/commands.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

/// One prepared installation, without activation, configuration, or source data.
final class PreparedPluginInstallation {
  PreparedPluginInstallation({
    required this.metadata,
    required this.installationDirectory,
    required this.backendArtifactUri,
    Iterable<CapabilityKey> backendConsumedCapabilities = const [],
    this.frontend,
  }) : backendConsumedCapabilities = _backendConsumedCapabilityKeys(
         backendConsumedCapabilities,
       ) {
    if (backendArtifactUri == null &&
        this.backendConsumedCapabilities.isNotEmpty) {
      throw const FormatException(
        'consumesCapabilities requires a backend component.',
      );
    }
  }

  static const maxBackendConsumedCapabilities = 128;

  final PluginMetadata metadata;
  final Directory installationDirectory;
  final Uri? backendArtifactUri;

  /// Backend-only consumption declarations, not provider advertisements,
  /// activation dependencies, or authority grants.
  final List<CapabilityKey> backendConsumedCapabilities;
  final PreparedFrontendComponent? frontend;

  /// Encodes the backend's consumesCapabilities array, copying mutable data.
  List<Map<String, Object?>> backendConsumedCapabilitiesToJson() => [
    for (final key in backendConsumedCapabilities)
      {'id': key.id.value, 'majorVersion': key.majorVersion},
  ];
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
  const PreparedFrontendExtension();

  Map<String, Object?> toJson();
}

final class PreparedCommandExtension extends PreparedFrontendExtension {
  PreparedCommandExtension({
    required this.extensionId,
    required this.commandId,
    required this.label,
    required this.library,
    required this.entrypoint,
  }) {
    CommandContribution.validateLabel(label);
    _library(library, 'library');
    _entrypoint(entrypoint, 'entrypoint');
  }

  final ExtensionId extensionId;
  final CommandId commandId;
  final String label;
  final String library;
  final String entrypoint;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'command',
    'extensionId': extensionId.value,
    'commandId': commandId.value,
    'label': label,
    'library': library,
    'entrypoint': entrypoint,
  };
}

/// Names an existing console creation action without a separate operation.
final class PreparedConsoleActionCommandExtension
    extends PreparedFrontendExtension {
  PreparedConsoleActionCommandExtension({
    required this.extensionId,
    required this.commandId,
    required this.consoleExtensionId,
    required this.actionId,
  }) {
    _consoleActionId(actionId, 'actionId');
  }

  final ExtensionId extensionId;
  final CommandId commandId;
  final ExtensionId consoleExtensionId;
  final String actionId;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'consoleActionCommand',
    'extensionId': extensionId.value,
    'commandId': commandId.value,
    'consoleExtensionId': consoleExtensionId.value,
    'actionId': actionId,
  };
}

/// Names an existing Main Content input action without a separate operation.
final class PreparedMainContentActionCommandExtension
    extends PreparedFrontendExtension {
  PreparedMainContentActionCommandExtension({
    required this.extensionId,
    required this.commandId,
    required this.mainContentExtensionId,
    required this.actionId,
  }) {
    _text(actionId, 'actionId');
  }

  final ExtensionId extensionId;
  final CommandId commandId;
  final ExtensionId mainContentExtensionId;
  final String actionId;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'mainContentActionCommand',
    'extensionId': extensionId.value,
    'commandId': commandId.value,
    'mainContentExtensionId': mainContentExtensionId.value,
    'actionId': actionId,
  };
}

final class PreparedProjectSelectorExtension extends PreparedFrontendExtension {
  const PreparedProjectSelectorExtension({
    required this.extensionId,
    required this.projectProviderId,
    required this.displayName,
    required this.library,
    required this.entrypoint,
  });

  final ExtensionId extensionId;

  /// Always resolved from this selector's exact owning backend installation.
  final ProviderId projectProviderId;
  final String displayName;
  final String library;
  final String entrypoint;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'projectSelector',
    'extensionId': extensionId.value,
    'projectProviderId': projectProviderId.value,
    'displayName': displayName,
    'library': library,
    'entrypoint': entrypoint,
  };
}

sealed class PreparedPresentationDescriptor {
  const PreparedPresentationDescriptor({required this.library});

  final String library;
}

enum PreparedStrategyAffinity { independent, owningBackend }

final class PreparedMainContentAction {
  PreparedMainContentAction({
    required this.id,
    required this.label,
    required this.entrypoint,
  }) {
    _text(id, 'id');
    _text(label, 'label');
    if (label.length > 128) {
      throw const FormatException('label must not exceed 128 characters.');
    }
    _entrypoint(entrypoint, 'entrypoint');
  }

  final String id;
  final String label;

  /// Input presentation, not the finite operation it may request.
  final String entrypoint;
}

/// One contribution initializes its collection, then presents each admitted pane
/// through the same content entrypoint in an independent runtime.
final class PreparedMainContentPresentation
    extends PreparedPresentationDescriptor {
  PreparedMainContentPresentation({
    required this.extensionId,
    required this.order,
    required super.library,
    required this.initialize,
    required this.entrypoint,
    this.sessionExecution = false,
    Iterable<String> backendServices = const [],
    Iterable<CapabilityKey> capabilities = const [],
    Iterable<CapabilityKey> environmentReadCapabilities = const [],
    this.strategyAffinity = PreparedStrategyAffinity.independent,
    Iterable<PreparedMainContentAction> actions = const [],
    Map<String, String> operations = const {},
    this.closeOperation,
    this.exitOperation,
    this.displaySourceFileOperation,
    this.retainedData = false,
    this.nativeCodeEditor = false,
    this.environmentTextFiles = false,
    this.canRequestSourceDisplay = false,
  }) : backendServices = List.unmodifiable(backendServices),
       capabilities = List.unmodifiable(capabilities),
       environmentReadCapabilities = List.unmodifiable(
         environmentReadCapabilities,
       ),
       actions = List.unmodifiable(actions),
       operations = Map.unmodifiable(operations) {
    _library(library, 'library');
    _entrypoint(initialize, 'initialize');
    _entrypoint(entrypoint, 'entrypoint');
    final seen = <String>{};
    for (final service in this.backendServices) {
      adeleValidateServiceId(service);
      if (!seen.add(service)) {
        throw const FormatException(
          'backendServices must not contain duplicates.',
        );
      }
    }
    if (this.capabilities.toSet().length != this.capabilities.length) {
      throw const FormatException('capabilities must not contain duplicates.');
    }
    if (this.environmentReadCapabilities.toSet().length !=
        this.environmentReadCapabilities.length) {
      throw const FormatException(
        'environmentReadCapabilities must not contain duplicates.',
      );
    }
    final actionIds = <String>{};
    for (final action in this.actions) {
      if (!actionIds.add(action.id)) {
        throw const FormatException('actions must have unique ids.');
      }
    }
    for (final operation in this.operations.entries) {
      _text(operation.key, 'operations key');
      _entrypoint(operation.value, 'operations.${operation.key}');
    }
    for (final hook in {
      'closeOperation': closeOperation,
      'exitOperation': exitOperation,
      'displaySourceFileOperation': displaySourceFileOperation,
    }.entries) {
      if (hook.value == null) continue;
      _text(hook.value, hook.key);
      if (!this.operations.containsKey(hook.value)) {
        throw FormatException('${hook.key} must name a declared operation.');
      }
    }
    if (nativeCodeEditor && !retainedData) {
      throw const FormatException('nativeCodeEditor requires retainedData.');
    }
    if (environmentTextFiles && this.operations.isEmpty) {
      throw const FormatException('environmentTextFiles requires operations.');
    }
  }

  final ExtensionId extensionId;
  final int order;
  final String initialize;
  final String entrypoint;
  final bool sessionExecution;
  final List<String> backendServices;
  final List<CapabilityKey> capabilities;

  /// Pane-only contextual unary requests, separate from [capabilities].
  /// Initializers, input actions, and finite operations receive no such access.
  final List<CapabilityKey> environmentReadCapabilities;
  final PreparedStrategyAffinity strategyAffinity;
  final List<PreparedMainContentAction> actions;

  /// Finite operation keys mapped to top-level entrypoints in [library].
  final Map<String, String> operations;
  final String? closeOperation;
  final String? exitOperation;
  final String? displaySourceFileOperation;
  final bool retainedData;
  final bool nativeCodeEditor;
  final bool environmentTextFiles;

  /// Pane-only requests through the public source-display extension point.
  /// This grants no Environment file access to the requesting contribution.
  final bool canRequestSourceDisplay;

  Map<String, Object?> toJson() => {
    'role': 'mainContent',
    'extensionId': extensionId.value,
    'order': order,
    'library': library,
    'initialize': initialize,
    'entrypoint': entrypoint,
    'sessionExecution': sessionExecution,
    'backendServices': [...backendServices],
    'capabilities': [
      for (final key in capabilities)
        {'id': key.id.value, 'majorVersion': key.majorVersion},
    ],
    'environmentReadCapabilities': [
      for (final key in environmentReadCapabilities)
        {'id': key.id.value, 'majorVersion': key.majorVersion},
    ],
    'strategyAffinity': strategyAffinity.name,
    'actions': [
      for (final action in actions)
        {
          'id': action.id,
          'label': action.label,
          'entrypoint': action.entrypoint,
        },
    ],
    'operations': {...operations},
    if (closeOperation != null) 'closeOperation': closeOperation,
    if (exitOperation != null) 'exitOperation': exitOperation,
    if (displaySourceFileOperation != null)
      'displaySourceFileOperation': displaySourceFileOperation,
    'retainedData': retainedData,
    'nativeCodeEditor': nativeCodeEditor,
    'environmentTextFiles': environmentTextFiles,
    'canRequestSourceDisplay': canRequestSourceDisplay,
  };
}

final class PreparedConsoleAction {
  PreparedConsoleAction({
    required this.id,
    required this.label,
    required this.entrypoint,
  }) {
    _consoleActionId(id, 'id');
    _text(label, 'label');
    if (label.length > 128) {
      throw const FormatException('label must not exceed 128 characters.');
    }
    _entrypoint(entrypoint, 'entrypoint');
  }

  final String id;
  final String label;
  final String entrypoint;
}

final class PreparedConsolePresentation extends PreparedPresentationDescriptor {
  PreparedConsolePresentation({
    required this.extensionId,
    required super.library,
    required this.entrypoint,
    required Iterable<PreparedConsoleAction> actions,
    this.readOnly = false,
    this.keepAlive = false,
    Iterable<String> backendServices = const [],
  }) : actions = List.unmodifiable(actions),
       backendServices = List.unmodifiable(backendServices) {
    _library(library, 'library');
    _entrypoint(entrypoint, 'entrypoint');
    final seen = <String>{};
    for (final action in this.actions) {
      if (!seen.add(action.id)) {
        throw const FormatException('actions must have unique ids.');
      }
    }
    if (readOnly && this.actions.isNotEmpty) {
      throw const FormatException(
        'Read-only console must not declare actions.',
      );
    }
    if (!readOnly && this.backendServices.isNotEmpty) {
      throw const FormatException('Console backendServices require readOnly.');
    }
    if (keepAlive && !readOnly) {
      throw const FormatException('Console keepAlive requires readOnly.');
    }
    final services = <String>{};
    for (final service in this.backendServices) {
      adeleValidateServiceId(service);
      if (!services.add(service)) {
        throw const FormatException(
          'backendServices must not contain duplicates.',
        );
      }
    }
  }

  final ExtensionId extensionId;
  final String entrypoint;
  final List<PreparedConsoleAction> actions;
  final bool readOnly;
  final bool keepAlive;
  final List<String> backendServices;
}

final class PreparedTaskBrowserPresentation
    extends PreparedPresentationDescriptor {
  const PreparedTaskBrowserPresentation({
    required this.extensionId,
    required this.displayName,
    required super.library,
    required this.entrypoint,
  });

  final ExtensionId extensionId;
  final String displayName;
  final String entrypoint;
}

final class PreparedToolActivityPresentation
    extends PreparedPresentationDescriptor {
  PreparedToolActivityPresentation({
    required this.toolId,
    required this.inspectionExtensionId,
    required this.compactExtensionId,
    required this.inspectionEntrypoint,
    required this.compactEntrypoint,
    required super.library,
    Iterable<String> backendServices = const [],
    Iterable<ExtensionId> consoleExtensions = const [],
  }) : backendServices = List.unmodifiable(backendServices),
       consoleExtensions = List.unmodifiable(consoleExtensions) {
    final seen = <String>{};
    for (final service in this.backendServices) {
      adeleValidateServiceId(service);
      if (!seen.add(service)) {
        throw const FormatException(
          'backendServices must not contain duplicates.',
        );
      }
    }
    if (this.consoleExtensions.toSet().length !=
        this.consoleExtensions.length) {
      throw const FormatException(
        'consoleExtensions must not contain duplicates.',
      );
    }
  }

  final ToolId toolId;
  final ExtensionId inspectionExtensionId;
  final ExtensionId compactExtensionId;
  final String inspectionEntrypoint;
  final String compactEntrypoint;

  /// Available only to rich Inspection, never compact presentation.
  final List<String> backendServices;
  final List<ExtensionId> consoleExtensions;
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
        List<CapabilityKey> backendConsumedCapabilities = const [];
        PreparedFrontendComponent? frontend;
        for (final component in PreparedPluginComponent.values) {
          if (!components.containsKey(component.name)) continue;
          try {
            switch (component) {
              case PreparedPluginComponent.backend:
                final backend = _object(
                  components['backend'],
                  'components.backend',
                  {'artifact', 'consumesCapabilities'},
                );
                final consumedCapabilities = _backendConsumedCapabilityKeys(
                  _capabilityKeys(
                    backend.containsKey('consumesCapabilities')
                        ? backend['consumesCapabilities']
                        : const <Object?>[],
                    'backend.consumesCapabilities',
                    maxEntries: PreparedPluginInstallation
                        .maxBackendConsumedCapabilities,
                  ),
                );
                backendArtifactUri = await _artifact(
                  backend['artifact'],
                  'backend.artifact',
                  resolvedDirectory,
                );
                backendConsumedCapabilities = consumedCapabilities;
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
            backendConsumedCapabilities: backendConsumedCapabilities,
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
    case 'command':
      _object(value, label, {
        'kind',
        'extensionId',
        'commandId',
        'label',
        'library',
        'entrypoint',
      });
      try {
        return PreparedCommandExtension(
          extensionId: ExtensionId(text('extensionId')),
          commandId: CommandId(text('commandId')),
          label: _text(value['label'], '$label.label', blank: true),
          library: _library(value['library'], '$label.library'),
          entrypoint: _entrypoint(value['entrypoint'], '$label.entrypoint'),
        );
      } on ArgumentError catch (error) {
        throw FormatException('$label.label: ${error.message}');
      }
    case 'consoleActionCommand':
      _object(value, label, {
        'kind',
        'extensionId',
        'commandId',
        'consoleExtensionId',
        'actionId',
      });
      return PreparedConsoleActionCommandExtension(
        extensionId: ExtensionId(text('extensionId')),
        commandId: CommandId(text('commandId')),
        consoleExtensionId: ExtensionId(text('consoleExtensionId')),
        actionId: _consoleActionId(value['actionId'], '$label.actionId'),
      );
    case 'mainContentActionCommand':
      _object(value, label, {
        'kind',
        'extensionId',
        'commandId',
        'mainContentExtensionId',
        'actionId',
      });
      return PreparedMainContentActionCommandExtension(
        extensionId: ExtensionId(text('extensionId')),
        commandId: CommandId(text('commandId')),
        mainContentExtensionId: ExtensionId(text('mainContentExtensionId')),
        actionId: text('actionId'),
      );
    case 'projectSelector':
      _object(value, label, {
        'kind',
        'extensionId',
        'projectProviderId',
        'displayName',
        'library',
        'entrypoint',
      });
      final library = _library(value['library'], '$label.library');
      final entrypoint = _entrypoint(value['entrypoint'], '$label.entrypoint');
      final ProviderId projectProviderId;
      try {
        projectProviderId = ProviderId(text('projectProviderId'));
      } on InvalidCapabilityIdentity catch (error) {
        throw FormatException('$label.projectProviderId: ${error.message}');
      }
      return PreparedProjectSelectorExtension(
        extensionId: ExtensionId(text('extensionId')),
        projectProviderId: projectProviderId,
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
    case 'mainContent':
      _object(value, label, {
        'role',
        'extensionId',
        'order',
        'library',
        'initialize',
        'entrypoint',
        'sessionExecution',
        'backendServices',
        'capabilities',
        'environmentReadCapabilities',
        'strategyAffinity',
        'actions',
        'operations',
        'closeOperation',
        'exitOperation',
        'displaySourceFileOperation',
        'retainedData',
        'nativeCodeEditor',
        'environmentTextFiles',
        'canRequestSourceDisplay',
      });
      final order = value['order'];
      if (order is! int) {
        throw FormatException('$label.order must be an integer.');
      }
      final execution = value.containsKey('sessionExecution')
          ? value['sessionExecution']
          : false;
      if (execution is! bool) {
        throw FormatException('$label.sessionExecution must be a boolean.');
      }
      final services = value.containsKey('backendServices')
          ? value['backendServices']
          : const <String>[];
      if (services is! List<Object?> ||
          services.any((item) => item is! String)) {
        throw FormatException('$label.backendServices must be a string array.');
      }
      List<CapabilityKey> capabilityKeys(String field) => _capabilityKeys(
        value.containsKey(field) ? value[field] : const <Object?>[],
        '$label.$field',
      );
      final affinity = value.containsKey('strategyAffinity')
          ? switch (value['strategyAffinity']) {
              'independent' => PreparedStrategyAffinity.independent,
              'owningBackend' => PreparedStrategyAffinity.owningBackend,
              _ => throw FormatException(
                '$label.strategyAffinity is unsupported.',
              ),
            }
          : PreparedStrategyAffinity.independent;
      final actions = value.containsKey('actions')
          ? value['actions']
          : const <Object?>[];
      if (actions is! List<Object?>) {
        throw FormatException('$label.actions must be an array.');
      }
      final actionDescriptors = <PreparedMainContentAction>[];
      for (var index = 0; index < actions.length; index++) {
        final actionLabel = '$label.actions[$index]';
        final action = _object(actions[index], actionLabel, {
          'id',
          'label',
          'entrypoint',
        });
        actionDescriptors.add(
          PreparedMainContentAction(
            id: _text(action['id'], '$actionLabel.id'),
            label: _text(action['label'], '$actionLabel.label'),
            entrypoint: _entrypoint(
              action['entrypoint'],
              '$actionLabel.entrypoint',
            ),
          ),
        );
      }
      final operations = value.containsKey('operations')
          ? value['operations']
          : const <String, Object?>{};
      if (operations is! Map<String, Object?>) {
        throw FormatException('$label.operations must be an object.');
      }
      bool permission(String field) {
        final permission = value.containsKey(field) ? value[field] : false;
        if (permission is! bool) {
          throw FormatException('$label.$field must be a boolean.');
        }
        return permission;
      }

      return PreparedMainContentPresentation(
        extensionId: ExtensionId(text('extensionId')),
        order: order,
        library: _library(value['library'], '$label.library'),
        initialize: _entrypoint(value['initialize'], '$label.initialize'),
        entrypoint: _entrypoint(value['entrypoint'], '$label.entrypoint'),
        sessionExecution: execution,
        backendServices: services.cast<String>(),
        capabilities: capabilityKeys('capabilities'),
        environmentReadCapabilities: capabilityKeys(
          'environmentReadCapabilities',
        ),
        strategyAffinity: affinity,
        actions: actionDescriptors,
        operations: {
          for (final operation in operations.entries)
            _text(operation.key, '$label.operations key'): _entrypoint(
              operation.value,
              '$label.operations.${operation.key}',
            ),
        },
        closeOperation: value.containsKey('closeOperation')
            ? text('closeOperation')
            : null,
        exitOperation: value.containsKey('exitOperation')
            ? text('exitOperation')
            : null,
        displaySourceFileOperation:
            value.containsKey('displaySourceFileOperation')
            ? text('displaySourceFileOperation')
            : null,
        retainedData: permission('retainedData'),
        nativeCodeEditor: permission('nativeCodeEditor'),
        environmentTextFiles: permission('environmentTextFiles'),
        canRequestSourceDisplay: permission('canRequestSourceDisplay'),
      );
    case 'console':
      _object(value, label, {
        'role',
        'extensionId',
        'library',
        'entrypoint',
        'actions',
        'readOnly',
        'keepAlive',
        'backendServices',
      });
      final readOnly = value['readOnly'] ?? false;
      if (readOnly is! bool ||
          (value.containsKey('readOnly') && value['readOnly'] == null)) {
        throw FormatException('$label.readOnly must be a boolean.');
      }
      final keepAlive = value['keepAlive'] ?? false;
      if (keepAlive is! bool ||
          (value.containsKey('keepAlive') && value['keepAlive'] == null)) {
        throw FormatException('$label.keepAlive must be a boolean.');
      }
      final services = value.containsKey('backendServices')
          ? value['backendServices']
          : const <String>[];
      if (services is! List<Object?> ||
          services.any((item) => item is! String)) {
        throw FormatException('$label.backendServices must be a string array.');
      }
      final actions = value['actions'];
      if (actions is! List<Object?>) {
        throw FormatException('$label.actions must be an array.');
      }
      final descriptors = <PreparedConsoleAction>[];
      for (var index = 0; index < actions.length; index++) {
        final actionLabel = '$label.actions[$index]';
        final action = _object(actions[index], actionLabel, {
          'id',
          'label',
          'entrypoint',
        });
        descriptors.add(
          PreparedConsoleAction(
            id: _text(action['id'], '$actionLabel.id'),
            label: _text(action['label'], '$actionLabel.label'),
            entrypoint: _entrypoint(
              action['entrypoint'],
              '$actionLabel.entrypoint',
            ),
          ),
        );
      }
      return PreparedConsolePresentation(
        extensionId: ExtensionId(text('extensionId')),
        library: _library(value['library'], '$label.library'),
        entrypoint: _entrypoint(value['entrypoint'], '$label.entrypoint'),
        actions: descriptors,
        readOnly: readOnly,
        keepAlive: keepAlive,
        backendServices: services.cast<String>(),
      );
    case 'taskBrowser':
      _object(value, label, {
        'role',
        'library',
        'extensionId',
        'displayName',
        'entrypoint',
      });
      return PreparedTaskBrowserPresentation(
        extensionId: ExtensionId(text('extensionId')),
        displayName: text('displayName'),
        library: text('library'),
        entrypoint: text('entrypoint'),
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
        'backendServices',
        'consoleExtensions',
      });
      final services = value.containsKey('backendServices')
          ? value['backendServices']
          : const <String>[];
      if (services is! List<Object?> ||
          services.any((item) => item is! String)) {
        throw FormatException('$label.backendServices must be a string array.');
      }
      final consoles = value.containsKey('consoleExtensions')
          ? value['consoleExtensions']
          : const <String>[];
      if (consoles is! List<Object?> ||
          consoles.any((item) => item is! String)) {
        throw FormatException(
          '$label.consoleExtensions must be a string array.',
        );
      }
      return PreparedToolActivityPresentation(
        toolId: ToolId(text('toolId')),
        inspectionExtensionId: ExtensionId(text('inspectionExtensionId')),
        compactExtensionId: ExtensionId(text('compactExtensionId')),
        inspectionEntrypoint: text('inspectionEntrypoint'),
        compactEntrypoint: text('compactEntrypoint'),
        library: text('library'),
        backendServices: services.cast<String>(),
        consoleExtensions: consoles.cast<String>().map(ExtensionId.new),
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

List<CapabilityKey> _backendConsumedCapabilityKeys(
  Iterable<CapabilityKey> capabilities,
) {
  final keys = <CapabilityKey>[];
  final seen = <CapabilityKey>{};
  for (final key in capabilities) {
    if (keys.length ==
        PreparedPluginInstallation.maxBackendConsumedCapabilities) {
      throw const FormatException(
        'backend.consumesCapabilities must not exceed '
        '${PreparedPluginInstallation.maxBackendConsumedCapabilities} entries.',
      );
    }
    if (!seen.add(key)) {
      throw const FormatException(
        'backend.consumesCapabilities must not contain duplicates.',
      );
    }
    keys.add(key);
  }
  return List.unmodifiable(keys);
}

List<CapabilityKey> _capabilityKeys(
  Object? value,
  String label, {
  int? maxEntries,
}) {
  if (value is! List<Object?>) {
    throw FormatException('$label must be an array.');
  }
  if (maxEntries != null && value.length > maxEntries) {
    throw FormatException('$label must not exceed $maxEntries entries.');
  }
  final keys = <CapabilityKey>[];
  for (var index = 0; index < value.length; index++) {
    final capabilityLabel = '$label[$index]';
    final capability = _object(value[index], capabilityLabel, {
      'id',
      'majorVersion',
    });
    final majorVersion = capability['majorVersion'];
    if (majorVersion is! int) {
      throw FormatException(
        '$capabilityLabel.majorVersion must be an integer.',
      );
    }
    try {
      keys.add(
        CapabilityKey(
          id: CapabilityId(_text(capability['id'], '$capabilityLabel.id')),
          majorVersion: majorVersion,
        ),
      );
    } on CapabilityException catch (error) {
      throw FormatException('$capabilityLabel: ${error.message}');
    }
  }
  return keys;
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

String _library(Object? value, String label) {
  final library = _text(value, label);
  if (!RegExp(
        r'^package:[a-z_][a-z0-9_]*/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.dart$',
      ).hasMatch(library) ||
      library.split('/').any((part) => part == '.' || part == '..')) {
    throw FormatException(
      '$label must be a canonical package: URI to a Dart library '
      'without traversal.',
    );
  }
  return library;
}

String _consoleActionId(Object? value, String label) {
  final id = _text(value, label);
  if (id.length > 128 ||
      !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(id)) {
    throw FormatException('$label must be a bounded ASCII identifier.');
  }
  return id;
}

String _entrypoint(Object? value, String label) {
  final entrypoint = _text(value, label);
  if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(entrypoint)) {
    throw FormatException('$label must be a single top-level Dart identifier.');
  }
  return entrypoint;
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
