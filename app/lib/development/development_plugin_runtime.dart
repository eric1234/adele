import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/development/resource_inspector/resource_inspector_eval_adapter.dart';
import 'package:adele_desktop/development/resource_inspector/resource_inspector_eval_bridge.dart';
import 'package:adele_desktop/development/workspace_demo/workspace_demo_eval_adapter.dart';
import 'package:adele_desktop/development/workspace_demo/workspace_demo_eval_bridge.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';
import 'package:workspace_demo_contract/workspace_demo_contract.dart';

final class DevelopmentRuntimeConfiguration {
  const DevelopmentRuntimeConfiguration({
    required this.repositoryRoot,
    required this.pluginDirectory,
    required this.developmentDirectory,
    required this.dartExecutable,
    required this.dartAotRuntimeExecutable,
    required this.flutterExecutable,
  });

  factory DevelopmentRuntimeConfiguration.fromEnvironment() {
    String required(String name) {
      final String value = switch (name) {
        'ADELE_DEVELOPMENT_REPOSITORY_ROOT' => const String.fromEnvironment(
          'ADELE_DEVELOPMENT_REPOSITORY_ROOT',
        ),
        'ADELE_DEVELOPMENT_PLUGIN_DIRECTORY' => const String.fromEnvironment(
          'ADELE_DEVELOPMENT_PLUGIN_DIRECTORY',
        ),
        'ADELE_DEVELOPMENT_DIRECTORY' => const String.fromEnvironment(
          'ADELE_DEVELOPMENT_DIRECTORY',
        ),
        'ADELE_DEVELOPMENT_DART_EXECUTABLE' => const String.fromEnvironment(
          'ADELE_DEVELOPMENT_DART_EXECUTABLE',
        ),
        'ADELE_DEVELOPMENT_DARTAOTRUNTIME_EXECUTABLE' =>
          const String.fromEnvironment(
            'ADELE_DEVELOPMENT_DARTAOTRUNTIME_EXECUTABLE',
          ),
        'ADELE_DEVELOPMENT_FLUTTER_EXECUTABLE' => const String.fromEnvironment(
          'ADELE_DEVELOPMENT_FLUTTER_EXECUTABLE',
        ),
        _ => '',
      };
      if (value.isEmpty) throw StateError('Missing $name.');
      return value;
    }

    return DevelopmentRuntimeConfiguration(
      repositoryRoot: Directory(
        required('ADELE_DEVELOPMENT_REPOSITORY_ROOT'),
      ).absolute,
      pluginDirectory: Directory(
        required('ADELE_DEVELOPMENT_PLUGIN_DIRECTORY'),
      ).absolute,
      developmentDirectory: Directory(
        required('ADELE_DEVELOPMENT_DIRECTORY'),
      ).absolute,
      dartExecutable: required('ADELE_DEVELOPMENT_DART_EXECUTABLE'),
      dartAotRuntimeExecutable: required(
        'ADELE_DEVELOPMENT_DARTAOTRUNTIME_EXECUTABLE',
      ),
      flutterExecutable: required('ADELE_DEVELOPMENT_FLUTTER_EXECUTABLE'),
    );
  }

  final Directory repositoryRoot;
  final Directory pluginDirectory;
  final Directory developmentDirectory;
  final String dartExecutable;
  final String dartAotRuntimeExecutable;
  final String flutterExecutable;

  void validate() {
    for (final Directory directory in <Directory>[
      repositoryRoot,
      pluginDirectory,
      developmentDirectory,
    ]) {
      if (!directory.existsSync()) {
        throw StateError('Required directory is missing: ${directory.path}');
      }
    }
    for (final String executable in <String>[
      dartExecutable,
      dartAotRuntimeExecutable,
      flutterExecutable,
    ]) {
      if (!File(executable).existsSync()) {
        throw StateError('Required executable is missing: $executable');
      }
    }
  }
}

final class DevelopmentPluginRuntime {
  DevelopmentPluginRuntime(this.configuration);

  static const String workspaceDemoPluginId = 'dev.adele.workspace-demo';

