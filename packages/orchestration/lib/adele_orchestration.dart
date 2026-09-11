/// Public provider-neutral ADELE orchestration strategy execution API.
library;

import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

import 'src/model.dart';
import 'src/run.dart';
import 'src/tool.dart';

export 'package:adele_model_tool/adele_model_tool.dart'
    show ToolOutcome, ToolOutcomeDisposition, ToolFailureKind, EffectCertainty;
export 'package:adele_product/adele_product.dart'
    show OrchestrationStrategyId, RunId, SessionId, Session;

export 'src/context.dart';
export 'src/model.dart';
export 'src/run.dart';
export 'src/tool.dart';

final ExtensionPoint<OrchestrationStrategyContribution>
orchestrationStrategyContributions =
    ExtensionPoint<OrchestrationStrategyContribution>(
      'dev.adele.extension.orchestration-strategies',
    );

final class OrchestrationStrategyContribution {
  const OrchestrationStrategyContribution({
    required this.strategyId,
    required this.materialize,
  });

  final OrchestrationStrategyId strategyId;

  /// Constructs an execution without starting Run or model/tool work. The host
  /// keeps execution disabled until the application enters the returned execution.
  final OrchestrationExecution Function(OrchestrationStrategyHostContext)
  materialize;
}

abstract interface class OrchestrationExecution {
  Future<void> start();

  Future<void> resolveApproval(ToolApprovalResolution resolution);
}

final class OrchestrationStrategyHostContext {
  OrchestrationStrategyHostContext({
    required this.session,
    required this.host,
  }) {
    if (session.id != host.sessionId) {
      throw ArgumentError('Host and Session identities must match.');
    }
  }

  final Session session;
  final OrchestrationExecutionHost host;
}

/// Owns execution authority and retained approvals, not strategy sequencing.
/// Implementations validate the retained strategy binding on execution operations
/// and serialize them with lifecycle changes. Failure cleanup remains possible
/// after retirement, but must not discard an active operation's terminal evidence.
abstract interface class OrchestrationExecutionHost {
  RunId get id;
  SessionId get sessionId;
  RunState get state;

  void validateBinding();
  void start();
  void complete();
  void fail(Object error);

  Future<StrategyModelTurn> invokeModel(StrategyInferenceMaterial material);

  Future<StrategyToolResult> processProposal({
    required StrategyToolSnapshot tools,
    required ProviderToolProposal proposal,
  });

  /// Applies the exact resolution supplied to the current host-issued resume.
  /// A strategy cannot authorize itself by constructing another resolution.
  Future<SemanticToolOutcomeInput> resolveApproval(
    ToolApprovalResolution resolution,
  );
}

/// Opaque host-owned tool materialization retained for one model turn.
abstract interface class StrategyToolSnapshot {}

final class StrategyModelTurn {
  StrategyModelTurn.settled({
    required this.tools,
    required Iterable<ModelOutputItem> output,
    ModelSettlement this.settlement = ModelSettlement.completed,
    this.incompleteReason,
    ModelTerminalMetadata? metadata,
  }) : output = List<ModelOutputItem>.unmodifiable(output),
       metadata = metadata ?? ModelTerminalMetadata(),
       failure = null {
    if ((settlement == ModelSettlement.incomplete) !=
        (incompleteReason != null)) {
      throw const FormatException(
        'Only incomplete settlement requires an incomplete reason.',
      );
    }
  }

  StrategyModelTurn.failed({
    required this.tools,
    required Iterable<ModelOutputItem> output,
    required Object error,
  }) : output = List<ModelOutputItem>.unmodifiable(output),
       settlement = null,
       incompleteReason = null,
       metadata = null,
       failure = error;

  final StrategyToolSnapshot tools;
  final List<ModelOutputItem> output;
  final ModelSettlement? settlement;
  final ModelIncompleteReason? incompleteReason;
  final ModelTerminalMetadata? metadata;
  final Object? failure;
}

sealed class StrategyToolResult {
  const StrategyToolResult();
}

final class StrategyToolContinuation extends StrategyToolResult {
  const StrategyToolContinuation(this.item);

  final SemanticModelInputItem item;
}

final class StrategyToolWaiting extends StrategyToolResult {
  const StrategyToolWaiting();
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

  /// Validates materialization; callers also guard the returned execution's
  /// entrypoints with this exact binding.
  OrchestrationExecution materialize(OrchestrationStrategyHostContext context) {
    void validateContext() {
      validateBinding();
      if (context.session.strategyId != strategyId) {
        throw ArgumentError('Session and contribution strategies must match.');
      }
      if (context.session.id != context.host.sessionId) {
        throw ArgumentError('Host and Session identities must match.');
      }
      context.host.validateBinding();
    }

    validateContext();
    final OrchestrationExecution execution = contribution.materialize(context);
    validateContext();
    return execution;
  }
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
