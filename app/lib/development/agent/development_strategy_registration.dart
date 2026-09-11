import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

final OrchestrationStrategyId developmentToolLoopStrategyId =
    OrchestrationStrategyId('dev.adele.strategy.development-tool-loop');

/// Transitional metadata only; the development runner still sequences directly.
ExtensionRegistration registerDevelopmentToolLoopStrategy(
  ExtensionRegistry extensions,
) => extensions.register(
  point: orchestrationStrategyContributions,
  id: ExtensionId('dev.adele.development.tool-loop-registration'),
  value: OrchestrationStrategyContribution(
    strategyId: developmentToolLoopStrategyId,
  ),
);
