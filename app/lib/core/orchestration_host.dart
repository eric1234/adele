import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';

import 'inference_context_host.dart';
import 'product_lifecycle.dart';
import 'run_activity_projection.dart';

/// App-private, irreversible deadline fence, not semantic Run cancellation.
/// Allocated before preparation so even an unpublished execution is fenced.
final class ApplicationExitExecutionFence {
  bool _interrupted = false;
  final Set<void Function()> _interruptions = {};

  bool get isInterrupted => _interrupted;

  void throwIfInterrupted() {
    if (isInterrupted) throw const _ApplicationExitInterrupted();
  }

  void interruptForApplicationExit() {
    if (isInterrupted) return;
    _interrupted = true;
    for (final interrupt in _interruptions.toList()) {
      interrupt();
    }
    _interruptions.clear();
  }

  Stream<T> _observe<T>(Stream<T> source) {
    throwIfInterrupted();
    late final StreamController<T> controller;
    StreamSubscription<T>? subscription;
    final setup = Completer<void>();
    final interruptedCancellation = Completer<void>();
    Future<void>? cancellation;

    Future<void> cancelSource() => cancellation ??= Future<void>.sync(() async {
      if (!setup.isCompleted) await setup.future;
      await subscription?.cancel();
    });

    void interrupt() {
      // Cancellation must be initiated even if the consumer is paused. Its
      // cleanup may hang or fail, but must not hold the host collector open.
      unawaited(cancelSource().catchError((Object _) {}));
      if (!interruptedCancellation.isCompleted) {
        interruptedCancellation.complete();
      }
      if (!controller.isClosed) {
        controller.addError(const _ApplicationExitInterrupted());
        unawaited(controller.close());
      }
    }

    controller = StreamController<T>(
      onListen: () {
        if (isInterrupted) {
          setup.complete();
          interrupt();
          return;
        }
        _interruptions.add(interrupt);
        try {
          subscription = source.listen(
            (event) {
              if (!isInterrupted) controller.add(event);
            },
            onError: (Object error, StackTrace stack) {
              if (!isInterrupted) controller.addError(error, stack);
            },
            onDone: () => unawaited(controller.close()),
          );
        } on Object catch (error, stack) {
          if (!isInterrupted) controller.addError(error, stack);
          unawaited(controller.close());
        } finally {
          setup.complete();
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        // Preserve normal drain semantics until the application deadline.
        return Future.any<void>([
          cancelSource(),
          interruptedCancellation.future,
        ]).whenComplete(() => _interruptions.remove(interrupt));
      },
    );
    return controller.stream;
  }
}

final class _ApplicationExitInterrupted implements Exception {
  const _ApplicationExitInterrupted();
}

/// Captures the canonical Session's exact strategy for this Run. A supplied
/// selection is validated against this lifecycle, never replaced by resolution.
Future<SessionOrchestrationRun> createSessionOrchestrationRun({
  required ProductLifecycleCoordinator lifecycle,
  required SessionId sessionId,
  required RunId runId,
  required InferenceContextComposer contextComposer,
  required ModelPort model,
  required ToolCatalog toolCatalog,
  required ToolPolicy policy,
  ResolvedOrchestrationStrategy? resolvedStrategy,
  SessionFeedbackReceipt? expectedFeedback,
  ApplicationExitExecutionFence? applicationExitFence,
}) async {
  final exitFence = applicationExitFence ?? ApplicationExitExecutionFence();
  exitFence.throwIfInterrupted();
  final Session? session = lifecycle.store.session(sessionId);
  if (session == null) {
    throw StateError('Session $sessionId is not published.');
  }
  if (expectedFeedback != null &&
      expectedFeedback.sessionId != session.id.value) {
    throw ArgumentError('Expected feedback belongs to another Session.');
  }
  final ResolvedOrchestrationStrategy binding =
      resolvedStrategy ?? lifecycle.resolveSessionStrategy(sessionId);
  lifecycle.validateResolvedStrategy(session.strategyId, binding);
  final KernelOrchestrationHost host = KernelOrchestrationHost(
    run: AgentRun(id: runId, sessionId: sessionId),
    lifecycle: lifecycle,
    session: session,
    strategy: binding,
    contextComposer: contextComposer,
    sourceContextFactory: () => SessionInferenceContextSourceContext(
      session: session,
      runId: runId,
      environmentRuntime: lifecycle.environmentRuntime,
    ),
    model: model,
    toolCatalog: toolCatalog,
    policy: policy,
    applicationExitFence: exitFence,
  ).._executionEnabled = false;
  final releaseSessionExecution = lifecycle.retainSessionExecution(session);
  try {
    final OrchestrationExecution execution = await binding.materialize(
      OrchestrationStrategyHostContext(
        session: session,
        host: host,
        expectedFeedback: expectedFeedback,
      ),
    );
    try {
      exitFence.throwIfInterrupted();
      lifecycle.validateResolvedStrategy(session.strategyId, binding);
    } on Object {
      try {
        await execution.close();
      } on Object {
        // Preserve canonical ownership failure over cleanup failure.
      }
      rethrow;
    }
    return SessionOrchestrationRun._(
      host,
      execution,
      lifecycle,
      releaseSessionExecution,
    );
  } on Object {
    releaseSessionExecution();
    rethrow;
  }
}

/// Application inspection surface; none of these kernel objects reach plugins.
/// Owns execution release on terminal settlement or explicit close. Automatic
/// release preserves Run results; explicit close reports any cleanup failure.
final class SessionOrchestrationRun implements OrchestrationExecution {
  SessionOrchestrationRun._(
    this._host,
    this._execution,
    this._lifecycle,
    this._releaseSessionExecution,
  ) {
    _host._exitFence._interruptions.add(_interruptForApplicationExit);
  }

