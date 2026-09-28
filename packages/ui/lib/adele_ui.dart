/// Public semantic ADELE Task Browser, Session and activity presentation contracts.
library;

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

export 'package:adele_orchestration/adele_orchestration.dart'
    show ModelNativePresentation;

export 'console.dart';
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

/// Exactly one active contribution may present a Session's stored strategy.
/// Missing or ambiguous contributions are unavailable, never a default choice.
final ExtensionPoint<SessionPresentationContribution>
sessionPresentationContributions =
    ExtensionPoint<SessionPresentationContribution>(
      'dev.adele.extension.session-presentations',
    );

final class SessionPresentationContribution {
  const SessionPresentationContribution({
    required this.strategyId,
    required this.displayName,
    required this.createPresentation,
  });

  final OrchestrationStrategyId strategyId;
  final String displayName;

  /// Constructs presentation for the canonical Session without creating product
  /// state or starting execution. Presentation resources follow widget lifecycle.
  /// The host retains the widget and validates its exact registration binding.
  final Widget Function(Session) createPresentation;
}

/// Uses the existing registry and returns its exact binding, not a new registry
/// or a lifetime pin on the canonical Session's semantic strategy identity.
final class SessionPresentationResolver {
  const SessionPresentationResolver(this._registry);

  final ExtensionRegistry _registry;

  ExtensionBinding<SessionPresentationContribution> resolve(
    OrchestrationStrategyId strategyId,
  ) {
    final List<ExtensionBinding<SessionPresentationContribution>> matches =
        <ExtensionBinding<SessionPresentationContribution>>[
          for (final binding in _registry.discover(
            sessionPresentationContributions,
          ))
            if (binding.value.strategyId == strategyId) binding,
        ];
    if (matches.isEmpty) {
      throw SessionPresentationUnavailable(strategyId);
    }
    if (matches.length > 1) {
      throw AmbiguousSessionPresentation(
        strategyId,
        matches.map((binding) => binding.id),
      );
    }
    return matches.single;
  }
}

final class SessionPresentationUnavailable implements Exception {
  const SessionPresentationUnavailable(this.strategyId);

  final OrchestrationStrategyId strategyId;

  @override
  String toString() =>
      'SessionPresentationUnavailable: Strategy $strategyId has no presentation.';
}

final class AmbiguousSessionPresentation implements Exception {
  AmbiguousSessionPresentation(
    this.strategyId,
    Iterable<ExtensionId> extensionIds,
  ) : extensionIds = List<ExtensionId>.unmodifiable(
        List<ExtensionId>.of(extensionIds)
          ..sort((ExtensionId a, ExtensionId b) => a.value.compareTo(b.value)),
      );

  final OrchestrationStrategyId strategyId;
  final List<ExtensionId> extensionIds;

  @override
  String toString() =>
      'AmbiguousSessionPresentation: Strategy $strategyId has presentations '
      'from ${extensionIds.join(', ')}.';
}
