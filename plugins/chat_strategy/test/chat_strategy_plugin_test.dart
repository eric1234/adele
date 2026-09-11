import 'dart:async';

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart' show TaskId;
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:test/test.dart';

void main() {
  test(
    'activation contributes executable Chat under its stable identities',
    () async {
      final _Fixture fixture = _Fixture(
        turns: <StrategyModelTurn>[_finalTurn()],
      );

      expect(chatStrategyPluginId, PluginId('dev.adele.plugin.chat-strategy'));
      expect(
        chatStrategyId,
        OrchestrationStrategyId('dev.adele.strategy.chat'),
      );
      expect(
        fixture.resolved.binding.id,
        ExtensionId('dev.adele.plugin.chat-strategy.orchestration'),
      );
      expect(fixture.resolved.contribution.strategyId, chatStrategyId);
      await fixture.execution.start();

      expect(fixture.host.state, RunState.completed);
      expect(fixture.host.timeline, <String>[
        'start',
        'model-1',
        'validate',
        'complete',
      ]);
      await fixture.registration.close();
      expect(
        () => fixture.resolver.resolve(chatStrategyId),
        throwsA(isA<OrchestrationStrategyUnavailable>()),
      );
    },
  );

  test(
    'retired registration cannot materialize or retarget a replacement',
    () async {
      final _Fixture fixture = _Fixture();
      await fixture.registration.close();
      final ChatStrategyPlugin replacement = ChatStrategyPlugin();
      final ExtensionRegistration registration = replacement.activate(
        fixture.registry,
      );
      addTearDown(registration.close);

      expect(
        () => fixture.resolved.materialize(fixture.context),
        throwsA(isA<StaleExtensionBinding>()),
      );
      final ResolvedOrchestrationStrategy current = fixture.resolver.resolve(
        chatStrategyId,
      );
      expect(current.binding, isNot(same(fixture.resolved.binding)));
      expect(
        current.materialize(fixture.context),
        isA<OrchestrationExecution>(),
      );
      expect(
        replacement.sessions.obtain(fixture.session.id).snapshot().entries,
        isEmpty,
      );
    },
  );

  test(
    'final text is concatenated in output order before host completion',
    () async {
      final _Fixture fixture = _Fixture(
        turns: <StrategyModelTurn>[
          _finalTurn(
            output: <ModelOutputItem>[
              ModelTextOutput('  First'),
              ModelNativeOutput(providerNativeMetadata: _metadata()),
              ModelTextOutput(' second.\n'),
            ],
          ),
        ],
        maxModelInvocations: 1,
      );
      fixture.host.onValidate = () =>
          expect(fixture.state.snapshot().entries, hasLength(1));
      fixture.host.onComplete = () {
        expect(
          fixture.state.snapshot().entries.last,
          isA<ChatAssistantMessage>(),
        );
        expect(
          fixture.state.snapshot().entries.last.content,
          '  First second.\n',
        );
      };

      await fixture.execution.start();

      expect(fixture.host.state, RunState.completed);
      expect(fixture.host.requests, hasLength(1));
      expect(fixture.host.proposals, isEmpty);
      expect(fixture.state.snapshot().entries, hasLength(2));
    },
  );

  for (final ModelSettlement settlement in <ModelSettlement>[
    ModelSettlement.completed,
    ModelSettlement.refused,
  ]) {
    for (final bool whitespace in <bool>[false, true]) {
      test(
        '$settlement rejects ${whitespace ? 'blank' : 'missing'} final text',
        () async {
          final _Fixture fixture = _Fixture(
            turns: <StrategyModelTurn>[
              _finalTurn(
                settlement: settlement,
                output: <ModelOutputItem>[
                  ModelNativeOutput(providerNativeMetadata: _metadata()),
                  if (whitespace) ModelTextOutput(' \n\t'),
                ],
              ),
            ],
          );

          await fixture.execution.start();

          expect(fixture.host.state, RunState.failed);
          expect(fixture.host.failure, isA<StateError>());
          expect(fixture.host.proposals, isEmpty);
          expect(fixture.state.snapshot().entries, hasLength(1));
        },
      );
    }

    test('$settlement validates binding before final history append', () async {
      final _Fixture fixture = _Fixture(
        turns: <StrategyModelTurn>[_finalTurn(settlement: settlement)],
      );
      final StateError stale = StateError('Strategy binding retired.');
      fixture.host.onValidate = () => throw stale;

      await expectLater(fixture.execution.start(), throwsA(same(stale)));

      expect(fixture.host.state, RunState.failed);
      expect(fixture.host.failure, same(stale));
      expect(fixture.state.snapshot().entries, hasLength(1));
      expect(fixture.host.timeline, isNot(contains('complete')));
    });
  }

  test('refusal records text and never processes observed proposals', () async {
    final _Fixture fixture = _Fixture(
      turns: <StrategyModelTurn>[
        _batchTurn(settlement: ModelSettlement.refused),
      ],
      maxModelInvocations: 1,
    );

    await fixture.execution.start();

    expect(fixture.host.state, RunState.completed);
    expect(fixture.host.proposals, isEmpty);
    expect(fixture.host.requests, hasLength(1));
    expect(fixture.state.snapshot().entries.last.content, 'Between proposals.');
  });

  for (final ModelIncompleteReason reason in ModelIncompleteReason.values) {
    test(
      'incomplete $reason preserves metadata and skips the observed batch',
      () async {
        final ModelTerminalMetadata metadata = ModelTerminalMetadata(
          effectiveModel: 'fixture-v1',
          providerResponseId: 'response-1',
          providerRequestId: 'request-1',
          providerStopReason: 'limit',
          usage: ModelUsage(inputTokens: 12, outputTokens: 7),
          providerNativeState: _metadata(),
        );
        final _Fixture fixture = _Fixture(
          turns: <StrategyModelTurn>[
            _batchTurn(
              settlement: ModelSettlement.incomplete,
              incompleteReason: reason,
              metadata: metadata,
            ),
          ],
        );

        await fixture.execution.start();

        expect(fixture.host.state, RunState.failed);
        expect(
          fixture.host.failure,
          isA<ModelInvocationIncomplete>()
              .having((error) => error.reason, 'reason', reason)
              .having((error) => error.metadata, 'metadata', same(metadata)),
        );
        expect(fixture.host.proposals, isEmpty);
        expect(fixture.host.requests, hasLength(1));
        expect(fixture.state.snapshot().entries, hasLength(1));
      },
    );
  }

  test(
    'model failure after multiple proposals remains the original failure',
    () async {
      final StateError failure = StateError('Provider failed.');
      final _Fixture fixture = _Fixture(
        turns: <StrategyModelTurn>[
          StrategyModelTurn.failed(
            tools: _Tools(),
            output: _batchTurn().output,
            error: failure,
          ),
        ],
      );

      await fixture.execution.start();

      expect(fixture.host.state, RunState.failed);
      expect(fixture.host.failure, same(failure));
      expect(fixture.host.proposals, isEmpty);
      expect(fixture.state.snapshot().entries, hasLength(1));
    },
  );

  test(
    'three proposals drain sequentially from the exact opaque snapshot',
    () async {
      final _Fixture fixture = _Fixture();

      await fixture.execution.start();

      expect(fixture.host.state, RunState.completed);
      expect(fixture.host.timeline, <String>[
        'start',
        'model-1',
        'proposal-call-1',
        'result-call-1',
        'proposal-call-2',
        'result-call-2',
        'proposal-call-3',
        'result-call-3',
        'model-2',
        'validate',
        'complete',
      ]);
      expect(
        fixture.host.snapshots,
        everyElement(same(fixture.host.turns.first.tools)),
      );
      expect(
        fixture.host.turns.last.tools,
        isNot(same(fixture.host.turns.first.tools)),
      );
      final List<ProviderToolProposal> proposals = fixture
          .host
          .turns
          .first
          .output
          .whereType<ModelToolProposalOutput>()
          .map((item) => item.proposal)
          .toList();
      expect(fixture.host.proposals, orderedEquals(proposals));
      expect(fixture.outcomes.map((item) => item.providerCallId), <String>[
        'call-1',
        'call-2',
        'call-3',
      ]);
      expect(
        fixture.outcomes.map((item) => item.outcome.modelContent),
        <String>['Handled call-1.', 'Handled call-2.', 'Handled call-3.'],
      );
      expect(
        fixture.state.snapshot().entries.map((entry) => entry.content),
        <String>['Perform steps.', 'Complete.'],
      );
    },
  );

  test(
    'continuation preserves native, proposal-before-text, and outcome order',
    () async {
      final _Fixture fixture = _Fixture();

      await fixture.execution.start();

      final List<SemanticModelInputItem> replay =
          fixture.host.requests.last.input;
      expect(replay, hasLength(10));
      final List<ModelOutputItem> output = fixture.host.turns.first.output;
      for (int index = 0; index < output.length; index++) {
        final SemanticModelInputItem input = replay[index + 1];
        switch (output[index]) {
          case ModelNativeOutput(
            :final providerItemId,
            :final providerNativeMetadata,
          ):
            expect(input, isA<SemanticNativeInput>());
            final SemanticNativeInput native = input as SemanticNativeInput;
            expect(native.providerItemId, providerItemId);
            expect(native.providerNativeMetadata, same(providerNativeMetadata));
          case ModelTextOutput(
            :final content,
            :final providerItemId,
            :final providerNativeMetadata,
          ):
            expect(input, isA<SemanticMessageInput>());
            final SemanticMessageInput text = input as SemanticMessageInput;
            expect(text.role, SemanticMessageRole.assistant);
            expect(text.content, content);
            expect(text.providerItemId, providerItemId);
            expect(text.providerNativeMetadata, same(providerNativeMetadata));
          case ModelToolProposalOutput(
            :final proposal,
            :final providerItemId,
            :final providerNativeMetadata,
          ):
            expect(input, isA<SemanticToolProposalInput>());
            final SemanticToolProposalInput tool =
                input as SemanticToolProposalInput;
            expect(tool.proposal, same(proposal));
            expect(tool.providerItemId, providerItemId);
            expect(tool.providerNativeMetadata, same(providerNativeMetadata));
        }
      }
      expect(replay.skip(7), everyElement(isA<SemanticToolOutcomeInput>()));
      expect(fixture.host.requests.first.input, hasLength(1));
      expect(() => replay.clear(), throwsUnsupportedError);
    },
  );

  test(
    'later proposal and inference wait until prior processing completes',
    () async {
      final _Fixture fixture = _Fixture();
      final Completer<void> started = Completer<void>();
      final Completer<void> release = Completer<void>();
      fixture.host.onProposal = (tools, proposal) async {
        if (proposal.providerCallId == 'call-1') {
          started.complete();
          await release.future;
        }
        return StrategyToolContinuation(_outcome(proposal.providerCallId));
      };

      final Future<void> running = fixture.execution.start();
      await started.future;
      expect(fixture.host.proposals, hasLength(1));
      expect(fixture.host.requests, hasLength(1));
      expect(fixture.state.snapshot().entries, hasLength(1));
      release.complete();
      await running;

      expect(fixture.host.proposals, hasLength(3));
      expect(fixture.host.requests, hasLength(2));
    },
  );

  for (final ToolProposalFailureKind kind in ToolProposalFailureKind.values) {
    test(
      'batch continues after public proposal resolution failure $kind',
      () async {
        final _Fixture fixture = _Fixture();
        final SemanticToolProposalFailureInput failure = _proposalFailure(
          'call-2',
          kind,
        );
        fixture.host.onProposal = (tools, proposal) async =>
            StrategyToolContinuation(
              proposal.providerCallId == 'call-2'
                  ? failure
                  : _outcome(proposal.providerCallId),
            );

        await fixture.execution.start();

        expect(fixture.host.state, RunState.completed);
        expect(fixture.host.proposals, hasLength(3));
        expect(fixture.host.requests, hasLength(2));
        final List<SemanticModelInputItem> results = fixture
            .host
            .requests
            .last
            .input
            .skip(7)
            .toList();
        expect(results, <Matcher>[
          isA<SemanticToolOutcomeInput>(),
          same(failure),
          isA<SemanticToolOutcomeInput>(),
        ]);
        expect(failure.failure.providerCallId, 'call-2');
        expect(fixture.outcomes.map((item) => item.providerCallId), <String>[
          'call-1',
          'call-3',
        ]);
      },
    );
  }

  for (final ToolOutcomeDisposition disposition
      in ToolOutcomeDisposition.values) {
    test(
      'semantic tool outcome $disposition does not abort the batch',
      () async {
        final _Fixture fixture = _Fixture();
        final SemanticToolOutcomeInput outcome = _outcome(
          'call-2',
          disposition: disposition,
          failureKind: disposition == ToolOutcomeDisposition.failure
              ? ToolFailureKind.domain
              : null,
        );
        fixture.host.onProposal = (tools, proposal) async =>
            StrategyToolContinuation(
              proposal.providerCallId == 'call-2'
                  ? outcome
                  : _outcome(proposal.providerCallId),
            );

        await fixture.execution.start();

        expect(fixture.host.state, RunState.completed);
        expect(fixture.host.requests, hasLength(2));
        expect(fixture.host.proposals, hasLength(3));
        expect(fixture.outcomes[1], same(outcome));
        expect(fixture.outcomes.last.providerCallId, 'call-3');
        expect(
          fixture.host.timeline.where((event) => event.startsWith('resolve-')),
          isEmpty,
        );
        expect(fixture.host.failure, isNull);
      },
    );
  }

  for (final EffectCertainty certainty in <EffectCertainty>[
    EffectCertainty.knownNotOccurred,
    EffectCertainty.uncertain,
  ]) {
    test(
      'host infrastructure failure with $certainty continues unchanged',
      () async {
        final _Fixture fixture = _Fixture();
        final StateError cause = StateError('Tool execution failed.');
        final SemanticToolOutcomeInput result = SemanticToolOutcomeInput(
          providerCallId: 'call-2',
          outcome: ToolOutcome(
            disposition: ToolOutcomeDisposition.failure,
            failureKind: ToolFailureKind.infrastructure,
            effectCertainty: certainty,
            modelContent:
                'Tool execution failed without a valid terminal result.',
            hostDiagnostic: 'Host-only diagnostic.',
            hostData: const <String, Object?>{'retained': true},
            cause: cause,
          ),
        );
        fixture.host.onProposal = (tools, proposal) async =>
            StrategyToolContinuation(
              proposal.providerCallId == 'call-2'
                  ? result
                  : _outcome(proposal.providerCallId),
            );

        await fixture.execution.start();

        expect(fixture.host.state, RunState.completed);
        expect(fixture.outcomes[1], same(result));
        expect(fixture.outcomes[1].outcome.cause, same(cause));
        expect(fixture.outcomes.last.providerCallId, 'call-3');
      },
    );
  }

  for (final bool approved in <bool>[true, false]) {
    test(
      '${approved ? 'approval' : 'rejection'} drains remainder before inference',
      () async {
        final _Fixture fixture = _Fixture();
        fixture.host.waitingCalls.add('call-2');

        await fixture.execution.start();

        expect(fixture.host.state, RunState.waiting);
        expect(fixture.host.proposals, hasLength(2));
        expect(fixture.host.requests, hasLength(1));
        expect(fixture.state.snapshot().entries, hasLength(1));
        final SemanticToolOutcomeInput result = _outcome(
          'call-2',
          disposition: approved
              ? ToolOutcomeDisposition.success
              : ToolOutcomeDisposition.userRejected,
        );
        fixture.host.onApproval = (resolution) async {
          expect(resolution.approved, approved);
          return result;
        };
        await fixture.execution.resolveApproval(
          fixture.host.approval(approved),
        );

        expect(fixture.host.state, RunState.completed);
        expect(fixture.host.proposals, hasLength(3));
        expect(fixture.host.requests, hasLength(2));
        expect(
          fixture.host.snapshots,
          everyElement(same(fixture.host.turns.first.tools)),
        );
        expect(fixture.outcomes.map((item) => item.providerCallId), <String>[
          'call-1',
          'call-2',
          'call-3',
        ]);
        expect(fixture.outcomes[1], same(result));
        expect(
          fixture.host.timeline.indexOf('resolved-call-2'),
          lessThan(fixture.host.timeline.indexOf('proposal-call-3')),
        );
        expect(
          fixture.host.timeline.indexOf('result-call-3'),
          lessThan(fixture.host.timeline.indexOf('model-2')),
        );
      },
    );
  }

  test('approval of one proposal does not approve a later proposal', () async {
    final _Fixture fixture = _Fixture();
    fixture.host.waitingCalls.addAll(<String>['call-2', 'call-3']);
    await fixture.execution.start();
    final ToolApprovalResolution first = fixture.host.approval(true);
    await fixture.execution.resolveApproval(first);

    expect(fixture.host.state, RunState.waiting);
    expect(fixture.host.proposals, hasLength(3));
    expect(fixture.host.requests, hasLength(1));
    await expectLater(
      fixture.execution.resolveApproval(first),
      throwsA(isA<InvalidRunOperation>()),
    );
    expect(fixture.host.state, RunState.waiting);
    await fixture.execution.resolveApproval(fixture.host.approval(false));

    expect(fixture.host.state, RunState.completed);
    expect(
      fixture.outcomes.last.outcome.disposition,
      ToolOutcomeDisposition.userRejected,
    );
    expect(fixture.outcomes, hasLength(3));
  });

  test(
    'stale approved outcome and later proposal failure retain the batch',
    () async {
      final _Fixture fixture = _Fixture();
      fixture.host.waitingCalls.add('call-2');
      await fixture.execution.start();
      final SemanticToolOutcomeInput stale = _outcome(
        'call-2',
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.staleBinding,
        effectCertainty: EffectCertainty.knownNotOccurred,
      );
      final SemanticToolProposalFailureInput failure = _proposalFailure(
        'call-3',
        ToolProposalFailureKind.staleBinding,
      );
      fixture.host.onApproval = (resolution) async => stale;
      fixture.host.onProposal = (tools, proposal) async =>
          StrategyToolContinuation(failure);

      await fixture.execution.resolveApproval(fixture.host.approval(true));

      expect(fixture.host.state, RunState.completed);
      expect(fixture.outcomes.last, same(stale));
      expect(fixture.host.requests.last.input.last, same(failure));
      expect(fixture.host.proposals.last.providerCallId, 'call-3');
    },
  );

  for (final bool wrongInterruption in <bool>[true, false]) {
    test(
      'invalid ${wrongInterruption ? 'interruption' : 'tool'} identity does not lose pending approval',
      () async {
        final _Fixture fixture = _Fixture();
        fixture.host.waitingCalls.add('call-2');
        await fixture.execution.start();
        final ToolApprovalResolution valid = fixture.host.approval(true);
        final ToolApprovalResolution invalid = ToolApprovalResolution(
          interruptionId: wrongInterruption
              ? RunInterruptionId('wrong')
              : valid.interruptionId,
          toolInvocationId: wrongInterruption
              ? valid.toolInvocationId
              : ToolInvocationId('wrong'),
          approved: true,
        );

        await expectLater(
          fixture.execution.resolveApproval(invalid),
          throwsA(isA<InvalidRunOperation>()),
        );

        expect(fixture.host.state, RunState.waiting);
        expect(fixture.host.failure, isNull);
        expect(fixture.host.proposals, hasLength(2));
        await fixture.execution.resolveApproval(valid);
        expect(fixture.host.state, RunState.completed);
        expect(fixture.outcomes, hasLength(3));
      },
    );
  }

  test(
    'last proposal can pause and resume directly into model continuation',
    () async {
      final _Fixture fixture = _Fixture();
      fixture.host.waitingCalls.add('call-3');
      await fixture.execution.start();
      expect(fixture.host.requests, hasLength(1));

      await fixture.execution.resolveApproval(fixture.host.approval(true));

      expect(fixture.host.state, RunState.completed);
      expect(fixture.host.proposals, hasLength(3));
      expect(fixture.outcomes, hasLength(3));
    },
  );

  test(
    'final permitted invocation cannot process any proposal in a batch',
    () async {
      final _Fixture fixture = _Fixture(maxModelInvocations: 1);

      await fixture.execution.start();

      expect(fixture.host.state, RunState.failed);
      expect(
        fixture.host.failure,
        isA<ModelInvocationLimitExceeded>().having(
          (error) => error.maximum,
          'maximum',
          1,
        ),
      );
      expect(fixture.host.requests, hasLength(1));
      expect(fixture.host.proposals, isEmpty);
      expect(fixture.state.snapshot().entries, hasLength(1));
    },
  );

  test(
    'model budget fails accidental loop before the last batch executes',
    () async {
      final _Fixture fixture = _Fixture(
        maxModelInvocations: 2,
        turns: <StrategyModelTurn>[_batchTurn(proposalCount: 1), _batchTurn()],
      );

      await fixture.execution.start();

      expect(fixture.host.state, RunState.failed);
      expect(
        fixture.host.failure,
        isA<ModelInvocationLimitExceeded>().having(
          (error) => error.maximum,
          'maximum',
          2,
        ),
      );
      expect(fixture.host.requests, hasLength(2));
      expect(fixture.host.proposals, hasLength(1));
      expect(
        fixture.host.failure.toString(),
        'ModelInvocationLimitExceeded: Run exceeded 2 model invocations.',
      );
    },
  );

  test(
    'instructions and budget are captured at materialization, not start',
    () async {
      final _Fixture fixture = _Fixture(
        instructions: 'Use source tools before answering.',
        maxModelInvocations: 2,
        turns: <StrategyModelTurn>[_batchTurn(proposalCount: 1), _batchTurn()],
      );
      fixture.state
        ..instructions = 'Changed after materialization.'
        ..maxModelInvocations = 1;
      fixture.host.onProposal = (tools, proposal) async {
        fixture.state
          ..instructions = 'Changed during execution.'
          ..maxModelInvocations = 20;
        return StrategyToolContinuation(_outcome(proposal.providerCallId));
      };

      await fixture.execution.start();

      expect(fixture.host.requests, hasLength(2));
      expect(
        fixture.host.requests.map((request) => request.instructions),
        everyElement('Use source tools before answering.'),
      );
      expect(
        fixture.host.failure,
        isA<ModelInvocationLimitExceeded>().having(
          (error) => error.maximum,
          'maximum',
          2,
        ),
      );
      expect(fixture.host.proposals, hasLength(1));
    },
  );

  test(
    'two Runs share canonical Session history but never private Run items',
    () async {
      final _Fixture fixture = _Fixture(maxModelInvocations: 2);
      await fixture.execution.start();
      final ChatSessionSnapshot afterFirst = fixture.state.snapshot();
      fixture.plugin.sessions.obtain(SessionId(fixture.session.id.value))
        ..append(ChatUserMessage('Now explain.'))
        ..instructions = 'Second Run instructions.'
        ..maxModelInvocations = 2;
      final _Host secondHost = _Host(
        RunId('run-2'),
        fixture.session.id,
        <StrategyModelTurn>[
          _batchTurn(proposalCount: 1),
          _finalTurn(text: 'Explained.'),
        ],
      );
      final OrchestrationExecution second = fixture.resolver
          .resolve(fixture.session.strategyId)
          .materialize(
            OrchestrationStrategyHostContext(
              session: fixture.session,
              host: secondHost,
            ),
          );

      await second.start();

      expect(fixture.host.id, isNot(secondHost.id));
      expect(secondHost.sessionId, fixture.host.sessionId);
      expect(secondHost.state, RunState.completed);
      expect(
        secondHost.requests.first.instructions,
        'Second Run instructions.',
      );
      final List<SemanticMessageInput> messages = secondHost
          .requests
          .first
          .input
          .cast<SemanticMessageInput>();
      expect(messages.map((item) => item.role), <SemanticMessageRole>[
        SemanticMessageRole.user,
        SemanticMessageRole.assistant,
        SemanticMessageRole.user,
      ]);
      expect(messages.map((item) => item.content), <String>[
        'Perform steps.',
        'Complete.',
        'Now explain.',
      ]);
      expect(secondHost.requests.first.input, hasLength(3));
      expect(
        secondHost.requests.last.input.whereType<SemanticToolOutcomeInput>(),
        hasLength(1),
      );
      expect(
        secondHost.requests.last.input.whereType<SemanticToolProposalInput>(),
        hasLength(1),
      );
      expect(afterFirst.entries.map((entry) => entry.content), <String>[
        'Perform steps.',
        'Complete.',
      ]);
      expect(
        fixture.state.snapshot().entries.map((entry) => entry.content),
        <String>['Perform steps.', 'Complete.', 'Now explain.', 'Explained.'],
      );
      expect(
        fixture.state.snapshot().entries.map((entry) => entry.runtimeType),
        <Type>[
          ChatUserMessage,
          ChatAssistantMessage,
          ChatUserMessage,
          ChatAssistantMessage,
        ],
      );
    },
  );

  test(
    'resume without pending approval and repeated start preserve lifecycle',
    () async {
      final _Fixture fixture = _Fixture(
        turns: <StrategyModelTurn>[_finalTurn()],
      );
      final ToolApprovalResolution unrelated = _approval('unrelated', true);

      await expectLater(
        fixture.execution.resolveApproval(unrelated),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.host.state, RunState.created);
      await fixture.execution.start();
      await expectLater(
        fixture.execution.start(),
        throwsA(isA<InvalidRunOperation>()),
      );
      await expectLater(
        fixture.execution.resolveApproval(unrelated),
        throwsA(isA<InvalidRunOperation>()),
      );

      expect(fixture.host.state, RunState.completed);
      expect(fixture.host.requests, hasLength(1));
      expect(fixture.state.snapshot().entries, hasLength(2));
      expect(fixture.host.failure, isNull);
    },
  );

  for (final String phase in <String>['model', 'proposal', 'approval']) {
    test(
      'reentrant start and resume are rejected during $phase advancement',
      () async {
        final _Fixture fixture = _Fixture();
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        Future<void> running;
        ToolApprovalResolution resolution = _approval('call-1', true);
        if (phase == 'model') {
          fixture.host.onModel = (material) async {
            entered.complete();
            await release.future;
            return _finalTurn();
          };
          running = fixture.execution.start();
        } else if (phase == 'proposal') {
          fixture.host.onProposal = (tools, proposal) async {
            if (proposal.providerCallId == 'call-1') {
              entered.complete();
              await release.future;
            }
            return StrategyToolContinuation(_outcome(proposal.providerCallId));
          };
          running = fixture.execution.start();
        } else {
          fixture.host.waitingCalls.add('call-1');
          await fixture.execution.start();
          resolution = fixture.host.approval(true);
          fixture.host.onApproval = (resolution) async {
            entered.complete();
            await release.future;
            return _outcome('call-1');
          };
          running = fixture.execution.resolveApproval(resolution);
        }
        await entered.future;
        final int hostCalls = fixture.host.timeline.length;

        await expectLater(
          fixture.execution.start(),
          throwsA(isA<InvalidRunOperation>()),
        );
        await expectLater(
          fixture.execution.resolveApproval(resolution),
          throwsA(isA<InvalidRunOperation>()),
        );

        expect(fixture.host.timeline, hasLength(hostCalls));
        expect(fixture.host.failure, isNull);
        release.complete();
        await running;
        expect(fixture.host.state, RunState.completed);
      },
    );
  }

  test(
    'start while waiting and duplicate resolution do not restart a batch',
    () async {
      final _Fixture fixture = _Fixture();
      fixture.host.waitingCalls.add('call-2');
      await fixture.execution.start();
      final ToolApprovalResolution resolution = fixture.host.approval(true);

      await expectLater(
        fixture.execution.start(),
        throwsA(isA<InvalidRunOperation>()),
      );
      expect(fixture.host.state, RunState.waiting);
      await fixture.execution.resolveApproval(resolution);
      await expectLater(
        fixture.execution.resolveApproval(resolution),
        throwsA(isA<InvalidRunOperation>()),
      );

      expect(fixture.host.proposals, hasLength(3));
      expect(fixture.outcomes, hasLength(3));
      expect(fixture.host.requests, hasLength(2));
      expect(fixture.host.state, RunState.completed);
    },
  );

  for (final String phase in <String>['model', 'proposal', 'approval']) {
    test(
      'unexpected host $phase error fails active Run and is rethrown',
      () async {
        final _Fixture fixture = _Fixture();
        final StateError failure = StateError('Host $phase failed.');
        late final Future<void> operation;
        if (phase == 'model') {
          fixture.host.onModel = (material) async => throw failure;
          operation = fixture.execution.start();
        } else if (phase == 'proposal') {
          fixture.host.onProposal = (tools, proposal) async => throw failure;
          operation = fixture.execution.start();
        } else {
          fixture.host.waitingCalls.add('call-1');
          await fixture.execution.start();
          fixture.host.onApproval = (resolution) async => throw failure;
          operation = fixture.execution.resolveApproval(
            fixture.host.approval(true),
          );
        }

        await expectLater(operation, throwsA(same(failure)));

        expect(fixture.host.state, RunState.failed);
        expect(fixture.host.failure, same(failure));
        expect(
          fixture.host.timeline.where((event) => event == 'fail'),
          hasLength(1),
        );
        expect(fixture.host.requests, hasLength(1));
        expect(fixture.state.snapshot().entries, hasLength(1));
      },
    );
  }

  test(
    'InvalidRunOperation from host is rethrown without failing the Run',
    () async {
      final _Fixture fixture = _Fixture();
      const InvalidRunOperation invalid = InvalidRunOperation(
        'Host cannot advance.',
      );
      fixture.host.onModel = (material) async => throw invalid;

      await expectLater(fixture.execution.start(), throwsA(same(invalid)));

      expect(fixture.host.state, RunState.running);
      expect(fixture.host.failure, isNull);
    },
  );

  for (final RunState state in <RunState>[
    RunState.completed,
    RunState.failed,
    RunState.cancelled,
  ]) {
    test(
      'error after host becomes $state does not fail a terminal Run again',
      () async {
        final _Fixture fixture = _Fixture();
        final StateError failure = StateError('Host stopped.');
        fixture.host.onModel = (material) async {
          fixture.host.state = state;
          throw failure;
        };

        await expectLater(fixture.execution.start(), throwsA(same(failure)));

        expect(fixture.host.state, state);
        expect(fixture.host.timeline, isNot(contains('fail')));
        expect(fixture.state.snapshot().entries, hasLength(1));
      },
    );
  }
}

