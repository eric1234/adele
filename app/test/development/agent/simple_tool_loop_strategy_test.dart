import 'dart:async';

import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'allow executes without interruption and preserves proposal context',
    () async {
      final _StrategyFixture fixture = _fixture(ToolPolicyDecision.allow);

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.completed);
      expect(fixture.executable.executions, 1);
      expect(fixture.model.sawCorrelatedContinuation, isTrue);
      expect(
        fixture.run.journal.records
            .map((ExecutionEventRecord record) => record.event)
            .whereType<RunInterrupted>(),
        isEmpty,
      );
    },
  );

  test(
    'journals live structured progress before terminal continuation',
    () async {
      final _StrategyFixture fixture = _fixture(
        ToolPolicyDecision.allow,
        progress: <ToolProgress>[
          ToolProgress(kind: ToolProgressKind.stdout, content: 'out'),
          ToolProgress(kind: ToolProgressKind.stderr, content: '\n'),
        ],
      );

      await fixture.strategy.start();

      final List<ToolProgressObserved> progress = fixture.run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ToolProgressObserved>()
          .toList(growable: false);
      expect(
        progress.map((ToolProgressObserved event) => event.progress.kind),
        <ToolProgressKind>[ToolProgressKind.stdout, ToolProgressKind.stderr],
      );
      expect(
        progress.map((ToolProgressObserved event) => event.progress.content),
        <String>['out', '\n'],
      );
      expect(fixture.run.state, RunState.completed);
      expect(fixture.model.sawCorrelatedContinuation, isTrue);
    },
  );

  test('incomplete settlement fails without executing proposed tool', () async {
    final _StrategyFixture fixture = _fixture(
      ToolPolicyDecision.allow,
      settlement: ModelSettlement.incomplete,
    );

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.failed);
    expect(fixture.run.failure, isA<ModelInvocationIncomplete>());
    expect(fixture.executable.executions, 0);
    expect(
      fixture.run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ModelInvocationSettled>()
          .single
          .settlement,
      ModelSettlement.incomplete,
    );
  });

  test('refused settlement records refusal and never executes tool', () async {
    final _StrategyFixture fixture = _fixture(
      ToolPolicyDecision.allow,
      settlement: ModelSettlement.refused,
    );

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.completed);
    expect(fixture.executable.executions, 0);
    expect(
      fixture.run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ModelInvocationSettled>()
          .single
          .settlement,
      ModelSettlement.refused,
    );
  });

  test('continuation preserves proposal-before-text output order', () async {
    final _StrategyFixture fixture = _fixture(
      ToolPolicyDecision.allow,
      proposalBeforeText: true,
    );

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.completed);
    expect(fixture.model.sawPreservedOutputOrder, isTrue);
  });

  test('deny continues without interruption or execution', () async {
    final _StrategyFixture fixture = _fixture(ToolPolicyDecision.deny);

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.completed);
    expect(fixture.executable.executions, 0);
    expect(
      fixture.strategy.lastToolOutcome?.disposition,
      ToolOutcomeDisposition.policyDenied,
    );
    expect(
      fixture.run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ToolExecutionStarted>(),
      isEmpty,
    );
    expect(
      fixture.run.journal.records
          .map((ExecutionEventRecord record) => record.event)
          .whereType<ToolInvocationCompleted>(),
      hasLength(1),
    );
  });

  test(
    'context assembly cannot replace the model-visible tool snapshot',
    () async {
      final _StrategyFixture fixture = _fixture(
        ToolPolicyDecision.allow,
        contextAssembler: const _ReplacingContextAssembler(),
      );

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.failed);
      expect(fixture.model.invocations, 0);
      expect(fixture.executable.executions, 0);
    },
  );

  test(
    'unknown proposal continues without creating a ToolInvocation',
    () async {
      final _StrategyFixture fixture = _fixture(
        ToolPolicyDecision.allow,
        modelAlias: 'unknown_tool',
      );

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.completed);
      expect(fixture.model.invocations, 2);
      expect(fixture.strategy.lastToolInvocation, isNull);
      expect(fixture.executable.executions, 0);
      expect(
        fixture.run.journal.records
            .map((ExecutionEventRecord record) => record.event)
            .whereType<ToolInvocationPrepared>(),
        isEmpty,
      );
    },
  );

  test(
    'contributor retirement during inference becomes proposal failure',
    () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      final _Executable executable = _Executable();
      final ExtensionRegistration generationA = extensions.register(
        point: modelToolContributions,
        id: ExtensionId('dev.adele.test.in-flight-tools'),
        value: _RetiringContribution(executable),
      );
      final SessionId sessionId = SessionId('session-in-flight-retirement');
      final DevelopmentSessionHistory session = DevelopmentSessionHistory(
        sessionId,
      )..append(UserSessionMessage('Inspect.'));
      final AgentRun run = AgentRun(
        id: RunId('run-in-flight-retirement'),
        sessionId: sessionId,
      );
      final _RetiringProposalModel model = _RetiringProposalModel(
        generationA.close,
      );
      final ToolCatalog catalog = await ModelToolComposer(
        extensions,
      ).materialize(_NoHostServices(sessionId));
      final DevelopmentToolLoopStrategy strategy = DevelopmentToolLoopStrategy(
        run: run,
        session: session,
        contextAssembler: const DevelopmentContextAssembler(),
        model: model,
        toolCatalog: catalog,
        policy: const DevelopmentToolPolicy(ToolPolicyDecision.allow),
      );

      await strategy.start();

      expect(run.state, RunState.completed);
      expect(model.invocations, 2);
      expect(model.sawCorrelatedStaleFailure, isTrue);
      expect(strategy.lastToolInvocation, isNull);
      expect(executable.executions, 0);
      final Iterable<ExecutionEvent> events = run.journal.records.map(
        (ExecutionEventRecord record) => record.event,
      );
      expect(events.whereType<ToolInvocationPrepared>(), isEmpty);
      expect(events.whereType<ToolExecutionStarted>(), isEmpty);
    },
  );

  test('model invocation limit fails an accidental tool loop', () async {
    final _StrategyFixture fixture = _fixture(
      ToolPolicyDecision.allow,
      alwaysPropose: true,
      maxModelInvocations: 2,
    );

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.failed);
    expect(
      fixture.run.failure,
      isA<ModelInvocationLimitExceeded>().having(
        (ModelInvocationLimitExceeded error) => error.maximum,
        'maximum',
        2,
      ),
    );
    expect(fixture.model.invocations, 2);
    expect(fixture.executable.executions, 1);
  });

  test('development context assembler carries host instructions', () {
    final DevelopmentSessionHistory session = DevelopmentSessionHistory(
      SessionId('instructions-session'),
    )..append(UserSessionMessage('Inspect source.'));

    final SemanticModelRequest request =
        const DevelopmentContextAssembler(
          instructions: 'Use source tools before answering.',
        ).assemble(
          ContextAssemblyInput(
            invocationId: ModelInvocationId('instructions-model'),
            session: session.snapshot(),
            runItems: const <SemanticModelInputItem>[],
            tools: MaterializedToolSet(const <MaterializedTool>[]),
          ),
        );

    expect(request.instructions, 'Use source tools before answering.');
  });

  test('three proposals drain sequentially from one tool generation', () async {
    final _BatchFixture fixture = _BatchFixture();
    fixture.executable.beforeTerminal = (int step) async {
      // A catalog change must only affect the next model turn.
      if (step == 1) fixture.removeTools();
    };

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.completed);
    expect(fixture.model.requests, hasLength(2));
    expect(fixture.model.completedAtInvocation, <List<int>>[
      <int>[],
      <int>[1, 2, 3],
    ]);
    expect(fixture.executable.timeline, <String>[
      'start-1',
      'complete-1',
      'start-2',
      'complete-2',
      'start-3',
      'complete-3',
    ]);
    final List<ToolInvocation> invocations = fixture.events
        .whereType<ToolInvocationPrepared>()
        .map((ToolInvocationPrepared event) => event.invocation)
        .toList();
    expect(
      invocations.map((ToolInvocation invocation) => invocation.id.value),
      <String>['batch-run-tool-1', 'batch-run-tool-2', 'batch-run-tool-3'],
    );
    for (final ToolInvocation invocation in invocations) {
      expect(
        invocation.tool,
        same(
          fixture.model.requests.first.tools.byAlias(invocation.proposal.alias),
        ),
      );
    }
    expect(fixture.model.requests.last.tools.tools, isEmpty);
    expect(fixture.strategy.lastToolInvocation, same(invocations.last));
    expect(
      fixture.strategy.lastToolOutcome,
      same(fixture.outcomes.last.outcome),
    );
    expect(
      fixture.outcomes.map(
        (SemanticToolOutcomeInput item) => item.providerCallId,
      ),
      <String>['call-1', 'call-2', 'call-3'],
    );
    expect(
      fixture.outcomes.map(
        (SemanticToolOutcomeInput item) => item.outcome.modelContent,
      ),
      <String>['Handled 1.', 'Handled 2.', 'Handled 3.'],
    );

    final List<SemanticModelInputItem> replay =
        fixture.model.requests.last.input;
    expect(replay, hasLength(10)); // User, six output items, three outcomes.
    for (int index = 0; index < fixture.model.output.length; index++) {
      final SemanticModelInputItem input = replay[index + 1];
      switch (fixture.model.output[index]) {
        case ModelNativeOutput(
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          expect(
            input,
            isA<SemanticNativeInput>()
                .having(
                  (SemanticNativeInput item) => item.providerItemId,
                  'item ID',
                  providerItemId,
                )
                .having(
                  (SemanticNativeInput item) => item.providerNativeMetadata,
                  'native metadata',
                  same(providerNativeMetadata),
                ),
          );
        case ModelTextOutput(
          :final content,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          expect(
            input,
            isA<SemanticMessageInput>()
                .having(
                  (SemanticMessageInput item) => item.content,
                  'content',
                  content,
                )
                .having(
                  (SemanticMessageInput item) => item.providerItemId,
                  'item ID',
                  providerItemId,
                )
                .having(
                  (SemanticMessageInput item) => item.providerNativeMetadata,
                  'native metadata',
                  same(providerNativeMetadata),
                ),
          );
        case ModelToolProposalOutput(
          :final proposal,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          expect(
            input,
            isA<SemanticToolProposalInput>()
                .having(
                  (SemanticToolProposalInput item) => item.proposal,
                  'proposal',
                  same(proposal),
                )
                .having(
                  (SemanticToolProposalInput item) => item.providerItemId,
                  'item ID',
                  providerItemId,
                )
                .having(
                  (SemanticToolProposalInput item) =>
                      item.providerNativeMetadata,
                  'native metadata',
                  same(providerNativeMetadata),
                ),
          );
      }
    }
    final List<ExecutionEvent> events = fixture.events.toList();
    expect(events.whereType<ModelInvocationStarted>(), hasLength(2));
    expect(
      events
          .whereType<ModelOutputObserved>()
          .take(6)
          .map((ModelOutputObserved event) => event.invocationId),
      everyElement(fixture.model.requests.first.invocationId),
    );
    final int firstPrepared = events.indexWhere(
      (ExecutionEvent event) => event is ToolInvocationPrepared,
    );
    expect(
      events.take(firstPrepared).whereType<ModelOutputObserved>(),
      hasLength(6),
    );
    expect(
      events
          .skip(firstPrepared)
          .map((ExecutionEvent event) => event.runtimeType),
      <Type>[
        ToolInvocationPrepared,
        ToolPolicyEvaluated,
        ToolExecutionStarted,
        ToolExecutionCompleted,
        ToolInvocationPrepared,
        ToolPolicyEvaluated,
        ToolExecutionStarted,
        ToolExecutionCompleted,
        ToolInvocationPrepared,
        ToolPolicyEvaluated,
        ToolExecutionStarted,
        ToolExecutionCompleted,
        ModelInvocationStarted,
        ModelOutputObserved,
        ModelInvocationSettled,
        RunCompleted,
      ],
    );
    expect(fixture.session.snapshot().entries.last.content, 'Complete.');
  });

  test(
    'a later proposal cannot start until prior execution completes',
    () async {
      final _BatchFixture fixture = _BatchFixture();
      final Completer<void> started = Completer<void>();
      final Completer<void> release = Completer<void>();
      fixture.executable.beforeTerminal = (int step) async {
        if (step == 1) {
          started.complete();
          await release.future;
        } else {
          expect(
            fixture.executable.completed,
            List<int>.generate(step - 1, (int index) => index + 1),
          );
        }
      };

      final Future<void> running = fixture.strategy.start();
      await started.future;
      expect(fixture.executable.timeline, <String>['start-1']);
      expect(fixture.events.whereType<ToolInvocationPrepared>(), hasLength(1));
      expect(fixture.model.requests, hasLength(1));
      release.complete();
      await running;

      expect(fixture.executable.completed, <int>[1, 2, 3]);
      expect(fixture.model.requests, hasLength(2));
    },
  );

  for (final bool unknownAlias in <bool>[true, false]) {
    test(
      'batch continues after ${unknownAlias ? 'unknown alias' : 'invalid arguments'}',
      () async {
        final _BatchFixture fixture = _BatchFixture(
          invalidSecondProposal: true,
          unknownAlias: unknownAlias,
        );

        await fixture.strategy.start();

        expect(fixture.run.state, RunState.completed);
        expect(fixture.executable.completed, <int>[1, 3]);
        expect(fixture.model.requests, hasLength(2));
        final List<SemanticModelInputItem> results = fixture
            .model
            .requests
            .last
            .input
            .skip(7)
            .toList();
        expect(
          results.map((SemanticModelInputItem item) => item.runtimeType),
          <Type>[
            SemanticToolOutcomeInput,
            SemanticToolProposalFailureInput,
            SemanticToolOutcomeInput,
          ],
        );
        final ToolProposalFailure failure =
            (results[1] as SemanticToolProposalFailureInput).failure;
        expect(failure.providerCallId, 'call-2');
        expect(
          failure.kind,
          unknownAlias
              ? ToolProposalFailureKind.unknownAlias
              : ToolProposalFailureKind.invalidArguments,
        );
        expect(
          fixture.outcomes.map(
            (SemanticToolOutcomeInput item) => item.providerCallId,
          ),
          <String>['call-1', 'call-3'],
        );
        expect(
          fixture.events.whereType<ToolInvocationPrepared>().map(
            (ToolInvocationPrepared event) => event.invocation.id.value,
          ),
          <String>['batch-run-tool-1', 'batch-run-tool-3'],
        );
      },
    );
  }

  test('normal tool failure does not abort later proposals', () async {
    final _BatchFixture fixture = _BatchFixture(failedStep: 1);

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.completed);
    expect(fixture.executable.completed, <int>[1, 2, 3]);
    expect(fixture.model.completedAtInvocation.last, <int>[1, 2, 3]);
    expect(
      fixture.outcomes.map(
        (SemanticToolOutcomeInput item) => item.outcome.disposition,
      ),
      <ToolOutcomeDisposition>[
        ToolOutcomeDisposition.failure,
        ToolOutcomeDisposition.success,
        ToolOutcomeDisposition.success,
      ],
    );
    expect(fixture.outcomes.first.outcome.failureKind, ToolFailureKind.domain);
    expect(fixture.events.whereType<ModelInvocationFailed>(), isEmpty);
  });

  test(
    'policy denial records a result and continues the ordered batch',
    () async {
      final _BatchFixture fixture = _BatchFixture(
        decisions: <int, ToolPolicyDecision>{2: ToolPolicyDecision.deny},
      );

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.completed);
      expect(fixture.executable.completed, <int>[1, 3]);
      expect(fixture.model.requests, hasLength(2));
      expect(fixture.outcomes[1].providerCallId, 'call-2');
      expect(
        fixture.outcomes[1].outcome.disposition,
        ToolOutcomeDisposition.policyDenied,
      );
      expect(fixture.events.whereType<ToolInvocationCompleted>(), hasLength(1));
      expect(fixture.events.whereType<RunInterrupted>(), isEmpty);
    },
  );

  for (final bool approved in <bool>[true, false]) {
    test(
      '${approved ? 'approval' : 'rejection'} resumes remaining proposals before continuation',
      () async {
        final _BatchFixture fixture = _BatchFixture(
          decisions: <int, ToolPolicyDecision>{2: ToolPolicyDecision.ask},
        );

        await fixture.strategy.start();

        expect(fixture.run.state, RunState.waiting);
        expect(fixture.executable.completed, <int>[1]);
        expect(
          fixture.events.whereType<ToolInvocationPrepared>(),
          hasLength(2),
        );
        expect(fixture.events.whereType<ToolPolicyEvaluated>(), hasLength(2));
        expect(fixture.model.requests, hasLength(1));
        fixture.removeTools();
        await fixture.resolveApproval(approved);

        expect(fixture.run.state, RunState.completed);
        expect(
          fixture.executable.completed,
          approved ? <int>[1, 2, 3] : <int>[1, 3],
        );
        expect(fixture.model.requests, hasLength(2));
        expect(
          fixture.model.completedAtInvocation.last,
          fixture.executable.completed,
        );
        expect(
          fixture.outcomes.map(
            (SemanticToolOutcomeInput item) => item.providerCallId,
          ),
          <String>['call-1', 'call-2', 'call-3'],
        );
        expect(
          fixture.outcomes[1].outcome.disposition,
          approved
              ? ToolOutcomeDisposition.success
              : ToolOutcomeDisposition.userRejected,
        );
        expect(
          fixture.events
              .whereType<ToolInvocationPrepared>()
              .last
              .invocation
              .tool,
          same(fixture.model.requests.first.tools.byAlias('step_3')),
        );
        expect(
          fixture.events.whereType<RunInterruptionResolved>(),
          hasLength(1),
        );
        expect(
          fixture.strategy.lastToolInvocation?.proposal.providerCallId,
          'call-3',
        );
      },
    );
  }

  test('approval of one proposal does not approve a later proposal', () async {
    final _BatchFixture fixture = _BatchFixture(
      decisions: <int, ToolPolicyDecision>{
        2: ToolPolicyDecision.ask,
        3: ToolPolicyDecision.ask,
      },
    );

    await fixture.strategy.start();
    await fixture.resolveApproval(true);

    expect(fixture.run.state, RunState.waiting);
    expect(fixture.executable.completed, <int>[1, 2]);
    expect(fixture.model.requests, hasLength(1));
    expect(fixture.events.whereType<RunInterrupted>(), hasLength(2));
    await fixture.resolveApproval(false);

    expect(fixture.run.state, RunState.completed);
    expect(fixture.model.requests, hasLength(2));
    expect(
      fixture.outcomes.last.outcome.disposition,
      ToolOutcomeDisposition.userRejected,
    );
  });

  test(
    'approval revalidates bindings without dropping remaining proposals',
    () async {
      final _BatchFixture fixture = _BatchFixture(
        decisions: <int, ToolPolicyDecision>{2: ToolPolicyDecision.ask},
      );
      await fixture.strategy.start();
      fixture.executable.stale = true;

      await fixture.resolveApproval(true);

      expect(fixture.run.state, RunState.completed);
      expect(fixture.executable.completed, <int>[1]);
      expect(fixture.model.requests, hasLength(2));
      expect(fixture.outcomes.last.providerCallId, 'call-2');
      expect(
        fixture.outcomes.last.outcome.failureKind,
        ToolFailureKind.staleBinding,
      );
      final ToolProposalFailure failure = fixture.model.requests.last.input
          .whereType<SemanticToolProposalFailureInput>()
          .single
          .failure;
      expect(failure.providerCallId, 'call-3');
      expect(failure.kind, ToolProposalFailureKind.staleBinding);
    },
  );

  test(
    'final permitted model invocation cannot start a proposed batch',
    () async {
      final _BatchFixture fixture = _BatchFixture(maxModelInvocations: 1);

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.failed);
      expect(
        fixture.run.failure,
        isA<ModelInvocationLimitExceeded>().having(
          (ModelInvocationLimitExceeded error) => error.maximum,
          'maximum',
          1,
        ),
      );
      expect(fixture.model.requests, hasLength(1));
      expect(
        fixture.events.whereType<ModelOutputObserved>().where(
          (ModelOutputObserved event) => event.item is ModelToolProposalOutput,
        ),
        hasLength(3),
      );
      expect(fixture.events.whereType<ToolInvocationPrepared>(), isEmpty);
      expect(fixture.events.whereType<ToolPolicyEvaluated>(), isEmpty);
      expect(fixture.executable.timeline, isEmpty);
    },
  );

  for (final ModelSettlement settlement in <ModelSettlement>[
    ModelSettlement.incomplete,
    ModelSettlement.refused,
  ]) {
    test(
      '$settlement never executes an observed multi-proposal batch',
      () async {
        final _BatchFixture fixture = _BatchFixture(settlement: settlement);

        await fixture.strategy.start();

        expect(
          fixture.run.state,
          settlement == ModelSettlement.refused
              ? RunState.completed
              : RunState.failed,
        );
        expect(fixture.model.requests, hasLength(1));
        expect(fixture.events.whereType<ToolInvocationPrepared>(), isEmpty);
        expect(fixture.executable.timeline, isEmpty);
        if (settlement == ModelSettlement.incomplete) {
          expect(fixture.run.failure, isA<ModelInvocationIncomplete>());
        }
      },
    );
  }

  test(
    'model failure after multiple proposals remains a model failure',
    () async {
      final StateError failure = StateError('Provider failed.');
      final _BatchFixture fixture = _BatchFixture(modelFailure: failure);

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.failed);
      expect(fixture.run.failure, same(failure));
      expect(
        fixture.events.whereType<ModelInvocationFailed>().single.error,
        same(failure),
      );
      expect(fixture.events.whereType<ToolInvocationPrepared>(), isEmpty);
      expect(fixture.executable.timeline, isEmpty);
    },
  );

  for (final _InfrastructureFailure failure in _InfrastructureFailure.values) {
    test('$failure returns a tool failure and finishes the batch', () async {
      final _BatchFixture fixture = _BatchFixture(
        infrastructureFailure: failure,
      );

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.completed);
      expect(fixture.model.requests, hasLength(2));
      expect(fixture.model.completedAtInvocation.last, <int>[1, 3]);
      expect(
        fixture.outcomes.map(
          (SemanticToolOutcomeInput item) => item.providerCallId,
        ),
        <String>['call-1', 'call-2', 'call-3'],
      );
      expect(
        fixture.outcomes.map(
          (SemanticToolOutcomeInput item) => item.outcome.disposition,
        ),
        <ToolOutcomeDisposition>[
          ToolOutcomeDisposition.success,
          ToolOutcomeDisposition.failure,
          ToolOutcomeDisposition.success,
        ],
      );
      final ToolOutcome outcome = fixture.outcomes[1].outcome;
      expect(outcome.failureKind, ToolFailureKind.infrastructure);
      final bool executionStarted =
          failure == _InfrastructureFailure.execution ||
          failure == _InfrastructureFailure.missingTerminal;
      expect(
        outcome.effectCertainty,
        executionStarted
            ? EffectCertainty.uncertain
            : EffectCertainty.knownNotOccurred,
      );
      expect(fixture.executable.timeline, <String>[
        'start-1',
        'complete-1',
        if (executionStarted) 'start-2',
        'start-3',
        'complete-3',
      ]);
      final List<ExecutionEvent> events = fixture.events.toList();
      final int failureIndex = events.indexWhere(
        (ExecutionEvent event) => switch (event) {
          ToolInvocationCompleted(:final invocationId) ||
          ToolExecutionCompleted(
            :final invocationId,
          ) => invocationId.value == 'batch-run-tool-2',
          _ => false,
        },
      );
      expect(failureIndex, greaterThanOrEqualTo(0));
      expect(
        events[failureIndex].runtimeType,
        executionStarted ? ToolExecutionCompleted : ToolInvocationCompleted,
      );
      expect(
        events[failureIndex + 1],
        isA<ToolInvocationPrepared>().having(
          (ToolInvocationPrepared event) =>
              event.invocation.proposal.providerCallId,
          'next proposal',
          'call-3',
        ),
      );
      expect(events.whereType<ModelInvocationFailed>(), isEmpty);
      expect(events.whereType<RunFailed>(), isEmpty);
    });
  }

  test(
    'zero proposals completes with assistant output in the only slot',
    () async {
      final _BatchFixture fixture = _BatchFixture(
        proposalCount: 0,
        maxModelInvocations: 1,
      );

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.completed);
      expect(fixture.model.requests, hasLength(1));
      expect(fixture.executable.timeline, isEmpty);
      expect(fixture.session.snapshot().entries.last.content, 'Complete.');
    },
  );
}

