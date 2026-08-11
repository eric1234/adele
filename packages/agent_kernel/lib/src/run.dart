import 'identifiers.dart';
import 'model.dart';
import 'tool.dart';

enum RunState { created, running, waiting, completed, failed, cancelled }

sealed class RunInterruptionResolution {
  const RunInterruptionResolution(this.interruptionId);

  final RunInterruptionId interruptionId;
}

sealed class RunInterruption {
  const RunInterruption(this.id);

  final RunInterruptionId id;

  bool accepts(RunInterruptionResolution resolution);
}

final class ToolApprovalInterruption extends RunInterruption {
  const ToolApprovalInterruption({
    required RunInterruptionId id,
    required this.invocation,
    required this.effects,
  }) : super(id);

  final ToolInvocation invocation;
  final EffectDescription effects;

  ToolInvocationId get toolInvocationId => invocation.id;
  ToolId get toolId => invocation.toolId;
  Map<String, Object?> get canonicalArguments => invocation.canonicalArguments;

  @override
  bool accepts(RunInterruptionResolution resolution) =>
      resolution is ToolApprovalResolution &&
      resolution.interruptionId == id &&
      resolution.toolInvocationId == invocation.id;
}

final class ToolApprovalResolution extends RunInterruptionResolution {
  const ToolApprovalResolution({
    required RunInterruptionId interruptionId,
    required this.toolInvocationId,
    required this.approved,
  }) : super(interruptionId);

  final ToolInvocationId toolInvocationId;
  final bool approved;
}

final class ResolvedRunInterruption {
  const ResolvedRunInterruption._({
    required this.interruption,
    required this.resolution,
  });

  final RunInterruption interruption;
  final RunInterruptionResolution resolution;
}

sealed class ToolPolicyGateResult {
  const ToolPolicyGateResult({required this.invocation, required this.effects});

  final ToolInvocation invocation;
  final EffectDescription effects;
}

final class ToolExecutionAllowed extends ToolPolicyGateResult {
  const ToolExecutionAllowed._({
    required super.invocation,
    required super.effects,
  });
}

final class ToolExecutionStart {
  ToolExecutionStart._(this.invocation);

  final ToolInvocation invocation;
  bool _eventsRead = false;

  Stream<ToolExecutionEvent> events() {
    if (_eventsRead) throw ToolExecutionAlreadyStarted(invocation.id);
    _eventsRead = true;
    return invocation.tool.executable.execute(
      invocation.arguments,
      invocation.context,
    );
  }
}

final class ToolExecutionDenied extends ToolPolicyGateResult {
  const ToolExecutionDenied._({
    required super.invocation,
    required super.effects,
    required this.outcome,
  });

  final ToolOutcome outcome;
}

final class ToolApprovalRequired extends ToolPolicyGateResult {
  const ToolApprovalRequired._({
    required super.invocation,
    required super.effects,
    required this.interruption,
  });

  final ToolApprovalInterruption interruption;
}

/// Applies effect preflight and policy without defining workflow sequencing.
final class ToolPolicyGate {
  const ToolPolicyGate();

  Future<ToolPolicyGateResult> evaluate({
    required ToolInvocation invocation,
    required ToolPolicy policy,
    required RunInterruptionId interruptionId,
  }) async {
    final EffectDescription effects;
    try {
      effects = await invocation.tool.executable.describe(
        invocation.arguments,
        invocation.context,
      );
    } on Object catch (error) {
      throw ToolEffectDescriptionFailed(error);
    }
    final ToolPolicyDecision decision;
    try {
      decision = policy.evaluate(
        ToolPolicyInput(
          invocation: invocation,
          effects: effects,
          context: invocation.context,
        ),
      );
    } on Object catch (error) {
      throw ToolPolicyEvaluationFailed(cause: error, effects: effects);
    }
    return switch (decision) {
      ToolPolicyDecision.allow => ToolExecutionAllowed._(
        invocation: invocation,
        effects: effects,
      ),
      ToolPolicyDecision.deny => ToolExecutionDenied._(
        invocation: invocation,
        effects: effects,
        outcome: ToolOutcome(
          disposition: ToolOutcomeDisposition.policyDenied,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: 'Tool invocation denied by policy.',
        ),
      ),
      ToolPolicyDecision.ask => ToolApprovalRequired._(
        invocation: invocation,
        effects: effects,
        interruption: ToolApprovalInterruption(
          id: interruptionId,
          invocation: invocation,
          effects: effects,
        ),
      ),
    };
  }

  ToolExecutionAllowed approve(ResolvedRunInterruption resolved) {
    final RunInterruption interruption = resolved.interruption;
    final RunInterruptionResolution resolution = resolved.resolution;
    if (interruption is! ToolApprovalInterruption ||
        resolution is! ToolApprovalResolution ||
        !resolution.approved ||
        !interruption.accepts(resolution)) {
      throw const InvalidRunOperation(
        'Only an approved, resolved tool interruption authorizes execution.',
      );
    }
    return ToolExecutionAllowed._(
      invocation: interruption.invocation,
      effects: interruption.effects,
    );
  }
}

