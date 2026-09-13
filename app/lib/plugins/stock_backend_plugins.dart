import 'dart:io';

import '../core/application_plugin_bootstrap.dart';
import 'stock_git_environment.dart';
import 'stock_openai.dart';

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
  String openaiArtifactPath = const String.fromEnvironment(
    'ADELE_OPENAI_ARTIFACT',
  ),
  StockChatGptConfiguration? chatGptConfiguration,
  void Function(Object error, StackTrace stackTrace)? onModelActivationFailure,
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
  if (plugins.state != ApplicationPluginState.ready ||
      openaiArtifactPath.isEmpty) {
    return;
  }
  try {
    final StockChatGptConfiguration? configuration = chatGptConfiguration;
    if (configuration == null) return;
    await plugins.activateAdditional(
      (host, registry) => activateStockChatGpt(
        host: host,
        registry: registry,
        artifactUri: File(openaiArtifactPath).uri,
        configuration: configuration,
      ),
    );
  } on Object catch (error, stackTrace) {
    // Model availability must not turn successful Git startup into Task failure.
    onModelActivationFailure?.call(error, stackTrace);
  }
}