final class _BatchFixture {
  _BatchFixture({
    Map<int, ToolPolicyDecision> decisions = const <int, ToolPolicyDecision>{},
    int? failedStep,
    bool invalidSecondProposal = false,
    bool unknownAlias = false,
    int proposalCount = 3,
    int maxModelInvocations = 8,
    ModelSettlement settlement = ModelSettlement.completed,
    Object? modelFailure,
    _InfrastructureFailure? infrastructureFailure,
  }) {
    executable = _BatchExecutable(failedStep, infrastructureFailure);
    for (int step = 1; step <= 3; step++) {
      catalog.register(
        ToolRegistration(
          definition: ToolDefinition(
            id: ToolId('batch.tool.$step'),
            description: 'Step $step.',
          ),
          modelDefinition: ModelToolDefinition(
            alias: 'step_$step',
            description: 'Step $step.',
            argumentsSchema: const <String, Object?>{},
          ),
          executable: executable,
        ),
      );
    }
    final ModelNativeEnvelope metadata = ModelNativeEnvelope(
      kind: 'fixture',
      compatibility: const <String, Object?>{},
      data: const <String, Object?>{'retained': true},
    );
    model = _BatchModel(
      executable,
      <ModelOutputItem>[
        if (proposalCount == 0) ModelTextOutput('Complete.'),
        for (int step = 1; step <= proposalCount; step++) ...<ModelOutputItem>[
          if (step == 1 || step == 3)
            ModelNativeOutput(
              providerItemId: 'native-$step',
              providerNativeMetadata: metadata,
            ),
          ModelToolProposalOutput(
            ProviderToolProposal(
              providerCallId: 'call-$step',
              alias: invalidSecondProposal && unknownAlias && step == 2
                  ? 'unknown'
                  : 'step_$step',
              arguments: <String, Object?>{
                'step': step,
                if (invalidSecondProposal && !unknownAlias && step == 2)
                  'invalid': true,
              },
            ),
            providerItemId: 'item-$step',
            providerNativeMetadata: metadata,
          ),
          if (step == 1)
            ModelTextOutput(
              'Between proposals.',
              providerItemId: 'text-1',
              providerNativeMetadata: metadata,
            ),
        ],
      ],
      settlement: settlement,
      failure: modelFailure,
    );
    strategy = DevelopmentToolLoopStrategy(
      run: run,
      session: session,
      contextAssembler: const DevelopmentContextAssembler(),
      model: model,
      toolCatalog: catalog,
      policy: _BatchPolicy(decisions, infrastructureFailure),
      maxModelInvocations: maxModelInvocations,
    );
  }

