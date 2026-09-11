import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:test/test.dart';

void main() {
  final ModelNativeEnvelope native = ModelNativeEnvelope(
    kind: 'native-v1',
    compatibility: const <String, Object?>{'model': 'test-v1'},
    data: const <String, Object?>{'cursor': 'opaque'},
  );
  final ProviderToolProposal proposal = ProviderToolProposal(
    providerCallId: 'call-1',
    alias: 'inspect',
    arguments: const <String, Object?>{'path': 'example.dart'},
  );
  final ToolOutcome outcome = ToolOutcome(
    disposition: ToolOutcomeDisposition.success,
    effectCertainty: EffectCertainty.knownOccurred,
    modelContent: 'Inspected.',
  );
  final Object cause = StateError('unavailable');
  final ToolProposalFailure failure = ToolProposalFailure(
    kind: ToolProposalFailureKind.unknownAlias,
    providerCallId: proposal.providerCallId,
    alias: proposal.alias,
    message: 'No such tool.',
    cause: cause,
  );

  test('all semantic input variants are usable through the public barrel', () {
    final List<SemanticModelInputItem> input = <SemanticModelInputItem>[
      SemanticNativeInput(
        providerItemId: 'native-1',
        providerNativeMetadata: native,
      ),
      SemanticMessageInput(
        role: SemanticMessageRole.assistant,
        content: 'Inspecting.',
        providerItemId: 'message-1',
        providerNativeMetadata: native,
      ),
      SemanticToolProposalInput(
        proposal: proposal,
        providerItemId: 'proposal-1',
        providerNativeMetadata: native,
      ),
      SemanticToolProposalFailureInput(failure: failure),
      SemanticToolOutcomeInput(providerCallId: 'call-1', outcome: outcome),
    ];
    final StrategyInferenceMaterial material = StrategyInferenceMaterial(
      input: input,
    );

    expect(material.instructions, '');
    expect(material.input, orderedEquals(input));
    // Exhaustive matching remains available without a kernel dependency.
    expect(
      material.input.map(
        (item) => switch (item) {
          SemanticNativeInput(:final providerNativeMetadata) =>
            providerNativeMetadata,
          SemanticMessageInput(:final content) => content,
          SemanticToolProposalInput(:final proposal) => proposal,
          SemanticToolProposalFailureInput(:final failure) => failure,
          SemanticToolOutcomeInput(:final outcome) => outcome,
        },
      ),
      <Object>[native, 'Inspecting.', proposal, failure, outcome],
    );
    expect(failure.cause, same(cause));
    expect(failure.providerCallId, 'call-1');
    expect(failure.alias, 'inspect');
    expect(failure.message, 'No such tool.');
    input.clear();
    expect(material.input, hasLength(5));
    expect(() => material.input.clear(), throwsUnsupportedError);
    expect(
      () => material.input[0] = material.input.last,
      throwsUnsupportedError,
    );
    expect(
      StrategyInferenceMaterial(
        instructions: 'Inspect the source.',
        input: const <SemanticModelInputItem>[],
      ).instructions,
      'Inspect the source.',
    );
  });

  test('settled turns snapshot ordered output and retain exact tools', () {
    final StrategyToolSnapshot tools = _ToolSnapshot();
    final List<ModelOutputItem> output = <ModelOutputItem>[
      ModelNativeOutput(
        providerItemId: 'native-1',
        providerNativeMetadata: native,
      ),
      ModelTextOutput(
        'Inspecting.',
        providerItemId: 'text-1',
        providerNativeMetadata: native,
      ),
      ModelToolProposalOutput(
        proposal,
        providerItemId: 'proposal-1',
        providerNativeMetadata: native,
      ),
    ];
    final StrategyModelTurn turn = StrategyModelTurn.settled(
      tools: tools,
      output: output,
    );

    expect(turn.tools, same(tools));
    expect(turn.output, orderedEquals(output));
    expect(turn.settlement, ModelSettlement.completed);
    expect(turn.incompleteReason, isNull);
    expect(turn.failure, isNull);
    expect(turn.metadata, isA<ModelTerminalMetadata>());
    expect(
      turn.output.map(
        (item) => switch (item) {
          ModelNativeOutput(:final providerItemId) => providerItemId,
          ModelTextOutput(:final providerItemId) => providerItemId,
          ModelToolProposalOutput(:final providerItemId) => providerItemId,
        },
      ),
      <String>['native-1', 'text-1', 'proposal-1'],
    );
    output.clear();
    expect(turn.output, hasLength(3));
    expect(() => turn.output.clear(), throwsUnsupportedError);
    expect(() => turn.output[0] = turn.output.last, throwsUnsupportedError);
  });

  test('settled turns require an incomplete reason iff incomplete', () {
    final StrategyToolSnapshot tools = _ToolSnapshot();
    final ModelTerminalMetadata metadata = ModelTerminalMetadata(
      effectiveModel: 'test-v1',
      providerResponseId: 'response-1',
      providerRequestId: 'request-1',
      providerStopReason: 'limit',
      usage: ModelUsage(inputTokens: 12, outputTokens: 3),
      providerNativeState: native,
    );
    for (final ModelSettlement settlement in ModelSettlement.values) {
      for (final ModelIncompleteReason? reason in <ModelIncompleteReason?>[
        null,
        ...ModelIncompleteReason.values,
      ]) {
        StrategyModelTurn construct() => StrategyModelTurn.settled(
          tools: tools,
          output: const <ModelOutputItem>[],
          settlement: settlement,
          incompleteReason: reason,
          metadata: metadata,
        );

        if ((settlement == ModelSettlement.incomplete) != (reason != null)) {
          expect(construct, throwsFormatException);
        } else {
          final StrategyModelTurn turn = construct();
          expect(turn.settlement, settlement);
          expect(turn.incompleteReason, reason);
          expect(turn.metadata, same(metadata));
          expect(turn.failure, isNull);
        }
      }
    }
    expect(metadata.usage!.inputTokens, 12);
    expect(metadata.usage!.outputTokens, 3);
    expect(metadata.providerNativeState, same(native));
    expect(metadata.providerResponseId, 'response-1');
    expect(metadata.providerRequestId, 'request-1');
    expect(metadata.providerStopReason, 'limit');
  });

  test('failed turns retain partial output and error without settlement', () {
    final StrategyToolSnapshot tools = _ToolSnapshot();
    final ModelTextOutput item = ModelTextOutput('Partial.');
    final List<ModelOutputItem> output = <ModelOutputItem>[item];
    final StrategyModelTurn turn = StrategyModelTurn.failed(
      tools: tools,
      output: output,
      error: cause,
    );

    output.clear();
    expect(turn.tools, same(tools));
    expect(turn.output.single, same(item));
    expect(turn.failure, same(cause));
    expect(turn.settlement, isNull);
    expect(turn.incompleteReason, isNull);
    expect(turn.metadata, isNull);
    expect(() => turn.output.clear(), throwsUnsupportedError);
  });

  test(
    'tool results expose continuation items or an opaque waiting marker',
    () {
      final SemanticToolProposalFailureInput rejected =
          SemanticToolProposalFailureInput(failure: failure);
      final SemanticToolOutcomeInput completed = SemanticToolOutcomeInput(
        providerCallId: 'call-1',
        outcome: outcome,
      );
      final List<StrategyToolResult> results = <StrategyToolResult>[
        StrategyToolContinuation(rejected),
        StrategyToolContinuation(completed),
        const StrategyToolWaiting(),
      ];

      expect(
        results.map(
          (result) => switch (result) {
            StrategyToolContinuation(:final item) => item,
            StrategyToolWaiting() => null,
          },
        ),
        <SemanticModelInputItem?>[rejected, completed, null],
      );
    },
  );

  test('structured semantic values are deeply snapshotted and immutable', () {
    final List<Object?> nested = <Object?>[true, null, 1, 1.5, 'opaque'];
    final Map<String, Object?> source = <String, Object?>{
      'nested': nested,
      'map': <String, Object?>{'value': 'initial'},
    };
    final ModelNativeEnvelope envelope = ModelNativeEnvelope(
      kind: 'native-v1',
      compatibility: source,
      data: source,
    );
    final ModelUsage usage = ModelUsage(providerDetails: source);
    final ProviderToolProposal proposal = ProviderToolProposal(
      providerCallId: 'call-1',
      alias: 'inspect',
      arguments: source,
    );
    nested.clear();
    (source['map']! as Map<String, Object?>)['value'] = 'changed';
    source.clear();

    for (final Map<String, Object?> snapshot in <Map<String, Object?>>[
      envelope.compatibility,
      envelope.data,
      usage.providerDetails,
      proposal.arguments,
    ]) {
      expect(snapshot['nested'], <Object?>[true, null, 1, 1.5, 'opaque']);
      expect(snapshot['map'], <String, Object?>{'value': 'initial'});
      expect(() => snapshot.clear(), throwsUnsupportedError);
      expect(
        () => (snapshot['nested']! as List<Object?>).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (snapshot['map']! as Map<String, Object?>).clear(),
        throwsUnsupportedError,
      );
    }
  });

  test('semantic validation is preserved on the public boundary', () {
    final List<void Function()> invalid = <void Function()>[
      () => ModelNativeEnvelope(
        kind: ' ',
        compatibility: const <String, Object?>{},
        data: const <String, Object?>{},
      ),
      () => SemanticMessageInput(role: SemanticMessageRole.user, content: ''),
      () => SemanticMessageInput(
        role: SemanticMessageRole.user,
        content: 'text',
        providerItemId: ' ',
      ),
      () => SemanticNativeInput(
        providerNativeMetadata: native,
        providerItemId: ' ',
      ),
      () => SemanticToolProposalInput(proposal: proposal, providerItemId: ' '),
      () => SemanticToolOutcomeInput(providerCallId: ' ', outcome: outcome),
      () => ModelTextOutput(''),
      () => ModelTextOutput('text', providerItemId: ' '),
      () => ModelNativeOutput(
        providerNativeMetadata: native,
        providerItemId: ' ',
      ),
      () => ModelToolProposalOutput(proposal, providerItemId: ' '),
      () => ModelTerminalMetadata(effectiveModel: ' '),
      () => ModelTerminalMetadata(providerResponseId: ' '),
      () => ModelTerminalMetadata(providerRequestId: ' '),
      () => ModelTerminalMetadata(providerStopReason: ' '),
      () => ModelUsage(inputTokens: -1),
      () => ModelUsage(outputTokens: -1),
      () => ModelUsage(cacheReadTokens: -1),
      () => ModelUsage(cacheWriteTokens: -1),
      () => ProviderToolProposal(
        providerCallId: ' ',
        alias: 'inspect',
        arguments: const <String, Object?>{},
      ),
      () => ProviderToolProposal(
        providerCallId: 'call-1',
        alias: ' ',
        arguments: const <String, Object?>{},
      ),
      () => ToolProposalFailure(
        kind: ToolProposalFailureKind.invalidArguments,
        providerCallId: 'call-1',
        alias: 'inspect',
        message: ' ',
      ),
    ];
    for (final void Function() construct in invalid) {
      expect(construct, throwsFormatException);
    }
    expect(ModelTextOutput(' ').content, ' ');
    expect(
      SemanticMessageInput(
        role: SemanticMessageRole.assistant,
        content: ' ',
      ).content,
      ' ',
    );
  });

  test('structured metadata rejects invalid values, cycles and depth', () {
    final Map<String, Object?> cyclic = <String, Object?>{};
    cyclic['self'] = cyclic;
    final Map<String, Object?> deep = <String, Object?>{};
    Map<String, Object?> cursor = deep;
    for (int index = 0; index < 65; index++) {
      final Map<String, Object?> next = <String, Object?>{};
      cursor['next'] = next;
      cursor = next;
    }
    for (final Map<String, Object?> invalid in <Map<String, Object?>>[
      cyclic,
      deep,
      <String, Object?>{'value': double.infinity},
      <String, Object?>{'value': double.nan},
      <String, Object?>{'value': Object()},
    ]) {
      expect(() => ModelUsage(providerDetails: invalid), throwsFormatException);
      expect(
        () => ProviderToolProposal(
          providerCallId: 'call-1',
          alias: 'inspect',
          arguments: invalid,
        ),
        throwsFormatException,
      );
      expect(
        () => ModelNativeEnvelope(
          kind: 'native-v1',
          compatibility: const <String, Object?>{},
          data: invalid,
        ),
        throwsFormatException,
      );
    }
    final Map<String, Object?> shared = <String, Object?>{'value': true};
    expect(
      ModelUsage(
        providerDetails: <String, Object?>{'left': shared, 'right': shared},
      ).providerDetails,
      <String, Object?>{'left': shared, 'right': shared},
    );
  });

  test('proposal arguments reject list and mixed container cycles', () {
    final List<Object?> cyclicList = <Object?>[];
    cyclicList.add(cyclicList);
    final Map<String, Object?> mixed = <String, Object?>{};
    mixed['list'] = <Object?>[mixed];
    for (final Map<String, Object?> arguments in <Map<String, Object?>>[
      <String, Object?>{'list': cyclicList},
      mixed,
    ]) {
      expect(
        () => ProviderToolProposal(
          providerCallId: 'call-1',
          alias: 'inspect',
          arguments: arguments,
        ),
        throwsFormatException,
      );
    }
  });

  test('proposal arguments bound depth without rejecting shared values', () {
    Object? nested = true;
    for (int index = 0; index < 63; index++) {
      nested = <Object?>[nested];
    }
    final Map<String, Object?> arguments = <String, Object?>{
      'left': nested,
      'right': nested,
    };
    final ProviderToolProposal proposal = ProviderToolProposal(
      providerCallId: 'call-1',
      alias: 'inspect',
      arguments: arguments,
    );
    expect(proposal.arguments, arguments);
    expect(
      () => (proposal.arguments['left']! as List<Object?>).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => ProviderToolProposal(
        providerCallId: 'call-1',
        alias: 'inspect',
        arguments: <String, Object?>{
          'nested': <Object?>[nested],
        },
      ),
      throwsFormatException,
    );
  });

  test(
    'public invocation IDs retain validation and nominal value equality',
    () {
      for (final String invalid in <String>['', ' ', ' leading', 'trailing ']) {
        expect(() => ToolInvocationId(invalid), throwsFormatException);
        expect(() => RunInterruptionId(invalid), throwsFormatException);
      }
      final ToolInvocationId toolId = ToolInvocationId('same-id');
      final RunInterruptionId interruptionId = RunInterruptionId('same-id');
      expect(toolId, ToolInvocationId('same-id'));
      expect(toolId.hashCode, ToolInvocationId('same-id').hashCode);
      expect(toolId.toString(), 'same-id');
      expect(toolId, isNot(ToolInvocationId('different')));
      expect(interruptionId, RunInterruptionId('same-id'));
      expect(interruptionId.hashCode, RunInterruptionId('same-id').hashCode);
      expect(interruptionId.toString(), 'same-id');
      expect(interruptionId, isNot(RunInterruptionId('different')));
      expect(toolId, isNot(interruptionId));
    },
  );

  test('approval resolution and Run errors remain public values', () {
    final RunInterruptionId interruptionId = RunInterruptionId('approval-1');
    final ToolInvocationId toolInvocationId = ToolInvocationId('tool-1');
    for (final bool approved in <bool>[false, true]) {
      final RunInterruptionResolution resolution = ToolApprovalResolution(
        interruptionId: interruptionId,
        toolInvocationId: toolInvocationId,
        approved: approved,
      );
      expect(resolution.interruptionId, same(interruptionId));
      expect(
        switch (resolution) {
          ToolApprovalResolution(:final toolInvocationId, :final approved) => (
            toolInvocationId,
            approved,
          ),
        },
        (toolInvocationId, approved),
      );
    }
    const InvalidRunOperation error = InvalidRunOperation('Already advancing.');
    expect(error.message, 'Already advancing.');
    expect(error.toString(), 'InvalidRunOperation: Already advancing.');
    expect(RunState.values, <RunState>[
      RunState.created,
      RunState.running,
      RunState.waiting,
      RunState.completed,
      RunState.failed,
      RunState.cancelled,
    ]);
  });
}

final class _ToolSnapshot implements StrategyToolSnapshot {}
