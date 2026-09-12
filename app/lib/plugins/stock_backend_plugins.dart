import 'dart:io';

import '../core/application_plugin_bootstrap.dart';
import 'stock_git_environment.dart';

/// Temporary stock composition, replaceable by discovery/profile activation.
/// Locations are deployment inputs, not source-checkout compilation instructions.
Future<void> bootstrapStockBackendPlugins(
  ApplicationPluginBootstrap plugins, {
  String dartaotruntimeExecutable = const String.fromEnvironment(
    'ADELE_DARTAOTRUNTIME_EXECUTABLE',
  ),
  String hostArtifactPath = const String.fromEnvironment(
    'ADELE_BACKEND_HOST_ARTIFACT',
  ),
  String gitEnvironmentArtifactPath = const String.fromEnvironment(
    'ADELE_GIT_ENVIRONMENT_ARTIFACT',
  ),
}) async {
  if (dartaotruntimeExecutable.isEmpty &&
      hostArtifactPath.isEmpty &&
      gitEnvironmentArtifactPath.isEmpty) {
    return;
  }
  await plugins.start(
    dartaotruntimeExecutable: dartaotruntimeExecutable,
    hostArtifactPath: hostArtifactPath,
    activate: [
      (host, registry) => activateStockGitEnvironment(
        host: host,
        registry: registry,
        artifactUri: File(gitEnvironmentArtifactPath).uri,
      ),
    ],
  );
}