  final DevelopmentSessionHistory session = DevelopmentSessionHistory(
    SessionId('batch-session'),
  )..append(UserSessionMessage('Perform steps.'));
  final AgentRun run = AgentRun(
    id: RunId('batch-run'),
    sessionId: SessionId('batch-session'),
  );
  final ToolCatalog catalog = ToolCatalog();
  late final _BatchExecutable executable;
  late final _BatchModel model;
  late final DevelopmentToolLoopStrategy strategy;

  Iterable<ExecutionEvent> get events =>
      run.journal.records.map((ExecutionEventRecord record) => record.event);
  List<SemanticToolOutcomeInput> get outcomes =>
      model.requests.last.input.whereType<SemanticToolOutcomeInput>().toList();

  void removeTools() {
    for (int step = 1; step <= 3; step++) {
      catalog.remove(ToolId('batch.tool.$step'));
    }
  }

  Future<void> resolveApproval(bool approved) {
    final ToolApprovalInterruption interruption =
        run.interruptions.values.single as ToolApprovalInterruption;
    return strategy.resolveApproval(
      ToolApprovalResolution(
        interruptionId: interruption.id,
        toolInvocationId: interruption.toolInvocationId,
        approved: approved,
      ),
    );
  }
}

final class _BatchModel implements ModelPort {
  _BatchModel(
    this.executable,
    this.output, {
    required this.settlement,
    this.failure,
  });