final class _Fixture {
  _Fixture({
    List<StrategyModelTurn>? turns,
    int maxModelInvocations = 8,
    String instructions = '',
  }) {
    state = plugin.sessions.obtain(session.id)
      ..instructions = instructions
      ..maxModelInvocations = maxModelInvocations
      ..append(ChatUserMessage('Perform steps.'));
    host = _Host(
      RunId('run-1'),
      session.id,
      turns ?? <StrategyModelTurn>[_batchTurn(), _finalTurn()],
    );
    registration = plugin.activate(registry);
    addTearDown(registration.close);
    resolver = OrchestrationStrategyResolver(registry);
    resolved = resolver.resolve(session.strategyId);
    execution = resolved.materialize(context);
    // Execution assertions exclude the resolver's materialization validation.
    host.timeline.clear();
  }

  final ChatStrategyPlugin plugin = ChatStrategyPlugin();
  final ExtensionRegistry registry = ExtensionRegistry();
  final Session session = Session(
    id: SessionId('session-1'),
    taskId: TaskId('task-1'),
    strategyId: chatStrategyId,
  );
  late final ChatSessionState state;
  late final _Host host;
  late final ExtensionRegistration registration;
  late final OrchestrationStrategyResolver resolver;
  late final ResolvedOrchestrationStrategy resolved;
  late final OrchestrationExecution execution;

