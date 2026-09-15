import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';

import 'tool_activity_inspection.dart';

/// Compact and Inspection presentations resolve independently for an exact Tool.
final ExtensionPoint<ToolActivityCompactPresentationContribution>
toolActivityCompactPresentationContributions =
    ExtensionPoint<ToolActivityCompactPresentationContribution>(
      'dev.adele.extension.tool-activity-compact-presentations',
    );

final class ToolActivityCompactPresentationContribution {
  const ToolActivityCompactPresentationContribution({
    required this.toolId,
    required this.createPresentation,
  });

  final ToolId toolId;

  /// A bounded, read-only summary, without navigation or approval authority.
  /// The exact registration and widget lifecycle own presentation resources.
  final Widget Function(ToolActivityInspectionSource) createPresentation;
}

final class ToolActivityCompactPresentationResolver {
  const ToolActivityCompactPresentationResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<ToolActivityCompactPresentationContribution> resolve(
    ToolId toolId,
  ) {
    final matches = [
      for (final binding in _registry.discover(
        toolActivityCompactPresentationContributions,
      ))
        if (binding.value.toolId == toolId) binding,
    ];
    if (matches.isEmpty) {
      throw ToolActivityCompactPresentationUnavailable(toolId);
    }
    if (matches.length > 1) {
      throw AmbiguousToolActivityCompactPresentation(
        toolId,
        matches.map((binding) => binding.id),
      );
    }
    return matches.single;
  }
}

final class ToolActivityCompactPresentationUnavailable implements Exception {
  const ToolActivityCompactPresentationUnavailable(this.toolId);

  final ToolId toolId;

  @override
  String toString() => 'Tool compact presentation is unavailable for $toolId.';
}

final class AmbiguousToolActivityCompactPresentation implements Exception {
  AmbiguousToolActivityCompactPresentation(
    this.toolId,
    Iterable<ExtensionId> extensionIds,
  ) : extensionIds = List<ExtensionId>.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final ToolId toolId;
  final List<ExtensionId> extensionIds;

  @override
  String toString() => 'Tool compact presentation is ambiguous for $toolId.';
}
