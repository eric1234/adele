/// Public semantic ADELE Task Browser, Main Content and activity contracts.
library;

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

export 'package:adele_orchestration/adele_orchestration.dart'
    show ModelNativePresentation;

export 'console.dart';
export 'display_source_file.dart';
export 'main_content.dart';
export 'model_native_activity_compact_presentation.dart';
export 'model_native_activity_presentation.dart';
export 'tool_activity_compact_presentation.dart';
export 'tool_activity_inspection.dart';

/// Exactly one active contribution may present a Project's Task Browser.
final ExtensionPoint<TaskBrowserContribution> taskBrowserContributions =
    ExtensionPoint<TaskBrowserContribution>(
      'dev.adele.extension.task-browsers',
    );

final class TaskBrowserContribution {
  const TaskBrowserContribution({
    required this.displayName,
    required this.createPresentation,
  });

  final String displayName;

  /// Presentation invokes host lifecycle operations; it does not own product state.
  final Widget Function(Project) createPresentation;
}

final class TaskBrowserResolver {
  const TaskBrowserResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<TaskBrowserContribution> resolve() {
    final matches = _registry.discover(taskBrowserContributions).toList();
    if (matches.isEmpty) throw const TaskBrowserUnavailable();
    if (matches.length > 1) {
      throw AmbiguousTaskBrowser(matches.map((binding) => binding.id));
    }
    return matches.single;
  }
}

final class TaskBrowserUnavailable implements Exception {
  const TaskBrowserUnavailable();

  @override
  String toString() => 'TaskBrowserUnavailable: No Task Browser is available.';
}

final class AmbiguousTaskBrowser implements Exception {
  AmbiguousTaskBrowser(Iterable<ExtensionId> extensionIds)
    : extensionIds = List.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'AmbiguousTaskBrowser: Multiple Task Browsers: ${extensionIds.join(', ')}.';
}
