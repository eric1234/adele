import 'package:adele_orchestration/adele_orchestration.dart' as orchestration;
import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('kernel reexports the public semantic definitions without copies', () {
    expect(
      <Type>[
        SemanticMessageRole,
        ModelNativeEnvelope,
        SemanticModelInputItem,
        SemanticNativeInput,
        SemanticMessageInput,
        SemanticToolOutcomeInput,
        SemanticToolProposalInput,
        SemanticToolProposalFailureInput,
        ModelOutputItem,
        ModelNativeOutput,
        ModelTextOutput,
        ModelToolProposalOutput,
        ModelSettlement,
        ModelIncompleteReason,
        ModelTerminalMetadata,
        ModelUsage,
        ProviderToolProposal,
        ToolProposalFailure,
        ToolProposalFailureKind,
        ToolInvocationId,
        RunInterruptionId,
        RunState,
        InvalidRunOperation,
        RunInterruptionResolution,
        ToolApprovalResolution,
      ],
      <Type>[
        orchestration.SemanticMessageRole,
        orchestration.ModelNativeEnvelope,
        orchestration.SemanticModelInputItem,
        orchestration.SemanticNativeInput,
        orchestration.SemanticMessageInput,
        orchestration.SemanticToolOutcomeInput,
        orchestration.SemanticToolProposalInput,
        orchestration.SemanticToolProposalFailureInput,
        orchestration.ModelOutputItem,
        orchestration.ModelNativeOutput,
        orchestration.ModelTextOutput,
        orchestration.ModelToolProposalOutput,
        orchestration.ModelSettlement,
        orchestration.ModelIncompleteReason,
        orchestration.ModelTerminalMetadata,
        orchestration.ModelUsage,
        orchestration.ProviderToolProposal,
        orchestration.ToolProposalFailure,
        orchestration.ToolProposalFailureKind,
        orchestration.ToolInvocationId,
        orchestration.RunInterruptionId,
        orchestration.RunState,
        orchestration.InvalidRunOperation,
        orchestration.RunInterruptionResolution,
        orchestration.ToolApprovalResolution,
      ],
    );
  });

  test('semantic requests snapshot input and retain exact kernel tools', () {
    final orchestration.SemanticMessageInput item =
        orchestration.SemanticMessageInput(
          role: orchestration.SemanticMessageRole.user,
          content: 'Inspect.',
        );
    final List<SemanticModelInputItem> input = <SemanticModelInputItem>[item];
    final MaterializedToolSet tools = MaterializedToolSet(
      const <MaterializedTool>[],
    );
    final ModelInvocationId invocationId = ModelInvocationId('model-request');
    final SemanticModelRequest request = SemanticModelRequest(
      invocationId: invocationId,
      input: input,
      tools: tools,
    );

    input.clear();
    expect(request.invocationId, same(invocationId));
    expect(request.instructions, '');
    expect(request.tools, same(tools));
    expect(request.input.single, same(item));
    expect(() => request.input.clear(), throwsUnsupportedError);
    expect(() => request.input[0] = item, throwsUnsupportedError);
    expect(
      SemanticModelRequest(
        invocationId: invocationId,
        instructions: 'Explicit instructions.',
        input: const <SemanticModelInputItem>[],
        tools: tools,
      ).instructions,
      'Explicit instructions.',
    );
  });

  test('model invocation is a typed semantic event stream', () async {
    final SemanticModelRequest request = _request('model-1');
    final List<ModelEvent> events = await const _CompletingModel()
        .invoke(request)
        .toList();

    expect(events, hasLength(3));
    expect(events[0], isA<ModelOutputItemCompleted>());
    expect(
      (events[0] as ModelOutputItemCompleted).item,
      isA<ModelTextOutput>(),
    );
    expect(
      (events[1] as ModelOutputItemCompleted).item,
      isA<ModelToolProposalOutput>(),
    );
    expect(events.last, isA<ModelInvocationSettledEvent>());
    expect(
      events.map((ModelEvent event) => event.invocationId),
      everyElement(request.invocationId),
    );
  });

  test('terminal model failure is an authoritative typed event', () async {
    final List<ModelEvent> events = await const _FailingModel()
        .invoke(_request('model-failure'))
        .toList();

    expect(events, hasLength(1));
    expect(
      events.single,
      isA<ModelInvocationFailedEvent>().having(
        (ModelInvocationFailedEvent event) => event.error,
        'error',
        isA<StateError>(),
      ),
    );
  });

  test('model collection enforces one authoritative terminal event', () async {
    final ModelInvocationId id = ModelInvocationId('model-contract');
    await expectLater(
      collectModelInvocation(
        const Stream<ModelEvent>.empty(),
        invocationId: id,
      ),
      throwsA(isA<ModelInvocationContractException>()),
    );
    await expectLater(
      collectModelInvocation(
        Stream<ModelEvent>.fromIterable(<ModelEvent>[
          ModelInvocationSettledEvent(invocationId: id),
          ModelInvocationFailedEvent(
            invocationId: id,
            error: StateError('late failure'),
          ),
        ]),
        invocationId: id,
      ),
      throwsA(isA<ModelInvocationContractException>()),
    );
  });

  test(
    'observations remain separate from authoritative completed output',
    () async {
      final ModelInvocationId id = ModelInvocationId('observations');
      final ModelInvocationObservation observation =
          await collectModelInvocation(
            Stream<ModelEvent>.fromIterable(<ModelEvent>[
              ModelObservationEvent(
                invocationId: id,
                observation: ModelTextDeltaObservation('Part'),
              ),
              ModelOutputItemCompleted(
                invocationId: id,
                item: ModelTextOutput('Complete'),
              ),
              ModelInvocationSettledEvent(
                invocationId: id,
                metadata: ModelTerminalMetadata(
                  effectiveModel: 'effective-v1',
                  providerNativeState: ModelNativeEnvelope(
                    kind: 'cursor-v1',
                    compatibility: const <String, Object?>{'model': 'v1'},
                    data: const <String, Object?>{'cursor': 'opaque'},
                  ),
                ),
              ),
            ]),
            invocationId: id,
          );

      expect(observation.observations, hasLength(1));
      expect(observation.output, hasLength(1));
      expect(
        (observation.output.single as ModelTextOutput).content,
        'Complete',
      );
      expect(
        (observation.terminal as ModelInvocationSettledEvent)
            .metadata
            .effectiveModel,
        'effective-v1',
      );
    },
  );

  test('provider-native item metadata is retained immutably', () {
    final Map<String, Object?> metadata = <String, Object?>{
      'signed': <Object?>['opaque'],
    };
    final ModelToolProposalOutput output = ModelToolProposalOutput(
      ProviderToolProposal(
        providerCallId: 'call-1',
        alias: 'inspect_resource',
        arguments: const <String, Object?>{},
      ),
      providerItemId: 'item-1',
      providerNativeMetadata: ModelNativeEnvelope(
        kind: 'signed-v1',
        compatibility: const <String, Object?>{'model': 'v1'},
        data: metadata,
      ),
    );
    (metadata['signed']! as List<Object?>).add('changed');
    expect(output.providerItemId, 'item-1');
    expect(output.providerNativeMetadata!.kind, 'signed-v1');
    expect(
      output.providerNativeMetadata!.compatibility,
      const <String, Object?>{'model': 'v1'},
    );
    expect(output.providerNativeMetadata!.data, const <String, Object?>{
      'signed': <Object?>['opaque'],
    });
  });

  test('consecutive native-only outputs remain distinct and ordered', () {
    final List<ModelOutputItem> output = <ModelOutputItem>[
      ModelNativeOutput(
        providerItemId: 'native-1',
        providerNativeMetadata: ModelNativeEnvelope(
          kind: 'first-v1',
          compatibility: const <String, Object?>{'model': 'v1'},
          data: const <String, Object?>{'opaque': 'first'},
        ),
      ),
      ModelNativeOutput(
        providerItemId: 'native-2',
        providerNativeMetadata: ModelNativeEnvelope(
          kind: 'second-v1',
          compatibility: const <String, Object?>{'model': 'v1'},
          data: const <String, Object?>{'opaque': 'second'},
        ),
      ),
    ];

    expect(output.map((item) => item.runtimeType), <Type>[
      ModelNativeOutput,
      ModelNativeOutput,
    ]);
    expect(
      output.map((item) => (item as ModelNativeOutput).providerItemId),
      <String?>['native-1', 'native-2'],
    );
    expect(
      output.map(
        (item) => (item as ModelNativeOutput).providerNativeMetadata.kind,
      ),
      <String>['first-v1', 'second-v1'],
    );
  });

  test('semantic message accepts nonempty whitespace content', () {
    expect(
      SemanticMessageInput(
        role: SemanticMessageRole.assistant,
        content: ' ',
      ).content,
      ' ',
    );
    expect(
      () => SemanticMessageInput(
        role: SemanticMessageRole.assistant,
        content: '',
      ),
      throwsFormatException,
    );
  });

  test('model metadata rejects cycles and excessive depth', () {
    final Map<String, Object?> cyclic = <String, Object?>{};
    cyclic['self'] = cyclic;
    expect(
      () => ModelNativeEnvelope(
        kind: 'native-v1',
        compatibility: cyclic,
        data: const <String, Object?>{},
      ),
      throwsFormatException,
    );
    final Map<String, Object?> deep = <String, Object?>{};
    Map<String, Object?> cursor = deep;
    for (int i = 0; i < 65; i++) {
      final Map<String, Object?> next = <String, Object?>{};
      cursor['next'] = next;
      cursor = next;
    }
    expect(() => ModelUsage(providerDetails: deep), throwsFormatException);
  });

  test('model metadata accepts shared acyclic references', () {
    final Map<String, Object?> shared = <String, Object?>{'value': true};
    final ModelFailure failure = ModelFailure(
      kind: ModelFailureKind.providerFailure,
      providerDetails: <String, Object?>{'left': shared, 'right': shared},
    );
    expect(failure.providerDetails, const <String, Object?>{
      'left': <String, Object?>{'value': true},
      'right': <String, Object?>{'value': true},
    });
  });
}

SemanticModelRequest _request(String id) => SemanticModelRequest(
  invocationId: ModelInvocationId(id),
  input: <SemanticModelInputItem>[
    SemanticMessageInput(role: SemanticMessageRole.user, content: 'Inspect.'),
  ],
  tools: MaterializedToolSet(const <MaterializedTool>[]),
);

final class _CompletingModel implements ModelPort {
  const _CompletingModel();

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelTextOutput('Inspecting.'),
    );
    yield ModelOutputItemCompleted(
      invocationId: request.invocationId,
      item: ModelToolProposalOutput(
        ProviderToolProposal(
          providerCallId: 'provider-1',
          alias: 'inspect_resource',
          arguments: const <String, Object?>{'uri': 'file:///tmp/example.dart'},
        ),
      ),
    );
    yield ModelInvocationSettledEvent(invocationId: request.invocationId);
  }
}

final class _FailingModel implements ModelPort {
  const _FailingModel();

  @override
  Stream<ModelEvent> invoke(SemanticModelRequest request) async* {
    yield ModelInvocationFailedEvent(
      invocationId: request.invocationId,
      error: StateError('provider failed'),
    );
  }
}
