/// Experimental public ADELE orchestration strategy metadata API.
library;

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

export 'package:adele_product/adele_product.dart' show OrchestrationStrategyId;

final ExtensionPoint<OrchestrationStrategyContribution>
orchestrationStrategyContributions =
    ExtensionPoint<OrchestrationStrategyContribution>(
      'dev.adele.extension.orchestration-strategies',
    );

/// Metadata only; registering a strategy does not define its execution.
final class OrchestrationStrategyContribution {
  const OrchestrationStrategyContribution({required this.strategyId});

  final OrchestrationStrategyId strategyId;
}

final class OrchestrationStrategyResolver {
  const OrchestrationStrategyResolver(this._registry);

  final ExtensionRegistry _registry;

  ResolvedOrchestrationStrategy resolve(OrchestrationStrategyId strategyId) {
    final List<ExtensionBinding<OrchestrationStrategyContribution>> matches =
        <ExtensionBinding<OrchestrationStrategyContribution>>[
          for (final ExtensionBinding<OrchestrationStrategyContribution> binding
              in _registry.discover(orchestrationStrategyContributions))
            if (binding.value.strategyId == strategyId) binding,
        ];
    if (matches.isEmpty) {
      throw OrchestrationStrategyUnavailable(strategyId);
    }
    if (matches.length > 1) {
      throw AmbiguousOrchestrationStrategy(
        strategyId,
        matches.map(
          (ExtensionBinding<OrchestrationStrategyContribution> binding) =>
              binding.id,
        ),
      );
    }
    return ResolvedOrchestrationStrategy._(strategyId, matches.single);
  }
}

/// Retains the exact registration binding; it never retargets a replacement.
final class ResolvedOrchestrationStrategy {
  const ResolvedOrchestrationStrategy._(this.strategyId, this.binding);

  final OrchestrationStrategyId strategyId;
  final ExtensionBinding<OrchestrationStrategyContribution> binding;

  OrchestrationStrategyContribution get contribution => binding.value;

  void validateBinding() => binding.validate();
}

final class OrchestrationStrategyUnavailable implements Exception {
  const OrchestrationStrategyUnavailable(this.strategyId);

  final OrchestrationStrategyId strategyId;

  @override
  String toString() =>
      'OrchestrationStrategyUnavailable: Strategy $strategyId is unavailable.';
}

final class AmbiguousOrchestrationStrategy implements Exception {
  AmbiguousOrchestrationStrategy(
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
      'AmbiguousOrchestrationStrategy: Strategy $strategyId is contributed by '
      '${extensionIds.join(', ')}.';
}
