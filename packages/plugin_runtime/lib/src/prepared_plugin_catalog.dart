import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_core_extensions/commands.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_settings/adele_settings.dart';

/// One prepared installation, without activation, configured values, or source data.
final class PreparedPluginInstallation {
  PreparedPluginInstallation({
    required this.metadata,
    required this.installationDirectory,
    required this.backendArtifactUri,
    Iterable<CapabilityKey> backendConsumedCapabilities = const [],
    this.frontend,
    this.settingsSchema,
    this.recordsSchema,
  }) : backendConsumedCapabilities = _backendConsumedCapabilityKeys(
         backendConsumedCapabilities,
       ) {
    if (backendArtifactUri == null &&
        this.backendConsumedCapabilities.isNotEmpty) {
      throw const FormatException(
        'consumesCapabilities requires a backend component.',
      );
    }
    if (settingsSchema?.definitions.any(
          (definition) => definition.owner.value != metadata.id.value,
        ) ??
        false) {
      throw const FormatException('Settings schema owner must match PluginId.');
    }
    if (recordsSchema?.definitions.any(
          (definition) => definition.owner != metadata.id,
        ) ??
        false) {
      throw const FormatException('Records schema owner must match PluginId.');
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

  /// Installation-level declarations, independent of executable components.
  final PreparedSettingsSchema? settingsSchema;

  /// Named-record declarations, independent of settings and executable components.
  final PreparedRecordsSchema? recordsSchema;

  /// Encodes the backend's consumesCapabilities array, copying mutable data.
  List<Map<String, Object?>> backendConsumedCapabilitiesToJson() => [
    for (final key in backendConsumedCapabilities)
      {'id': key.id.value, 'majorVersion': key.majorVersion},
  ];
}

/// Validated declarative settings captured without executing plugin code.
final class PreparedSettingsSchema {
  PreparedSettingsSchema._({
    required this.artifactUri,
    required Iterable<SettingDefinition<Object>> definitions,
  }) : definitions = SettingsCatalog(definitions).definitions;

  static const schemaVersion = 1;
  static const maxBytes = 1024 * 1024;
  static const maxDefinitions = 256;
  static const maxEnumOptions = 128;
  static const maxIdLength = 256;
  static const maxLabelLength = 160;
  static const maxDescriptionLength = 4096;

  final Uri artifactUri;

  /// Immutable definitions in setting-ID order; owners derive from PluginId.
  final List<SettingDefinition<Object>> definitions;
}

/// Validated named-record declarations captured without executing plugin code.
final class PreparedRecordsSchema {
  PreparedRecordsSchema._({
    required this.artifactUri,
    required Iterable<RecordTypeDefinition> definitions,
  }) : definitions = RecordCatalog(definitions).definitions;

  static const schemaVersion = 1;
  static const maxBytes = 1024 * 1024;
  static const maxRecordTypes = 256;
  static const maxFields = 128;
  static const maxEnumOptions = 128;
  static const maxIdLength = 256;
  static const maxLabelLength = 160;
  static const maxDescriptionLength = 4096;

  final Uri artifactUri;

  /// Immutable definitions in type-ID order; field order remains authored order.
  final List<RecordTypeDefinition> definitions;
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
    Iterable<CapabilityKey> environmentReviewCapabilities = const [],
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
       environmentReviewCapabilities = List.unmodifiable(
         environmentReviewCapabilities,
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
    if (this.environmentReviewCapabilities.toSet().length !=
        this.environmentReviewCapabilities.length) {
      throw const FormatException(
        'environmentReviewCapabilities must not contain duplicates.',
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

  /// Explicit pane-only review operations; neither implied by nor granting reads
  /// through [environmentReadCapabilities] or context-free [capabilities].
  final List<CapabilityKey> environmentReviewCapabilities;
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
    'environmentReviewCapabilities': [
      for (final key in environmentReviewCapabilities)
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

/// An excluded installation, component, or schema. Healthy siblings remain usable.
final class PreparedPluginCatalogIssue {
  const PreparedPluginCatalogIssue({
    required this.installationDirectory,
    required this.message,
    this.pluginId,
    this.component,
    this.isSettingsSchemaIssue = false,
    this.isRecordsSchemaIssue = false,
  });

  final Directory installationDirectory;
  final String message;
  final PluginId? pluginId;

  /// Null for installation-wide failures or a declaration schema failure.
  final PreparedPluginComponent? component;

  /// True only when an installation's whole settings schema was rejected.
  /// The installation and its healthy executable components remain discoverable.
  final bool isSettingsSchemaIssue;

  /// True only when an installation's whole records schema was rejected.
  /// Settings and healthy executable components remain discoverable.
  final bool isRecordsSchemaIssue;

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

  /// Aggregates declarations in setting-ID order without activating plugins.
  ///
  /// Cross-installation collisions throw [DuplicateSettingId], including nested
  /// owner namespaces. Discovery never selects a winner or loses healthy code.
  SettingsCatalog get settings => SettingsCatalog([
    for (final installation in installations)
      ...?installation.settingsSchema?.definitions,
  ]);

  /// Aggregates record declarations without starting plugins or reading values.
  /// Duplicate types and inconsistent collection labels fail explicitly.
  RecordCatalog get records => RecordCatalog([
    for (final installation in installations)
      ...?installation.recordsSchema?.definitions,
  ]);

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
          'settingsSchema',
          'recordsSchema',
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
        PreparedSettingsSchema? settingsSchema;
        PreparedRecordsSchema? recordsSchema;
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
        if (document.containsKey('settingsSchema')) {
          try {
            settingsSchema = await _settingsSchema(
              document['settingsSchema'],
              resolvedDirectory,
              pluginMetadata.id,
            );
          } on FormatException catch (error) {
            issues.add(
              PreparedPluginCatalogIssue(
                installationDirectory: directory,
                pluginId: id,
                isSettingsSchemaIssue: true,
                message: 'Invalid settings schema: ${error.message}',
              ),
            );
          } on FileSystemException catch (error) {
            issues.add(
              PreparedPluginCatalogIssue(
                installationDirectory: directory,
                pluginId: id,
                isSettingsSchemaIssue: true,
                message: 'Unable to read settings schema: $error',
              ),
            );
          }
        }
        if (document.containsKey('recordsSchema')) {
          try {
            recordsSchema = await _recordsSchema(
              document['recordsSchema'],
              resolvedDirectory,
              pluginMetadata.id,
            );
          } on FormatException catch (error) {
            issues.add(
              PreparedPluginCatalogIssue(
                installationDirectory: directory,
                pluginId: id,
                isRecordsSchemaIssue: true,
                message: 'Invalid records schema: ${error.message}',
              ),
            );
          } on FileSystemException catch (error) {
            issues.add(
              PreparedPluginCatalogIssue(
                installationDirectory: directory,
                pluginId: id,
                isRecordsSchemaIssue: true,
                message: 'Unable to read records schema: $error',
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
            settingsSchema: settingsSchema,
            recordsSchema: recordsSchema,
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

Future<PreparedSettingsSchema> _settingsSchema(
  Object? reference,
  Directory directory,
  PluginId pluginId,
) async {
  final uri = await _artifact(reference, 'settingsSchema', directory);
  final document = await _schemaDocument(
    uri,
    'settingsSchema',
    PreparedSettingsSchema.maxBytes,
    {'schemaVersion', 'definitions'},
  );
  if (document['schemaVersion'] is! int ||
      document['schemaVersion'] != PreparedSettingsSchema.schemaVersion) {
    throw const FormatException(
      'settingsSchema.schemaVersion must be integer 1.',
    );
  }
  final definitions = document['definitions'];
  if (definitions is! List<Object?> ||
      definitions.length > PreparedSettingsSchema.maxDefinitions) {
    throw const FormatException(
      'settingsSchema.definitions must be an array with at most '
      '${PreparedSettingsSchema.maxDefinitions} entries.',
    );
  }
  final owner = SettingOwnerId(pluginId.value);
  try {
    return PreparedSettingsSchema._(
      artifactUri: uri,
      definitions: [
        for (var index = 0; index < definitions.length; index++)
          _settingDefinition(
            definitions[index],
            'settingsSchema.definitions[$index]',
            owner,
          ),
      ],
    );
  } on ArgumentError catch (error) {
    throw FormatException('settingsSchema: ${error.message}');
  } on InvalidSettingValue catch (error) {
    throw FormatException('settingsSchema: $error');
  } on DuplicateSettingId catch (error) {
    throw FormatException('settingsSchema: $error');
  }
}

Future<Map<String, Object?>> _schemaDocument(
  Uri uri,
  String label,
  int maxBytes,
  Set<String> fields,
) async {
  // Limit the read itself, not only the decoded document or a prior file stat.
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in File.fromUri(uri).openRead(0, maxBytes + 1)) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) {
      throw FormatException('$label must not exceed $maxBytes bytes.');
    }
  }
  return _object(jsonDecode(utf8.decode(bytes.takeBytes())), label, fields);
}

Future<PreparedRecordsSchema> _recordsSchema(
  Object? reference,
  Directory directory,
  PluginId owner,
) async {
  final uri = await _artifact(reference, 'recordsSchema', directory);
  final document = await _schemaDocument(
    uri,
    'recordsSchema',
    PreparedRecordsSchema.maxBytes,
    {'schemaVersion', 'recordTypes'},
  );
  if (document['schemaVersion'] is! int ||
      document['schemaVersion'] != PreparedRecordsSchema.schemaVersion) {
    throw const FormatException(
      'recordsSchema.schemaVersion must be integer 1.',
    );
  }
  final definitions = document['recordTypes'];
  if (definitions is! List<Object?> ||
      definitions.length > PreparedRecordsSchema.maxRecordTypes) {
    throw const FormatException(
      'recordsSchema.recordTypes must be an array with at most '
      '${PreparedRecordsSchema.maxRecordTypes} entries.',
    );
  }
  try {
    return PreparedRecordsSchema._(
      artifactUri: uri,
      definitions: [
        for (var index = 0; index < definitions.length; index++)
          _recordTypeDefinition(
            definitions[index],
            'recordsSchema.recordTypes[$index]',
            owner,
          ),
      ],
    );
  } on ArgumentError catch (error) {
    throw FormatException('recordsSchema: ${error.message}');
  } on DuplicateRecordTypeId catch (error) {
    throw FormatException('recordsSchema: $error');
  } on ConflictingRecordCollectionLabel catch (error) {
    throw FormatException('recordsSchema: $error');
  }
}

RecordTypeDefinition _recordTypeDefinition(
  Object? value,
  String label,
  PluginId owner,
) {
  final definition = _object(value, label, {
    'id',
    'collection',
    'collectionLabel',
    'label',
    'description',
    'fields',
  });
  final fields = definition['fields'];
  if (fields is! List<Object?> ||
      fields.length > PreparedRecordsSchema.maxFields) {
    throw FormatException(
      '$label.fields must be an array with at most '
      '${PreparedRecordsSchema.maxFields} entries.',
    );
  }
  return RecordTypeDefinition(
    id: RecordTypeId(
      _schemaText(
        definition['id'],
        '$label.id',
        PreparedRecordsSchema.maxIdLength,
      ),
    ),
    owner: owner,
    collection: RecordCollectionId(
      _text(definition['collection'], '$label.collection'),
    ),
    collectionLabel: _schemaText(
      definition['collectionLabel'],
      '$label.collectionLabel',
      PreparedRecordsSchema.maxLabelLength,
    ),
    label: _schemaText(
      definition['label'],
      '$label.label',
      PreparedRecordsSchema.maxLabelLength,
    ),
    description: definition.containsKey('description')
        ? _schemaText(
            definition['description'],
            '$label.description',
            PreparedRecordsSchema.maxDescriptionLength,
          )
        : null,
    fields: [
      for (var index = 0; index < fields.length; index++)
        _recordFieldDefinition(fields[index], '$label.fields[$index]'),
    ],
  );
}

RecordFieldDefinition<Object> _recordFieldDefinition(
  Object? value,
  String label,
) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$label must be an object.');
  }
  final kind = _text(value['type'], '$label.type');
  _object(value, label, {
    'id',
    'label',
    'description',
    'type',
    'required',
    if (kind == 'integer') ...['minimum', 'maximum'],
    if (kind == 'enum') 'options',
  });
  final required = value['required'];
  if (required is! bool) {
    throw FormatException('$label.required must be a boolean.');
  }
  return RecordFieldDefinition(
    id: RecordFieldId(_text(value['id'], '$label.id')),
    label: _schemaText(
      value['label'],
      '$label.label',
      PreparedRecordsSchema.maxLabelLength,
    ),
    description: value.containsKey('description')
        ? _schemaText(
            value['description'],
            '$label.description',
            PreparedRecordsSchema.maxDescriptionLength,
          )
        : null,
    type: _scalarType(
      value,
      label,
      maxEnumOptions: PreparedRecordsSchema.maxEnumOptions,
      maxLabelLength: PreparedRecordsSchema.maxLabelLength,
    ),
    required: required,
  );
}

SettingDefinition<Object> _settingDefinition(
  Object? value,
  String label,
  SettingOwnerId owner,
) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$label must be an object.');
  }
  final definition = value;
  final kind = _text(definition['type'], '$label.type');
  final allowed = {
    'id',
    'type',
    'default',
    'label',
    'category',
    'section',
    'description',
    if (kind == 'integer') ...['minimum', 'maximum'],
    if (kind == 'enum') 'options',
  };
  _object(definition, label, allowed);
  return SettingDefinition(
    id: SettingId(
      _schemaText(
        definition['id'],
        '$label.id',
        PreparedSettingsSchema.maxIdLength,
      ),
    ),
    owner: owner,
    label: _schemaText(
      definition['label'],
      '$label.label',
      PreparedSettingsSchema.maxLabelLength,
    ),
    category: _schemaText(
      definition['category'],
      '$label.category',
      PreparedSettingsSchema.maxLabelLength,
    ),
    section: _schemaText(
      definition['section'],
      '$label.section',
      PreparedSettingsSchema.maxLabelLength,
    ),
    description: definition.containsKey('description')
        ? _schemaText(
            definition['description'],
            '$label.description',
            PreparedSettingsSchema.maxDescriptionLength,
          )
        : null,
    type: _scalarType(
      definition,
      label,
      maxEnumOptions: PreparedSettingsSchema.maxEnumOptions,
      maxLabelLength: PreparedSettingsSchema.maxLabelLength,
    ),
    defaultValue: definition['default'],
  );
}

SettingType<Object> _scalarType(
  Map<String, Object?> definition,
  String label, {
  required int maxEnumOptions,
  required int maxLabelLength,
}) {
  final kind = _text(definition['type'], '$label.type');
  int? bound(String field) {
    if (!definition.containsKey(field)) return null;
    final value = definition[field];
    if (value is! int) {
      throw FormatException('$label.$field must be an integer.');
    }
    return value;
  }

  final SettingType<Object> type;
  switch (kind) {
    case 'boolean':
      type = const BooleanSettingType();
    case 'integer':
      type = IntegerSettingType(
        minimum: bound('minimum'),
        maximum: bound('maximum'),
      );
    case 'string':
      type = const StringSettingType();
    case 'enum':
      final options = definition['options'];
      if (options is! List<Object?> || options.length > maxEnumOptions) {
        throw FormatException(
          '$label.options must be an array with at most '
          '$maxEnumOptions entries.',
        );
      }
      type = EnumSettingType([
        for (var index = 0; index < options.length; index++)
          _settingEnumOption(
            options[index],
            '$label.options[$index]',
            maxLabelLength,
          ),
      ]);
    default:
      throw FormatException('$label.type is unsupported.');
  }
  return type;
}

SettingEnumOption _settingEnumOption(
  Object? value,
  String label,
  int maxLabelLength,
) {
  final option = _object(value, label, {'value', 'label'});
  return SettingEnumOption(
    _schemaText(option['value'], '$label.value', maxLabelLength),
    label: option.containsKey('label')
        ? _schemaText(option['label'], '$label.label', maxLabelLength)
        : null,
  );
}

String _schemaText(Object? value, String label, int limit) {
  final text = _text(value, label, blank: true);
  if (text.length > limit) {
    throw FormatException('$label must not exceed $limit UTF-16 code units.');
  }
  return text;
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
        'environmentReviewCapabilities',
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
        environmentReviewCapabilities: capabilityKeys(
          'environmentReviewCapabilities',
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