sealed class ToolPolicyGateException implements Exception {
  const ToolPolicyGateException(this.cause);

  final Object cause;
}

final class ToolEffectDescriptionFailed extends ToolPolicyGateException {
  const ToolEffectDescriptionFailed(super.cause);
}

final class ToolPolicyEvaluationFailed extends ToolPolicyGateException {
  const ToolPolicyEvaluationFailed({
    required Object cause,
    required this.effects,
  }) : super(cause);

  final EffectDescription effects;
}

sealed class ExecutionEvent {
  const ExecutionEvent();
}

final class RunStarted extends ExecutionEvent {
  const RunStarted();
}

final class RunWaiting extends ExecutionEvent {
  RunWaiting(Iterable<RunInterruptionId> interruptionIds)
    : interruptionIds = List<RunInterruptionId>.unmodifiable(interruptionIds);

  final List<RunInterruptionId> interruptionIds;
}

final class RunResumed extends ExecutionEvent {
  const RunResumed();
}

final class RunCompleted extends ExecutionEvent {
  const RunCompleted();
}

final class RunFailed extends ExecutionEvent {
  const RunFailed(this.error);

  final Object error;
}

final class RunCancelled extends ExecutionEvent {
  const RunCancelled();
}

final class ModelInvocationStarted extends ExecutionEvent {
  const ModelInvocationStarted(this.invocationId);

  final ModelInvocationId invocationId;
}

final class ModelOutputObserved extends ExecutionEvent {
  const ModelOutputObserved({required this.invocationId, required this.item});

  final ModelInvocationId invocationId;
  final ModelOutputItem item;
}

final class ModelInvocationCompleted extends ExecutionEvent {
  const ModelInvocationCompleted(this.invocationId);

  final ModelInvocationId invocationId;
}

final class ModelInvocationFailed extends ExecutionEvent {
  const ModelInvocationFailed({
    required this.invocationId,
    required this.error,
  });

  final ModelInvocationId invocationId;
  final Object error;
}

final class ToolInvocationPrepared extends ExecutionEvent {
  const ToolInvocationPrepared(this.invocation);

  final ToolInvocation invocation;
}

final class ToolPolicyEvaluated extends ExecutionEvent {
  const ToolPolicyEvaluated({
    required this.invocationId,
    required this.decision,
    required this.effects,
  });

  final ToolInvocationId invocationId;
  final ToolPolicyDecision decision;
  final EffectDescription effects;
}

final class RunInterrupted extends ExecutionEvent {
  const RunInterrupted(this.interruption);

  final RunInterruption interruption;
}

final class RunInterruptionResolved extends ExecutionEvent {
  const RunInterruptionResolved({
    required this.interruption,
    required this.resolution,
  });

  final RunInterruption interruption;
  final RunInterruptionResolution resolution;
}

final class ToolExecutionStarted extends ExecutionEvent {
  const ToolExecutionStarted(this.invocationId);

  final ToolInvocationId invocationId;
}

final class ToolProgressObserved extends ExecutionEvent {
  const ToolProgressObserved({
    required this.invocationId,
    required this.progress,
  });

  final ToolInvocationId invocationId;
  final ToolProgress progress;
}

final class ToolExecutionCompleted extends ExecutionEvent {
  const ToolExecutionCompleted({
    required this.invocationId,
    required this.outcome,
  });

  final ToolInvocationId invocationId;
  final ToolOutcome outcome;
}

final class ToolInvocationCompleted extends ExecutionEvent {
  const ToolInvocationCompleted({
    required this.invocationId,
    required this.outcome,
  });

  final ToolInvocationId invocationId;
  final ToolOutcome outcome;
}

final class ExecutionEventRecord {
  const ExecutionEventRecord({required this.sequence, required this.event});

  final int sequence;
  final ExecutionEvent event;
}

/// A deterministic in-memory observation journal, not durable event storage.
final class RunJournal {
  final List<ExecutionEventRecord> _records = <ExecutionEventRecord>[];
  int _nextSequence = 1;

  List<ExecutionEventRecord> get records =>
      List<ExecutionEventRecord>.unmodifiable(_records);

  void _record(ExecutionEvent event) {
    _records.add(ExecutionEventRecord(sequence: _nextSequence++, event: event));
  }
}

final class AgentRun {
  AgentRun({required this.id, required this.sessionId})
    : journal = RunJournal();