  final KernelOrchestrationHost _host;
  OrchestrationExecution? _execution;
  final ProductLifecycleCoordinator _lifecycle;
  final void Function() _releaseSessionExecution;
  bool _busy = false;
  bool _closed = false;
  bool _terminalRecordAttempted = false;
  Completer<void>? _advanceSettled;
  Future<void>? _closing;
  (Object, StackTrace)? _exitRetentionFailure;

  AgentRun get run => _host._run;
  RunActivitySource get activity => _host.activity;
  ToolOutcome? get lastToolOutcome => _host._lastToolOutcome;
  ToolInvocation? get lastToolInvocation => _host._lastToolInvocation;
  MaterializedToolSet? get lastModelTools => _host._lastModelTools;

  /// Called synchronously before runtime/storage retirement at the exit deadline.
  void interruptForApplicationExit() =>
      _host._exitFence.interruptForApplicationExit();

  void _interruptForApplicationExit() {
    _closed = true;
    try {
      // An actual terminal state may precede pending strategy persistence. Keep
      // that evidence now, while storage is still open, then seal all late writes.
      _retainTerminalRun();
    } on Object catch (error, stack) {
      _exitRetentionFailure = (error, stack);
    } finally {
      _terminalRecordAttempted = true;
    }
    unawaited(close().catchError((Object _) {}));
  }

  @override
  Future<void> start() => _advance();

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      _advance(resolution: resolution);

