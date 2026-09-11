import 'dart:async';

import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/orchestration_test_lifecycle.dart';

void main() {
  for (final bool foreign in <bool>[true, false]) {
    test(
      'escaped ${foreign ? 'foreign' : 'used'} snapshot error fails the active Run with evidence',
      () async {
        final _Fixture? donor = foreign ? await _Fixture.create() : null;
        await donor?.strategy.start();
        final List<ExecutionEventRecord>? donorRecords =
            donor?.run.journal.records;
        final _Fixture fixture = await _Fixture.create(
          decision: ToolPolicyDecision.allow,
        );
        fixture.execution.beforeProposal = () async {
          final StrategyModelTurn turn =
              donor?.execution.turn ?? fixture.execution.turn;
          await fixture.execution.host.processProposal(
            tools: turn.tools,
            proposal: (turn.output.single as ModelToolProposalOutput).proposal,
          );
        };

        await expectLater(
          fixture.strategy.start(),
          throwsA(isA<InvalidRunOperation>()),
        );

        expect(fixture.run.state, RunState.failed);
        expect(fixture.run.failure, isA<InvalidRunOperation>());
        expect(fixture.run.interruptions, isEmpty);
        expect(fixture.events.last, isA<RunFailed>());
        expect(
          fixture.events.whereType<RunFailed>().single.error,
          same(fixture.run.failure),
        );
        expect(fixture.model.requests, hasLength(1));
        expect(fixture.events.whereType<ModelOutputObserved>(), hasLength(1));
        expect(
          fixture.events.whereType<ModelInvocationSettled>(),
          hasLength(1),
        );
        expect(fixture.events.whereType<ModelInvocationFailed>(), isEmpty);
        expect(fixture.tool.executions, foreign ? 0 : 1);
        expect(
          fixture.events.whereType<ToolInvocationPrepared>(),
          hasLength(foreign ? 0 : 1),
        );
        expect(
          fixture.events.whereType<ToolExecutionCompleted>(),
          hasLength(foreign ? 0 : 1),
        );
        if (donor != null) {
          expect(donor.run.state, RunState.waiting);
          expect(donor.run.journal.records, orderedEquals(donorRecords!));
          expect(donor.tool.executions, 0);
          await donor.strategy.resolveApproval(_decision(donor.run, true));
          expect(donor.run.state, RunState.completed);
          expect(donor.tool.executions, 1);
        }
      },
    );
  }

  for (final bool duringApproval in <bool>[false, true]) {
    test(
      'strategy-owned invalid operation fails ${duringApproval ? 'resumed' : 'waiting'} Run',
      () async {
        final _Fixture fixture = await _Fixture.create();
        if (duringApproval) {
          await fixture.strategy.start();
          fixture.execution.completeOnApproval = false;
        }
        const InvalidRunOperation error = InvalidRunOperation('Strategy bug');
        late List<ExecutionEventRecord> beforeFailure;
        fixture.execution.beforeReturn = () async {
          beforeFailure = fixture.run.journal.records;
          throw error;
        };

        await expectLater(
          duringApproval
              ? fixture.strategy.resolveApproval(_decision(fixture.run, true))
              : fixture.strategy.start(),
          throwsA(same(error)),
        );

        expect(fixture.run.state, RunState.failed);
        expect(fixture.run.failure, same(error));
        expect(fixture.run.interruptions, isEmpty);
        expect(
          fixture.run.journal.records.take(beforeFailure.length),
          orderedEquals(beforeFailure),
        );
        expect(
          fixture.run.journal.records,
          hasLength(beforeFailure.length + 1),
        );
        expect(fixture.events.whereType<RunFailed>().single.error, same(error));
        expect(fixture.model.requests, hasLength(1));
        expect(fixture.tool.executions, duringApproval ? 1 : 0);
      },
    );
  }

  for (final bool factoryThrows in <bool>[false, true]) {
    test(
      '${factoryThrows ? 'throwing' : 'successful'} materializer cannot operate its host before wrapper start',
      () async {
        final _Model model = _Model();
        final _Tool tool = _Tool();
        final StateError failure = StateError('Factory failed');
        final List<Future<void>> rejected = <Future<void>>[];
        late OrchestrationExecutionHost retainedHost;
        late Future<void> deferredProbe;
        final Matcher blocked = throwsA(
          isA<InvalidRunOperation>().having(
            (InvalidRunOperation error) => error.message,
            'activation guard',
            contains('before its wrapper starts'),
          ),
        );
        void probe(OrchestrationExecutionHost host) {
          expect(host.id, RunId('run-authority'));
          expect(host.sessionId, SessionId('session-authority'));
          expect(host.state, RunState.created);
          host.validateBinding();
          expect(host.start, blocked);
          expect(host.complete, blocked);
          expect(() => host.fail(failure), blocked);
          // These Futures are deliberately not awaited by the materializer.
          rejected.add(
            expectLater(
              host.invokeModel(
                StrategyInferenceMaterial(
                  input: const <SemanticModelInputItem>[],
                ),
              ),
              blocked,
            ),
          );
          rejected.add(
            expectLater(
              host.processProposal(
                tools: _ForgedToolSnapshot(),
                proposal: ProviderToolProposal(
                  providerCallId: 'factory-call',
                  alias: 'test_tool',
                  arguments: const <String, Object?>{},
                ),
              ),
              blocked,
            ),
          );
          rejected.add(
            expectLater(
              host.resolveApproval(
                ToolApprovalResolution(
                  interruptionId: RunInterruptionId('factory-interruption'),
                  toolInvocationId: ToolInvocationId('factory-tool'),
                  approved: true,
                ),
              ),
              blocked,
            ),
          );
        }

        final Future<_Fixture> creating = _Fixture.create(
          model: model,
          tool: tool,
          duringMaterialize: (OrchestrationExecutionHost host) {
            retainedHost = host;
            probe(host);
            deferredProbe = Future<void>.microtask(() => probe(host));
            if (factoryThrows) throw failure;
          },
        );
        final _Fixture? fixture;
        if (factoryThrows) {
          await expectLater(creating, throwsA(same(failure)));
          fixture = null;
        } else {
          fixture = await creating;
        }
        await deferredProbe;
        probe(retainedHost);
        await Future.wait(rejected);

        expect(retainedHost.state, RunState.created);
        expect(model.requests, isEmpty);
        expect(tool.executions, 0);
        if (fixture != null) {
          expect(fixture.run.journal.records, isEmpty);
          await fixture.strategy.start();
          expect(fixture.run.state, RunState.waiting);
          await fixture.strategy.resolveApproval(_decision(fixture.run, true));
          expect(fixture.run.state, RunState.completed);
          expect(model.requests, hasLength(1));
          expect(tool.executions, 1);
          expect(fixture.events.whereType<RunStarted>(), hasLength(1));
          expect(fixture.events.whereType<RunFailed>(), isEmpty);
        }
      },
    );
  }

  test('invalid caller entrypoints never enter strategy callbacks', () async {
    final _Fixture fixture = await _Fixture.create();
    final ToolApprovalResolution early = ToolApprovalResolution(
      interruptionId: RunInterruptionId('not-pending'),
      toolInvocationId: ToolInvocationId('not-pending'),
      approved: true,
    );
    await expectLater(
      fixture.strategy.resolveApproval(early),
      throwsA(isA<InvalidRunOperation>()),
    );
    expect(fixture.execution.approvalCalls, 0);
    expect(fixture.run.journal.records, isEmpty);
    await fixture.strategy.start();
    final ToolApprovalResolution valid = _decision(fixture.run, true);
    final List<ExecutionEventRecord> waiting = fixture.run.journal.records;
    for (final ToolApprovalResolution invalid in <ToolApprovalResolution>[
      ToolApprovalResolution(
        interruptionId: early.interruptionId,
        toolInvocationId: valid.toolInvocationId,
        approved: true,
      ),
      ToolApprovalResolution(
        interruptionId: valid.interruptionId,
        toolInvocationId: early.toolInvocationId,
        approved: true,
      ),
    ]) {
      await expectLater(
        fixture.strategy.resolveApproval(invalid),
        throwsA(isA<InvalidRunOperation>()),
      );
    }
    await expectLater(
      fixture.strategy.start(),
      throwsA(isA<InvalidRunOperation>()),
    );
    expect(fixture.execution.startCalls, 1);
    expect(fixture.execution.approvalCalls, 0);
    expect(fixture.run.state, RunState.waiting);
    expect(fixture.run.journal.records, orderedEquals(waiting));
    await fixture.strategy.resolveApproval(valid);
    expect(fixture.execution.approvalCalls, 1);
    expect(fixture.run.state, RunState.completed);
    expect(fixture.tool.executions, 1);
  });

  test(
    'retirement before start preserves the binding error without execution',
    () async {
      final _Fixture fixture = await _Fixture.create();
      await fixture.registration.close();

      await expectLater(
        fixture.strategy.start(),
        throwsA(isA<StaleExtensionBinding>()),
      );

      expect(fixture.execution.startCalls, 0);
      expect(fixture.run.state, RunState.created);
      expect(fixture.run.failure, isNull);
      expect(fixture.run.journal.records, isEmpty);
      expect(fixture.model.requests, isEmpty);
      expect(fixture.tool.executions, 0);
    },
  );

  for (final bool? approved in <bool?>[null, false, true]) {
    test(
      'escaped ${approved == null ? 'manufactured' : 'substituted ($approved)'} approval fails the strategy Run',
      () async {
        final _Fixture fixture = await _Fixture.create();
        late ToolApprovalResolution rejection;
        late List<ExecutionEventRecord> waiting;
        if (approved == null) {
          fixture.execution.beforeReturn = () async {
            rejection = _decision(fixture.run, false);
            waiting = fixture.run.journal.records;
            await fixture.execution.host.resolveApproval(
              _decision(fixture.run, true),
            );
          };
        } else {
          await fixture.strategy.start();
          rejection = _decision(fixture.run, false);
          waiting = fixture.run.journal.records;
          fixture.execution.substituteResolution =
              (ToolApprovalResolution resolution) => ToolApprovalResolution(
                interruptionId: resolution.interruptionId,
                toolInvocationId: resolution.toolInvocationId,
                approved: approved,
              );
        }

        await expectLater(
          approved == null
              ? fixture.strategy.start()
              : fixture.strategy.resolveApproval(rejection),
          throwsA(isA<InvalidRunOperation>()),
        );

        expect(fixture.run.state, RunState.failed);
        expect(fixture.run.failure, isA<InvalidRunOperation>());
        expect(fixture.run.interruptions, isEmpty);
        expect(
          fixture.run.journal.records.take(waiting.length),
          orderedEquals(waiting),
        );
        expect(fixture.run.journal.records, hasLength(waiting.length + 1));
        expect(
          fixture.events.whereType<RunFailed>().single.error,
          same(fixture.run.failure),
        );
        expect(fixture.events.whereType<RunInterruptionResolved>(), isEmpty);
        expect(fixture.events.whereType<ToolExecutionStarted>(), isEmpty);
        expect(fixture.strategy.lastToolOutcome, isNull);
        expect(fixture.tool.executions, 0);
        expect(fixture.model.requests, hasLength(1));

        final List<ExecutionEventRecord> failed = fixture.run.journal.records;
        await expectLater(
          fixture.execution.host.resolveApproval(rejection),
          throwsA(isA<InvalidRunOperation>()),
        );
        await expectLater(
          fixture.strategy.resolveApproval(rejection),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(fixture.run.journal.records, orderedEquals(failed));
      },
    );
  }

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
      'escaped misuse defers Run failure until active ${duringModel ? 'model' : 'tool'} terminal evidence',
      () async {
        final _Fixture fixture = await _Fixture.create(
          decision: ToolPolicyDecision.allow,
        );
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        Future<void> suspend() async {
          entered.complete();
          await release.future;
        }

        late Future<Object> mechanics;
        late Object misuse;
        fixture.execution.beforeProposal = () async {
          if (duringModel) {
            fixture.model.beforeSettlement = suspend;
            mechanics = fixture.execution.host.invokeModel(
              StrategyInferenceMaterial(
                input: const <SemanticModelInputItem>[],
              ),
            );
          } else {
            fixture.tool.beforeTerminal = suspend;
            mechanics = fixture.execution.host.processProposal(
              tools: fixture.execution.turn.tools,
              proposal:
                  (fixture.execution.turn.output.single
                          as ModelToolProposalOutput)
                      .proposal,
            );
          }
          await entered.future;
          try {
            fixture.execution.host.complete();
          } on Object catch (error) {
            misuse = error;
            rethrow;
          }
        };

        await expectLater(
          fixture.strategy.start(),
          throwsA(isA<InvalidRunOperation>()),
        );
        final List<ExecutionEventRecord> inFlight = fixture.run.journal.records;
        expect(fixture.run.state, RunState.running);
        expect(fixture.run.failure, isNull);
        expect(
          fixture.events.whereType<ModelInvocationSettled>(),
          hasLength(1),
        );
        expect(fixture.events.whereType<ToolExecutionCompleted>(), isEmpty);
        expect(fixture.events.whereType<RunFailed>(), isEmpty);
        await expectLater(
          fixture.strategy.start(),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(fixture.run.journal.records, orderedEquals(inFlight));
        release.complete();
        await mechanics;

        expect(fixture.run.state, RunState.failed);
        expect(fixture.run.failure, same(misuse));
        expect(fixture.model.requests, hasLength(duringModel ? 2 : 1));
        expect(fixture.tool.executions, duringModel ? 0 : 1);
        expect(fixture.events.whereType<ModelInvocationFailed>(), isEmpty);
        expect(
          fixture.run.journal.records.take(inFlight.length),
          orderedEquals(inFlight),
        );
        expect(
          fixture.events
              .skip(inFlight.length)
              .map((ExecutionEvent event) => event.runtimeType),
          <Type>[
            duringModel ? ModelInvocationSettled : ToolExecutionCompleted,
            RunFailed,
          ],
        );
        expect(
          fixture.events.whereType<RunFailed>().single.error,
          same(misuse),
        );
        if (!duringModel) {
          expect(
            fixture.strategy.lastToolOutcome!.disposition,
            ToolOutcomeDisposition.success,
          );
          expect(
            fixture.strategy.lastToolOutcome!.effectCertainty,
            EffectCertainty.knownOccurred,
          );
        }
      },
    );

    test(
      'public fail and wrapper reentry reject active ${duringModel ? 'model' : 'tool'} work without losing terminal evidence',
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
        await expectLater(
          fixture.strategy.start(),
          throwsA(isA<InvalidRunOperation>()),
        );
        await expectLater(
          fixture.strategy.resolveApproval(
            ToolApprovalResolution(
              interruptionId: RunInterruptionId('run-authority-interruption-1'),
              toolInvocationId: ToolInvocationId('run-authority-tool-1'),
              approved: true,
            ),
          ),
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

  static Future<_Fixture> create({
    ToolPolicyDecision decision = ToolPolicyDecision.ask,
    void Function(OrchestrationExecutionHost)? duringMaterialize,
    _Model? model,
    _Tool? tool,
  }) async {
    final ExtensionRegistry extensions = ExtensionRegistry();
    late _Execution execution;
    final ExtensionRegistration registration = extensions.register(
      point: orchestrationStrategyContributions,
      id: _extensionId,
      value: OrchestrationStrategyContribution(
        strategyId: _strategyId,
        materialize: (OrchestrationStrategyHostContext context) {
          duringMaterialize?.call(context.host);
          return execution = _Execution(context.host);
        },
      ),
    );
    addTearDown(registration.close);
    final OrchestrationTestLifecycle topology =
        await OrchestrationTestLifecycle.create(
          extensions,
          SessionId('session-authority'),
        );
    final Session session = topology.createSession(_strategyId);
    model ??= _Model();
    tool ??= _Tool();
    final SessionOrchestrationRun strategy = createSessionOrchestrationRun(
      lifecycle: topology.lifecycle,
      sessionId: session.id,
      runId: RunId('run-authority'),
      model: model,
      toolCatalog: _catalog(tool),
      policy: _Policy(decision),
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
  Future<void> Function()? beforeProposal;
  Future<void> Function()? beforeReturn;
  bool completeOnApproval = true;
  int startCalls = 0;
  int approvalCalls = 0;
  late StrategyModelTurn turn;

  @override
  Future<void> start() async {
    startCalls++;
    host.start();
    turn = await host.invokeModel(
      StrategyInferenceMaterial(input: const <SemanticModelInputItem>[]),
    );
    await beforeProposal?.call();
    await host.processProposal(
      tools: turn.tools,
      proposal: (turn.output.single as ModelToolProposalOutput).proposal,
    );
    await beforeReturn?.call();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    approvalCalls++;
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

final class _ForgedToolSnapshot implements StrategyToolSnapshot {}

final class _Policy implements ToolPolicy {
  const _Policy(this.decision);

  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}
