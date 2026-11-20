import 'dart:io';
import 'dart:isolate';

import '../../../tools/backend_artifacts.dart';
import '../../tool/agent_configuration_frontend_compiler.dart';

const agentConfigurationPluginId = 'dev.adele.plugin.agent-configuration';

/// Publish the stock selector and schema beside the fixture's compiled backend.
Future<void> publishAgentSelector(Directory installationDirectory) async {
  final repository = Directory.current.parent;
  // The pinned compiler caches bridge type indices. Do not share them with a
  // previously compiled strategy or another accessory in the same test process.
  final bytes = await Isolate.run(
    () => compileAgentConfigurationFrontend(repositoryRoot: repository),
  );
  await File('${installationDirectory.path}/frontend.evc').writeAsBytes(bytes);
  await publishStockPluginInstallation(
    repositoryRoot: repository,
    installationDirectory: installationDirectory,
    pluginId: agentConfigurationPluginId,
    displayName: 'Agent Configuration',
    backend: true,
    frontend: true,
  );
}