  Future<void> _advance({ToolApprovalResolution? resolution}) async {
    _host._exitFence.throwIfInterrupted();
    if (_closed) {
      throw const InvalidRunOperation('The orchestration execution is closed.');
    }
    if (_busy) {
      throw const InvalidRunOperation(
        'The strategy is already advancing this Run.',
      );
    }
    // Reject caller mistakes before entering strategy-owned execution.
    final ToolInvocation? pending = _host._pendingApproval;
    if (resolution == null) {
      if (run.state != RunState.created) {
        throw InvalidRunOperation(
          'Cannot start Run ${run.id} while ${run.state}.',
        );
      }
    } else {
      final RunInterruption? interruption =
          run.interruptions[resolution.interruptionId];
      if (run.state != RunState.waiting ||
          pending == null ||
          interruption is! ToolApprovalInterruption ||
          !identical(interruption.invocation, pending) ||
          !interruption.accepts(resolution)) {
        throw const InvalidRunOperation(
          'Resolution does not match this Run\'s pending tool approval.',
        );
      }
    }
    _busy = true;
    final Completer<void> settled = Completer<void>();
    _advanceSettled = settled;
    bool failed = false;
    try {
      _host._executionEnabled = true;
      _host.validateBinding();
      if (resolution == null) {
        await _execution!.start();
      } else {
        await _host._resume(_execution!, resolution);
      }
      _host._exitFence.throwIfInterrupted();
      if (run.state == RunState.created ||
          run.state == RunState.running ||
          run.state == RunState.waiting) {
        _host.validateBinding();
      }
    } on Object catch (error) {
      failed = true;
      _host._fail(error);
      rethrow;
    } finally {
      _busy = false;
      _host._executionEnabled = false;
      _advanceSettled = null;
      settled.complete();
      try {
        _retainTerminalRun();
      } on Object {
        // A secondary storage failure cannot replace the strategy's error.
        // With no primary error, storage failure must reach the caller.
        if (!failed) rethrow;
      } finally {
        if (failed ||
            run.state == RunState.completed ||
            run.state == RunState.failed ||
            run.state == RunState.cancelled) {
          final cleanup = close().catchError((Object _) {
            // Cleanup cannot rewrite terminal evidence or replace advancement's
            // failure. Explicit close still reports the retained cleanup failure.
          });
          if (_host._busy) {
            // Report strategy failure now; close still drains detached mechanics.
            unawaited(cleanup);
          } else {
            await cleanup;
          }
        }
      }
    }
  }

  void _retainTerminalRun() {
    if (_terminalRecordAttempted) return;
    final state = switch (run.state) {
      RunState.completed => RunTerminalState.completed,
      RunState.failed => RunTerminalState.failed,
      RunState.cancelled => RunTerminalState.cancelled,
      RunState.created || RunState.running || RunState.waiting => null,
    };
    if (state == null) return;
    // Own the attempt even on storage failure: cleanup must not retry publication.
    _terminalRecordAttempted = true;
    _lifecycle.retainTerminalRun(
      RunRecord(id: run.id, sessionId: run.sessionId, state: state),
      activity.snapshot,
    );
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= Future<void>.microtask(() async {
      await _advanceSettled?.future;
      _host._executionEnabled = false;
      if (_host._operationSettled case final Completer<void> operation) {
        await operation.future;
      }
      // Detached mechanics can settle a deferred failure after advancement ends.
      // Release resources even if recording that terminal state fails.
      var recordingFailed = false;
      try {
        _retainTerminalRun();
        if (_exitRetentionFailure case final failure?) {
          Error.throwWithStackTrace(failure.$1, failure.$2);
        }
      } on Object {
        recordingFailed = true;
        rethrow;
      } finally {
        try {
          await _execution?.close();
        } on Object {
          if (!recordingFailed) rethrow;
        } finally {
          // Retained evidence may outlive settlement, not the backend execution.
          _execution = null;
          _host._exitFence._interruptions.remove(_interruptForApplicationExit);
          _releaseSessionExecution();
        }
      }
    });
  }
}

/// Internal adapter from semantic strategy operations to kernel mechanics.
/// Policy, exact executable objects, stream collection and evidence stay here.
final class KernelOrchestrationHost implements OrchestrationExecutionHost {
  KernelOrchestrationHost({
    required AgentRun run,
    required ProductLifecycleCoordinator lifecycle,
    required Session session,
    required ResolvedOrchestrationStrategy strategy,
    required InferenceContextComposer contextComposer,
    required InferenceContextSourceContext Function() sourceContextFactory,
    required ModelPort model,
    required ToolCatalog toolCatalog,
    required ToolPolicy policy,
    ApplicationExitExecutionFence? applicationExitFence,
  }) : _run = run,
       _lifecycle = lifecycle,
       _session = session,
       _strategy = strategy,
       _contextComposer = contextComposer,
       _sourceContextFactory = sourceContextFactory,
       _model = model,
       _toolCatalog = toolCatalog,
       _policy = policy,
       _exitFence = applicationExitFence ?? ApplicationExitExecutionFence();

