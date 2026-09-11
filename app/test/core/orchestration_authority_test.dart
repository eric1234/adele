import 'dart:async';

import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/orchestration_test_lifecycle.dart';

void main() {
  test(
    'strategy cannot manufacture approval or turn rejection into approval',
    () async {
      final _Fixture fixture = await _Fixture.create();
      await fixture.strategy.start();
      final ToolApprovalInterruption interruption =
          fixture.run.interruptions.values.single as ToolApprovalInterruption;
      final ToolApprovalResolution rejection = _decision(fixture.run, false);
      final List<ExecutionEventRecord> waiting = fixture.run.journal.records;

      await expectLater(
        fixture.execution.host.resolveApproval(_decision(fixture.run, true)),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.run.state, RunState.waiting);
      expect(fixture.run.journal.records, orderedEquals(waiting));
      expect(fixture.tool.executions, 0);

      for (final bool approved in <bool>[false, true]) {
        fixture.execution.substituteResolution =
            (ToolApprovalResolution resolution) => ToolApprovalResolution(
              interruptionId: resolution.interruptionId,
              toolInvocationId: resolution.toolInvocationId,
              approved: approved,
            );
        await expectLater(
          fixture.strategy.resolveApproval(rejection),
          throwsA(isA<InvalidRunOperation>()),
        );
        // Even the original object is unauthorized after its callback returns.
        await expectLater(
          fixture.execution.host.resolveApproval(rejection),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(fixture.run.state, RunState.waiting);
        expect(fixture.run.failure, isNull);
        expect(fixture.run.interruptions.values.single, same(interruption));
        expect(fixture.run.journal.records, orderedEquals(waiting));
        expect(fixture.strategy.lastToolOutcome, isNull);
        expect(fixture.tool.executions, 0);
      }

      fixture.execution.substituteResolution = null;
      await fixture.strategy.resolveApproval(rejection);
      expect(
        fixture.strategy.lastToolOutcome!.disposition,
        ToolOutcomeDisposition.userRejected,
      );
      expect(
        fixture.strategy.lastToolOutcome!.effectCertainty,
        EffectCertainty.knownNotOccurred,
      );
      expect(fixture.run.state, RunState.completed);
      expect(fixture.run.interruptions, isEmpty);
      expect(fixture.tool.executions, 0);
      expect(fixture.model.requests, hasLength(1));
      final RunInterruptionResolved resolved = fixture.events
          .whereType<RunInterruptionResolved>()
          .single;
      expect(resolved.interruption, same(interruption));
      expect(resolved.resolution, same(rejection));
      expect(fixture.events.whereType<ToolExecutionStarted>(), isEmpty);
      expect(
        fixture.events.whereType<ToolInvocationCompleted>().single.outcome,
        same(fixture.strategy.lastToolOutcome),
      );
      expect(fixture.events.whereType<RunFailed>(), isEmpty);
    },
  );

  test(
    'dynamic strategy access cannot expose kernel or snapshot internals',
    () async {
      final _Fixture fixture = await _Fixture.create();
      await fixture.strategy.start();
      final List<ExecutionEventRecord> waiting = fixture.run.journal.records;
      // A private class name alone does not hide public members from dynamic.
      final dynamic publicHost = fixture.execution.host;
      final dynamic publicSnapshot = fixture.execution.turn.tools;
      for (final MapEntry<String, Object? Function()> probe
          in <String, Object? Function()>{
            'host.run': () => publicHost.run,
            'host.lastModelTools': () => publicHost.lastModelTools,
            'host.lastToolInvocation': () => publicHost.lastToolInvocation,
            'host.lastToolOutcome': () => publicHost.lastToolOutcome,
            'snapshot.owner': () => publicSnapshot.owner,
            'snapshot.tools': () => publicSnapshot.tools,
            'snapshot.proposals': () => publicSnapshot.proposals,
          }.entries) {
        expect(
          probe.value,
          throwsA(isA<NoSuchMethodError>()),
          reason: probe.key,
        );
      }
      expect(fixture.run.state, RunState.waiting);
      expect(fixture.run.journal.records, orderedEquals(waiting));
      expect(fixture.tool.executions, 0);
      expect(
        fixture.strategy.lastModelTools,
        same(fixture.model.requests.single.tools),
      );
      expect(
        fixture.strategy.lastToolInvocation,
        same(
          fixture.events.whereType<ToolInvocationPrepared>().single.invocation,
        ),
      );
      expect(fixture.strategy.lastToolOutcome, isNull);
      await fixture.strategy.resolveApproval(_decision(fixture.run, false));
      expect(fixture.run.state, RunState.completed);
      expect(
        fixture.strategy.lastToolOutcome!.disposition,
        ToolOutcomeDisposition.userRejected,
      );
      expect(fixture.tool.executions, 0);
    },
  );

  for (final bool duringModel in <bool>[true, false]) {
    test(
      'public fail rejects active ${duringModel ? 'model' : 'tool'} work without losing terminal evidence',
      () async {
        final _Fixture fixture = await _Fixture.create();
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        Future<void> suspend() async {
          entered.complete();
          await release.future;
        }

        final Future<void> advancing;
        if (duringModel) {
          fixture.model.beforeSettlement = suspend;
          advancing = fixture.strategy.start();
        } else {
          await fixture.strategy.start();
          fixture.tool.beforeTerminal = suspend;
          advancing = fixture.strategy.resolveApproval(
            _decision(fixture.run, true),
          );
        }
        await entered.future;
        final List<ExecutionEventRecord> inFlight = fixture.run.journal.records;
        expect(fixture.run.state, RunState.running);
        expect(
          () => fixture.execution.host.fail(StateError('Premature failure')),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(fixture.run.state, RunState.running);
        expect(fixture.run.failure, isNull);
        expect(fixture.run.journal.records, orderedEquals(inFlight));
        expect(fixture.model.requests, hasLength(1));
        expect(fixture.tool.executions, duringModel ? 0 : 1);
        expect(fixture.events.whereType<ModelOutputObserved>(), hasLength(1));
        expect(fixture.events.whereType<ToolExecutionCompleted>(), isEmpty);
        release.complete();
        await advancing;
        if (duringModel) {
          expect(fixture.run.state, RunState.waiting);
          await fixture.strategy.resolveApproval(_decision(fixture.run, true));
        }

        expect(fixture.run.state, RunState.completed);
        expect(fixture.tool.executions, 1);
        expect(
          fixture.events.whereType<ModelInvocationSettled>().single.settlement,
          ModelSettlement.completed,
        );
        expect(fixture.events.whereType<ModelInvocationFailed>(), isEmpty);
        expect(fixture.events.whereType<ToolExecutionStarted>(), hasLength(1));
        expect(
          fixture.events.whereType<ToolExecutionCompleted>().single.outcome,
          same(fixture.strategy.lastToolOutcome),
        );
        expect(
          fixture.strategy.lastToolOutcome!.disposition,
          ToolOutcomeDisposition.success,
        );
        expect(
          fixture.strategy.lastToolOutcome!.effectCertainty,
          EffectCertainty.knownOccurred,
        );
        expect(
          fixture.events.whereType<RunInterruptionResolved>(),
          hasLength(1),
        );
        expect(fixture.events.whereType<RunFailed>(), isEmpty);
        expect(
          fixture.events
              .map((ExecutionEvent event) => event.runtimeType)
              .toList()
              .sublist(inFlight.length),
          duringModel
              ? <Type>[
                  ModelInvocationSettled,
                  ToolInvocationPrepared,
                  ToolPolicyEvaluated,
                  RunInterrupted,
                  RunWaiting,
                  RunInterruptionResolved,
                  RunResumed,
                  ToolExecutionStarted,
                  ToolExecutionCompleted,
                  RunCompleted,
                ]
              : <Type>[ToolExecutionCompleted, RunCompleted],
        );
      },
    );
  }

  for (final bool duringApproval in <bool>[false, true]) {
    test(
      'wrapper catches retirement during strategy-owned async ${duringApproval ? 'resume' : 'start'}',
      () async {
        final _Fixture fixture = await _Fixture.create();
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        Future<void> suspend() async {
          entered.complete();
          await release.future;
        }

        final Future<void> advancing;
        if (duringApproval) {
          await fixture.strategy.start();
          fixture.execution.completeOnApproval = false;
          fixture.execution.beforeReturn = suspend;
          advancing = fixture.strategy.resolveApproval(
            _decision(fixture.run, true),
          );
        } else {
          fixture.execution.beforeReturn = suspend;
          advancing = fixture.strategy.start();
        }
        final Future<void> failed = expectLater(
          advancing,
          throwsA(isA<StaleExtensionBinding>()),
        );
        await entered.future;
        final RunState suspendedState = duringApproval
            ? RunState.running
            : RunState.waiting;
        final List<ExecutionEventRecord> settled = fixture.run.journal.records;
        expect(fixture.run.state, suspendedState);
        expect(
          fixture.events.whereType<ModelInvocationSettled>(),
          hasLength(1),
        );
        expect(
          fixture.events.whereType<ToolExecutionCompleted>(),
          hasLength(duringApproval ? 1 : 0),
        );
        await fixture.registration.close();
        int replacementCallbacks = 0;
        addTearDown(
          fixture.extensions
              .register(
                point: orchestrationStrategyContributions,
                id: _extensionId,
                value: OrchestrationStrategyContribution(
                  strategyId: _strategyId,
                  materialize: (OrchestrationStrategyHostContext context) {
                    replacementCallbacks++;
                    return _Execution(context.host);
                  },
                ),
              )
              .close,
        );
        expect(fixture.run.state, suspendedState);
        expect(fixture.run.failure, isNull);
        expect(fixture.run.journal.records, orderedEquals(settled));
        release.complete();
        await failed;

        expect(fixture.run.state, RunState.failed);
        expect(
          fixture.run.failure,
          isA<StaleExtensionBinding>().having(
            (StaleExtensionBinding error) => error.id,
            'retired generation',
            _extensionId,
          ),
        );
        expect(fixture.run.interruptions, isEmpty);
        expect(
          fixture.run.journal.records.take(settled.length),
          orderedEquals(settled),
        );
        expect(fixture.run.journal.records, hasLength(settled.length + 1));
        expect(fixture.events.last, isA<RunFailed>());
        expect(
          fixture.events.whereType<RunFailed>().single.error,
          same(fixture.run.failure),
        );
        expect(fixture.events.whereType<RunCompleted>(), isEmpty);
        expect(fixture.events.whereType<ModelInvocationFailed>(), isEmpty);
        expect(fixture.model.requests, hasLength(1));
        expect(fixture.tool.executions, duringApproval ? 1 : 0);
        expect(replacementCallbacks, 0);
        if (duringApproval) {
          expect(
            fixture.strategy.lastToolOutcome!.disposition,
            ToolOutcomeDisposition.success,
          );
          expect(
            fixture.strategy.lastToolOutcome!.effectCertainty,
            EffectCertainty.knownOccurred,
          );
        } else {
          expect(fixture.strategy.lastToolOutcome, isNull);
        }
      },
    );
  }
}

final OrchestrationStrategyId _strategyId = OrchestrationStrategyId(
  'dev.adele.test.approval',
);
final ExtensionId _extensionId = ExtensionId(
  'dev.adele.test.approval.registration',
);

final class _Fixture {
  const _Fixture._(
    this.extensions,
    this.registration,
    this.strategy,
    this.execution,
    this.model,
    this.tool,
  );

  static Future<_Fixture> create() async {
    final ExtensionRegistry extensions = ExtensionRegistry();
    late _Execution execution;
    final ExtensionRegistration registration = extensions.register(
      point: orchestrationStrategyContributions,
      id: _extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: _strategyId,
        materialize: (OrchestrationStrategyHostContext context) =>
            execution = _Execution(context.host),
      ),
    );
    addTearDown(registration.close);
    final OrchestrationTestLifecycle topology =
        await OrchestrationTestLifecycle.create(
          extensions,
          SessionId('session-authority'),
        );
    final Session session = topology.createSession(_strategyId);
    final _Model model = _Model();
    final _Tool tool = _Tool();
    final SessionOrchestrationRun strategy = createSessionOrchestrationRun(
      lifecycle: topology.lifecycle,
      sessionId: session.id,
      runId: RunId('run-authority'),
      model: model,
      toolCatalog: _catalog(tool),
      policy: const _AskPolicy(),
    );
    return _Fixture._(
      extensions,
      registration,
      strategy,
      execution,
      model,
      tool,
    );
  }

  final ExtensionRegistry extensions;
  final ExtensionRegistration registration;
  final SessionOrchestrationRun strategy;
  final _Execution execution;
  final _Model model;
  final _Tool tool;

  AgentRun get run => strategy.run;
  Iterable<ExecutionEvent> get events =>
      run.journal.records.map((ExecutionEventRecord record) => record.event);
}

final class _Execution implements OrchestrationExecution {
  _Execution(this.host);

  final OrchestrationExecutionHost host;
  ToolApprovalResolution Function(ToolApprovalResolution)? substituteResolution;
  Future<void> Function()? beforeReturn;
  bool completeOnApproval = true;
  late StrategyModelTurn turn;

  @override
  Future<void> start() async {
    host.start();
    turn = await host.invokeModel(
      StrategyInferenceMaterial(input: const <SemanticModelInputItem>[]),
    );
    await host.processProposal(
      tools: turn.tools,
      proposal: (turn.output.single as ModelToolProposalOutput).proposal,
    );
    await beforeReturn?.call();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    await host.resolveApproval(
      substituteResolution?.call(resolution) ?? resolution,
    );
    if (completeOnApproval) host.complete();
    await beforeReturn?.call();
  }
}

final class _Model implements ModelPort {
  final List<SemanticModelRequest> requests = <SemanticModelRequest>[];
  Future<void> Function()? beforeSettlement;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests.add(request);
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelToolProposalOutput(
        ProviderToolProposal(
          providerCallId: 'call-1',
          alias: 'test_tool',
          arguments: const <String, Object?>{},
        ),
      ),
    );
    await beforeSettlement?.call();
    yield ModelInvocationSettledEvent(invocationId: request.invocationId);
  }
}

