import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:agent_kernel/agent_kernel.dart';

/// App-owned translation of internal journal evidence into public read values.
/// The exposed source is a separate object with no execution or journal API.
/// Consumes the model-driven host journal, including explicit proposal origins.
final class RunActivityProjection {
  RunActivityProjection(AgentRun run) : _run = run {
    _snapshot = RunActivitySnapshot(
      runId: run.id,
      sessionId: run.sessionId,
      state: RunState.created,
      sequence: 0,
    );
    _changes = StreamController<void>.broadcast(
      onListen: () {
        _notifiedSequence = _run.journal.lastSequence;
        _subscription = _run.journal.changes.listen((_) {
          // Invalidations must not force a full immutable snapshot per chunk.
          // Consumers choose when to read; UI can coalesce reads per frame.
          final List<ExecutionEventRecord> records = _run.journal.recordsAfter(
            _notifiedSequence,
          );
          _notifiedSequence = _run.journal.lastSequence;
          if (records.any(
            (record) => record.event is! ModelObservationObserved,
          )) {
            _changes.add(null);
          }
        });
      },
      onCancel: () {
        final StreamSubscription<void>? subscription = _subscription;
        _subscription = null;
        unawaited(subscription?.cancel());
      },
    );
    source = _RunActivityReadFacade(this);
  }

  final AgentRun _run;
  late final RunActivitySource source;
  late final StreamController<void> _changes;
  StreamSubscription<void>? _subscription;
  late RunActivitySnapshot _snapshot;
  int _scannedSequence = 0;
  int _notifiedSequence = 0;
  final List<RunLifecycleActivity> _lifecycle = [];
  final Map<ModelInvocationId, _ModelActivity> _models = {};
  final Map<ToolInvocationId, _ToolActivity> _tools = {};
  final List<RejectedToolProposalActivity> _rejections = [];

  RunActivitySnapshot _readSnapshot() {
    if (_scannedSequence == _run.journal.lastSequence) return _snapshot;
    int sequence = _snapshot.sequence;
    RunState state = _snapshot.state;
    ActivityFailure? failure = _snapshot.failure;
    for (final ExecutionEventRecord record in _run.journal.recordsAfter(
      _scannedSequence,
    )) {
      _scannedSequence = record.sequence;
      final ExecutionEvent event = record.event;
      // Completed outputs are authoritative. Text deltas neither invalidate nor
      // rebuild the public snapshot, but their journal sequence gaps remain.
      if (event is ModelObservationObserved) continue;
      sequence = record.sequence;
      final RunState? nextState = switch (event) {
        RunStarted() || RunResumed() => RunState.running,
        RunWaiting() => RunState.waiting,
        RunCompleted() => RunState.completed,
        RunFailed() => RunState.failed,
        RunCancelled() => RunState.cancelled,
        _ => null,
      };
      if (nextState != null) {
        state = nextState;
        _lifecycle.add(RunLifecycleActivity(sequence: sequence, state: state));
      }
      switch (event) {
        case RunFailed(:final error):
          failure = _failure(error, 'Run failed.');
        case ModelInvocationStarted(:final invocationId):
          _models[invocationId] = _ModelActivity(invocationId, sequence);
        case ModelOutputObserved(:final invocationId, :final item):
          final _ModelActivity model = _models[invocationId]!;
          model.outputs.add(
            ModelOutputActivity(sequence: sequence, item: item),
          );
          model._snapshot = null;
        case ModelInvocationSettled(:final invocationId):
          _models[invocationId]!
            ..terminalSequence = sequence
            ..settlement = event.settlement
            ..incompleteReason = event.incompleteReason
            ..metadata = event.metadata
            .._snapshot = null;
        case ModelInvocationFailed(:final invocationId):
          _models[invocationId]!
            ..terminalSequence = sequence
            ..metadata = event.semanticTerminalMetadata
            ..failure = _failure(event.error, 'Model invocation failed.')
            .._snapshot = null;
        case ToolInvocationPrepared(:final invocation):
          if (event.modelInvocationId == null ||
              event.proposalSequence == null) {
            throw StateError(
              'Host tool activity requires an exact model output origin.',
            );
          }
          _tools[invocation.id] = _ToolActivity(
            ToolInvocationActivity(
              id: invocation.id,
              preparedSequence: sequence,
              modelInvocationId: event.modelInvocationId!,
              proposalSequence: event.proposalSequence!,
              toolId: invocation.toolId,
              alias: invocation.proposal.alias,
              providerCallId: invocation.proposal.providerCallId,
              canonicalArguments: invocation.canonicalArguments,
              changes: [
                ToolActivityChange(
                  sequence: sequence,
                  kind: ToolActivityKind.prepared,
                ),
              ],
            ),
          );
        case ToolProposalRejected():
          _rejections.add(
            RejectedToolProposalActivity(
              sequence: sequence,
              modelInvocationId: event.modelInvocationId,
              proposalSequence: event.proposalSequence,
              proposal: event.proposal,
              kind: event.failure.kind,
              message: event.failure.message,
            ),
          );
        case ToolPolicyEvaluated(:final invocationId):
          _updateTool(
            invocationId,
            ToolActivityChange(
              sequence: sequence,
              kind: ToolActivityKind.policyEvaluated,
              policyDecision: switch (event.decision) {
                ToolPolicyDecision.allow => ToolActivityPolicyDecision.allow,
                ToolPolicyDecision.deny => ToolActivityPolicyDecision.deny,
                ToolPolicyDecision.ask => ToolActivityPolicyDecision.ask,
              },
              effects: event.effects,
            ),
          );
        case ToolPolicyFailed(:final invocationId):
          _updateTool(
            invocationId,
            ToolActivityChange(
              sequence: sequence,
              kind: ToolActivityKind.policyFailed,
              effects: event.effects,
            ),
          );
        case RunInterrupted(
          interruption: final ToolApprovalInterruption interruption,
        ):
          _updateTool(
            interruption.toolInvocationId,
            ToolActivityChange(
              sequence: sequence,
              kind: ToolActivityKind.approvalRequested,
              interruptionId: interruption.id,
              effects: interruption.effects,
            ),
          );
        case RunInterruptionResolved(
          interruption: final ToolApprovalInterruption interruption,
          resolution: final ToolApprovalResolution resolution,
        ):
          _updateTool(
            interruption.toolInvocationId,
            ToolActivityChange(
              sequence: sequence,
              kind: ToolActivityKind.approvalResolved,
              interruptionId: interruption.id,
              approved: resolution.approved,
            ),
          );
        case ToolExecutionStarted(:final invocationId):
          _updateTool(
            invocationId,
            ToolActivityChange(
              sequence: sequence,
              kind: ToolActivityKind.executionStarted,
            ),
          );
        case ToolProgressObserved(:final invocationId, :final progress):
          _updateTool(
            invocationId,
            ToolActivityChange(
              sequence: sequence,
              kind: ToolActivityKind.progress,
              progress: progress,
            ),
          );
        case ToolExecutionCompleted(:final invocationId, :final outcome) ||
            ToolInvocationCompleted(:final invocationId, :final outcome):
          _updateTool(
            invocationId,
            ToolActivityChange(
              sequence: sequence,
              kind: ToolActivityKind.completed,
              outcome: ToolOutcomeActivity(
                disposition: outcome.disposition,
                failureKind: outcome.failureKind,
                effectCertainty: outcome.effectCertainty,
                modelContent: outcome.modelContent,
                hostData: outcome.hostData,
              ),
            ),
          );
        case RunStarted() ||
            RunWaiting() ||
            RunResumed() ||
            RunCompleted() ||
            RunCancelled() ||
            RunInterrupted() ||
            RunInterruptionResolved() ||
            ModelObservationObserved():
          break;
      }
    }
    if (sequence != _snapshot.sequence) {
      _snapshot = RunActivitySnapshot(
        runId: _run.id,
        sessionId: _run.sessionId,
        state: state,
        sequence: sequence,
        lifecycle: _lifecycle,
        // Freeze each touched entity once, after the entire unread suffix.
        models: _models.values.map((model) => model.snapshot),
        tools: _tools.values.map((tool) => tool.snapshot),
        rejectedProposals: _rejections,
        failure: failure,
      );
    }
    return _snapshot;
  }

