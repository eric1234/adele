import 'dart:io';

import 'package:adele_desktop/phase1/eval/workspace_demo_eval_bridge.dart';
import 'package:adele_desktop/phase1/eval/workspace_demo_eval_runtime.dart';
import 'package:adele_desktop/phase1/workspace_demo/workspace_demo_proxy.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';
import 'package:plugin_builder/plugin_builder.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

final class Phase1Configuration {
  const Phase1Configuration({
    required this.repositoryRoot,
    required this.pluginDirectory,
    required this.developmentDirectory,
    required this.dartExecutable,
    required this.dartAotRuntimeExecutable,
    required this.flutterExecutable,
  });

  factory Phase1Configuration.fromEnvironment() {
    String required(String name) {
      final String value = switch (name) {
        'ADELE_PHASE1_REPOSITORY_ROOT' => const String.fromEnvironment(
          'ADELE_PHASE1_REPOSITORY_ROOT',
        ),
        'ADELE_PHASE1_PLUGIN_DIRECTORY' => const String.fromEnvironment(
          'ADELE_PHASE1_PLUGIN_DIRECTORY',
        ),
        'ADELE_PHASE1_DEVELOPMENT_DIRECTORY' => const String.fromEnvironment(
          'ADELE_PHASE1_DEVELOPMENT_DIRECTORY',
        ),
        'ADELE_PHASE1_DART_EXECUTABLE' => const String.fromEnvironment(
          'ADELE_PHASE1_DART_EXECUTABLE',
        ),
        'ADELE_PHASE1_DARTAOTRUNTIME_EXECUTABLE' =>
          const String.fromEnvironment(
            'ADELE_PHASE1_DARTAOTRUNTIME_EXECUTABLE',
          ),
        'ADELE_PHASE1_FLUTTER_EXECUTABLE' => const String.fromEnvironment(
          'ADELE_PHASE1_FLUTTER_EXECUTABLE',
        ),
        _ => '',
      };
      if (value.isEmpty) throw StateError('Missing $name.');
      return value;
    }

    final Directory repository = Directory(
      required('ADELE_PHASE1_REPOSITORY_ROOT'),
    ).absolute;
    return Phase1Configuration(
      repositoryRoot: repository,
      pluginDirectory: Directory(
        required('ADELE_PHASE1_PLUGIN_DIRECTORY'),
      ).absolute,
      developmentDirectory: Directory(
        required('ADELE_PHASE1_DEVELOPMENT_DIRECTORY'),
      ).absolute,
      dartExecutable: required('ADELE_PHASE1_DART_EXECUTABLE'),
      dartAotRuntimeExecutable: required(
        'ADELE_PHASE1_DARTAOTRUNTIME_EXECUTABLE',
      ),
      flutterExecutable: required('ADELE_PHASE1_FLUTTER_EXECUTABLE'),
    );
  }

  final Directory repositoryRoot;
  final Directory pluginDirectory;
  final Directory developmentDirectory;
  final String dartExecutable;
  final String dartAotRuntimeExecutable;
  final String flutterExecutable;

  void validate() {
    if (!repositoryRoot.existsSync()) {
      throw StateError('Repository root missing.');
    }
    if (!pluginDirectory.existsSync()) {
      throw StateError('Plugin directory missing.');
    }
    if (!developmentDirectory.existsSync()) {
      throw StateError('Development directory missing.');
    }
    if (!File(dartExecutable).existsSync()) {
      throw StateError('Dart executable missing.');
    }
    if (!File(dartAotRuntimeExecutable).existsSync()) {
      throw StateError('Dart AOT runtime executable missing.');
    }
    if (!File(flutterExecutable).existsSync()) {
      throw StateError('Flutter executable missing.');
    }
  }
}

final class DevelopmentPluginController extends ChangeNotifier {
  DevelopmentPluginController(this.configuration);

  final Phase1Configuration configuration;
  final List<String> diagnostics = <String>[];
  String phase = 'inactive';
  String backendState = 'stopped';
  String frontendState = 'inactive';
  String connectionState = 'disconnected';
  String? buildId;
  String? lastFailure;
  bool busy = false;
  PluginBackendConnection? _connection;
  PluginBackendHost? _backendHost;
  WorkspaceDemoEvalRuntime? _eval;