  final _BatchExecutable executable;
  final List<ModelOutputItem> output;
  final ModelSettlement settlement;
  final Object? failure;
  final List<SemanticModelRequest> requests = <SemanticModelRequest>[];
  final List<List<int>> completedAtInvocation = <List<int>>[];

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    requests.add(request);
    completedAtInvocation.add(List<int>.of(executable.completed));
    for (final ModelOutputItem item
        in requests.length == 1
            ? output
            : <ModelOutputItem>[ModelTextOutput('Complete.')]) {
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: item,
      );
    }
    if (failure != null) {
      yield ModelInvocationFailedEvent(
        invocationId: request.invocationId,
        error: failure!,
      );
    } else {
      yield ModelInvocationSettledEvent(
        invocationId: request.invocationId,
        settlement: settlement,
        incompleteReason: settlement == ModelSettlement.incomplete
            ? ModelIncompleteReason.outputLimit
            : null,
      );
    }
  }
}

enum _InfrastructureFailure {
  effectDescription,
  policyEvaluation,
  execution,
  missingTerminal,
}

final class _BatchPolicy implements ToolPolicy {
  const _BatchPolicy(this.decisions, this.failure);
  final Map<int, ToolPolicyDecision> decisions;
  final _InfrastructureFailure? failure;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) {
    final Object? step = input.invocation.canonicalArguments['step'];
    if (step == 2 && failure == _InfrastructureFailure.policyEvaluation) {
      throw StateError('Policy evaluation failed.');
    }
    return decisions[step] ?? ToolPolicyDecision.allow;
  }
}

