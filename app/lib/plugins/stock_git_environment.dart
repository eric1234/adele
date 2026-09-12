import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

// Provisional stock exposure metadata until plugin activation advertises it.
const String stockGitEnvironmentPluginId = 'dev.adele.plugin.git-environment';
final ProviderId stockGitEnvironmentProviderId = ProviderId(
  'dev.adele.environment.git-worktree',
);

Future<PluginCapabilityActivation> activateStockGitEnvironment({
  required PluginBackendHost host,
  required CapabilityRegistry registry,
  required Uri artifactUri,
}) async {
  final PluginBackendConnection connection = await host.startPlugin(
    pluginId: stockGitEnvironmentPluginId,
    artifactUri: artifactUri,
  );
  try {
    return await PluginCapabilityActivation.register(
      connection: connection,
      registry: registry,
      exposures: [
        PluginCapabilityExposure(
          provider: ProviderDescriptor(
            id: stockGitEnvironmentProviderId,
            capability: environmentProviderCapability,
            pluginId: stockGitEnvironmentPluginId,
            displayName: 'Git Worktree Environment',
            serviceId: environmentProviderServiceId,
          ),
          configurationContext: connection.defaultConfigurationContext,
        ),
      ],
    );
  } on Object {
    try {
      await connection.close();
    } on Object {
      // Preserve registration failure; the owning bootstrap also closes its host.
    }
    rethrow;
  }
}
