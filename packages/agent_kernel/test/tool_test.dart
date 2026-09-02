import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('identity and materialization', () {
    test('semantic ToolId is independent from model alias', () {
      final TestExecutable executable = TestExecutable();
      final MaterializedTool tool =
          (ToolCatalog()..register(
                testRegistration(
                  executable,
                  id: 'dev.adele.tool.resource-inspection',
                  alias: 'inspect_resource',
                ),
              ))
              .materialize()
              .tools
              .single;

      expect(tool.definition.id.value, 'dev.adele.tool.resource-inspection');
      expect(tool.modelDefinition.alias, 'inspect_resource');
      expect(tool.definition.id.value, isNot(tool.modelDefinition.alias));
    });

    test('aliases are unique within one immutable materialization', () {
      final ToolCatalog catalog = ToolCatalog()
        ..register(
          testRegistration(
            TestExecutable(provider: 'a'),
            id: 'dev.adele.tool.a',
            alias: 'same_alias',
          ),
        )
        ..register(
          testRegistration(
            TestExecutable(provider: 'b'),
            id: 'dev.adele.tool.b',
            alias: 'same_alias',
          ),
        );

      expect(catalog.materialize, throwsA(isA<ToolMaterializationException>()));
    });

    test('catalog replacement does not mutate an old materialized set', () {
      final TestExecutable generationA = TestExecutable(
        provider: 'generation-a',
      );
      final TestExecutable generationB = TestExecutable(
        provider: 'generation-b',
      );
      final ToolCatalog catalog = ToolCatalog()
        ..register(testRegistration(generationA));
      final MaterializedToolSet oldSet = catalog.materialize();

      catalog.register(testRegistration(generationB));
      final MaterializedToolSet newSet = catalog.materialize();

      expect(oldSet.tools.single.executable, same(generationA));
      expect(newSet.tools.single.executable, same(generationB));
      expect(
        () => oldSet.tools.add(newSet.tools.single),
        throwsUnsupportedError,
      );
      expect(
        () => oldSet.tools.single.modelDefinition.argumentsSchema['new'] = true,
        throwsUnsupportedError,
      );
    });
  });

  group('proposal resolution', () {
    test('known alias and valid arguments create a ToolInvocation', () {
      final TestExecutable executable = TestExecutable();
      final ToolInvocation invocation = testInvocation(executable);

      expect(invocation.toolId, ToolId('dev.adele.tool.resource-inspection'));
      expect(invocation.proposal.providerCallId, 'provider-1');
      expect(invocation.arguments.snapshot, const <String, Object?>{
        'uri': 'file:///tmp/example.dart',
      });
      expect(invocation.tool.executable, same(executable));
      expect(invocation.context.runId, RunId('run-1'));
      expect(invocation.context.sessionId, SessionId('session-1'));
      expect(
        () => invocation.arguments.snapshot['uri'] = 'file:///tmp/changed.dart',
        throwsUnsupportedError,
      );
    });

    test('unknown alias does not create a fake ToolInvocation', () {
      final ToolProposalResolution resolution = const ToolInvocationResolver()
          .resolve(
            invocationId: ToolInvocationId('tool-1'),
            proposal: ProviderToolProposal(
              providerCallId: 'provider-1',
              alias: 'unknown_tool',
              arguments: const <String, Object?>{},
            ),
            tools: (ToolCatalog()..register(testRegistration(TestExecutable())))
                .materialize(),
            context: testExecutionContext(),
          );

      expect(resolution, isA<RejectedToolProposal>());
      expect(
        (resolution as RejectedToolProposal).failure.kind,
        ToolProposalFailureKind.unknownAlias,
      );
    });

    test('invalid arguments do not create or execute an invocation', () {
      final TestExecutable executable = TestExecutable();
      final ToolProposalResolution resolution = const ToolInvocationResolver()
          .resolve(
            invocationId: ToolInvocationId('tool-1'),
            proposal: ProviderToolProposal(
              providerCallId: 'provider-1',
              alias: 'inspect_resource',
              arguments: const <String, Object?>{'uri': 42},
            ),
            tools: (ToolCatalog()..register(testRegistration(executable)))
                .materialize(),
            context: testExecutionContext(),
          );

      expect(resolution, isA<RejectedToolProposal>());
      expect(
        (resolution as RejectedToolProposal).failure.kind,
        ToolProposalFailureKind.invalidArguments,
      );
      expect(executable.descriptions, 0);
      expect(executable.executions, 0);
    });

    test('plain FormatException is a typed invalid-arguments failure', () {
      final TestExecutable executable = TestExecutable(
        plainFormatFailure: true,
      );
      final ToolProposalResolution resolution = const ToolInvocationResolver()
          .resolve(
            invocationId: ToolInvocationId('tool-1'),
            proposal: ProviderToolProposal(
              providerCallId: 'provider-1',
              alias: 'inspect_resource',
              arguments: const <String, Object?>{
                'uri': 'file:///tmp/example.dart',
              },
            ),
            tools: (ToolCatalog()..register(testRegistration(executable)))
                .materialize(),
            context: testExecutionContext(),
          );

      expect(
        (resolution as RejectedToolProposal).failure.kind,
        ToolProposalFailureKind.invalidArguments,
      );
    });

    test('tool proposal failure rejects empty model-facing messages', () {
      for (final String message in <String>['', '  ']) {
        expect(
          () => ToolProposalFailure(
            kind: ToolProposalFailureKind.invalidArguments,
            providerCallId: 'provider-1',
            alias: 'inspect_resource',
            message: message,
          ),
          throwsFormatException,
        );
      }
    });

    for (final ({FormatException error, String expected}) fixture
        in <({FormatException error, String expected})>[
          (
            error: const ToolArgumentValidationException(''),
            expected: 'The proposed tool arguments are invalid.',
          ),
          (
            error: const FormatException('Specific validation.'),
            expected: 'Specific validation.',
          ),
        ]) {
      test('normalizes validator message ${fixture.expected}', () {
        final ToolProposalResolution resolution = const ToolInvocationResolver()
            .resolve(
              invocationId: ToolInvocationId('tool-1'),
              proposal: ProviderToolProposal(
                providerCallId: 'provider-1',
                alias: 'inspect_resource',
                arguments: const <String, Object?>{},
              ),
              tools:
                  (ToolCatalog()
                        ..register(_throwingRegistration(fixture.error)))
                      .materialize(),
              context: testExecutionContext(),
            );
        final ToolProposalFailure failure =
            (resolution as RejectedToolProposal).failure;
        expect(failure.message, fixture.expected);
        expect(failure.cause, same(fixture.error));
      });
    }

    test('binding lifecycle failures reject without ToolInvocation', () {
      for (final ({ToolBindingException error, ToolProposalFailureKind kind})
          fixture
          in <({ToolBindingException error, ToolProposalFailureKind kind})>[
            (
              error: const StaleToolBindingException('stale generation'),
              kind: ToolProposalFailureKind.staleBinding,
            ),
            (
              error: const ToolBindingUnavailableException(
                'endpoint unavailable',
              ),
              kind: ToolProposalFailureKind.bindingUnavailable,
            ),
          ]) {
        final ToolProposalResolution resolution = const ToolInvocationResolver()
            .resolve(
              invocationId: ToolInvocationId('tool-lifecycle'),
              proposal: ProviderToolProposal(
                providerCallId: 'provider-lifecycle',
                alias: 'inspect_resource',
                arguments: const <String, Object?>{
                  'uri': 'file:///tmp/example.dart',
                },
              ),
              tools:
                  (ToolCatalog()
                        ..register(_throwingRegistration(fixture.error)))
                      .materialize(),
              context: testExecutionContext(),
            );

        expect(resolution, isA<RejectedToolProposal>());
        final ToolProposalFailure failure =
            (resolution as RejectedToolProposal).failure;
        expect(failure.kind, fixture.kind);
        expect(failure.providerCallId, 'provider-lifecycle');
        expect(failure.alias, 'inspect_resource');
        expect(failure.cause, same(fixture.error));
      }
    });
  });

  group('policy and approval', () {
    test('allow authorizes execution without interruption', () async {
      final TestExecutable executable = TestExecutable();
      final ToolPolicyGateResult result = await const ToolPolicyGate().evaluate(
        invocation: testInvocation(executable),
        policy: const DecisionPolicy(ToolPolicyDecision.allow),
        interruptionId: RunInterruptionId('unused-approval'),
      );

      expect(result, isA<ToolExecutionAllowed>());
      final ToolExecutionAllowed allowed = result as ToolExecutionAllowed;
      final AgentRun run = AgentRun(
        id: RunId('run-1'),
        sessionId: SessionId('session-1'),
      )..start();
      final ToolExecutionStart start = run.startToolExecution(allowed);
      final ToolExecutionObservation observation = await collectToolExecution(
        start.events(),
      );
      expect(observation.outcome.disposition, ToolOutcomeDisposition.success);
      expect(executable.executions, 1);
      expect(
        () => run.startToolExecution(allowed),
        throwsA(isA<ToolExecutionAlreadyStarted>()),
      );
    });

    test('deny is terminal without execution or interruption', () async {
      final TestExecutable executable = TestExecutable();
      final ToolPolicyGateResult result = await const ToolPolicyGate().evaluate(
        invocation: testInvocation(executable),
        policy: const DecisionPolicy(ToolPolicyDecision.deny),
        interruptionId: RunInterruptionId('unused-approval'),
      );

      expect(result, isA<ToolExecutionDenied>());
      expect(
        (result as ToolExecutionDenied).outcome.disposition,
        ToolOutcomeDisposition.policyDenied,
      );
      expect(executable.executions, 0);
    });

    test('ask interrupts and rejection executes nothing', () async {
      final TestExecutable executable = TestExecutable();
      final ToolPolicyGateResult result = await const ToolPolicyGate().evaluate(
        invocation: testInvocation(executable),
        policy: const DecisionPolicy(ToolPolicyDecision.ask),
        interruptionId: RunInterruptionId('approval-1'),
      );
      final ToolApprovalRequired required = result as ToolApprovalRequired;
      final AgentRun run = AgentRun(
        id: RunId('run-1'),
        sessionId: SessionId('session-1'),
      )..start();

      run.interrupt(required.interruption);
      expect(run.state, RunState.waiting);
      expect(executable.executions, 0);
      final ResolvedRunInterruption rejected = run.resolveInterruption(
        ToolApprovalResolution(
          interruptionId: required.interruption.id,
          toolInvocationId: required.invocation.id,
          approved: false,
        ),
      );
      expect(run.state, RunState.running);
      expect(executable.executions, 0);
      expect(
        () => const ToolPolicyGate().approve(rejected),
        throwsA(isA<InvalidRunOperation>()),
      );
    });

    test('approval remains bound to the stale exact executable', () async {
      final TestExecutable generationA = TestExecutable(
        provider: 'generation-a',
      );
      final ToolApprovalRequired required =
          await const ToolPolicyGate().evaluate(
                invocation: testInvocation(generationA),
                policy: const DecisionPolicy(ToolPolicyDecision.ask),
                interruptionId: RunInterruptionId('approval-1'),
              )
              as ToolApprovalRequired;
      final AgentRun run = AgentRun(
        id: RunId('run-1'),
        sessionId: SessionId('session-1'),
      )..start();
      run.interrupt(required.interruption);
      final ResolvedRunInterruption resolved = run.resolveInterruption(
        ToolApprovalResolution(
          interruptionId: required.interruption.id,
          toolInvocationId: required.invocation.id,
          approved: true,
        ),
      );
      generationA.active = false;
      final TestExecutable generationB = TestExecutable(
        provider: 'generation-b',
      );
      final ToolCatalog catalog = ToolCatalog()
        ..register(testRegistration(generationB));

      final ToolExecutionAllowed approved = const ToolPolicyGate().approve(
        resolved,
      );

      expect(
        () => run.startToolExecution(approved),
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(approved.invocation.tool.executable, same(generationA));
      expect(catalog.materialize().tools.single.executable, same(generationB));
      expect(generationA.executions, 0);
      expect(generationB.executions, 0);
    });

    test('effect-description and policy failures remain distinct', () async {
      await expectLater(
        const ToolPolicyGate().evaluate(
          invocation: testInvocation(TestExecutable(descriptionFailure: true)),
          policy: const DecisionPolicy(ToolPolicyDecision.allow),
          interruptionId: RunInterruptionId('approval-1'),
        ),
        throwsA(isA<ToolEffectDescriptionFailed>()),
      );
      await expectLater(
        const ToolPolicyGate().evaluate(
          invocation: testInvocation(TestExecutable()),
          policy: const ThrowingPolicy(),
          interruptionId: RunInterruptionId('approval-1'),
        ),
        throwsA(isA<ToolPolicyEvaluationFailed>()),
      );
    });
  });

  group('execution outcomes', () {
    test('one started execution has exactly one terminal outcome', () async {
      final ToolOutcome outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.success,
        effectCertainty: EffectCertainty.knownOccurred,
        modelContent: 'complete',
      );
      final ToolExecutionObservation observation = await collectToolExecution(
        Stream<ToolExecutionEvent>.fromIterable(<ToolExecutionEvent>[
          ToolExecutionProgress(ToolProgress(message: 'working')),
          ToolExecutionTerminal(outcome),
        ]),
      );
      expect(observation.progress, hasLength(1));
      expect(observation.outcome, same(outcome));

      await expectLater(
        collectToolExecution(const Stream<ToolExecutionEvent>.empty()),
        throwsA(isA<ToolExecutionContractException>()),
      );
      await expectLater(
        collectToolExecution(
          Stream<ToolExecutionEvent>.fromIterable(<ToolExecutionEvent>[
            ToolExecutionTerminal(outcome),
            ToolExecutionTerminal(outcome),
          ]),
        ),
        throwsA(isA<ToolExecutionContractException>()),
      );
    });

    test('model content, host data, and effect certainty are independent', () {
      final ToolOutcome outcome = ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.infrastructure,
        effectCertainty: EffectCertainty.uncertain,
        modelContent: 'Inspection transport failed.',
        hostData: const <String, Object?>{
          'resource': 'file:///tmp/example.dart',
          'providerLabel': 'Basic Inspector',
          'summary': 'partial host summary',
        },
        hostDiagnostic: 'Connection ended after dispatch.',
      );

      expect(outcome.modelContent, isNot(contains('providerLabel')));
      expect(outcome.hostData['providerLabel'], 'Basic Inspector');
      expect(outcome.effectCertainty, EffectCertainty.uncertain);
      expect(
        () => outcome.hostData['providerLabel'] = 'replacement',
        throwsUnsupportedError,
      );
    });
  });

  group('model-tool contributions', () {
    test(
      'multiple contributors compose for supplied Session context',
      () async {
        final ExtensionRegistry extensions = ExtensionRegistry();
        extensions.register(
          point: modelToolContributions,
          id: ExtensionId('dev.adele.test.tools.one'),
          value: const _Contribution('one', 'tool_one'),
        );
        extensions.register(
          point: modelToolContributions,
          id: ExtensionId('dev.adele.test.tools.two'),
          value: const _Contribution('two', 'tool_two'),
        );

        final MaterializedToolSet tools =
            (await ModelToolComposer(extensions).materialize(
              _HostContext(SessionId('session-context')),
            )).materialize();

        expect(tools.tools.map((tool) => tool.modelDefinition.alias), <String>[
          'tool_one',
          'tool_two',
        ]);
        expect(
          tools.tools.map((tool) => tool.definition.description),
          everyElement(contains('session-context')),
        );
      },
    );

    test('alias collisions fail deterministically', () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      extensions.register(
        point: modelToolContributions,
        id: ExtensionId('dev.adele.test.tools.alias-one'),
        value: const _Contribution('one', 'collision'),
      );
      extensions.register(
        point: modelToolContributions,
        id: ExtensionId('dev.adele.test.tools.alias-two'),
        value: const _Contribution('two', 'collision'),
      );

      await expectLater(
        ModelToolComposer(
          extensions,
        ).materialize(_HostContext(SessionId('session-context'))),
        throwsA(isA<ToolMaterializationException>()),
      );
    });

    test('retired contributor stales old tools and never retargets', () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ExtensionId id = ExtensionId('dev.adele.test.tools.replaceable');
      final ExtensionRegistration generationA = extensions.register(
        point: modelToolContributions,
        id: id,
        value: const _Contribution('generation-a', 'replaceable'),
      );
      final ToolExecutable oldTool =
          (await ModelToolComposer(extensions).materialize(
            _HostContext(SessionId('session-context')),
          )).materialize().tools.single.executable;
      final Stream<ToolExecutionEvent> deferredExecution = oldTool.execute(
        CanonicalToolArguments(const <String, Object?>{
          'uri': 'file:///source.dart',
        }),
        ToolExecutionContext(
          runId: RunId('run-context'),
          sessionId: SessionId('session-context'),
        ),
      );

      await generationA.close();
      extensions.register(
        point: modelToolContributions,
        id: id,
        value: const _Contribution('generation-b', 'replaceable'),
      );
      final MaterializedTool freshTool =
          (await ModelToolComposer(extensions).materialize(
            _HostContext(SessionId('session-context')),
          )).materialize().tools.single;

      expect(
        oldTool.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      await expectLater(
        deferredExecution.toList(),
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(freshTool.definition.id.value, contains('generation-b'));
      expect(
        oldTool.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
    });
  });
}