final class _BatchExecutable implements ToolExecutable {
  _BatchExecutable(this.failedStep, this.infrastructureFailure);

  final int? failedStep;
  final _InfrastructureFailure? infrastructureFailure;
  final List<int> completed = <int>[];
  final List<String> timeline = <String>[];
  Future<void> Function(int step)? beforeTerminal;
  bool stale = false;

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    if (proposedArguments['invalid'] == true) {
      throw const FormatException('Invalid step.');
    }
    return CanonicalToolArguments(proposedArguments);
  }

  @override
  void validateBinding() {
    if (stale) {
      throw const StaleToolBindingException('Fixture binding retired.');
    }
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    if (arguments.snapshot['step'] == 2 &&
        infrastructureFailure == _InfrastructureFailure.effectDescription) {
      throw StateError('Effect description failed.');
    }
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.sourceMutation],
      targets: const <EffectTarget>[],
      summary: 'Perform step.',
    );
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final int step = arguments.snapshot['step']! as int;
    timeline.add('start-$step');
    if (step == 2) {
      if (infrastructureFailure == _InfrastructureFailure.execution) {
        throw StateError('Execution failed.');
      }
      if (infrastructureFailure == _InfrastructureFailure.missingTerminal) {
        return;
      }
    }
    await beforeTerminal?.call(step);
    completed.add(step);
    timeline.add('complete-$step');
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: step == failedStep
            ? ToolOutcomeDisposition.failure
            : ToolOutcomeDisposition.success,
        failureKind: step == failedStep ? ToolFailureKind.domain : null,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Handled $step.',
      ),
    );
  }
}

