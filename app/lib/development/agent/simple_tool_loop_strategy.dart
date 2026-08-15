import 'package:agent_kernel/agent_kernel.dart';

/// Provisional development sequencing; it is not the semantic definition of Run.
final class DevelopmentToolLoopStrategy {
  DevelopmentToolLoopStrategy({
    required this.run,
    required this.session,
    required this.contextAssembler,
    required this.model,
    required this.toolCatalog,
    required this.policy,
  }) {
    if (run.sessionId != session.id) {
      throw ArgumentError('Run and Session identities must match.');
    }
  }

  final AgentRun run;
  final SessionHistoryPort session;
  final ContextAssembler contextAssembler;
  final ModelPort model;
  final ToolCatalog toolCatalog;
  final ToolPolicy policy;
  final List<SemanticModelInputItem> _runItems = <SemanticModelInputItem>[];
  final ToolInvocationResolver _invocationResolver =
      const ToolInvocationResolver();
  final ToolPolicyGate _policyGate = const ToolPolicyGate();
  int _nextModelInvocation = 1;
  int _nextToolInvocation = 1;
  int _nextInterruption = 1;
  bool _busy = false;
  _PendingApproval? _pendingApproval;
  ToolOutcome? _lastToolOutcome;
  ToolInvocation? _lastToolInvocation;
  MaterializedToolSet? _lastModelTools;

  ToolOutcome? get lastToolOutcome => _lastToolOutcome;
  ToolInvocation? get lastToolInvocation => _lastToolInvocation;
  MaterializedToolSet? get lastModelTools => _lastModelTools;