final class _HostContext implements ModelToolHostContext {
  const _HostContext(this.sessionId);

  @override
  final SessionId sessionId;

  @override
  Future<T> requireHostService<T extends Object>() =>
      throw StateError('No host service needed.');
}

final class _Contribution implements ModelToolContribution {
  const _Contribution(this.generation, this.alias);

  final String generation;
  final String alias;

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async => <ToolRegistration>[
    testRegistration(
      TestExecutable(provider: generation),
      id: 'dev.adele.test.tool.$generation',
      alias: alias,
      description: 'Tool for ${context.sessionId}.',
    ),
  ];
}

final class _ThrowingValidator implements ToolExecutable {
  _ThrowingValidator(this.error);

  final Object error;

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    if (error case final FormatException formatError) throw formatError;
    throw StateError('Binding validation should reject before normalization.');
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) => throw StateError('Unused.');

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) => throw StateError('Unused.');

  @override
  void validateBinding() {
    if (error case final ToolBindingException bindingError) throw bindingError;
  }
}

ToolRegistration _throwingRegistration(Object error) => ToolRegistration(
  definition: ToolDefinition(
    id: ToolId('dev.adele.tool.resource-inspection'),
    description: 'Inspect one resource.',
  ),
  modelDefinition: ModelToolDefinition(
    alias: 'inspect_resource',
    description: 'Inspect one resource.',
    argumentsSchema: const <String, Object?>{'type': 'object'},
  ),
  executable: _ThrowingValidator(error),
);