_StrategyFixture _fixture(
  ToolPolicyDecision decision, {
  ContextAssembler contextAssembler = const DevelopmentContextAssembler(),
  String modelAlias = 'inspect_resource',
  bool proposalBeforeText = false,
  ModelSettlement settlement = ModelSettlement.completed,
  bool alwaysPropose = false,
  int maxModelInvocations = 8,
  List<ToolProgress> progress = const <ToolProgress>[],
}) {
  final DevelopmentSessionHistory session = DevelopmentSessionHistory(
    SessionId('session-1'),
  )..append(UserSessionMessage('Inspect.'));
  final AgentRun run = AgentRun(id: RunId('run-1'), sessionId: session.id);
  final _Model model = _Model(
    alias: modelAlias,
    proposalBeforeText: proposalBeforeText,
    settlement: settlement,
    alwaysPropose: alwaysPropose,
  );
  final _Executable executable = _Executable(progress: progress);
  final ToolCatalog catalog = ToolCatalog()
    ..register(
      ToolRegistration(
        definition: ToolDefinition(
          id: ToolId('dev.adele.tool.resource-inspection'),
          description: 'Inspect.',
        ),
        modelDefinition: ModelToolDefinition(
          alias: 'inspect_resource',
          description: 'Inspect.',
          argumentsSchema: const <String, Object?>{},
        ),
        executable: executable,
      ),
    );
  return _StrategyFixture(
    run: run,
    model: model,
    executable: executable,
    strategy: DevelopmentToolLoopStrategy(
      run: run,
      session: session,
      contextAssembler: contextAssembler,
      model: model,
      toolCatalog: catalog,
      policy: DevelopmentToolPolicy(decision),
      maxModelInvocations: maxModelInvocations,
    ),
  );
}

