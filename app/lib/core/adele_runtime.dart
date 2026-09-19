import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

import 'application_plugin_bootstrap.dart';
import 'product_lifecycle.dart';

/// Application-lifetime host graph without implicit plugin activations.
/// Providers and product operations are established separately by callers.
final class AdeleRuntime {
  AdeleRuntime({ProductIdSource? ids}) {
    plugins = ApplicationPluginBootstrap(registry, extensions);
    lifecycle = ProductLifecycleCoordinator.generated(
      store: store,
      registry: registry,
      extensions: extensions,
      ids: ids,
    );
    contextComposer = InferenceContextComposer(extensions);
  }

  final CapabilityRegistry registry = CapabilityRegistry();
  final ExtensionRegistry extensions = ExtensionRegistry();
  final InMemoryProductStore store = InMemoryProductStore();
  late final ProductLifecycleCoordinator lifecycle;
  late final InferenceContextComposer contextComposer;
  late final ApplicationPluginBootstrap plugins;
  Future<void>? _closing;

  /// Closes the installed backend resources owned by this runtime.
  /// Concurrent and subsequent callers observe the same completion or failure.
  Future<void> close() => _closing ??= plugins.close();
}