  final RunId id;
  final SessionId sessionId;
  final RunJournal journal;
  final Map<RunInterruptionId, RunInterruption> _interruptions =
      <RunInterruptionId, RunInterruption>{};
  final Set<ToolInvocationId> _startedToolInvocations = <ToolInvocationId>{};
  RunState _state = RunState.created;
  Object? _failure;

  RunState get state => _state;
  Object? get failure => _failure;
  Map<RunInterruptionId, RunInterruption> get interruptions =>
      Map<RunInterruptionId, RunInterruption>.unmodifiable(_interruptions);

  void start() {
    _requireState(RunState.created, 'start');
    _state = RunState.running;
    journal._record(const RunStarted());
  }

  void record(ExecutionEvent event) {
    if (_state != RunState.running && _state != RunState.waiting) {
      throw InvalidRunOperation(
        'Cannot record execution activity while Run $id is $_state.',
      );
    }
    if (event is RunStarted ||
        event is RunWaiting ||
        event is RunResumed ||
        event is RunCompleted ||
        event is RunFailed ||
        event is RunCancelled ||
        event is RunInterrupted ||
        event is RunInterruptionResolved) {
      throw InvalidRunOperation(
        'Run lifecycle and interruption events are recorded by Run itself.',
      );
    }
    if (event case ToolInvocationPrepared(:final invocation)) {
      _validateInvocationContext(invocation);
    }
    journal._record(event);
  }

  ToolExecutionStart startToolExecution(ToolExecutionAllowed allowed) {
    _requireState(RunState.running, 'start tool execution');
    final ToolInvocation invocation = allowed.invocation;
    _validateInvocationContext(invocation);
    if (_startedToolInvocations.contains(invocation.id)) {
      throw ToolExecutionAlreadyStarted(invocation.id);
    }
    invocation.tool.executable.validateBinding();
    _startedToolInvocations.add(invocation.id);
    return ToolExecutionStart._(invocation);
  }

  void interrupt(RunInterruption interruption) {
    if (_state != RunState.running && _state != RunState.waiting) {
      throw InvalidRunOperation('Cannot interrupt Run $id while $_state.');
    }
    if (_interruptions.containsKey(interruption.id)) {
      throw InvalidRunOperation(
        'Run $id already has interruption ${interruption.id}.',
      );
    }
    if (interruption is ToolApprovalInterruption) {
      _validateInvocationContext(interruption.invocation);
    }
    _interruptions[interruption.id] = interruption;
    journal._record(RunInterrupted(interruption));
    if (_state == RunState.running) {
      _state = RunState.waiting;
      journal._record(RunWaiting(_interruptions.keys));
    }
  }

  ResolvedRunInterruption resolveInterruption(
    RunInterruptionResolution resolution,
  ) {
    _requireState(RunState.waiting, 'resolve an interruption');
    final RunInterruption? interruption =
        _interruptions[resolution.interruptionId];
    if (interruption == null || !interruption.accepts(resolution)) {
      throw InvalidRunOperation(
        'Resolution does not match interruption ${resolution.interruptionId}.',
      );
    }
    _interruptions.remove(interruption.id);
    journal._record(
      RunInterruptionResolved(
        interruption: interruption,
        resolution: resolution,
      ),
    );
    if (_interruptions.isEmpty) {
      _state = RunState.running;
      journal._record(const RunResumed());
    }
    return ResolvedRunInterruption._(
      interruption: interruption,
      resolution: resolution,
    );
  }

  void complete() {
    _requireState(RunState.running, 'complete');
    _state = RunState.completed;
    journal._record(const RunCompleted());
  }

  void fail(Object error) {
    if (_state != RunState.running && _state != RunState.waiting) {
      throw InvalidRunOperation('Cannot fail Run $id while $_state.');
    }
    _failure = error;
    _interruptions.clear();
    _state = RunState.failed;
    journal._record(RunFailed(error));
  }

  void cancel() {
    if (_state != RunState.created &&
        _state != RunState.running &&
        _state != RunState.waiting) {
      throw InvalidRunOperation('Cannot cancel Run $id while $_state.');
    }
    _interruptions.clear();
    _state = RunState.cancelled;
    journal._record(const RunCancelled());
  }

  void _requireState(RunState expected, String operation) {
    if (_state != expected) {
      throw InvalidRunOperation(
        'Cannot $operation Run $id while $_state; expected $expected.',
      );
    }
  }

  void _validateInvocationContext(ToolInvocation invocation) {
    if (invocation.context.runId != id ||
        invocation.context.sessionId != sessionId) {
      throw InvalidRunOperation(
        'Tool invocation ${invocation.id} belongs to '
        '${invocation.context.runId}/${invocation.context.sessionId}, not '
        '$id/$sessionId.',
      );
    }
  }
}

final class InvalidRunOperation implements Exception {
  const InvalidRunOperation(this.message);

  final String message;

  @override
  String toString() => 'InvalidRunOperation: $message';
}