final class _StrategyFixture {
  const _StrategyFixture({
    required this.run,
    required this.model,
    required this.executable,
    required this.strategy,
  });

  final AgentRun run;
  final _Model model;
  final _Executable executable;
  final DevelopmentToolLoopStrategy strategy;
}

final class _Model implements ModelPort {
  _Model({
    required this.alias,
    required this.proposalBeforeText,
    required this.settlement,
    required this.alwaysPropose,
  });

  final String alias;
  final bool proposalBeforeText;
  final ModelSettlement settlement;
  final bool alwaysPropose;
  int invocations = 0;
  bool sawCorrelatedContinuation = false;
  bool sawPreservedOutputOrder = false;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    invocations++;
    final List<SemanticToolOutcomeInput> outcomes = request.input
        .whereType<SemanticToolOutcomeInput>()
        .toList(growable: false);
    final List<SemanticToolProposalFailureInput> proposalFailures = request
        .input
        .whereType<SemanticToolProposalFailureInput>()
        .toList(growable: false);
    if (alwaysPropose || (outcomes.isEmpty && proposalFailures.isEmpty)) {
      if (settlement == ModelSettlement.refused) {
        yield ModelOutputItemCompleted(
          invocationId: request.invocationId,
          item: ModelTextOutput('I cannot perform that request.'),
        );
      } else {
        yield ModelOutputItemCompleted(
          invocationId: request.invocationId,
          item: ModelToolProposalOutput(
            ProviderToolProposal(
              providerCallId: 'provider-1',
              alias: alias,
              arguments: const <String, Object?>{
                'uri': 'file:///tmp/example.dart',
              },
            ),
          ),
        );
        if (proposalBeforeText) {
          yield ModelOutputItemCompleted(
            invocationId: request.invocationId,
            item: ModelTextOutput('Text after proposal.'),
          );
        }
      }
    } else {
      if (outcomes.isNotEmpty) {
        sawCorrelatedContinuation = request.input
            .whereType<SemanticToolProposalInput>()
            .any(
              (SemanticToolProposalInput item) =>
                  item.proposal.providerCallId ==
                  outcomes.single.providerCallId,
            );
      }
      if (proposalBeforeText) {
        final int proposalIndex = request.input.indexWhere(
          (SemanticModelInputItem item) => item is SemanticToolProposalInput,
        );
        final int textIndex = request.input.indexWhere(
          (SemanticModelInputItem item) =>
              item is SemanticMessageInput &&
              item.content == 'Text after proposal.',
        );
        sawPreservedOutputOrder =
            proposalIndex >= 0 && textIndex > proposalIndex;
      }
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput('Complete.'),
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: settlement,
      incompleteReason: settlement == ModelSettlement.incomplete
          ? ModelIncompleteReason.outputLimit
          : null,
      metadata: ModelTerminalMetadata(effectiveModel: 'fixture-v1'),
    );
  }
}