  OrchestrationStrategyHostContext get context =>
      OrchestrationStrategyHostContext(session: session, host: host);

  List<SemanticToolOutcomeInput> get outcomes =>
      host.requests.last.input.whereType<SemanticToolOutcomeInput>().toList();
}

/// Scripts semantic host responses only, not tools, policy, or kernel evidence.
final class _Host implements OrchestrationExecutionHost {
  _Host(this.id, this.sessionId, this.turns);

  @override
  final RunId id;
  @override
  final SessionId sessionId;
  @override
  RunState state = RunState.created;
  final List<StrategyModelTurn> turns;
  final List<StrategyInferenceMaterial> requests =
      <StrategyInferenceMaterial>[];
  final List<ProviderToolProposal> proposals = <ProviderToolProposal>[];
  final List<StrategyToolSnapshot> snapshots = <StrategyToolSnapshot>[];
  final List<String> timeline = <String>[];
  final Set<String> waitingCalls = <String>{};
  Object? failure;
  String? _pendingCall;
  void Function()? onValidate;
  void Function()? onComplete;
  Future<StrategyModelTurn> Function(StrategyInferenceMaterial)? onModel;
  Future<StrategyToolResult> Function(
    StrategyToolSnapshot,
    ProviderToolProposal,
  )?
  onProposal;
  Future<SemanticToolOutcomeInput> Function(ToolApprovalResolution)? onApproval;

