import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('Session history remains canonical and separate from Run execution', () {
    final _MemorySession session = _MemorySession(SessionId('session-1'))
      ..append(UserSessionMessage('Inspect the resource.'));
    final AgentRun run = AgentRun(id: RunId('run-1'), sessionId: session.id)
      ..start();

    run.record(ModelInvocationStarted(ModelInvocationId('model-1')));
    run.record(
      ModelOutputObserved(
        invocationId: ModelInvocationId('model-1'),
        item: ModelTextOutput('Working.'),
      ),
    );

    expect(run.sessionId, session.id);
    expect(session.snapshot().entries, hasLength(1));
    expect(session.snapshot().entries.single, isA<UserSessionMessage>());
    expect(run.journal.records, hasLength(3));

    session.append(AssistantSessionMessage('Inspection complete.'));
    expect(session.snapshot().entries, <Matcher>[
      isA<UserSessionMessage>(),
      isA<AssistantSessionMessage>(),
    ]);
  });

  test('context assembly projects Session plus current execution context', () {
    final _MemorySession session = _MemorySession(SessionId('session-1'))
      ..append(UserSessionMessage('Inspect the resource.'))
      ..append(AssistantSessionMessage('I will inspect it.'));
    final ToolOutcome outcome = ToolOutcome(
      disposition: ToolOutcomeDisposition.success,
      effectCertainty: EffectCertainty.knownOccurred,
      modelContent: 'Resource summary.',
      hostData: const <String, Object?>{'resource': 'file:///tmp/example.dart'},
    );
    final ContextAssemblyInput input = ContextAssemblyInput(
      invocationId: ModelInvocationId('model-2'),
      session: session.snapshot(),
      runItems: <SemanticModelInputItem>[
        SemanticToolOutcomeInput(
          providerCallId: 'provider-1',
          outcome: outcome,
        ),
      ],
      tools: MaterializedToolSet(const <MaterializedTool>[]),
    );

    final SemanticModelRequest request = const _TestContextAssembler().assemble(
      input,
    );

    expect(request, isNot(same(input.session)));
    expect(request.invocationId, input.invocationId);
    expect(request.input, hasLength(3));
    expect(
      (request.input.first as SemanticMessageInput).role,
      SemanticMessageRole.user,
    );
    expect(request.input.last, isA<SemanticToolOutcomeInput>());
    expect(session.snapshot().entries, hasLength(2));
  });
}

final class _MemorySession implements SessionHistoryPort {
  _MemorySession(this.id);

  @override
  final SessionId id;
  final List<SessionEntry> _entries = <SessionEntry>[];

  @override
  void append(SessionEntry entry) => _entries.add(entry);

  @override
  SessionSnapshot snapshot() => SessionSnapshot(id: id, entries: _entries);
}

final class _TestContextAssembler implements ContextAssembler {
  const _TestContextAssembler();

  @override
  SemanticModelRequest assemble(ContextAssemblyInput input) =>
      SemanticModelRequest(
        invocationId: input.invocationId,
        input: <SemanticModelInputItem>[
          for (final SessionEntry entry in input.session.entries)
            SemanticMessageInput(
              role: switch (entry) {
                UserSessionMessage() => SemanticMessageRole.user,
                AssistantSessionMessage() => SemanticMessageRole.assistant,
              },
              content: entry.content,
            ),
          ...input.runItems,
        ],
        tools: input.tools,
      );
}