  final AgentRun _run;
  final ProductLifecycleCoordinator _lifecycle;
  final Session _session;
  final ResolvedOrchestrationStrategy _strategy;
  final InferenceContextComposer _contextComposer;
  final InferenceContextSourceContext Function() _sourceContextFactory;
  final ModelPort _model;
  final ToolCatalog _toolCatalog;
  final ToolPolicy _policy;
  final ApplicationExitExecutionFence _exitFence;
  final ToolInvocationResolver _resolver = const ToolInvocationResolver();
  final ToolPolicyGate _gate = const ToolPolicyGate();
  int _nextModelInvocation = 1;
  int _nextToolInvocation = 1;
  int _nextInterruption = 1;
  // Direct adapter construction is trusted; canonical Runs enable at start.
  bool _executionEnabled = true;
  bool _busy = false;
  Completer<void>? _operationSettled;
  Object? _deferredFailure;
  ToolInvocation? _pendingApproval;
  ToolApprovalResolution? _authorizedResolution;
  ToolOutcome? _lastToolOutcome;
  ToolInvocation? _lastToolInvocation;
  MaterializedToolSet? _lastModelTools;
  late final RunActivitySource activity = RunActivityProjection(_run).source;

  @override
  RunId get id => _run.id;
  @override
  SessionId get sessionId => _run.sessionId;
  @override
  RunState get state => _run.state;

  @override
  void validateBinding() {
    _exitFence.throwIfInterrupted();
    _strategy.validateBinding();
  }

  @override
  Future<HistoricalRunEvidence> readHistoricalRun(RunId runId) async {
    _requireIdle();
    validateBinding();
    _lifecycle.validateSessionInput(_session);
    if (_session.id != sessionId) {
      throw ArgumentError('History and Run Sessions must match.');
    }
    if (state == RunState.completed ||
        state == RunState.failed ||
        state == RunState.cancelled) {
      throw InvalidRunOperation('Cannot read history while Run $id is $state.');
    }
    if (runId == id) {
      throw const HistoricalRunEvidenceFailure(
        code: 'current_run',
        message: 'Historical evidence does not include the current Run.',
      );
    }
    final record = _lifecycle.store.runRecord(runId);
    final activity = record?.sessionId == _session.id
        ? _lifecycle.runActivity(runId)
        : null;
    if (record == null ||
        activity == null ||
        activity.runId != record.id ||
        activity.sessionId != record.sessionId ||
        activity.state.name != record.state.name) {
      throw const HistoricalRunEvidenceFailure(
        code: 'unavailable',
        message: 'Historical Run evidence is unavailable.',
      );
    }
    return HistoricalRunEvidence.fromActivity(
      record: record,
      activity: activity,
    );
  }

  @override
  void start() {
    _requireIdle();
    validateBinding();
    _run.start();
  }

  @override
  void complete() {
    _requireIdle();
    validateBinding();
    _run.complete();
  }

  @override
  void fail(Object error) {
    _requireIdle();
    _fail(error);
  }

  void _fail(Object error) {
    if (_exitFence.isInterrupted) return;
    if (_busy) {
      // Preserve the active mechanics operation's terminal evidence first.
      _deferredFailure ??= error;
      return;
    }
    if (state == RunState.running || state == RunState.waiting) {
      _run.fail(error);
    }
  }