  @override
  void validateBinding() {
    timeline.add('validate');
    onValidate?.call();
  }

  @override
  void start() {
    _requireState(RunState.created);
    timeline.add('start');
    state = RunState.running;
  }

  @override
  void complete() {
    _requireState(RunState.running);
    timeline.add('complete');
    onComplete?.call();
    state = RunState.completed;
  }

  @override
  void fail(Object error) {
    expect(state, anyOf(RunState.running, RunState.waiting));
    timeline.add('fail');
    failure = error;
    state = RunState.failed;
  }

  @override
  Future<StrategyModelTurn> invokeModel(
    StrategyInferenceMaterial material,
  ) async {
    _requireState(RunState.running);
    requests.add(material);
    timeline.add('model-${requests.length}');
    return onModel == null
        ? turns[requests.length - 1]
        : await onModel!(material);
  }

  @override
  Future<StrategyToolResult> processProposal({
    required StrategyToolSnapshot tools,
    required ProviderToolProposal proposal,
  }) async {
    _requireState(RunState.running);
    proposals.add(proposal);
    snapshots.add(tools);
    final String callId = proposal.providerCallId;
    timeline.add('proposal-$callId');
    final StrategyToolResult result = onProposal != null
        ? await onProposal!(tools, proposal)
        : waitingCalls.contains(callId)
        ? const StrategyToolWaiting()
        : StrategyToolContinuation(_outcome(callId));
    if (result is StrategyToolWaiting) {
      _pendingCall = callId;
      state = RunState.waiting;
    } else {
      timeline.add('result-$callId');
    }
    return result;
  }

