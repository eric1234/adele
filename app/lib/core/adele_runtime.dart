import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agents_md_plugin/agents_md_plugin.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:local_directory_project_selector_plugin/local_directory_project_selector_plugin.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

import 'product_lifecycle.dart';
import 'resource_cleanup.dart';

/// Application-lifetime host graph and implicit stock in-process composition.
/// Providers and product operations are established separately by callers.
final class AdeleRuntime {
  AdeleRuntime({ProductIdSource? ids, bool includeCommandTools = true}) {
    lifecycle = ProductLifecycleCoordinator.generated(
      store: store,
      registry: registry,
      extensions: extensions,
      ids: ids,
    );
    contextComposer = InferenceContextComposer(extensions);
    _activations = <ExtensionRegistration>[
      chat.activate(extensions),
      const AgentsMdPlugin().activate(extensions),
      const FilesystemToolsPlugin().activate(extensions),
      const SearchToolsPlugin().activate(extensions),
      // Retain the existing reduced live-smoke composition, not a profile API.
      if (includeCommandTools) const CommandToolsPlugin().activate(extensions),
      const LocalDirectoryProjectSelectorPlugin().activate(extensions),
    ];
  }

  final CapabilityRegistry registry = CapabilityRegistry();
  final ExtensionRegistry extensions = ExtensionRegistry();
  final InMemoryProductStore store = InMemoryProductStore();
  final ChatStrategyPlugin chat = ChatStrategyPlugin();
  late final ProductLifecycleCoordinator lifecycle;
  late final InferenceContextComposer contextComposer;
  late final List<ExtensionRegistration> _activations;
  Future<void>? _closing;

  /// Retires owned extensions in reverse activation order, attempting every close.
  /// Concurrent and subsequent callers observe the same completion or failure.
  Future<void> close() => _closing ??= closeResources(<Future<void> Function()>[
    for (final ExtensionRegistration activation in _activations.reversed)
      activation.close,
  ]);
}