  void _updateTool(ToolInvocationId id, ToolActivityChange change) {
    final _ToolActivity tool = _tools[id]!;
    tool.changes.add(change);
    tool.effects = change.effects ?? tool.effects;
    tool.outcome = change.outcome ?? tool.outcome;
    tool._snapshot = null;
  }

  ActivityFailure _failure(Object error, String message) => switch (error) {
    ModelFailure() => ActivityFailure(
      kind: error.kind.name,
      message: error.providerMessage ?? message,
      providerCode: error.providerCode,
      providerDetails: error.providerDetails,
    ),
    ModelInvocationContractException() => ActivityFailure(
      kind: 'modelContract',
      message: message,
    ),
    _ => ActivityFailure(kind: 'unknown', message: message),
  };
}

// Mutable accumulation never escapes the projection. Cached public values own
// frozen lists and are reused until that particular entity changes again.
final class _ModelActivity {
  _ModelActivity(this.id, this.startSequence);

  final ModelInvocationId id;
  final int startSequence;
  final List<ModelOutputActivity> outputs = [];
  int? terminalSequence;
  ModelSettlement? settlement;
  ModelIncompleteReason? incompleteReason;
  ModelTerminalMetadata? metadata;
  ActivityFailure? failure;
  ModelInvocationActivity? _snapshot;

  ModelInvocationActivity get snapshot => _snapshot ??= ModelInvocationActivity(
    id: id,
    startSequence: startSequence,
    outputs: outputs,
    terminalSequence: terminalSequence,
    settlement: settlement,
    incompleteReason: incompleteReason,
    metadata: metadata,
    failure: failure,
  );
}

final class _ToolActivity {
  _ToolActivity(this._prepared)
    : changes = List.of(_prepared.changes),
      _snapshot = _prepared;

  final ToolInvocationActivity _prepared;
  final List<ToolActivityChange> changes;
  EffectDescription? effects;
  ToolOutcomeActivity? outcome;
  ToolInvocationActivity? _snapshot;

  ToolInvocationActivity get snapshot => _snapshot ??= ToolInvocationActivity(
    id: _prepared.id,
    preparedSequence: _prepared.preparedSequence,
    modelInvocationId: _prepared.modelInvocationId,
    proposalSequence: _prepared.proposalSequence,
    toolId: _prepared.toolId,
    alias: _prepared.alias,
    providerCallId: _prepared.providerCallId,
    canonicalArguments: _prepared.canonicalArguments,
    changes: changes,
    effects: effects,
    outcome: outcome,
  );
}

final class _RunActivityReadFacade implements RunActivitySource {
  const _RunActivityReadFacade(this._projection);

  final RunActivityProjection _projection;

  @override
  RunActivitySnapshot get snapshot => _projection._readSnapshot();

  @override
  Stream<void> get changes => _projection._changes.stream;
}