final class _Tool implements ToolExecutable {
  int executions = 0;
  Future<void> Function()? beforeTerminal;

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) => CanonicalToolArguments(proposedArguments);

  @override
  void validateBinding() {}

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const <ToolEffect>[ToolEffect.sourceMutation],
    targets: const <EffectTarget>[],
    summary: 'Test effect',
  );

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    executions++;
    await beforeTerminal?.call();
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Executed',
      ),
    );
  }
}

ToolCatalog _catalog(ToolExecutable tool) => ToolCatalog()
  ..register(
    ToolRegistration(
      definition: ToolDefinition(
        id: ToolId('dev.adele.test.tool'),
        description: 'Test',
      ),
      modelDefinition: ModelToolDefinition(
        alias: 'test_tool',
        description: 'Test',
        argumentsSchema: const <String, Object?>{},
      ),
      executable: tool,
    ),
  );

ToolApprovalResolution _decision(AgentRun run, bool approved) {
  final ToolApprovalInterruption interruption =
      run.interruptions.values.single as ToolApprovalInterruption;
  return ToolApprovalResolution(
    interruptionId: interruption.id,
    toolInvocationId: interruption.toolInvocationId,
    approved: approved,
  );
}

final class _AskPolicy implements ToolPolicy {
  const _AskPolicy();

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => ToolPolicyDecision.ask;
}