  ToolApprovalResolution approval(bool approved) =>
      _approval(_pendingCall!, approved);

  @override
  Future<SemanticToolOutcomeInput> resolveApproval(
    ToolApprovalResolution resolution,
  ) async {
    _requireState(RunState.waiting);
    final String callId = _pendingCall!;
    final ToolApprovalResolution expected = approval(resolution.approved);
    if (resolution.interruptionId != expected.interruptionId ||
        resolution.toolInvocationId != expected.toolInvocationId) {
      throw const InvalidRunOperation(
        'Resolution does not match the pending approval.',
      );
    }
    timeline.add('resolve-$callId');
    final SemanticToolOutcomeInput outcome = onApproval != null
        ? await onApproval!(resolution)
        : _outcome(
            callId,
            disposition: resolution.approved
                ? ToolOutcomeDisposition.success
                : ToolOutcomeDisposition.userRejected,
          );
    _pendingCall = null;
    state = RunState.running;
    timeline.add('resolved-$callId');
    return outcome;
  }

  void _requireState(RunState expected) {
    if (state != expected) {
      throw InvalidRunOperation('Expected $expected, got $state.');
    }
  }
}

final class _Tools implements StrategyToolSnapshot {}

StrategyModelTurn _finalTurn({
  String text = 'Complete.',
  Iterable<ModelOutputItem>? output,
  ModelSettlement settlement = ModelSettlement.completed,
}) => StrategyModelTurn.settled(
  tools: _Tools(),
  output: output ?? <ModelOutputItem>[ModelTextOutput(text)],
  settlement: settlement,
);

