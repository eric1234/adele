import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_product/adele_product.dart';

import 'model.dart';
import 'run.dart';
import 'tool.dart';

/// Read-only Run-local evidence, independent of strategy-owned Session history.
abstract interface class RunActivitySource {
  /// Current immutable value, readable before start and after terminal settlement.
  RunActivitySnapshot get snapshot;

  /// Asynchronous, coalesced invalidations, not an event log or text-delta stream.
  /// Read [snapshot] initially and after notifications. Cancelling a subscription
  /// only detaches observation; it never cancels execution. Listener errors belong
  /// to the subscriber's Zone and cannot fail the Run.
  Stream<void> get changes;
}

final class RunActivitySnapshot {
  RunActivitySnapshot({
    required this.runId,
    required this.sessionId,
    required this.state,
    required this.sequence,
    Iterable<RunLifecycleActivity> lifecycle = const [],
    Iterable<ModelInvocationActivity> models = const [],
    Iterable<ToolInvocationActivity> tools = const [],
    Iterable<RejectedToolProposalActivity> rejectedProposals = const [],
    this.failure,
  }) : lifecycle = List.unmodifiable(lifecycle),
       models = List.unmodifiable(models),
       tools = List.unmodifiable(tools),
       rejectedProposals = List.unmodifiable(rejectedProposals);

  final RunId runId;
  final SessionId sessionId;
  final RunState state;

  /// Last projected journal sequence (zero initially); omitted observations may
  /// leave gaps. Every sequence in this read model is scoped to [runId].
  final int sequence;
  final List<RunLifecycleActivity> lifecycle;
  final List<ModelInvocationActivity> models;
  final List<ToolInvocationActivity> tools;
  final List<RejectedToolProposalActivity> rejectedProposals;
  final ActivityFailure? failure;
}

final class RunLifecycleActivity {
  const RunLifecycleActivity({required this.sequence, required this.state});

  final int sequence;
  final RunState state;
}

/// Deliberately data-only failure evidence, never an exception or stack trace.
final class ActivityFailure {
  ActivityFailure({
    required this.kind,
    required this.message,
    this.providerCode,
    Map<String, Object?> providerDetails = const {},
  }) : providerDetails = CanonicalToolArguments(providerDetails).snapshot;

  final String kind;
  final String message;
  final String? providerCode;
  final Map<String, Object?> providerDetails;
}

final class ModelInvocationActivity {
  ModelInvocationActivity({
    required this.id,
    required this.startSequence,
    Iterable<ModelOutputActivity> outputs = const [],
    this.terminalSequence,
    this.settlement,
    this.incompleteReason,
    this.metadata,
    this.failure,
  }) : outputs = List.unmodifiable(outputs);

  final ModelInvocationId id;
  final int startSequence;
  final List<ModelOutputActivity> outputs;
  final int? terminalSequence;
  final ModelSettlement? settlement;
  final ModelIncompleteReason? incompleteReason;
  final ModelTerminalMetadata? metadata;
  final ActivityFailure? failure;
}

final class ModelOutputActivity {
  const ModelOutputActivity({required this.sequence, required this.item});

  /// Identity of the original completed-output occurrence, not a list index or
  /// provider item/call ID. Native and semantic items retain their exact order.
  final int sequence;
  final ModelOutputItem item;
}

enum ToolActivityKind {
  prepared,
  policyEvaluated,
  policyFailed,
  approvalRequested,
  approvalResolved,
  executionStarted,
  progress,
  completed,
}

enum ToolActivityPolicyDecision { allow, deny, ask }

/// Ordered evidence, not execution or approval authority. Optional payloads
/// belong to the corresponding [kind]; completion does not imply execution.
final class ToolActivityChange {
  const ToolActivityChange({
    required this.sequence,
    required this.kind,
    this.policyDecision,
    this.effects,
    this.interruptionId,
    this.approved,
    this.progress,
    this.outcome,
  });

  final int sequence;
  final ToolActivityKind kind;
  final ToolActivityPolicyDecision? policyDecision;
  final EffectDescription? effects;
  final RunInterruptionId? interruptionId;
  final bool? approved;
  final ToolProgress? progress;
  final ToolOutcomeActivity? outcome;
}

final class ToolInvocationActivity {
  ToolInvocationActivity({
    required this.id,
    required this.preparedSequence,
    required this.modelInvocationId,
    required this.proposalSequence,
    required this.toolId,
    required this.alias,
    required this.providerCallId,
    required Map<String, Object?> canonicalArguments,
    required Iterable<ToolActivityChange> changes,
    this.effects,
    this.outcome,
  }) : canonicalArguments = CanonicalToolArguments(canonicalArguments).snapshot,
       changes = List.unmodifiable(changes);

  final ToolInvocationId id;
  final int preparedSequence;
  final ModelInvocationId modelInvocationId;
  final int proposalSequence;
  final ToolId toolId;
  final String alias;
  final String providerCallId;
  final Map<String, Object?> canonicalArguments;
  final EffectDescription? effects;
  final List<ToolActivityChange> changes;
  final ToolOutcomeActivity? outcome;
}

/// ToolOutcome's public data, intentionally excluding cause and hostDiagnostic.
final class ToolOutcomeActivity {
  ToolOutcomeActivity({
    required this.disposition,
    required this.effectCertainty,
    required this.modelContent,
    this.failureKind,
    Map<String, Object?> hostData = const {},
  }) : hostData = CanonicalToolArguments(hostData).snapshot;

  final ToolOutcomeDisposition disposition;
  final ToolFailureKind? failureKind;
  final EffectCertainty effectCertainty;
  final String modelContent;
  final Map<String, Object?> hostData;
}

/// Rejection of a model proposal, not an executed or prepared tool invocation.
final class RejectedToolProposalActivity {
  const RejectedToolProposalActivity({
    required this.sequence,
    required this.modelInvocationId,
    required this.proposalSequence,
    required this.proposal,
    required this.kind,
    required this.message,
  });

  final int sequence;
  final ModelInvocationId modelInvocationId;
  final int proposalSequence;
  final ProviderToolProposal proposal;
  final ToolProposalFailureKind kind;
  final String message;
}
