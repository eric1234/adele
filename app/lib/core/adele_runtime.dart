import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

import '../terminal/environment_terminal_owner.dart';
import 'application_plugin_bootstrap.dart';
import 'product_lifecycle.dart';
import 'project_storage_host.dart';
import 'run_id_source.dart';

/// Application-lifetime host graph without implicit plugin activations.
/// Providers and product operations are established separately by callers.
final class AdeleRuntime {
  AdeleRuntime({ProductIdSource? ids, RunIdSource? runIds})
    : runIds = runIds ?? MonotonicRunIdSource() {
    lifecycle = ProductLifecycleCoordinator.generated(
      store: store,
      registry: registry,
      extensions: extensions,
      ids: ids,
    );
    plugins = ApplicationPluginBootstrap(
      registry,
      extensions,
      createInfrastructureServices: (connection) =>
          projectStorageServices(lifecycle, connection),
    );
    contextComposer = InferenceContextComposer(extensions);
    terminals = EnvironmentTerminalCoordinator(
      environmentRuntime: lifecycle.environmentRuntime,
    );
  }

  final CapabilityRegistry registry = CapabilityRegistry();
  final ExtensionRegistry extensions = ExtensionRegistry();
  final InMemoryProductStore store = InMemoryProductStore();
  final RunIdSource runIds;
  late final ProductLifecycleCoordinator lifecycle;
  late final InferenceContextComposer contextComposer;
  late final ApplicationPluginBootstrap plugins;
  late final EnvironmentTerminalCoordinator terminals;
  Future<void>? _closing;

  /// Stops admission and grants terminal owners a bounded cleanup window before
  /// backend teardown. Database cleanup still joins backend shutdown so normal
  /// request revocation can settle outstanding product opens.
  /// Concurrent and subsequent callers observe the same completion or failure.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() {
    final terminalClosing = Future<void>.sync(terminals.close);
    final productClosing = Future<void>.sync(lifecycle.close);
    return Future.wait<void>([
      productClosing,
      terminalClosing.whenComplete(plugins.close),
    ]).then((_) {});
  }
}