  final DevelopmentRuntimeConfiguration configuration;
  final List<String> diagnostics = <String>[];
  PluginBackendHost? _host;
  PluginBackendConnection? _connection;
  final CapabilityRegistry capabilityRegistry = CapabilityRegistry();
  final List<PluginCapabilityActivation> _capabilityActivations =
      <PluginCapabilityActivation>[];
  final List<PluginBackendConnection> _capabilityConnections =
      <PluginBackendConnection>[];
  WorkspaceDemoEvalAdapter? _eval;
  ResourceInspectorEvalAdapter? _capabilityEval;

  String? buildId;
  int? get hostProcessId => _host?.processId;
  Widget? get interpretedWidget => _eval?.widget;
  Widget? get capabilityWidget => _capabilityEval?.widget;

  Future<void> buildAndStart() async {
    if (_host != null) {
      throw StateError('Development runtime is already active.');
    }
    configuration.validate();
    final DevelopmentPluginBuilder builder = const DevelopmentPluginBuilder();
    final PluginBuildResult pluginBuild = await builder.prepareBackend(
      repositoryRoot: configuration.repositoryRoot,
      pluginDirectory: configuration.pluginDirectory,
      dartExecutable: configuration.dartExecutable,
      flutterExecutable: configuration.flutterExecutable,
      expectedDartVersion: '3.10.9',
      expectedFlutterVersion: '3.38.10',
    );
    final BackendHostBuildResult hostBuild = await builder.buildBackendHost(
      repositoryRoot: configuration.repositoryRoot,
      dartExecutable: configuration.dartExecutable,
    );
    diagnostics.addAll(
      pluginBuild.diagnostics.map(
        (PluginBuildDiagnostic value) =>
            '${value.stage}: exit ${value.exitCode}',
      ),
    );
    diagnostics.add(
      '${hostBuild.diagnostic.stage}: exit ${hostBuild.diagnostic.exitCode}',
    );
    buildId = pluginBuild.buildId;
    try {
      _host = await PluginBackendHost.start(
        dartaotruntimeExecutable: configuration.dartAotRuntimeExecutable,
        hostArtifactPath: hostBuild.artifact.path,
        onDiagnostic: diagnostics.add,
      );
      _connection = await _host!.startPlugin(
        pluginId: workspaceDemoPluginId,
        artifactUri: pluginBuild.backendArtifact.uri,
        arguments: <String>[configuration.developmentDirectory.path],
      );
      await _startCapabilityExample(hostBuild.artifact.parent);
      final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
        service: WorkspaceDemoServiceClient(_connection!),
        developmentRoot: ResourceRef(
          uri: configuration.developmentDirectory.uri,
        ),
      );
      await WorkspaceDemoEvalAdapter.compile(
        pluginDirectory: configuration.pluginDirectory,
        artifact: pluginBuild.frontendArtifact,
        bridge: bridge,
      );
      await builder.activate(pluginBuild);
      _eval = await WorkspaceDemoEvalAdapter.load(
        artifact: pluginBuild.frontendArtifact,
        bridge: bridge,
      );
    } on Object catch (error, stackTrace) {
      try {
        await stop();
      } on Object catch (cleanupError) {
        diagnostics.add('startup cleanup failed: $cleanupError');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _startCapabilityExample(Directory artifactDirectory) async {
    final Directory root = configuration.repositoryRoot;
    final File basicArtifact = File(
      '${artifactDirectory.path}/resource-inspector-basic.aot',
    );
    final File alternateArtifact = File(
      '${artifactDirectory.path}/resource-inspector-alternate.aot',
    );
    await _compileBackend(
      '${root.path}/plugins/resource_inspector/packages/basic_backend/bin/resource_inspector_basic_backend.dart',
      basicArtifact,
    );
    await _compileBackend(
      '${root.path}/plugins/resource_inspector/packages/alternate_backend/bin/resource_inspector_alternate_backend.dart',
      alternateArtifact,
    );
    for (final ({
          String pluginId,
          File artifact,
          ProviderId providerId,
          String displayName,
        })
        value
        in <
          ({
            String pluginId,
            File artifact,
            ProviderId providerId,
            String displayName,
          })
        >[
          (
            pluginId: 'dev.adele.resource-inspector.basic-plugin',
            artifact: basicArtifact,
            providerId: basicResourceInspectorProviderId,
            displayName: 'Basic Inspector',
          ),
          (
            pluginId: 'dev.adele.resource-inspector.alternate-plugin',
            artifact: alternateArtifact,
            providerId: alternateResourceInspectorProviderId,
            displayName: 'Alternate Inspector',
          ),
        ]) {
      final PluginBackendConnection connection = await _host!.startPlugin(
        pluginId: value.pluginId,
        artifactUri: value.artifact.uri,
      );
      _capabilityConnections.add(connection);
      _capabilityActivations.add(
        await PluginCapabilityActivation.register(
          connection: connection,
          registry: capabilityRegistry,
          providers: <ProviderDescriptor>[
            ProviderDescriptor(
              id: value.providerId,
              capability: resourceInspectCapability,
              pluginId: value.pluginId,
              displayName: value.displayName,
              serviceId: resourceInspectorServiceId,
            ),
          ],
        ),
      );
    }
    final ResourceInspectorEvalBridge bridge = ResourceInspectorEvalBridge(
      registry: capabilityRegistry,
    );
    _capabilityEval = await ResourceInspectorEvalAdapter.compileAndLoad(
      repositoryRoot: root,
      bridge: bridge,
    );
  }

  Future<void> _compileBackend(String entrypoint, File artifact) async {
    final ProcessResult result = await Process.run(
      configuration.dartExecutable,
      <String>['compile', 'aot-snapshot', entrypoint, '-o', artifact.path],
      workingDirectory: configuration.repositoryRoot.path,
    );
    diagnostics.add('resource-inspector compile: exit ${result.exitCode}');
    if (result.exitCode != 0) {
      throw StateError(
        'Resource inspector compilation failed: ${result.stderr}',
      );
    }
  }

  Future<void> stop() async {
    final WorkspaceDemoEvalAdapter? eval = _eval;
    final ResourceInspectorEvalAdapter? capabilityEval = _capabilityEval;
    final PluginBackendConnection? connection = _connection;
    final PluginBackendHost? host = _host;
    _eval = null;
    _capabilityEval = null;
    _connection = null;
    _host = null;
    buildId = null;
    eval?.invalidate();
    capabilityEval?.invalidate();

    for (final PluginCapabilityActivation activation
        in _capabilityActivations.reversed) {
      try {
        await activation.retire();
      } on Object catch (error) {
        diagnostics.add('capability retirement failed: $error');
      }
    }
    _capabilityActivations.clear();
    for (final PluginBackendConnection capabilityConnection
        in _capabilityConnections.reversed) {
      try {
        if (!capabilityConnection.isClosed) await capabilityConnection.close();
      } on Object catch (error) {
        diagnostics.add('capability connection cleanup failed: $error');
      }
    }
    _capabilityConnections.clear();

    await cleanupDevelopmentRuntimeResources(
      closeConnection: connection?.close,
      closeHost: host == null
          ? null
          : ({required bool graceful}) => host.close(graceful: graceful),
      onCleanupError: (Object error) {
        diagnostics.add('backend-host cleanup failed: $error');
      },
    );
  }
}

Future<void> cleanupDevelopmentRuntimeResources({
  Future<void> Function()? closeConnection,
  Future<void> Function({required bool graceful})? closeHost,
  void Function(Object error)? onCleanupError,
}) async {
  Object? connectionError;
  StackTrace? connectionStack;
  try {
    await closeConnection?.call();
  } on Object catch (error, stackTrace) {
    connectionError = error;
    connectionStack = stackTrace;
  } finally {
    try {
      await closeHost?.call(graceful: connectionError == null);
    } on Object catch (hostError) {
      onCleanupError?.call(hostError);
      if (connectionError == null) rethrow;
    }
  }
  if (connectionError != null) {
    Error.throwWithStackTrace(connectionError, connectionStack!);
  }
}