StrategyModelTurn _batchTurn({
  int proposalCount = 3,
  ModelSettlement settlement = ModelSettlement.completed,
  ModelIncompleteReason? incompleteReason,
  ModelTerminalMetadata? metadata,
}) {
  final ModelNativeEnvelope native = _metadata();
  return StrategyModelTurn.settled(
    tools: _Tools(),
    output: <ModelOutputItem>[
      for (int step = 1; step <= proposalCount; step++) ...<ModelOutputItem>[
        if (step == 1 || step == 3)
          ModelNativeOutput(
            providerItemId: 'native-$step',
            providerNativeMetadata: native,
          ),
        ModelToolProposalOutput(
          ProviderToolProposal(
            providerCallId: 'call-$step',
            alias: 'step_$step',
            arguments: <String, Object?>{'step': step},
          ),
          providerItemId: 'item-$step',
          providerNativeMetadata: native,
        ),
        if (step == 1)
          ModelTextOutput(
            'Between proposals.',
            providerItemId: 'text-1',
            providerNativeMetadata: native,
          ),
      ],
    ],
    settlement: settlement,
    incompleteReason: incompleteReason,
    metadata: metadata,
  );
}

ModelNativeEnvelope _metadata() => ModelNativeEnvelope(
  kind: 'fixture',
  compatibility: const <String, Object?>{},
  data: const <String, Object?>{'retained': true},
);

SemanticToolOutcomeInput _outcome(
  String callId, {
  ToolOutcomeDisposition disposition = ToolOutcomeDisposition.success,
  ToolFailureKind? failureKind,
  EffectCertainty effectCertainty = EffectCertainty.knownOccurred,
}) => SemanticToolOutcomeInput(
  providerCallId: callId,
  outcome: ToolOutcome(
    disposition: disposition,
    failureKind: failureKind,
    effectCertainty: effectCertainty,
    modelContent: 'Handled $callId.',
  ),
);

SemanticToolProposalFailureInput _proposalFailure(
  String callId,
  ToolProposalFailureKind kind,
) => SemanticToolProposalFailureInput(
  failure: ToolProposalFailure(
    kind: kind,
    providerCallId: callId,
    alias: 'step_${callId.split('-').last}',
    message: 'Proposal could not be resolved.',
  ),
);

ToolApprovalResolution _approval(String callId, bool approved) =>
    ToolApprovalResolution(
      interruptionId: RunInterruptionId('approval-$callId'),
      toolInvocationId: ToolInvocationId('tool-$callId'),
      approved: approved,
    );
