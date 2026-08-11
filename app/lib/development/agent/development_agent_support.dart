import 'package:agent_kernel/agent_kernel.dart';

final class DevelopmentSessionHistory implements SessionHistoryPort {
  DevelopmentSessionHistory(this.id);

  @override
  final SessionId id;
  final List<SessionEntry> _entries = <SessionEntry>[];

  @override
  void append(SessionEntry entry) => _entries.add(entry);

  @override
  SessionSnapshot snapshot() => SessionSnapshot(id: id, entries: _entries);
}

final class DevelopmentContextAssembler implements ContextAssembler {
  const DevelopmentContextAssembler();

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

final class DevelopmentToolPolicy implements ToolPolicy {
  const DevelopmentToolPolicy(this.decision);

  final ToolPolicyDecision decision;

  @override
  ToolPolicyDecision evaluate(ToolPolicyInput input) => decision;
}
