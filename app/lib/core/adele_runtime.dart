import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';

import 'application_plugin_bootstrap.dart';
import 'product_lifecycle.dart';
import 'resource_cleanup.dart';

/// Application-lifetime host graph and implicit stock in-process composition.
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
    _activations = <ExtensionRegistration>[chat.activate(extensions)];
  }

  final CapabilityRegistry registry = CapabilityRegistry();
  final ExtensionRegistry extensions = ExtensionRegistry();
  final InMemoryProductStore store = InMemoryProductStore();
  final ChatStrategyPlugin chat = ChatStrategyPlugin();
  late final ProductLifecycleCoordinator lifecycle;
  late final InferenceContextComposer contextComposer;
  late final ApplicationPluginBootstrap plugins;
  late final List<ExtensionRegistration> _activations;
  Future<void>? _closing;

  /// Closes backend resources, then owned extensions in reverse activation order.
  /// Concurrent and subsequent callers observe the same completion or failure.
  Future<void> close() => _closing ??= closeResources(<Future<void> Function()>[
    plugins.close,
    for (final ExtensionRegistration activation in _activations.reversed)
      activation.close,
  ]);
}