  Widget? get interpretedWidget => _eval?.widget;
  int? get backendHostProcessId => _backendHost?.processId;

  Future<void> buildAndStart() async {
    if (busy) return;
    busy = true;
    lastFailure = null;
    _stage('configuration');
    try {
      configuration.validate();
      _stage('backend-compilation');
      final PluginBuildResult build = await const DevelopmentPluginBuilder()
          .prepareBackend(
            repositoryRoot: configuration.repositoryRoot,
            pluginDirectory: configuration.pluginDirectory,
            dartExecutable: configuration.dartExecutable,
            flutterExecutable: configuration.flutterExecutable,
            expectedDartVersion: '3.10.9',
            expectedFlutterVersion: '3.38.10',
          );
      for (final PluginBuildDiagnostic diagnostic in build.diagnostics) {
        diagnostics.add(
          '${diagnostic.stage}: exit ${diagnostic.exitCode} in ${diagnostic.workingDirectory}',
        );
      }
      buildId = build.buildId;
      _stage('backend-host-compilation');
      final BackendHostBuildResult hostBuild =
          await const DevelopmentPluginBuilder().buildBackendHost(
            repositoryRoot: configuration.repositoryRoot,
            dartExecutable: configuration.dartExecutable,
          );
      diagnostics.add(
        '${hostBuild.diagnostic.stage}: exit ${hostBuild.diagnostic.exitCode}',
      );
      _stage('backend-launch');
      _backendHost = await PluginBackendHost.start(
        dartaotruntimeExecutable: configuration.dartAotRuntimeExecutable,
        hostArtifactPath: hostBuild.artifact.path,
        onDiagnostic: diagnostics.add,
      );
      _connection = await _backendHost!.startPlugin(
        pluginId: 'dev.adele.workspace-demo',
        artifactUri: build.backendArtifact.uri,
        arguments: <String>[configuration.developmentDirectory.path],
      );
      backendState = 'running';
      connectionState = 'connected';
      final WorkspaceDemoEvalBridge bridge = WorkspaceDemoEvalBridge(
        service: WorkspaceDemoProxy(_connection!),
        developmentRoot: ResourceRef(
          uri: configuration.developmentDirectory.uri,
        ),
      );
      _stage('frontend-compilation');
      await WorkspaceDemoEvalRuntime.compile(
        pluginDirectory: configuration.pluginDirectory,
        artifact: build.frontendArtifact,
        bridge: bridge,
      );
      await const DevelopmentPluginBuilder().activate(build);
      _stage('frontend-runtime');
      _eval = await WorkspaceDemoEvalRuntime.load(
        artifact: build.frontendArtifact,
        bridge: bridge,
      );
      frontendState = 'rendering';
      phase = 'running';
    } on Object catch (error, stackTrace) {
      lastFailure = error.toString();
      diagnostics.add('$phase: $error\n$stackTrace');
      await _stopResources();
      phase = 'failed';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (busy) return;
    busy = true;
    _stage('shutdown');
    _eval?.invalidate();
    _eval = null;
    frontendState = 'inactive';
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    await _stopResources();
    phase = 'inactive';
    buildId = null;
    busy = false;
    notifyListeners();
  }

  Future<void> rebuildAndReload() async {
    await stop();
    await buildAndStart();
  }

  Future<void> _stopResources() async {
    _eval?.invalidate();
    _eval = null;
    frontendState = 'inactive';
    final PluginBackendConnection? connection = _connection;
    _connection = null;
    connectionState = 'disconnected';
    if (connection != null) await connection.close();
    final PluginBackendHost? backendHost = _backendHost;
    _backendHost = null;
    if (backendHost != null) await backendHost.close();
    backendState = 'stopped';
  }

  void _stage(String value) {
    phase = value;
    diagnostics.add(value);
    notifyListeners();
  }

  @override
  void dispose() {
    _eval?.invalidate();
    _connection = null;
    super.dispose();
  }
}
