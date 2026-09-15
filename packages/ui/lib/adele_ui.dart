/// Public semantic ADELE Session and activity presentation contracts.
library;

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter/widgets.dart';

export 'package:adele_orchestration/adele_orchestration.dart'
    show ModelNativePresentation;

export 'model_native_activity_presentation.dart';
export 'tool_activity_inspection.dart';

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
    required this.createPresentation,
  });

  final OrchestrationStrategyId strategyId;

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
