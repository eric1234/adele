import 'dart:async';
import 'dart:convert';

import 'package:adele_desktop/core/inference_context_host.dart';
import 'package:adele_desktop/core/orchestration_host.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/orchestration_test_lifecycle.dart';

void main() {
  test(
    'allow executes without interruption and preserves proposal context',
    () async {
      final _StrategyFixture fixture = await _fixture(ToolPolicyDecision.allow);

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
      final _StrategyFixture fixture = await _fixture(
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
    final _StrategyFixture fixture = await _fixture(
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
    final _StrategyFixture fixture = await _fixture(
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
    final _StrategyFixture fixture = await _fixture(
      ToolPolicyDecision.allow,
      proposalBeforeText: true,
    );

    await fixture.strategy.start();

    expect(fixture.run.state, RunState.completed);
    expect(fixture.model.sawPreservedOutputOrder, isTrue);
  });

  test('deny continues without interruption or execution', () async {
    final _StrategyFixture fixture = await _fixture(ToolPolicyDecision.deny);

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
    'opaque snapshots reject cross-run, forged, wrong-turn and duplicate proposals',
    () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ChatStrategyPlugin chat = ChatStrategyPlugin();
      addTearDown(chat.activate(extensions).close);
      final OrchestrationTestLifecycle topology =
          await OrchestrationTestLifecycle.create(
            extensions,
            SessionId('snapshot-session'),
          );
      final Session session = topology.createSession(chatStrategyId);
      final _Executable executable = _Executable();
      final ToolCatalog catalog = _catalog(executable);
      final _Model model = _Model();
      KernelOrchestrationHost host(AgentRun run) => KernelOrchestrationHost(
        run: run,
        strategy: topology.lifecycle.resolveSessionStrategy(session.id),
        contextComposer: InferenceContextComposer(extensions),
        sourceContextFactory: () => SessionInferenceContextSourceContext(
          session: session,
          runId: run.id,
          environmentRuntime: topology.lifecycle.environmentRuntime,
        ),
        model: model,
        toolCatalog: catalog,
        policy: const _Policy(ToolPolicyDecision.allow),
      );
      final AgentRun firstRun = AgentRun(
        id: RunId('snapshot-a'),
        sessionId: session.id,
      );
      final AgentRun secondRun = AgentRun(
        id: RunId('snapshot-b'),
        sessionId: session.id,
      );
      final KernelOrchestrationHost first = host(firstRun)..start();
      final KernelOrchestrationHost second = host(secondRun)..start();
      final StrategyInferenceMaterial material = StrategyInferenceMaterial(
        instructions: ' \tHost owns tools and invocation IDs.\r\n\n',
        input: <SemanticModelInputItem>[
          SemanticMessageInput(
            role: SemanticMessageRole.user,
            content: 'Inspect.',
          ),
          SemanticNativeInput(
            providerNativeMetadata: ModelNativeEnvelope(
              kind: 'untrusted-inference-material',
              compatibility: const <String, Object?>{},
              data: const <String, Object?>{
                'invocationId': 'replacement-model',
                'tools': <Object?>[],
              },
            ),
          ),
        ],
      );
      final StrategyModelTurn turn = await first.invokeModel(material);
      final MaterializedToolSet originalTools = model.requests.single.tools;
      final ProviderToolProposal proposal = turn.output
          .whereType<ModelToolProposalOutput>()
          .single
          .proposal;
      final StrategyModelTurn later = await first.invokeModel(material);
      final ProviderToolProposal laterProposal = later.output
          .whereType<ModelToolProposalOutput>()
          .single
          .proposal;
      final ProviderToolProposal forged = ProviderToolProposal(
        providerCallId: proposal.providerCallId,
        alias: proposal.alias,
        arguments: proposal.arguments,
      );

      expect(
        model.requests.map(
          (SemanticModelRequest request) => request.invocationId.value,
        ),
        <String>['snapshot-a-model-1', 'snapshot-a-model-2'],
      );
      expect(model.requests.first.instructions, material.instructions);
      expect(model.requests.first.input, orderedEquals(material.input));
      for (final SemanticModelRequest request in model.requests) {
        expect(
          utf8.encode(request.instructions),
          orderedEquals(utf8.encode(material.instructions)),
        );
        expect(request.context.instructionGroups, hasLength(1));
        expect(
          request.context.instructionGroups.single,
          isA<StrategyInstructionGroup>().having(
            (StrategyInstructionGroup group) => group.instructions,
            'verbatim strategy instructions',
            material.instructions,
          ),
        );
        expect(request.context.sourceResults, isEmpty);
        expect(request.input, same(request.context.input));
        expect(request.input, hasLength(material.input.length));
        for (int index = 0; index < material.input.length; index++) {
          expect(request.input[index], same(material.input[index]));
        }
      }
      expect(model.requests.first.tools, same(originalTools));
      expect(originalTools.tools, hasLength(1));
      expect(
        originalTools.byAlias('inspect_resource')!.executable,
        same(executable),
      );
      expect(turn.settlement, ModelSettlement.completed);
      expect(turn.metadata!.effectiveModel, 'fixture-v1');
      expect(turn.failure, isNull);
      expect(model.requests.last.tools, isNot(same(originalTools)));
      expect(turn.tools, isNot(isA<MaterializedToolSet>()));
      expect(turn.tools, isNot(same(later.tools)));
      for (final ({
            KernelOrchestrationHost host,
            StrategyToolSnapshot tools,
            ProviderToolProposal proposal,
          })
          attempt
          in [
            (host: second, tools: turn.tools, proposal: proposal),
            (host: first, tools: _ForgedToolSnapshot(), proposal: proposal),
            (host: first, tools: turn.tools, proposal: forged),
            (host: first, tools: later.tools, proposal: proposal),
            (host: first, tools: turn.tools, proposal: laterProposal),
          ]) {
        await expectLater(
          attempt.host.processProposal(
            tools: attempt.tools,
            proposal: attempt.proposal,
          ),
          throwsA(isA<InvalidRunOperation>()),
        );
        expect(firstRun.state, RunState.running);
        expect(secondRun.state, RunState.running);
        expect(executable.executions, 0);
        expect(_events(firstRun).whereType<ToolInvocationPrepared>(), isEmpty);
        expect(_events(secondRun).whereType<ToolInvocationPrepared>(), isEmpty);
      }

      catalog.remove(ToolId('dev.adele.tool.resource-inspection'));
      final StrategyToolResult result = await first.processProposal(
        tools: turn.tools,
        proposal: proposal,
      );
      expect(result, isA<StrategyToolContinuation>());
      final ToolInvocation invocation = _events(
        firstRun,
      ).whereType<ToolInvocationPrepared>().single.invocation;
      expect(invocation.id.value, 'snapshot-a-tool-1');
      expect(invocation.proposal, same(proposal));
      expect(invocation.tool, same(originalTools.byAlias(proposal.alias)));
      expect(invocation.context.runId, first.id);
      expect(invocation.context.sessionId, session.id);
      expect(executable.executions, 1);
      final int records = firstRun.journal.records.length;
      await expectLater(
        first.processProposal(tools: turn.tools, proposal: proposal),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(firstRun.journal.records, hasLength(records));
      expect(executable.executions, 1);
      expect(_events(firstRun).whereType<ToolExecutionStarted>(), hasLength(1));
      expect(_events(secondRun).whereType<ToolExecutionStarted>(), isEmpty);
    },
  );

  test(
    'unknown proposal continues without creating a ToolInvocation',
    () async {
      final _StrategyFixture fixture = await _fixture(
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
      final ChatStrategyPlugin chat = ChatStrategyPlugin();
      addTearDown(chat.activate(extensions).close);
      final OrchestrationTestLifecycle topology =
          await OrchestrationTestLifecycle.create(extensions, sessionId);
      final Session session = topology.createSession(chatStrategyId);
      chat.sessions.obtain(session.id).append(ChatUserMessage('Inspect.'));
      final _RetiringProposalModel model = _RetiringProposalModel(
        generationA.close,
      );
      final ToolCatalog catalog = await ModelToolComposer(
        extensions,
      ).materialize(_NoHostServices(sessionId));
      final SessionOrchestrationRun strategy = createSessionOrchestrationRun(
        lifecycle: topology.lifecycle,
        contextComposer: InferenceContextComposer(extensions),
        sessionId: session.id,
        runId: RunId('run-in-flight-retirement'),
        model: model,
        toolCatalog: catalog,
        policy: const _Policy(ToolPolicyDecision.allow),
      );
      final AgentRun run = strategy.run;

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
    final _StrategyFixture fixture = await _fixture(
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

  test('Chat inference material carries host instructions', () async {
    final _StrategyFixture fixture = await _fixture(
      ToolPolicyDecision.allow,
      instructions: 'Use source tools before answering.',
    );
    await fixture.strategy.start();
    final SemanticModelRequest request = fixture.model.requests.first;
    expect(request.instructions, 'Use source tools before answering.');
    expect(fixture.model.requests.last.instructions, request.instructions);
    expect(request.input.single, isA<SemanticMessageInput>());
    expect(request.context.sourceResults, isEmpty);
    expect(
      request.context.instructionGroups.single,
      isA<StrategyInstructionGroup>(),
    );
    expect(request.input, same(request.context.input));
    expect(
      (request.input.single as SemanticMessageInput).role,
      SemanticMessageRole.user,
    );
    expect((request.input.single as SemanticMessageInput).content, 'Inspect.');
    expect(fixture.model.requests, hasLength(2));
    expect(fixture.model.sawCorrelatedContinuation, isTrue);
    expect(
      fixture.model.requests.map(
        (SemanticModelRequest request) => request.invocationId.value,
      ),
      <String>['run-1-model-1', 'run-1-model-2'],
    );
    for (final SemanticModelRequest request in fixture.model.requests) {
      expect(request.tools.tools, hasLength(1));
      expect(
        request.tools.byAlias('inspect_resource')!.executable,
        same(fixture.executable),
      );
    }
    expect(fixture.run.state, RunState.completed);
  });

  test(
    'Chat receives structured source groups without partial optional context',
    () async {
      const String instructions = ' \tKeep strategy instructions.\r\n';
      final _StrategyFixture fixture = await _fixture(
        ToolPolicyDecision.allow,
        instructions: instructions,
      );
      final ExtensionId firstId = ExtensionId('dev.adele.test.context.a');
      final ExtensionId failedId = ExtensionId('dev.adele.test.context.b');
      final ExtensionId emptyId = ExtensionId('dev.adele.test.context.c');
      final ExtensionId lastId = ExtensionId('dev.adele.test.context.d');
      final StateError failure = StateError('Optional source failed.');
      final InferenceInstructionMaterial first = InferenceInstructionMaterial(
        key: 'shared',
        text: 'First source.',
        revision: 'revision-a',
      );
      final InferenceInstructionMaterial last = InferenceInstructionMaterial(
        key: 'shared',
        text: 'Last source.',
      );
      final List<InferenceContextSourceContext> contexts =
          <InferenceContextSourceContext>[];
      final List<ExtensionId> captures = <ExtensionId>[];
      Iterable<InferenceContextMaterial> partial() sync* {
        yield InferenceInstructionMaterial(
          key: 'partial',
          text: 'Must never reach the model.',
        );
        throw failure;
      }

      // Registration order is deliberately not source identity order.
      fixture.registerSource(
        lastId,
        snapshot: (InferenceContextSourceContext context) async {
          captures.add(lastId);
          return <InferenceContextMaterial>[last];
        },
      );
      fixture.registerSource(
        failedId,
        failureMode: InferenceContextFailureMode.optional,
        snapshot: (InferenceContextSourceContext context) async {
          captures.add(failedId);
          return partial();
        },
      );
      fixture.registerSource(
        emptyId,
        snapshot: (InferenceContextSourceContext context) async {
          captures.add(emptyId);
          return const <InferenceContextMaterial>[];
        },
      );
      fixture.registerSource(
        firstId,
        snapshot: (InferenceContextSourceContext context) async {
          contexts.add(context);
          captures.add(firstId);
          expect(context.session, same(fixture.session));
          expect(context.runId, fixture.run.id);
          return <InferenceContextMaterial>[first];
        },
      );

      await fixture.strategy.start();

      expect(fixture.run.state, RunState.completed);
      expect(fixture.model.requests, hasLength(2));
      expect(captures, <ExtensionId>[
        firstId,
        failedId,
        emptyId,
        lastId,
        firstId,
        failedId,
        emptyId,
        lastId,
      ]);
      expect(contexts, hasLength(2));
      expect(contexts.last, isNot(same(contexts.first)));
      for (final SemanticModelRequest request in fixture.model.requests) {
        final InferenceContextSnapshot snapshot = request.context;
        expect(
          snapshot.instructionGroups.first,
          isA<StrategyInstructionGroup>(),
        );
        expect(
          (snapshot.instructionGroups.first as StrategyInstructionGroup)
              .instructions,
          instructions,
        );
        final List<SourceInstructionGroup> groups = snapshot.instructionGroups
            .whereType<SourceInstructionGroup>()
            .toList();
        expect(
          groups.map((SourceInstructionGroup group) => group.sourceId),
          <ExtensionId>[firstId, lastId],
        );
        final InferenceInstructionMaterial capturedFirst =
            groups.first.materials.single;
        final InferenceInstructionMaterial capturedLast =
            groups.last.materials.single;
        expect(capturedFirst.key, 'shared');
        expect(capturedFirst.text, 'First source.');
        expect(capturedFirst.revision, 'revision-a');
        expect(capturedLast.key, 'shared');
        expect(capturedLast.text, 'Last source.');
        expect(capturedLast.revision, isNull);
        expect(snapshot.sourceResults, hasLength(4));
        expect(
          snapshot.sourceResults.map(
            (InferenceContextSourceResult result) => result.sourceId,
          ),
          <ExtensionId>[firstId, failedId, emptyId, lastId],
        );
        expect(
          snapshot.sourceResults.map(
            (InferenceContextSourceResult result) => result.status,
          ),
          <InferenceContextSourceStatus>[
            InferenceContextSourceStatus.contributed,
            InferenceContextSourceStatus.omitted,
            InferenceContextSourceStatus.empty,
            InferenceContextSourceStatus.contributed,
          ],
        );
        final InferenceContextSourceResult omitted = snapshot.sourceResults[1];
        expect(omitted.failureMode, InferenceContextFailureMode.optional);
        expect(omitted.materials, isEmpty);
        expect(omitted.failure!.sourceId, failedId);
        expect(omitted.failure!.cause, same(failure));
        final InferenceContextSourceResult empty = snapshot.sourceResults[2];
        expect(empty.failureMode, InferenceContextFailureMode.required);
        expect(empty.materials, isEmpty);
        expect(empty.failure, isNull);
        expect(snapshot.sourceResults.first.failure, isNull);
        expect(snapshot.sourceResults.last.failure, isNull);
        expect(request.instructions, renderInferenceInstructions(snapshot));
        expect(
          request.instructions,
          '$instructions\n\nFirst source.\n\nLast source.',
        );
        expect(request.instructions, contains('First source.'));
        expect(request.instructions, contains('Last source.'));
        expect(
          request.instructions,
          isNot(contains('Must never reach the model.')),
        );
        expect(request.input, same(snapshot.input));
        expect(request.tools.tools, hasLength(1));
        expect(
          request.tools.byAlias('inspect_resource')!.executable,
          same(fixture.executable),
        );
        expect(
          () => snapshot.instructionGroups.clear(),
          throwsUnsupportedError,
        );
        expect(() => snapshot.sourceResults.clear(), throwsUnsupportedError);
        expect(() => snapshot.input.clear(), throwsUnsupportedError);
        expect(() => groups.first.materials.clear(), throwsUnsupportedError);
      }
      expect(fixture.model.sawCorrelatedContinuation, isTrue);
      expect(fixture.executable.executions, 1);
      expect(
        fixture.history.snapshot().entries.map(
          (ChatEntry entry) => entry.content,
        ),
        <String>['Inspect.', 'Complete.'],
      );
      expect(fixture.history.instructions, instructions);
      expect(_events(fixture.run).whereType<ModelInvocationFailed>(), isEmpty);
      expect(_events(fixture.run).whereType<RunFailed>(), isEmpty);
    },
  );

  test(
    'required source failure fails Chat before any model invocation',
    () async {
      final _StrategyFixture fixture = await _fixture(ToolPolicyDecision.allow);
      final ExtensionId sourceId = ExtensionId(
        'dev.adele.test.context.required',
      );
      final StateError failure = StateError('Required source unavailable.');
      final StackTrace stackTrace = StackTrace.current;
      fixture.registerSource(
        sourceId,
        snapshot: (InferenceContextSourceContext context) async {
          Error.throwWithStackTrace(failure, stackTrace);
        },
      );

      await expectLater(
        fixture.strategy.start(),
        throwsA(
          isA<InferenceContextSourceFailed>()
              .having(
                (InferenceContextSourceFailed error) => error.sourceId,
                'source',
                sourceId,
              )
              .having(
                (InferenceContextSourceFailed error) => error.cause,
                'cause',
                same(failure),
              )
              .having(
                (InferenceContextSourceFailed error) =>
                    error.stackTrace.toString(),
                'source stack',
                stackTrace.toString(),
              ),
        ),
      );

      _expectContextPreparationFailed(fixture);
    },
  );

  for (final InferenceContextFailureMode mode
      in InferenceContextFailureMode.values) {
    for (final bool duplicate in <bool>[true, false]) {
      test(
        '$mode ${duplicate ? 'duplicate keys' : 'lazy invalid material'} rejects the whole source',
        () async {
          final _StrategyFixture fixture = await _fixture(
            ToolPolicyDecision.allow,
            instructions: 'Strategy only.',
          );
          final ExtensionId sourceId = ExtensionId(
            'dev.adele.test.context.invalid',
          );
          final ExtensionId goodId = ExtensionId(
            'dev.adele.test.context.valid',
          );
          int yielded = 0;
          Iterable<InferenceContextMaterial> invalid() sync* {
            yielded++;
            yield InferenceInstructionMaterial(
              key: 'first',
              text: 'Partial material.',
            );
            yielded++;
            yield InferenceInstructionMaterial(
              key: duplicate ? 'first' : ' ',
              text: 'Invalid material.',
            );
          }

          fixture.registerSource(
            sourceId,
            failureMode: mode,
            snapshot: (InferenceContextSourceContext context) async =>
                invalid(),
          );
          fixture.registerSource(
            goodId,
            snapshot: (InferenceContextSourceContext context) async =>
                <InferenceContextMaterial>[
                  InferenceInstructionMaterial(
                    key: 'first',
                    text: 'Unaffected source.',
                  ),
                ],
          );

          if (mode == InferenceContextFailureMode.required) {
            await expectLater(
              fixture.strategy.start(),
              throwsA(
                isA<InferenceContextSourceFailed>()
                    .having(
                      (InferenceContextSourceFailed error) => error.sourceId,
                      'invalid source',
                      sourceId,
                    )
                    .having(
                      (InferenceContextSourceFailed error) => error.cause,
                      'invalid material',
                      isA<FormatException>(),
                    ),
              ),
            );
            expect(yielded, 2);
            _expectContextPreparationFailed(fixture);
          } else {
            await fixture.strategy.start();
            expect(fixture.run.state, RunState.completed);
            expect(fixture.model.requests, hasLength(2));
            expect(yielded, 4);
            for (final SemanticModelRequest request in fixture.model.requests) {
              final SourceInstructionGroup group = request
                  .context
                  .instructionGroups
                  .whereType<SourceInstructionGroup>()
                  .single;
              expect(group.sourceId, goodId);
              expect(group.materials.single.text, 'Unaffected source.');
              expect(request.instructions, contains('Unaffected source.'));
              expect(
                request.instructions,
                isNot(contains('Partial material.')),
              );
              expect(
                request.instructions,
                isNot(contains('Invalid material.')),
              );
              expect(request.context.sourceResults, hasLength(2));
              final InferenceContextSourceResult omitted =
                  request.context.sourceResults.first;
              expect(omitted.sourceId, sourceId);
              expect(omitted.status, InferenceContextSourceStatus.omitted);
              expect(omitted.materials, isEmpty);
              expect(omitted.failure!.sourceId, sourceId);
              expect(omitted.failure!.cause, isA<FormatException>());
              expect(
                request.context.sourceResults.last.status,
                InferenceContextSourceStatus.contributed,
              );
            }
            expect(fixture.model.sawCorrelatedContinuation, isTrue);
            expect(fixture.executable.executions, 1);
            expect(_events(fixture.run).whereType<RunFailed>(), isEmpty);
            expect(
              _events(fixture.run).whereType<ModelInvocationFailed>(),
              isEmpty,
            );
          }
        },
      );
    }
  }

  for (final InferenceContextFailureMode mode
      in InferenceContextFailureMode.values) {
    test(
      '$mode pending source retirement never accepts A or calls replacement B in the same inference',
      () async {
        const String instructions = 'Canonical Chat instructions.';
        final _StrategyFixture fixture = await _fixture(
          ToolPolicyDecision.allow,
          instructions: instructions,
          proposalBeforeText: true,
        );
        final ExtensionId sourceId = ExtensionId(
          'dev.adele.test.context.replace',
        );
        final Completer<void> captureStarted = Completer<void>();
        final Completer<void> releaseCapture = Completer<void>();
        final Completer<void> modelStarted = Completer<void>();
        final Completer<void> releaseModel = Completer<void>();
        final List<InferenceContextSourceContext> contexts =
            <InferenceContextSourceContext>[];
        final ChatEntry originalUser = fixture.history
            .snapshot()
            .entries
            .single;
        int callsA = 0;
        int callsB = 0;
        final ExtensionRegistration generationA = fixture.registerSource(
          sourceId,
          failureMode: mode,
          snapshot: (InferenceContextSourceContext context) async {
            callsA++;
            contexts.add(context);
            captureStarted.complete();
            await releaseCapture.future;
            return <InferenceContextMaterial>[
              InferenceInstructionMaterial(
                key: 'state',
                text: 'Retired A.',
                revision: 'a',
              ),
            ];
          },
        );
        fixture.model.beforeSettlement = () async {
          if (fixture.model.invocations != 1) return;
          modelStarted.complete();
          await releaseModel.future;
        };
        final Future<void> running = fixture.strategy.start();
        final Future<void> finished =
            mode == InferenceContextFailureMode.required
            ? expectLater(
                running,
                throwsA(
                  isA<InferenceContextSourceFailed>()
                      .having(
                        (InferenceContextSourceFailed error) => error.sourceId,
                        'retired source',
                        sourceId,
                      )
                      .having(
                        (InferenceContextSourceFailed error) => error.cause,
                        'retirement',
                        isA<StaleExtensionBinding>().having(
                          (StaleExtensionBinding error) => error.id,
                          'generation A',
                          sourceId,
                        ),
                      ),
                ),
              )
            : running;
        await captureStarted.future;
        expect(fixture.model.requests, isEmpty);
        expect(_events(fixture.run).single, isA<RunStarted>());
        await generationA.close();
        fixture.registerSource(
          sourceId,
          failureMode: mode,
          snapshot: (InferenceContextSourceContext context) async {
            callsB++;
            contexts.add(context);
            return <InferenceContextMaterial>[
              InferenceInstructionMaterial(
                key: 'state',
                text: 'Fresh B.',
                revision: 'b',
              ),
            ];
          },
        );
        expect(callsA, 1);
        expect(callsB, 0);
        expect(fixture.run.state, RunState.running);
        expect(fixture.run.failure, isNull);
        releaseCapture.complete();

        if (mode == InferenceContextFailureMode.required) {
          await finished;
          _expectContextPreparationFailed(fixture);
          expect(callsB, 0);
        } else {
          await modelStarted.future;
          expect(callsA, 1);
          expect(callsB, 0);
          final SemanticModelRequest first = fixture.model.requests.single;
          final InferenceContextSnapshot frozen = first.context;
          final InferenceContextSourceResult omitted =
              frozen.sourceResults.single;
          expect(omitted.sourceId, sourceId);
          expect(omitted.status, InferenceContextSourceStatus.omitted);
          expect(omitted.materials, isEmpty);
          expect(omitted.failure!.cause, isA<StaleExtensionBinding>());
          expect(
            frozen.instructionGroups.whereType<SourceInstructionGroup>(),
            isEmpty,
          );
          expect(first.instructions, instructions);
          expect(fixture.history.snapshot().entries.single, same(originalUser));
          releaseModel.complete();
          await finished;

          expect(fixture.run.state, RunState.completed);
          expect(fixture.model.requests, hasLength(2));
          expect(callsA, 1);
          expect(callsB, 1);
          final SemanticModelRequest next = fixture.model.requests.last;
          expect(next.context, isNot(same(frozen)));
          final SourceInstructionGroup replacement = next
              .context
              .instructionGroups
              .whereType<SourceInstructionGroup>()
              .single;
          expect(replacement.sourceId, sourceId);
          expect(replacement.materials.single.key, 'state');
          expect(replacement.materials.single.text, 'Fresh B.');
          expect(replacement.materials.single.revision, 'b');
          expect(
            next.context.sourceResults.single.status,
            InferenceContextSourceStatus.contributed,
          );
          expect(next.context.sourceResults.single.failure, isNull);
          expect(next.instructions, '$instructions\n\nFresh B.');
          expect(next.instructions, renderInferenceInstructions(next.context));
          expect(first.context, same(frozen));
          expect(first.instructions, instructions);
          expect(first.context.sourceResults.single, same(omitted));
          expect(next.input, same(next.context.input));
          expect(
            next.input.map((SemanticModelInputItem item) => item.runtimeType),
            <Type>[
              SemanticMessageInput,
              SemanticToolProposalInput,
              SemanticMessageInput,
              SemanticToolOutcomeInput,
            ],
          );
          expect(
            (next.input[0] as SemanticMessageInput).role,
            SemanticMessageRole.user,
          );
          expect(
            (next.input[0] as SemanticMessageInput).content,
            originalUser.content,
          );
          final ProviderToolProposal proposal =
              (_events(fixture.run).whereType<ModelOutputObserved>().first.item
                      as ModelToolProposalOutput)
                  .proposal;
          expect(
            (next.input[1] as SemanticToolProposalInput).proposal,
            same(proposal),
          );
          expect(
            (next.input[2] as SemanticMessageInput).role,
            SemanticMessageRole.assistant,
          );
          expect(
            (next.input[2] as SemanticMessageInput).content,
            'Text after proposal.',
          );
          final SemanticToolOutcomeInput outcome =
              next.input[3] as SemanticToolOutcomeInput;
          expect(outcome.providerCallId, proposal.providerCallId);
          expect(outcome.outcome, same(fixture.strategy.lastToolOutcome));
          expect(outcome.outcome.modelContent, 'Inspected.');
          expect(
            fixture.strategy.lastToolInvocation!.tool,
            same(first.tools.byAlias('inspect_resource')),
          );
          expect(next.tools, isNot(same(first.tools)));
          expect(
            next.tools.byAlias('inspect_resource')!.executable,
            same(fixture.executable),
          );
          expect(fixture.model.sawCorrelatedContinuation, isTrue);
          expect(fixture.model.sawPreservedOutputOrder, isTrue);
          expect(fixture.executable.executions, 1);
          expect(fixture.history.snapshot().entries.first, same(originalUser));
          expect(
            fixture.history.snapshot().entries.map(
              (ChatEntry entry) => entry.content,
            ),
            <String>['Inspect.', 'Complete.'],
          );
          expect(
            _events(fixture.run).whereType<ModelInvocationStarted>(),
            hasLength(2),
          );
          expect(
            _events(fixture.run).whereType<ModelInvocationSettled>(),
            hasLength(2),
          );
          expect(
            _events(fixture.run).whereType<ModelInvocationFailed>(),
            isEmpty,
          );
          expect(_events(fixture.run).whereType<RunFailed>(), isEmpty);
          expect(contexts.last, isNot(same(contexts.first)));
        }
        expect(fixture.history.instructions, instructions);
        for (final InferenceContextSourceContext context in contexts) {
          expect(context.session, same(fixture.session));
          expect(context.runId, fixture.run.id);
        }
      },
    );

    test(
      '$mode source retirement after frozen capture does not fail the held invocation',
      () async {
        final _StrategyFixture fixture = await _fixture(
          ToolPolicyDecision.allow,
        );
        final ExtensionId sourceId = ExtensionId(
          'dev.adele.test.context.frozen',
        );
        final List<InferenceContextMaterial> supplied =
            <InferenceContextMaterial>[
              InferenceInstructionMaterial(
                key: 'frozen',
                text: 'Captured once.',
                revision: 'v1',
              ),
            ];
        int captures = 0;
        int replacementCaptures = 0;
        final ExtensionRegistration registration = fixture.registerSource(
          sourceId,
          failureMode: mode,
          snapshot: (InferenceContextSourceContext context) async {
            captures++;
            return supplied;
          },
        );
        final Completer<void> modelStarted = Completer<void>();
        final Completer<void> releaseModel = Completer<void>();
        fixture.model.beforeSettlement = () async {
          if (fixture.model.invocations != 1) return;
          modelStarted.complete();
          await releaseModel.future;
        };
        final Future<void> running = fixture.strategy.start();
        await modelStarted.future;
        final SemanticModelRequest request = fixture.model.requests.single;
        final InferenceContextSnapshot frozen = request.context;
        final SourceInstructionGroup group = frozen.instructionGroups
            .whereType<SourceInstructionGroup>()
            .single;
        final InferenceInstructionMaterial material = group.materials.single;
        expect(group.sourceId, sourceId);
        expect(material.text, 'Captured once.');
        expect(material.revision, 'v1');
        expect(material, isNot(same(supplied.single)));
        final List<ExecutionEventRecord> inFlight = fixture.run.journal.records;
        expect(
          _events(fixture.run).whereType<ModelInvocationStarted>(),
          hasLength(1),
        );
        expect(
          _events(fixture.run).whereType<ModelInvocationSettled>(),
          isEmpty,
        );

        supplied.clear();
        await registration.close();
        fixture.registerSource(
          sourceId,
          failureMode: mode,
          snapshot: (InferenceContextSourceContext context) async {
            replacementCaptures++;
            return <InferenceContextMaterial>[
              InferenceInstructionMaterial(
                key: 'frozen',
                text: 'Replacement context.',
                revision: 'v2',
              ),
            ];
          },
        );
        expect(replacementCaptures, 0);
        expect(fixture.run.state, RunState.running);
        expect(fixture.run.failure, isNull);
        expect(fixture.run.journal.records, orderedEquals(inFlight));
        expect(group.materials.single, same(material));
        expect(request.instructions, 'Captured once.');
        expect(renderInferenceInstructions(frozen), 'Captured once.');
        expect(
          frozen.sourceResults.single.status,
          InferenceContextSourceStatus.contributed,
        );
        expect(frozen.sourceResults.single.failure, isNull);
        releaseModel.complete();
        await running;

        expect(fixture.run.state, RunState.completed);
        expect(fixture.run.failure, isNull);
        expect(captures, 1);
        expect(replacementCaptures, 1);
        expect(fixture.model.requests, hasLength(2));
        expect(fixture.model.requests.first.context, same(frozen));
        expect(request.instructions, 'Captured once.');
        final InferenceContextSnapshot next =
            fixture.model.requests.last.context;
        final SourceInstructionGroup replacement = next.instructionGroups
            .whereType<SourceInstructionGroup>()
            .single;
        expect(replacement.sourceId, sourceId);
        expect(replacement.materials.single.key, material.key);
        expect(replacement.materials.single.revision, 'v2');
        expect(next.sourceResults.single.failure, isNull);
        expect(
          next.sourceResults.single.status,
          InferenceContextSourceStatus.contributed,
        );
        expect(
          fixture.model.requests.last.instructions,
          'Replacement context.',
        );
        expect(fixture.model.sawCorrelatedContinuation, isTrue);
        expect(fixture.executable.executions, 1);
        expect(
          _events(fixture.run).whereType<ModelInvocationFailed>(),
          isEmpty,
        );
        expect(_events(fixture.run).whereType<RunFailed>(), isEmpty);
        expect(
          _events(fixture.run).whereType<ModelInvocationSettled>(),
          hasLength(2),
        );
        expect(
          _events(
            fixture.run,
          ).whereType<ModelInvocationSettled>().first.settlement,
          ModelSettlement.completed,
        );
        expect(
          fixture.history.snapshot().entries.map(
            (ChatEntry entry) => entry.content,
          ),
          <String>['Inspect.', 'Complete.'],
        );
      },
    );
  }

  test('three proposals drain sequentially from one tool generation', () async {
    final _BatchFixture fixture = await _BatchFixture.create();
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
      final _BatchFixture fixture = await _BatchFixture.create();
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
        final _BatchFixture fixture = await _BatchFixture.create(
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
    final _BatchFixture fixture = await _BatchFixture.create(failedStep: 1);

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
      final _BatchFixture fixture = await _BatchFixture.create(
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
        final _BatchFixture fixture = await _BatchFixture.create(
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
    final _BatchFixture fixture = await _BatchFixture.create(
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
      final _BatchFixture fixture = await _BatchFixture.create(
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
      final _BatchFixture fixture = await _BatchFixture.create(
        maxModelInvocations: 1,
      );

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
        final _BatchFixture fixture = await _BatchFixture.create(
          settlement: settlement,
        );

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
      final _BatchFixture fixture = await _BatchFixture.create(
        modelFailure: failure,
      );

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
      final _BatchFixture fixture = await _BatchFixture.create(
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
      final _BatchFixture fixture = await _BatchFixture.create(
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

  test(
    'canonical Session stored strategy selects the contribution without fallback',
    () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ChatStrategyPlugin chat = ChatStrategyPlugin();
      addTearDown(chat.activate(extensions).close);
      final OrchestrationStrategyId selectedId = OrchestrationStrategyId(
        'dev.adele.strategy.selected',
      );
      final List<Session> materialized = <Session>[];
      final List<String> callbacks = <String>[];
      addTearDown(
        extensions
            .register(
              point: orchestrationStrategyContributions,
              id: ExtensionId('dev.adele.test.selected'),
              value: OrchestrationStrategyContribution(
                strategyId: selectedId,
                materialize: (OrchestrationStrategyHostContext context) {
                  materialized.add(context.session);
                  return _CompletingExecution(context.host, callbacks);
                },
              ),
            )
            .close,
      );
      final OrchestrationTestLifecycle topology =
          await OrchestrationTestLifecycle.create(
            extensions,
            SessionId('routing-session'),
          );
      final Session session = topology.createSession(selectedId);
      final _Model model = _Model();
      final _Executable executable = _Executable();
      final SessionOrchestrationRun execution = createSessionOrchestrationRun(
        lifecycle: topology.lifecycle,
        contextComposer: InferenceContextComposer(extensions),
        sessionId: session.id,
        runId: RunId('routing-run'),
        model: model,
        toolCatalog: _catalog(executable),
        policy: const _Policy(ToolPolicyDecision.allow),
      );

      expect(materialized.single, same(session));
      expect(topology.lifecycle.store.session(session.id), same(session));
      expect(session.strategyId, selectedId);
      expect(execution.run.sessionId, session.id);
      expect(execution.run.state, RunState.created);
      expect(callbacks, isEmpty);
      await execution.start();

      expect(callbacks, <String>['start']);
      expect(execution.run.state, RunState.completed);
      expect(
        _events(execution.run).map((ExecutionEvent event) => event.runtimeType),
        <Type>[RunStarted, RunCompleted],
      );
      expect(model.invocations, 0);
      expect(executable.executions, 0);
      expect(chat.sessions.obtain(session.id).snapshot().entries, isEmpty);
    },
  );

  for (final bool ambiguous in <bool>[false, true]) {
    test(
      'canonical Run rejects ${ambiguous ? 'ambiguous' : 'unavailable'} stored strategy without fallback',
      () async {
        final ExtensionRegistry extensions = ExtensionRegistry();
        final ChatStrategyPlugin chat = ChatStrategyPlugin();
        addTearDown(chat.activate(extensions).close);
        final OrchestrationStrategyId selectedId = OrchestrationStrategyId(
          'dev.adele.strategy.selected',
        );
        final List<String> callbacks = <String>[];
        final OrchestrationStrategyContribution contribution =
            OrchestrationStrategyContribution(
              strategyId: selectedId,
              materialize: (OrchestrationStrategyHostContext context) {
                callbacks.add('materialize');
                return _CompletingExecution(context.host, callbacks);
              },
            );
        final ExtensionRegistration selected = extensions.register(
          point: orchestrationStrategyContributions,
          id: ExtensionId('dev.adele.test.selected'),
          value: contribution,
        );
        addTearDown(selected.close);
        final OrchestrationTestLifecycle topology =
            await OrchestrationTestLifecycle.create(
              extensions,
              SessionId('unresolved-session'),
            );
        final Session session = topology.createSession(selectedId);
        final Object authority = topology.lifecycle.store
            .requireSessionAuthority(session.id);
        if (ambiguous) {
          addTearDown(
            extensions
                .register(
                  point: orchestrationStrategyContributions,
                  id: ExtensionId('dev.adele.test.duplicate'),
                  value: contribution,
                )
                .close,
          );
        } else {
          await selected.close();
        }
        final _Model model = _Model();
        final _Executable executable = _Executable();
        SessionOrchestrationRun create(SessionId id) =>
            createSessionOrchestrationRun(
              lifecycle: topology.lifecycle,
              contextComposer: InferenceContextComposer(extensions),
              sessionId: id,
              runId: RunId('unresolved-run'),
              model: model,
              toolCatalog: _catalog(executable),
              policy: const _Policy(ToolPolicyDecision.allow),
            );

        expect(
          () => create(session.id),
          throwsA(
            ambiguous
                ? isA<AmbiguousOrchestrationStrategy>()
                      .having(
                        (AmbiguousOrchestrationStrategy error) =>
                            error.strategyId,
                        'stored strategy',
                        selectedId,
                      )
                      .having(
                        (AmbiguousOrchestrationStrategy error) =>
                            error.extensionIds,
                        'competing registrations',
                        <ExtensionId>[
                          ExtensionId('dev.adele.test.duplicate'),
                          ExtensionId('dev.adele.test.selected'),
                        ],
                      )
                : isA<OrchestrationStrategyUnavailable>().having(
                    (OrchestrationStrategyUnavailable error) =>
                        error.strategyId,
                    'stored strategy',
                    selectedId,
                  ),
          ),
        );
        expect(
          () => create(SessionId('unpublished-session')),
          throwsStateError,
        );
        expect(callbacks, isEmpty);
        expect(model.invocations, 0);
        expect(executable.executions, 0);
        expect(topology.lifecycle.store.session(session.id), same(session));
        expect(session.strategyId, selectedId);
        expect(
          topology.lifecycle.store.requireSessionAuthority(session.id),
          same(authority),
        );
        expect(chat.sessions.obtain(session.id).snapshot().entries, isEmpty);
      },
    );
  }

  test(
    'approved Run retains exact Chat generation; fresh Run resolves replacement',
    () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      final ChatSessionStore sessions = ChatSessionStore();
      final ChatStrategyPlugin chatA = ChatStrategyPlugin(sessions: sessions);
      final ExtensionRegistration generationA = chatA.activate(extensions);
      addTearDown(generationA.close);
      final OrchestrationTestLifecycle topology =
          await OrchestrationTestLifecycle.create(
            extensions,
            SessionId('generation-session'),
          );
      final Session session = topology.createSession(chatStrategyId);
      final ChatSessionState history = sessions.obtain(session.id)
        ..instructions = 'Generation A'
        ..append(ChatUserMessage('Inspect.'));
      final ResolvedOrchestrationStrategy bindingA = topology.lifecycle
          .resolveSessionStrategy(session.id);
      final _Model modelA = _Model();
      final _Executable executable = _Executable();
      final ToolCatalog catalog = _catalog(executable);
      final SessionOrchestrationRun runA = createSessionOrchestrationRun(
        lifecycle: topology.lifecycle,
        contextComposer: InferenceContextComposer(extensions),
        sessionId: session.id,
        runId: RunId('generation-run-a'),
        model: modelA,
        toolCatalog: catalog,
        policy: const _Policy(ToolPolicyDecision.ask),
      );
      await runA.start();
      expect(runA.run.state, RunState.waiting);
      expect(modelA.invocations, 1);
      expect(modelA.requests.single.instructions, 'Generation A');
      expect(executable.executions, 0);
      final ToolApprovalResolution approval = _approval(runA.run);
      final ToolInvocation retainedInvocation = runA.lastToolInvocation!;
      final List<ExecutionEventRecord> beforeResume = runA.run.journal.records;
      expect(
        retainedInvocation.tool,
        same(modelA.requests.single.tools.byAlias('inspect_resource')),
      );
      expect(_events(runA.run).whereType<RunInterrupted>(), hasLength(1));
      expect(
        _events(runA.run).whereType<ToolPolicyEvaluated>().single.decision,
        ToolPolicyDecision.ask,
      );

      await generationA.close();
      final ChatStrategyPlugin chatB = ChatStrategyPlugin(sessions: sessions);
      chatB.sessions.obtain(session.id).instructions = 'Generation B';
      // Observe the real plugin materializer, without substituting its execution.
      final ExtensionRegistry activationRegistryB = ExtensionRegistry();
      addTearDown(chatB.activate(activationRegistryB).close);
      final ResolvedOrchestrationStrategy activatedB =
          OrchestrationStrategyResolver(
            activationRegistryB,
          ).resolve(chatStrategyId);
      final List<Session> materializedB = <Session>[];
      final List<String> callbacksB = <String>[];
      addTearDown(
        extensions
            .register(
              point: orchestrationStrategyContributions,
              id: activatedB.binding.id,
              value: OrchestrationStrategyContribution(
                strategyId: chatStrategyId,
                materialize: (OrchestrationStrategyHostContext context) {
                  materializedB.add(context.session);
                  return _ObservedExecution(
                    activatedB.materialize(context),
                    callbacksB,
                  );
                },
              ),
            )
            .close,
      );
      final ResolvedOrchestrationStrategy bindingB = topology.lifecycle
          .resolveSessionStrategy(session.id);
      expect(bindingB.binding.id, bindingA.binding.id);
      expect(bindingB.binding, isNot(same(bindingA.binding)));
      expect(bindingA.validateBinding, throwsA(isA<StaleExtensionBinding>()));
      bindingB.validateBinding();
      expect(chatB.sessions.obtain(session.id), same(history));

      await expectLater(
        runA.resolveApproval(approval),
        throwsA(isA<StaleExtensionBinding>()),
      );

      expect(runA.run.state, RunState.failed);
      expect(runA.run.failure, isA<StaleExtensionBinding>());
      expect(runA.run.interruptions, isEmpty);
      expect(runA.lastToolInvocation, same(retainedInvocation));
      expect(runA.lastToolOutcome, isNull);
      expect(modelA.invocations, 1);
      expect(executable.executions, 0);
      expect(materializedB, isEmpty);
      expect(callbacksB, isEmpty);
      expect(
        history.snapshot().entries.map((ChatEntry entry) => entry.content),
        <String>['Inspect.'],
      );
      expect(
        runA.run.journal.records.take(beforeResume.length),
        orderedEquals(beforeResume),
      );
      expect(runA.run.journal.records, hasLength(beforeResume.length + 1));
      expect(
        _events(runA.run).whereType<RunFailed>().single.error,
        same(runA.run.failure),
      );
      expect(_events(runA.run).whereType<RunInterruptionResolved>(), isEmpty);
      expect(_events(runA.run).whereType<ToolExecutionStarted>(), isEmpty);

      final _Model modelB = _Model();
      final SessionOrchestrationRun runB = createSessionOrchestrationRun(
        lifecycle: topology.lifecycle,
        contextComposer: InferenceContextComposer(extensions),
        sessionId: session.id,
        runId: RunId('generation-run-b'),
        model: modelB,
        toolCatalog: catalog,
        policy: const _Policy(ToolPolicyDecision.allow),
      );
      expect(materializedB.single, same(session));
      expect(callbacksB, isEmpty);
      await runB.start();

      expect(callbacksB, <String>['start']);
      expect(runB.run.state, RunState.completed);
      expect(runB.run.sessionId, runA.run.sessionId);
      expect(runB.run.id, isNot(runA.run.id));
      expect(runB.lastToolInvocation!.context.runId, runB.run.id);
      expect(runB.lastToolInvocation!.context.sessionId, session.id);
      expect(modelB.invocations, 2);
      expect(modelB.requests.first.instructions, 'Generation B');
      expect(modelB.sawCorrelatedContinuation, isTrue);
      expect(executable.executions, 1);
      expect(history.snapshot().entries.last, isA<ChatAssistantMessage>());
      expect(history.snapshot().entries.last.content, 'Complete.');
      expect(topology.lifecycle.store.session(session.id), same(session));
      expect(session.strategyId, chatStrategyId);
      expect(runA.run.state, RunState.failed);
      expect(modelA.invocations, 1);
      expect(runA.run.journal.records, hasLength(beforeResume.length + 1));
    },
  );

  for (final bool duringModel in <bool>[true, false]) {
    test(
      'Chat retirement during in-flight ${duringModel ? 'model' : 'tool'} work fails at the next host boundary',
      () async {
        final ExtensionRegistry extensions = ExtensionRegistry();
        final ChatStrategyPlugin chat = ChatStrategyPlugin();
        final ExtensionRegistration generation = chat.activate(extensions);
        addTearDown(generation.close);
        final OrchestrationTestLifecycle topology =
            await OrchestrationTestLifecycle.create(
              extensions,
              SessionId('retiring-chat-session'),
            );
        final Session session = topology.createSession(chatStrategyId);
        final ChatSessionState history = chat.sessions.obtain(session.id)
          ..append(ChatUserMessage('Inspect.'));
        final _Executable executable = _Executable();
        final _Model model = _Model();
        final Completer<void> started = Completer<void>();
        final Completer<void> release = Completer<void>();
        Future<void> suspend() async {
          started.complete();
          await release.future;
        }

        if (duringModel) {
          model.beforeSettlement = suspend;
        } else {
          executable.beforeTerminal = suspend;
        }
        final SessionOrchestrationRun execution = createSessionOrchestrationRun(
          lifecycle: topology.lifecycle,
          contextComposer: InferenceContextComposer(extensions),
          sessionId: session.id,
          runId: RunId('retiring-chat-run'),
          model: model,
          toolCatalog: _catalog(executable),
          policy: const _Policy(ToolPolicyDecision.allow),
        );
        final Future<void> running = execution.start();
        await started.future;
        expect(execution.run.state, RunState.running);
        expect(model.invocations, 1);
        expect(executable.executions, duringModel ? 0 : 1);
        expect(
          _events(execution.run).whereType<ModelInvocationStarted>(),
          hasLength(1),
        );
        expect(
          _events(execution.run).whereType<ModelOutputObserved>(),
          hasLength(1),
        );
        expect(
          _events(execution.run).whereType<ToolExecutionCompleted>(),
          isEmpty,
        );
        await generation.close();
        expect(execution.run.state, RunState.running);
        expect(execution.run.failure, isNull);
        final Future<void> failed = expectLater(
          running,
          throwsA(isA<StaleExtensionBinding>()),
        );
        release.complete();
        await failed;

        expect(execution.run.state, RunState.failed);
        expect(execution.run.failure, isA<StaleExtensionBinding>());
        expect(model.invocations, 1);
        expect(
          _events(execution.run).whereType<ModelOutputObserved>(),
          hasLength(1),
        );
        expect(
          _events(
            execution.run,
          ).whereType<ModelInvocationSettled>().single.settlement,
          ModelSettlement.completed,
        );
        expect(
          _events(execution.run).whereType<ModelInvocationFailed>(),
          isEmpty,
        );
        expect(
          _events(execution.run).whereType<ToolInvocationPrepared>(),
          hasLength(duringModel ? 0 : 1),
        );
        expect(
          _events(execution.run).whereType<ToolExecutionStarted>(),
          hasLength(duringModel ? 0 : 1),
        );
        expect(
          _events(execution.run).whereType<ToolExecutionCompleted>(),
          hasLength(duringModel ? 0 : 1),
        );
        expect(
          _events(execution.run).whereType<RunFailed>().single.error,
          same(execution.run.failure),
        );
        final List<ExecutionEvent> events = _events(execution.run).toList();
        expect(
          events[events.length - 2],
          duringModel
              ? isA<ModelInvocationSettled>()
              : isA<ToolExecutionCompleted>(),
        );
        expect(events.last, isA<RunFailed>());
        expect(events.whereType<RunCancelled>(), isEmpty);
        expect(events.whereType<RunCompleted>(), isEmpty);
        if (duringModel) {
          expect(execution.lastToolInvocation, isNull);
          expect(execution.lastToolOutcome, isNull);
        } else {
          expect(
            execution.lastToolInvocation,
            same(events.whereType<ToolInvocationPrepared>().single.invocation),
          );
          expect(
            execution.lastToolOutcome,
            same(events.whereType<ToolExecutionCompleted>().single.outcome),
          );
          expect(
            execution.lastToolOutcome!.disposition,
            ToolOutcomeDisposition.success,
          );
          expect(
            execution.lastToolOutcome!.effectCertainty,
            EffectCertainty.knownOccurred,
          );
        }
        expect(executable.executions, duringModel ? 0 : 1);
        expect(
          history.snapshot().entries.map((ChatEntry entry) => entry.content),
          <String>['Inspect.'],
        );
      },
    );
  }

  test(
    'invalid and duplicate approval resumes preserve pending authority and evidence',
    () async {
      final _StrategyFixture fixture = await _fixture(ToolPolicyDecision.ask);
      final ToolApprovalResolution early = ToolApprovalResolution(
        interruptionId: RunInterruptionId('not-pending'),
        toolInvocationId: ToolInvocationId('not-pending'),
        approved: true,
      );
      await expectLater(
        fixture.strategy.resolveApproval(early),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.run.state, RunState.created);
      expect(fixture.run.journal.records, isEmpty);
      expect(fixture.model.invocations, 0);
      await fixture.strategy.start();
      final ToolApprovalResolution valid = _approval(fixture.run);
      final ToolApprovalInterruption pending =
          fixture.run.interruptions.values.single as ToolApprovalInterruption;
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
        expect(fixture.run.state, RunState.waiting);
        expect(fixture.run.interruptions.values.single, same(pending));
        expect(fixture.run.journal.records, orderedEquals(waiting));
        expect(fixture.run.failure, isNull);
        expect(fixture.executable.executions, 0);
        expect(fixture.model.invocations, 1);
      }
      await expectLater(
        fixture.strategy.start(),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.run.journal.records, orderedEquals(waiting));
      await fixture.strategy.resolveApproval(valid);
      expect(fixture.run.state, RunState.completed);
      expect(fixture.run.interruptions, isEmpty);
      expect(fixture.executable.executions, 1);
      expect(fixture.model.invocations, 2);
      expect(fixture.model.sawCorrelatedContinuation, isTrue);
      expect(
        _events(fixture.run).whereType<RunInterruptionResolved>(),
        hasLength(1),
      );
      final List<ExecutionEventRecord> completed = fixture.run.journal.records;
      await expectLater(
        fixture.strategy.resolveApproval(valid),
        throwsA(isA<InvalidRunOperation>()),
      );
      await expectLater(
        fixture.strategy.start(),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.run.journal.records, orderedEquals(completed));
      expect(fixture.run.state, RunState.completed);
      expect(fixture.executable.executions, 1);
      expect(fixture.model.invocations, 2);
    },
  );

  test(
    'invalid caller resumes preserve the unprocessed approval batch',
    () async {
      final _BatchFixture fixture = await _BatchFixture.create(
        decisions: <int, ToolPolicyDecision>{2: ToolPolicyDecision.ask},
      );
      await fixture.strategy.start();
      final ToolApprovalResolution valid = _approval(fixture.run);
      final RunInterruption pending = fixture.run.interruptions.values.single;
      final List<ExecutionEventRecord> waiting = fixture.run.journal.records;
      for (final ToolApprovalResolution invalid in <ToolApprovalResolution>[
        ToolApprovalResolution(
          interruptionId: RunInterruptionId('wrong-interruption'),
          toolInvocationId: valid.toolInvocationId,
          approved: true,
        ),
        ToolApprovalResolution(
          interruptionId: valid.interruptionId,
          toolInvocationId: ToolInvocationId('wrong-tool'),
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
      expect(fixture.run.state, RunState.waiting);
      expect(fixture.run.failure, isNull);
      expect(fixture.run.interruptions.values.single, same(pending));
      expect(fixture.run.journal.records, orderedEquals(waiting));
      expect(fixture.executable.completed, <int>[1]);
      expect(fixture.model.requests, hasLength(1));

      await fixture.strategy.resolveApproval(valid);

      expect(fixture.run.state, RunState.completed);
      expect(fixture.executable.completed, <int>[1, 2, 3]);
      expect(fixture.model.requests, hasLength(2));
      expect(
        fixture.outcomes.map(
          (SemanticToolOutcomeInput input) => input.providerCallId,
        ),
        <String>['call-1', 'call-2', 'call-3'],
      );
      expect(fixture.events.whereType<RunInterruptionResolved>(), hasLength(1));
      expect(fixture.events.whereType<RunFailed>(), isEmpty);
    },
  );

  test(
    'reentrant start and approval cannot advance an in-flight resume',
    () async {
      final _BatchFixture fixture = await _BatchFixture.create(
        decisions: <int, ToolPolicyDecision>{2: ToolPolicyDecision.ask},
      );
      await fixture.strategy.start();
      final ToolApprovalResolution resolution = _approval(fixture.run);
      final Completer<void> started = Completer<void>();
      final Completer<void> release = Completer<void>();
      fixture.executable.beforeTerminal = (int step) async {
        if (step == 2) {
          started.complete();
          await release.future;
        }
      };
      final Future<void> resuming = fixture.strategy.resolveApproval(
        resolution,
      );
      await started.future;
      final List<ExecutionEventRecord> inFlight = fixture.run.journal.records;
      await expectLater(
        fixture.strategy.resolveApproval(resolution),
        throwsA(isA<InvalidRunOperation>()),
      );
      await expectLater(
        fixture.strategy.start(),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.run.state, RunState.running);
      expect(fixture.run.failure, isNull);
      expect(fixture.run.journal.records, orderedEquals(inFlight));
      expect(fixture.executable.timeline, <String>[
        'start-1',
        'complete-1',
        'start-2',
      ]);
      expect(fixture.model.requests, hasLength(1));
      expect(fixture.events.whereType<RunInterruptionResolved>(), hasLength(1));
      release.complete();
      await resuming;

      expect(fixture.run.state, RunState.completed);
      expect(fixture.executable.timeline, <String>[
        'start-1',
        'complete-1',
        'start-2',
        'complete-2',
        'start-3',
        'complete-3',
      ]);
      expect(fixture.model.requests, hasLength(2));
      expect(
        fixture.outcomes.map(
          (SemanticToolOutcomeInput input) => input.providerCallId,
        ),
        <String>['call-1', 'call-2', 'call-3'],
      );
      expect(fixture.events.whereType<RunInterruptionResolved>(), hasLength(1));
      expect(fixture.events.whereType<ToolExecutionStarted>(), hasLength(3));
      expect(fixture.events.whereType<RunFailed>(), isEmpty);
    },
  );
}

final class _BatchFixture {
  _BatchFixture._(
    this.session,
    this.strategy,
    this.catalog,
    this.executable,
    this.model,
  );

  static Future<_BatchFixture> create({
    Map<int, ToolPolicyDecision> decisions = const <int, ToolPolicyDecision>{},
    int? failedStep,
    bool invalidSecondProposal = false,
    bool unknownAlias = false,
    int proposalCount = 3,
    int maxModelInvocations = 8,
    ModelSettlement settlement = ModelSettlement.completed,
    Object? modelFailure,
    _InfrastructureFailure? infrastructureFailure,
  }) async {
    final _BatchExecutable executable = _BatchExecutable(
      failedStep,
      infrastructureFailure,
    );
    final ToolCatalog catalog = ToolCatalog();
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
    final _BatchModel model = _BatchModel(
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
    final ExtensionRegistry extensions = ExtensionRegistry();
    final ChatStrategyPlugin chat = ChatStrategyPlugin();
    addTearDown(chat.activate(extensions).close);
    final OrchestrationTestLifecycle topology =
        await OrchestrationTestLifecycle.create(
          extensions,
          SessionId('batch-session'),
        );
    final Session productSession = topology.createSession(chatStrategyId);
    final ChatSessionState session = chat.sessions.obtain(productSession.id)
      ..maxModelInvocations = maxModelInvocations
      ..append(ChatUserMessage('Perform steps.'));
    final SessionOrchestrationRun strategy = createSessionOrchestrationRun(
      lifecycle: topology.lifecycle,
      contextComposer: InferenceContextComposer(extensions),
      sessionId: productSession.id,
      runId: RunId('batch-run'),
      model: model,
      toolCatalog: catalog,
      policy: _BatchPolicy(decisions, infrastructureFailure),
    );
    return _BatchFixture._(session, strategy, catalog, executable, model);
  }

  final ChatSessionState session;
  AgentRun get run => strategy.run;
  final ToolCatalog catalog;
  final _BatchExecutable executable;
  final _BatchModel model;
  final SessionOrchestrationRun strategy;

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

Future<_StrategyFixture> _fixture(
  ToolPolicyDecision decision, {
  String instructions = '',
  String modelAlias = 'inspect_resource',
  bool proposalBeforeText = false,
  ModelSettlement settlement = ModelSettlement.completed,
  bool alwaysPropose = false,
  int maxModelInvocations = 8,
  List<ToolProgress> progress = const <ToolProgress>[],
}) async {
  final ExtensionRegistry extensions = ExtensionRegistry();
  final ChatStrategyPlugin chat = ChatStrategyPlugin();
  addTearDown(chat.activate(extensions).close);
  final OrchestrationTestLifecycle topology =
      await OrchestrationTestLifecycle.create(
        extensions,
        SessionId('session-1'),
      );
  final Session session = topology.createSession(chatStrategyId);
  final ChatSessionState history = chat.sessions.obtain(session.id)
    ..instructions = instructions
    ..maxModelInvocations = maxModelInvocations
    ..append(ChatUserMessage('Inspect.'));
  final _Model model = _Model(
    alias: modelAlias,
    proposalBeforeText: proposalBeforeText,
    settlement: settlement,
    alwaysPropose: alwaysPropose,
  );
  final _Executable executable = _Executable(progress: progress);
  final ToolCatalog catalog = _catalog(executable);
  return _StrategyFixture(
    extensions: extensions,
    session: session,
    history: history,
    model: model,
    executable: executable,
    strategy: createSessionOrchestrationRun(
      lifecycle: topology.lifecycle,
      contextComposer: InferenceContextComposer(extensions),
      sessionId: session.id,
      runId: RunId('run-1'),
      model: model,
      toolCatalog: catalog,
      policy: _Policy(decision),
    ),
  );
}

final class _StrategyFixture {
  const _StrategyFixture({
    required this.extensions,
    required this.session,
    required this.history,
    required this.model,
    required this.executable,
    required this.strategy,
  });

  AgentRun get run => strategy.run;
  final ExtensionRegistry extensions;
  final Session session;
  final ChatSessionState history;
  final _Model model;
  final _Executable executable;
  final SessionOrchestrationRun strategy;

  ExtensionRegistration registerSource(
    ExtensionId id, {
    InferenceContextFailureMode failureMode =
        InferenceContextFailureMode.required,
    required Future<Iterable<InferenceContextMaterial>> Function(
      InferenceContextSourceContext,
    )
    snapshot,
  }) {
    final ExtensionRegistration registration = extensions.register(
      point: inferenceContextSources,
      id: id,
      value: InferenceContextSourceContribution(
        failureMode: failureMode,
        snapshot: snapshot,
      ),
    );
    addTearDown(registration.close);
    return registration;
  }
}

void _expectContextPreparationFailed(_StrategyFixture fixture) {
  expect(fixture.run.state, RunState.failed);
  expect(fixture.run.failure, isA<InferenceContextSourceFailed>());
  expect(fixture.model.requests, isEmpty);
  expect(fixture.model.invocations, 0);
  expect(fixture.executable.executions, 0);
  expect(fixture.strategy.lastModelTools, isNull);
  expect(fixture.strategy.lastToolInvocation, isNull);
  expect(fixture.strategy.lastToolOutcome, isNull);
  final Iterable<ExecutionEvent> events = _events(fixture.run);
  expect(events.whereType<ModelInvocationStarted>(), isEmpty);
  expect(events.whereType<ModelInvocationFailed>(), isEmpty);
  expect(events.map((ExecutionEvent event) => event.runtimeType), <Type>[
    RunStarted,
    RunFailed,
  ]);
  expect(events.whereType<RunFailed>().single.error, same(fixture.run.failure));
  expect(
    fixture.history.snapshot().entries.map((ChatEntry entry) => entry.content),
    <String>['Inspect.'],
  );
}

final class _Model implements ModelPort {
  _Model({
    this.alias = 'inspect_resource',
    this.proposalBeforeText = false,
    this.settlement = ModelSettlement.completed,
    this.alwaysPropose = false,
  });

  final String alias;
  final bool proposalBeforeText;
  final ModelSettlement settlement;
  final bool alwaysPropose;
  final List<SemanticModelRequest> requests = <SemanticModelRequest>[];
  int invocations = 0;
  Future<void> Function()? beforeSettlement;
  bool sawCorrelatedContinuation = false;
  bool sawPreservedOutputOrder = false;

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    invocations++;
    requests.add(request);
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
    await beforeSettlement?.call();
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
  Future<void> Function()? beforeTerminal;

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
    await beforeTerminal?.call();
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

final class _ForgedToolSnapshot implements StrategyToolSnapshot {}

final class _Policy implements ToolPolicy {
  const _Policy(this.decision);

  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}

ToolCatalog _catalog(ToolExecutable executable) => ToolCatalog()
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

Iterable<ExecutionEvent> _events(AgentRun run) =>
    run.journal.records.map((ExecutionEventRecord record) => record.event);

ToolApprovalResolution _approval(AgentRun run) {
  final ToolApprovalInterruption interruption =
      run.interruptions.values.single as ToolApprovalInterruption;
  return ToolApprovalResolution(
    interruptionId: interruption.id,
    toolInvocationId: interruption.toolInvocationId,
    approved: true,
  );
}

final class _CompletingExecution implements OrchestrationExecution {
  _CompletingExecution(this.host, this.callbacks);

  final OrchestrationExecutionHost host;
  final List<String> callbacks;

  @override
  Future<void> start() async {
    callbacks.add('start');
    host.start();
    host.complete();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) =>
      throw const InvalidRunOperation(
        'This fixture does not request approval.',
      );
}

final class _ObservedExecution implements OrchestrationExecution {
  _ObservedExecution(this.delegate, this.callbacks);

  final OrchestrationExecution delegate;
  final List<String> callbacks;

  @override
  Future<void> start() {
    callbacks.add('start');
    return delegate.start();
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) {
    callbacks.add('resolveApproval');
    return delegate.resolveApproval(resolution);
  }
}