final class _Executable implements ToolExecutable {
  _Executable({this.progress = const <ToolProgress>[]});

  final List<ToolProgress> progress;
  int executions = 0;

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async => EffectDescription(
    effects: const <ToolEffect>[ToolEffect.resourceInspection],
    targets: <EffectTarget>[
      EffectTarget(uri: Uri.parse(arguments.snapshot['uri']! as String)),
    ],
    summary: 'Inspect.',
  );

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    executions++;
    for (final ToolProgress item in progress) {
      yield ToolExecutionProgress(item);
    }
    yield ToolExecutionTerminal(
      ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'Inspected.',
      ),
    );
  }

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) => CanonicalToolArguments(proposedArguments);

  @override
  void validateBinding() {}
}

final class _NoHostServices implements ModelToolHostContext {
  const _NoHostServices(this.sessionId);

  @override
  final SessionId sessionId;

  @override
  Future<T> requireHostService<T extends Object>() =>
      throw StateError('No host service is required by this test.');
}

final class _RetiringContribution implements ModelToolContribution {
  const _RetiringContribution(this.executable);

  final ToolExecutable executable;

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async => <ToolRegistration>[
    ToolRegistration(
      definition: ToolDefinition(
        id: ToolId('dev.adele.test.in-flight-tool'),
        description: 'Inspect during a lifecycle race.',
      ),
      modelDefinition: ModelToolDefinition(
        alias: 'inspect_in_flight',
        description: 'Inspect during a lifecycle race.',
        argumentsSchema: const <String, Object?>{},
      ),
      executable: executable,
    ),
  ];
}

final class _RetiringProposalModel implements ModelPort {
  _RetiringProposalModel(this.retire);

  final Future<void> Function() retire;
  int invocations = 0;
  bool sawCorrelatedStaleFailure = false;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    invocations++;
    final List<SemanticToolProposalFailureInput> failures = request.input
        .whereType<SemanticToolProposalFailureInput>()
        .toList(growable: false);
    if (failures.isEmpty) {
      expect(request.tools.byAlias('inspect_in_flight'), isNotNull);
      await retire();
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'provider-in-flight',
            alias: 'inspect_in_flight',
            arguments: const <String, Object?>{
              'uri': 'file:///tmp/example.dart',
            },
          ),
        ),
      );
    } else {
      final ToolProposalFailure failure = failures.single.failure;
      sawCorrelatedStaleFailure =
          failure.kind == ToolProposalFailureKind.staleBinding &&
          failure.providerCallId == 'provider-in-flight' &&
          request.input.whereType<SemanticToolProposalInput>().any(
            (SemanticToolProposalInput item) =>
                item.proposal.providerCallId == failure.providerCallId,
          );
      yield ModelOutputItemCompleted(
        invocationId: request.invocationId,
        item: ModelTextOutput('Continued after stale proposal.'),
      );
    }
    yield ModelInvocationSettledEvent(
      invocationId: request.invocationId,
      settlement: ModelSettlement.completed,
      metadata: ModelTerminalMetadata(effectiveModel: 'retirement-fixture-v1'),
    );
  }
}

final class _ReplacingContextAssembler implements ContextAssembler {
  const _ReplacingContextAssembler();

  @override
  SemanticModelRequest assemble(ContextAssemblyInput input) =>
      SemanticModelRequest(
        invocationId: input.invocationId,
        input: input.runItems,
        tools: MaterializedToolSet(const <MaterializedTool>[]),
      );
}