  Future<void> start() async {
    await _exclusive(() async {
      run.start();
      await _advanceModel();
    });
  }

  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    await _exclusive(() async {
      final _PendingApproval? pending = _pendingApproval;
      if (pending == null) {
        throw const InvalidRunOperation('No tool approval is pending.');
      }
      final ResolvedRunInterruption resolved = run.resolveInterruption(
        resolution,
      );
      _pendingApproval = null;
      if (!resolution.approved) {
        final ToolOutcome outcome = ToolOutcome(
          disposition: ToolOutcomeDisposition.userRejected,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: 'The user rejected this tool invocation.',
        );
        _recordToolTerminal(
          pending.invocation,
          outcome,
          executionStarted: false,
        );
        await _continueAfterTool(pending.invocation, outcome);
        return;
      }
      await _execute(_policyGate.approve(resolved));
    });
  }

  Future<void> _advanceModel() async {
    if (run.state != RunState.running) return;
    final ModelInvocationId invocationId = ModelInvocationId(
      '${run.id.value}-model-${_nextModelInvocation++}',
    );
    final MaterializedToolSet tools = toolCatalog.materialize();
    final SemanticModelRequest request = contextAssembler.assemble(
      ContextAssemblyInput(
        invocationId: invocationId,
        session: session.snapshot(),
        runItems: _runItems,
        tools: tools,
      ),
    );
    if (request.invocationId != invocationId ||
        !identical(request.tools, tools)) {
      _fail(
        StateError(
          'Context assembly changed the invocation identity or tool materialization.',
        ),
      );
      return;
    }
    _lastModelTools = request.tools;
    final _ModelTurn turn = await _invokeModel(request);
    if (turn.failure != null) {
      _fail(turn.failure!);
      return;
    }
    final ModelInvocationSettledEvent settlement = turn.settlement!;
    switch (settlement.settlement) {
      case ModelSettlement.completed:
        break;
      case ModelSettlement.incomplete:
        _fail(
          ModelInvocationIncomplete(
            reason: settlement.incompleteReason!,
            metadata: settlement.metadata,
          ),
        );
        return;
      case ModelSettlement.refused:
        if (turn.text.trim().isEmpty) {
          _fail(StateError('The model refused without assistant output.'));
          return;
        }
        session.append(AssistantSessionMessage(turn.text));
        run.complete();
        return;
    }
    final ProviderToolProposal? proposal = turn.proposal;
    if (proposal == null) {
      if (turn.text.trim().isEmpty) {
        _fail(StateError('The model completed without assistant output.'));
        return;
      }
      session.append(AssistantSessionMessage(turn.text));
      run.complete();
      return;
    }
    for (final ModelOutputItem item in turn.output) {
      switch (item) {
        case ModelNativeOutput(
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          _runItems.add(
            SemanticNativeInput(
              providerItemId: providerItemId,
              providerNativeMetadata: providerNativeMetadata,
            ),
          );
        case ModelTextOutput(
          :final content,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          _runItems.add(
            SemanticMessageInput(
              role: SemanticMessageRole.assistant,
              content: content,
              providerItemId: providerItemId,
              providerNativeMetadata: providerNativeMetadata,
            ),
          );
        case ModelToolProposalOutput(
          :final proposal,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          _runItems.add(
            SemanticToolProposalInput(
              proposal: proposal,
              providerItemId: providerItemId,
              providerNativeMetadata: providerNativeMetadata,
            ),
          );
      }
    }
    final ToolProposalResolution resolution = _invocationResolver.resolve(
      invocationId: ToolInvocationId(
        '${run.id.value}-tool-${_nextToolInvocation++}',
      ),
      proposal: proposal,
      tools: request.tools,
      context: _executionContext,
    );
    switch (resolution) {
      case RejectedToolProposal(:final failure):
        _runItems.add(SemanticToolProposalFailureInput(failure: failure));
        await _advanceModel();
      case ResolvedToolProposal(:final invocation):
        _lastToolInvocation = invocation;
        run.record(ToolInvocationPrepared(invocation));
        await _applyPolicy(invocation);
    }
  }

  Future<_ModelTurn> _invokeModel(SemanticModelRequest request) async {
    run.record(ModelInvocationStarted(request.invocationId));
    final StringBuffer text = StringBuffer();
    final List<ModelOutputItem> output = <ModelOutputItem>[];
    ProviderToolProposal? proposal;
    try {
      final ModelInvocationObservation
      observation = await collectModelInvocation(
        model.invoke(request),
        invocationId: request.invocationId,
        onObservation: (ModelObservation observation) {
          run.record(
            ModelObservationObserved(
              invocationId: request.invocationId,
              observation: observation,
            ),
          );
        },
        onOutput: (ModelOutputItem item) {
          output.add(item);
          run.record(
            ModelOutputObserved(invocationId: request.invocationId, item: item),
          );
          switch (item) {
            case ModelNativeOutput():
              break;
            case ModelTextOutput(:final content):
              text.write(content);
            case ModelToolProposalOutput(proposal: final value):
              if (proposal != null) {
                throw StateError(
                  'The provisional strategy supports one proposal per model invocation.',
                );
              }
              proposal = value;
          }
        },
      );
      switch (observation.terminal) {
        case final ModelInvocationSettledEvent terminal:
          run.record(
            ModelInvocationSettled(
              invocationId: request.invocationId,
              settlement: terminal.settlement,
              incompleteReason: terminal.incompleteReason,
              metadata: terminal.metadata,
            ),
          );
          return _ModelTurn(
            text: text.toString(),
            proposal: proposal,
            failure: null,
            output: output,
            settlement: terminal,
          );
        case ModelInvocationFailedEvent(
          :final error,
          :final semanticTerminalMetadata,
        ):
          run.record(
            ModelInvocationFailed(
              invocationId: request.invocationId,
              error: error,
              semanticTerminalMetadata: semanticTerminalMetadata,
            ),
          );
          return _ModelTurn(
            text: text.toString(),
            proposal: proposal,
            failure: error,
            output: output,
            settlement: null,
          );
      }
    } on Object catch (error) {
      run.record(
        ModelInvocationFailed(invocationId: request.invocationId, error: error),
      );
      return _ModelTurn(
        text: text.toString(),
        proposal: proposal,
        failure: error,
        output: output,
        settlement: null,
      );
    }
  }

  Future<void> _applyPolicy(ToolInvocation invocation) async {
    final ToolPolicyGateResult result;
    try {
      result = await _policyGate.evaluate(
        invocation: invocation,
        policy: policy,
        interruptionId: RunInterruptionId(
          '${run.id.value}-interruption-${_nextInterruption++}',
        ),
      );
    } on ToolEffectDescriptionFailed catch (error) {
      final ToolOutcome outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.infrastructure,
        effectCertainty: EffectCertainty.knownNotOccurred,
        modelContent: 'Tool effect description failed.',
        hostDiagnostic: error.cause.toString(),
        cause: error.cause,
      );
      _recordToolTerminal(invocation, outcome, executionStarted: false);
      await _continueAfterTool(invocation, outcome);
      return;
    } on ToolPolicyEvaluationFailed catch (error) {
      final ToolOutcome outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.infrastructure,
        effectCertainty: EffectCertainty.knownNotOccurred,
        modelContent: 'Tool policy evaluation failed.',
        hostDiagnostic: error.cause.toString(),
        cause: error.cause,
      );
      _recordToolTerminal(invocation, outcome, executionStarted: false);
      await _continueAfterTool(invocation, outcome);
      return;
    }
    final ToolPolicyDecision decision = switch (result) {
      ToolExecutionAllowed() => ToolPolicyDecision.allow,
      ToolExecutionDenied() => ToolPolicyDecision.deny,
      ToolApprovalRequired() => ToolPolicyDecision.ask,
    };
    run.record(
      ToolPolicyEvaluated(
        invocationId: invocation.id,
        decision: decision,
        effects: result.effects,
      ),
    );
    switch (result) {
      case ToolExecutionAllowed():
        await _execute(result);
      case ToolExecutionDenied(:final outcome):
        _recordToolTerminal(invocation, outcome, executionStarted: false);
        await _continueAfterTool(invocation, outcome);
      case ToolApprovalRequired(:final interruption):
        _pendingApproval = _PendingApproval(invocation: invocation);
        run.interrupt(interruption);
    }
  }

  Future<void> _execute(ToolExecutionAllowed allowed) async {
    final ToolInvocation invocation = allowed.invocation;
    final ToolExecutionStart start;
    try {
      start = run.startToolExecution(allowed);
    } on StaleToolBindingException catch (error) {
      final ToolOutcome outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.staleBinding,
        effectCertainty: EffectCertainty.knownNotOccurred,
        modelContent: 'The approved tool binding is stale.',
        hostDiagnostic: error.message,
        cause: error.cause ?? error,
      );
      _recordToolTerminal(invocation, outcome, executionStarted: false);
      await _continueAfterTool(invocation, outcome);
      return;
    } on ToolBindingUnavailableException catch (error) {
      final ToolOutcome outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.infrastructure,
        effectCertainty: EffectCertainty.knownNotOccurred,
        modelContent: 'The approved tool binding is unavailable.',
        hostDiagnostic: error.message,
        cause: error.cause ?? error,
      );
      _recordToolTerminal(invocation, outcome, executionStarted: false);
      await _continueAfterTool(invocation, outcome);
      return;
    }
    run.record(ToolExecutionStarted(invocation.id));
    late final ToolOutcome outcome;
    try {
      final ToolExecutionObservation observation = await collectToolExecution(
        start.events(),
        onProgress: (ToolProgress progress) {
          run.record(
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
    _recordToolTerminal(invocation, outcome, executionStarted: true);
    await _continueAfterTool(invocation, outcome);
  }

  void _recordToolTerminal(
    ToolInvocation invocation,
    ToolOutcome outcome, {
    required bool executionStarted,
  }) {
    _lastToolOutcome = outcome;
    run.record(
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
  }

  Future<void> _continueAfterTool(
    ToolInvocation invocation,
    ToolOutcome outcome,
  ) async {
    _runItems.add(
      SemanticToolOutcomeInput(
        providerCallId: invocation.proposal.providerCallId,
        outcome: outcome,
      ),
    );
    await _advanceModel();
  }

  ToolExecutionContext get _executionContext =>
      ToolExecutionContext(runId: run.id, sessionId: run.sessionId);

  void _fail(Object error) {
    if (run.state == RunState.running || run.state == RunState.waiting) {
      run.fail(error);
    }
  }

  Future<void> _exclusive(Future<void> Function() operation) async {
    if (_busy) {
      throw const InvalidRunOperation(
        'The development strategy is already advancing this Run.',
      );
    }
    _busy = true;
    try {
      await operation();
    } on InvalidRunOperation {
      rethrow;
    } on Object catch (error, stackTrace) {
      _fail(error);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _busy = false;
    }
  }
}

final class _PendingApproval {
  const _PendingApproval({required this.invocation});

  final ToolInvocation invocation;
}

final class _ModelTurn {
  const _ModelTurn({
    required this.text,
    required this.proposal,
    required this.failure,
    required this.output,
    required this.settlement,
  });

  final String text;
  final ProviderToolProposal? proposal;
  final Object? failure;
  final List<ModelOutputItem> output;
  final ModelInvocationSettledEvent? settlement;
}

final class ModelInvocationIncomplete implements Exception {
  const ModelInvocationIncomplete({
    required this.reason,
    required this.metadata,
  });

  final ModelIncompleteReason reason;
  final ModelTerminalMetadata metadata;
}
