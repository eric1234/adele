import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
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
    expect(events.last, isA<ModelInvocationCompletedEvent>());
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
          ModelInvocationCompletedEvent(invocationId: id),
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
    yield ModelInvocationCompletedEvent(invocationId: request.invocationId);
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
