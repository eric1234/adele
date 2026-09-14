import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_orchestration/adele_orchestration.dart'
    show ToolInvocationActivity;
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:flutter/widgets.dart';

/// Read-only observation of one invocation. Its invocation and Tool identities
/// remain fixed for the source's lifetime; updates replace only the snapshot.
/// Presentation may listen, but neither disposes the source nor gains authority
/// to execute a tool or resolve an approval.
abstract interface class ToolActivityInspectionSource implements Listenable {
  ToolInvocationActivity get snapshot;
}

/// Exactly one contribution may inspect the invocation's exact semantic Tool ID.
final ExtensionPoint<ToolActivityInspectionContribution>
toolActivityInspectionContributions =
    ExtensionPoint<ToolActivityInspectionContribution>(
      'dev.adele.extension.tool-activity-inspections',
    );

final class ToolActivityInspectionContribution {
  const ToolActivityInspectionContribution({
    required this.toolId,
    required this.createPresentation,
  });

  final ToolId toolId;

  /// Creates read-only presentation, retained across updates to the same source.
  /// Resources follow widget lifecycle and the exact registration binding.
  final Widget Function(ToolActivityInspectionSource) createPresentation;
}

final class ToolActivityInspectionResolver {
  const ToolActivityInspectionResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<ToolActivityInspectionContribution> resolve(ToolId toolId) {
    final List<ExtensionBinding<ToolActivityInspectionContribution>> matches = [
      for (final binding in _registry.discover(
        toolActivityInspectionContributions,
      ))
        if (binding.value.toolId == toolId) binding,
    ];
    if (matches.isEmpty) throw ToolActivityInspectionUnavailable(toolId);
    if (matches.length > 1) {
      throw AmbiguousToolActivityInspection(
        toolId,
        matches.map((binding) => binding.id),
      );
    }
    return matches.single;
  }
}

final class ToolActivityInspectionUnavailable implements Exception {
  const ToolActivityInspectionUnavailable(this.toolId);

  final ToolId toolId;

  @override
  String toString() =>
      'ToolActivityInspectionUnavailable: Tool $toolId has no inspection.';
}

final class AmbiguousToolActivityInspection implements Exception {
  AmbiguousToolActivityInspection(
    this.toolId,
    Iterable<ExtensionId> extensionIds,
  ) : extensionIds = List<ExtensionId>.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((a, b) => a.value.compareTo(b.value)),
      );

  final ToolId toolId;
  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'AmbiguousToolActivityInspection: Tool $toolId has inspections '
      'from ${extensionIds.join(', ')}.';
}