  @override
  Future<StrategyModelTurn> invokeModel(
    StrategyInferenceMaterial material,
  ) => _operation(() async {
    _requireRunning();
    final InferenceContextSourceContext sourceContext = _sourceContextFactory();
    if (sourceContext.session.id != sessionId || sourceContext.runId != id) {
      throw ArgumentError('Context source and Run identities must match.');
    }
    final InferenceContextSnapshot context = await _contextComposer.compose(
      strategyMaterial: material,
      sourceContext: sourceContext,
    );
    // Preparation may await plugin code; executable strategy authority is still
    // required, unlike the pure data copied from context-source bindings.
    validateBinding();
    _requireRunning();
    final ModelInvocationId invocationId = ModelInvocationId(
      '${id.value}-model-${_nextModelInvocation++}',
    );
    final MaterializedToolSet tools = _toolCatalog.materialize();
    _lastModelTools = tools;
    final SemanticModelRequest request = SemanticModelRequest(
      invocationId: invocationId,
      context: context,
      tools: tools,
    );
    final _ToolSnapshot snapshot = _ToolSnapshot(this, tools, invocationId);
    _exitFence.throwIfInterrupted();
    _run.record(ModelInvocationStarted(invocationId));
    final List<ModelOutputItem> output = <ModelOutputItem>[];
    try {
      final ModelInvocationObservation observation =
          await collectModelInvocation(
            _exitFence._observe(_model.invoke(request)),
            invocationId: invocationId,
            onObservation: (ModelObservation observation) {
              if (_exitFence.isInterrupted) return;
              _run.record(
                ModelObservationObserved(
                  invocationId: invocationId,
                  observation: observation,
                ),
              );
            },
            onOutput: (ModelOutputItem item) {
              if (_exitFence.isInterrupted) return;
              output.add(item);
              final ExecutionEventRecord record = _run.record(
                ModelOutputObserved(invocationId: invocationId, item: item),
              );
              if (item is ModelToolProposalOutput) {
                snapshot._proposals.add((
                  proposal: item.proposal,
                  sequence: record.sequence,
                ));
              }
            },
          );
      _exitFence.throwIfInterrupted();
      switch (observation.terminal) {
        case final ModelInvocationSettledEvent terminal:
          _run.record(
            ModelInvocationSettled(
              invocationId: invocationId,
              settlement: terminal.settlement,
              incompleteReason: terminal.incompleteReason,
              metadata: terminal.metadata,
            ),
          );
          snapshot._completed =
              terminal.settlement == ModelSettlement.completed;
          return StrategyModelTurn.settled(
            tools: snapshot,
            output: output,
            settlement: terminal.settlement,
            incompleteReason: terminal.incompleteReason,
            metadata: terminal.metadata,
          );
        case ModelInvocationFailedEvent(
          :final error,
          :final semanticTerminalMetadata,
        ):
          _run.record(
            ModelInvocationFailed(
              invocationId: invocationId,
              error: error,
              semanticTerminalMetadata: semanticTerminalMetadata,
            ),
          );
          return StrategyModelTurn.failed(
            tools: snapshot,
            output: output,
            error: error,
          );
      }
    } on Object catch (error) {
      _exitFence.throwIfInterrupted();
      _run.record(
        ModelInvocationFailed(invocationId: invocationId, error: error),
      );
      return StrategyModelTurn.failed(
        tools: snapshot,
        output: output,
        error: error,
      );
    }
  });

  @override
  Future<StrategyToolResult> processProposal({
    required StrategyToolSnapshot tools,
    required ProviderToolProposal proposal,
  }) => _operation(() async {
    _requireRunning();
    final int proposalIndex =
        tools is _ToolSnapshot &&
            identical(tools._owner, this) &&
            tools._completed
        ? tools._proposals.indexWhere(
            (item) => identical(item.proposal, proposal),
          )
        : -1;
    if (tools is! _ToolSnapshot || proposalIndex < 0) {
      throw const InvalidRunOperation(
        'Proposal must belong to this Run\'s exact model materialization and be unused.',
      );
    }
    final int proposalSequence = tools._proposals
        .removeAt(proposalIndex)
        .sequence;
    final ToolProposalResolution resolution = await _resolver.resolve(
      invocationId: ToolInvocationId(
        '${id.value}-tool-${_nextToolInvocation++}',
      ),
      proposal: proposal,
      tools: tools._tools,
      runId: id,
      sessionId: sessionId,
    );
    validateBinding();
    switch (resolution) {
      case RejectedToolProposal(:final failure):
        _run.record(
          ToolProposalRejected(
            modelInvocationId: tools._modelInvocationId,
            proposalSequence: proposalSequence,
            proposal: proposal,
            failure: failure,
          ),
        );
        return StrategyToolContinuation(
          SemanticToolProposalFailureInput(failure: failure),
        );
      case ResolvedToolProposal(:final invocation):
        _lastToolInvocation = invocation;
        _run.record(
          ToolInvocationPrepared(
            invocation,
            modelInvocationId: tools._modelInvocationId,
            proposalSequence: proposalSequence,
          ),
        );
        return _applyPolicy(invocation);
    }
  });

