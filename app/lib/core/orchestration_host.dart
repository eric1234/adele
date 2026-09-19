import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:agent_kernel/agent_kernel.dart';

import 'inference_context_host.dart';
import 'product_lifecycle.dart';
import 'run_activity_projection.dart';

/// Resolves only the canonical Session's stored strategy, once for this Run.
Future<SessionOrchestrationRun> createSessionOrchestrationRun({
  required ProductLifecycleCoordinator lifecycle,
  required SessionId sessionId,
  required RunId runId,
  required InferenceContextComposer contextComposer,
  required ModelPort model,
  required ToolCatalog toolCatalog,
  required ToolPolicy policy,
}) async {
  final Session? session = lifecycle.store.session(sessionId);
  if (session == null) {
    throw StateError('Session $sessionId is not published.');
  }
  final ResolvedOrchestrationStrategy binding = lifecycle
      .resolveSessionStrategy(sessionId);
  final KernelOrchestrationHost host = KernelOrchestrationHost(
    run: AgentRun(id: runId, sessionId: sessionId),
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
  ).._executionEnabled = false;
  final OrchestrationExecution execution = await binding.materialize(
    OrchestrationStrategyHostContext(session: session, host: host),
  );
  return SessionOrchestrationRun._(host, execution);
}

/// Application inspection surface; none of these kernel objects reach plugins.
/// Owns execution release on terminal settlement or explicit close. Automatic
/// release preserves Run results; explicit close reports any cleanup failure.
final class SessionOrchestrationRun implements OrchestrationExecution {
  SessionOrchestrationRun._(this._host, this._execution);

  final KernelOrchestrationHost _host;
  final OrchestrationExecution _execution;
  bool _busy = false;
  bool _closed = false;
  Completer<void>? _advanceSettled;
  Future<void>? _closing;

  AgentRun get run => _host._run;
  RunActivitySource get activity => _host.activity;
  ToolOutcome? get lastToolOutcome => _host._lastToolOutcome;
  ToolInvocation? get lastToolInvocation => _host._lastToolInvocation;
  MaterializedToolSet? get lastModelTools => _host._lastModelTools;

  @override
  Future<void> start() => _advance();

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      _advance(resolution: resolution);

  Future<void> _advance({ToolApprovalResolution? resolution}) async {
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
        await _execution.start();
      } else {
        await _host._resume(_execution, resolution);
      }
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

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= Future<void>.microtask(() async {
      await _advanceSettled?.future;
      _host._executionEnabled = false;
      if (_host._operationSettled case final Completer<void> operation) {
        await operation.future;
      }
      await _execution.close();
    });
  }
}

/// Internal adapter from semantic strategy operations to kernel mechanics.
/// Policy, exact executable objects, stream collection and evidence stay here.
final class KernelOrchestrationHost implements OrchestrationExecutionHost {
  KernelOrchestrationHost({
    required AgentRun run,
    required ResolvedOrchestrationStrategy strategy,
    required InferenceContextComposer contextComposer,
    required InferenceContextSourceContext Function() sourceContextFactory,
    required ModelPort model,
    required ToolCatalog toolCatalog,
    required ToolPolicy policy,
  }) : _run = run,
       _strategy = strategy,
       _contextComposer = contextComposer,
       _sourceContextFactory = sourceContextFactory,
       _model = model,
       _toolCatalog = toolCatalog,
       _policy = policy;

  final AgentRun _run;
  final ResolvedOrchestrationStrategy _strategy;
  final InferenceContextComposer _contextComposer;
  final InferenceContextSourceContext Function() _sourceContextFactory;
  final ModelPort _model;
  final ToolCatalog _toolCatalog;
  final ToolPolicy _policy;
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
  void validateBinding() => _strategy.validateBinding();

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
    _run.record(ModelInvocationStarted(invocationId));
    final List<ModelOutputItem> output = <ModelOutputItem>[];
    try {
      final ModelInvocationObservation observation =
          await collectModelInvocation(
            _model.invoke(request),
            invocationId: invocationId,
            onObservation: (ModelObservation observation) {
              _run.record(
                ModelObservationObserved(
                  invocationId: invocationId,
                  observation: observation,
                ),
              );
            },
            onOutput: (ModelOutputItem item) {
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
      context: ToolExecutionContext(runId: id, sessionId: sessionId),
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
    _run.record(ToolExecutionStarted(invocation.id));
    late final ToolOutcome outcome;
    try {
      final ToolExecutionObservation observation = await collectToolExecution(
        start.events(),
        retainProgress: false,
        onProgress: (ToolProgress progress) {
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
