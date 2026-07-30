import 'dart:io';

import 'package:adele_desktop/development/workspace_demo/workspace_demo_eval_adapter.dart';
import 'package:adele_desktop/development/workspace_demo/workspace_demo_eval_bridge.dart';
import 'package:adele_desktop/development/workspace_demo/workspace_demo_proxy.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

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
  WorkspaceDemoEvalAdapter? _eval;

  String? buildId;
  int? get hostProcessId => _host?.processId;
  Widget? get interpretedWidget => _eval?.widget;

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
      final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
        service: WorkspaceDemoProxy(_connection!),
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
    } on Object {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _eval?.invalidate();
    _eval = null;
    final PluginBackendConnection? connection = _connection;
    _connection = null;
    if (connection != null) await connection.close();
    final PluginBackendHost? host = _host;
    _host = null;
    if (host != null) await host.close();
    buildId = null;
  }
}