  Future<StrategyToolResult> _applyPolicy(ToolInvocation invocation) async {
    final ToolPolicyGateResult result;
    try {
      result = await _gate.evaluate(
        invocation: invocation,
        policy: _policy,
        interruptionId: RunInterruptionId(
          '${id.value}-interruption-${_nextInterruption++}',
        ),
      );
    } on ToolEffectDescriptionFailed catch (error) {
      return StrategyToolContinuation(
        _recordToolTerminal(
          invocation,
          ToolOutcome(
            disposition: ToolOutcomeDisposition.failure,
            failureKind: ToolFailureKind.infrastructure,
            effectCertainty: EffectCertainty.knownNotOccurred,
            modelContent: 'Tool effect description failed.',
            hostDiagnostic: error.cause.toString(),
            cause: error.cause,
          ),
          executionStarted: false,
        ),
      );
    } on ToolPolicyEvaluationFailed catch (error) {
      _exitFence.throwIfInterrupted();
      _run.record(
        ToolPolicyFailed(invocationId: invocation.id, effects: error.effects),
      );
      return StrategyToolContinuation(
        _recordToolTerminal(
          invocation,
          ToolOutcome(
            disposition: ToolOutcomeDisposition.failure,
            failureKind: ToolFailureKind.infrastructure,
            effectCertainty: EffectCertainty.knownNotOccurred,
            modelContent: 'Tool policy evaluation failed.',
            hostDiagnostic: error.cause.toString(),
            cause: error.cause,
          ),
          executionStarted: false,
        ),
      );
    }
    // Preserve the completed preflight evidence even if the strategy retired
    // while describe() was pending; execution still requires a live binding.
    _exitFence.throwIfInterrupted();
    _run.record(
      ToolPolicyEvaluated(
        invocationId: invocation.id,
        decision: switch (result) {
          ToolExecutionAllowed() => ToolPolicyDecision.allow,
          ToolExecutionDenied() => ToolPolicyDecision.deny,
          ToolApprovalRequired() => ToolPolicyDecision.ask,
        },
        effects: result.effects,
      ),
    );
    validateBinding();
    switch (result) {
      case ToolExecutionAllowed():
        return StrategyToolContinuation(await _execute(result));
      case ToolExecutionDenied(:final outcome):
        return StrategyToolContinuation(
          _recordToolTerminal(invocation, outcome, executionStarted: false),
        );
      case ToolApprovalRequired(:final interruption):
        _pendingApproval = invocation;
        _run.interrupt(interruption);
        return const StrategyToolWaiting();
    }
  }

  @override
  Future<SemanticToolOutcomeInput> resolveApproval(
    ToolApprovalResolution resolution,
  ) => _operation(() async {
    if (!identical(resolution, _authorizedResolution)) {
      throw const InvalidRunOperation(
        'Only the current host-supplied approval resolution may be applied.',
      );
    }
    final ToolInvocation? invocation = _pendingApproval;
    if (invocation == null) {
      throw const InvalidRunOperation('No tool approval is pending.');
    }
    final ResolvedRunInterruption resolved = _run.resolveInterruption(
      resolution,
    );
    _authorizedResolution = null;
    _pendingApproval = null;
    if (!resolution.approved) {
      return _recordToolTerminal(
        invocation,
        ToolOutcome(
          disposition: ToolOutcomeDisposition.userRejected,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: 'The user rejected this tool invocation.',
        ),
        executionStarted: false,
      );
    }
    return _execute(_gate.approve(resolved));
  });

  Future<void> _resume(
    OrchestrationExecution execution,
    ToolApprovalResolution resolution,
  ) async {
    // A strategy may decide how to continue, but cannot manufacture approval.
    _authorizedResolution = resolution;
    try {
      await execution.resolveApproval(resolution);
    } finally {
      _authorizedResolution = null;
    }
  }

