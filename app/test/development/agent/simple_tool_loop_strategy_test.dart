import 'package:adele_desktop/development/agent/development_agent_support.dart';
import 'package:adele_desktop/development/agent/simple_tool_loop_strategy.dart';
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
}

_StrategyFixture _fixture(
  ToolPolicyDecision decision, {
  ContextAssembler contextAssembler = const DevelopmentContextAssembler(),
  String modelAlias = 'inspect_resource',
  bool proposalBeforeText = false,
  ModelSettlement settlement = ModelSettlement.completed,
  bool alwaysPropose = false,
  int maxModelInvocations = 8,
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
  final _Executable executable = _Executable();
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