  Future<SemanticToolOutcomeInput> _execute(
    ToolExecutionAllowed allowed,
  ) async {
    validateBinding();
    final ToolInvocation invocation = allowed.invocation;
    final ToolExecutionStart start;
    try {
      start = _run.startToolExecution(allowed);
    } on StaleToolBindingException catch (error) {
      return _recordToolTerminal(
        invocation,
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.staleBinding,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: 'The approved tool binding is stale.',
          hostDiagnostic: error.message,
          cause: error.cause ?? error,
        ),
        executionStarted: false,
      );
    } on ToolBindingUnavailableException catch (error) {
      return _recordToolTerminal(
        invocation,
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.infrastructure,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: 'The approved tool binding is unavailable.',
          hostDiagnostic: error.message,
          cause: error.cause ?? error,
        ),
        executionStarted: false,
      );
    }
    _exitFence.throwIfInterrupted();
    _run.record(ToolExecutionStarted(invocation.id));
    late final ToolOutcome outcome;
    try {
      final ToolExecutionObservation observation = await collectToolExecution(
        _exitFence._observe(start.events()),
        retainProgress: false,
        onProgress: (ToolProgress progress) {
          if (_exitFence.isInterrupted) return;
          _run.record(
            ToolProgressObserved(
              invocationId: invocation.id,
              progress: progress,
            ),
          );
        },
      );
      outcome = observation.outcome;
    } on Object catch (error) {
      _exitFence.throwIfInterrupted();
      outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.infrastructure,
        effectCertainty: EffectCertainty.uncertain,
        modelContent: 'Tool execution failed without a valid terminal result.',
        hostDiagnostic: error.toString(),
        cause: error,
      );
    }
    return _recordToolTerminal(invocation, outcome, executionStarted: true);
  }

  SemanticToolOutcomeInput _recordToolTerminal(
    ToolInvocation invocation,
    ToolOutcome outcome, {
    required bool executionStarted,
  }) {
    _exitFence.throwIfInterrupted();
    _lastToolOutcome = outcome;
    _run.record(
      executionStarted
          ? ToolExecutionCompleted(
              invocationId: invocation.id,
              outcome: outcome,
            )
          : ToolInvocationCompleted(
              invocationId: invocation.id,
              outcome: outcome,
            ),
    );
    return SemanticToolOutcomeInput(
      providerCallId: invocation.proposal.providerCallId,
      outcome: outcome,
    );
  }

  Future<T> _operation<T>(Future<T> Function() operation) async {
    _requireIdle();
    _busy = true;
    final Completer<void> settled = Completer<void>();
    _operationSettled = settled;
    try {
      validateBinding();
      final T result = await operation();
      // An in-flight operation may settle, but retired code cannot advance from it.
      validateBinding();
      return result;
    } on InvalidRunOperation {
      rethrow;
    } on Object catch (error) {
      _fail(error);
      rethrow;
    } finally {
      _busy = false;
      final Object? failure = _deferredFailure;
      _deferredFailure = null;
      if (failure != null) _fail(failure);
      _operationSettled = null;
      settled.complete();
    }
  }

  void _requireIdle() {
    _exitFence.throwIfInterrupted();
    if (!_executionEnabled) {
      throw const InvalidRunOperation(
        'The execution host is unavailable outside active strategy advancement.',
      );
    }
    if (_busy) {
      throw const InvalidRunOperation(
        'An execution host operation is already active.',
      );
    }
  }

  void _requireRunning() {
    if (state != RunState.running) {
      throw InvalidRunOperation('Cannot execute while Run $id is $state.');
    }
  }
}

final class _ToolSnapshot implements StrategyToolSnapshot {
  _ToolSnapshot(this._owner, this._tools, this._modelInvocationId);

  final KernelOrchestrationHost _owner;
  final MaterializedToolSet _tools;
  final ModelInvocationId _modelInvocationId;
  bool _completed = false;
  final List<({ProviderToolProposal proposal, int sequence})> _proposals = [];
}
