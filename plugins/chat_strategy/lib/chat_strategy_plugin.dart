/// Stock Chat sequencing over the public orchestration execution host.
library;

import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

final PluginId chatStrategyPluginId = PluginId(
  'dev.adele.plugin.chat-strategy',
);

final OrchestrationStrategyId chatStrategyId = OrchestrationStrategyId(
  'dev.adele.strategy.chat',
);

final class ChatStrategyPlugin {
  ChatStrategyPlugin({ChatSessionStore? sessions})
    : sessions = sessions ?? ChatSessionStore();

  final ChatSessionStore sessions;

  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: orchestrationStrategyContributions,
        id: ExtensionId('dev.adele.plugin.chat-strategy.orchestration'),
        value: OrchestrationStrategyContribution(
          strategyId: chatStrategyId,
          materialize: (OrchestrationStrategyHostContext context) =>
              _ChatExecution(context.host, sessions.obtain(context.session.id)),
        ),
      );
}

/// Retains Chat-owned conversation state by canonical product Session identity.
final class ChatSessionStore {
  final Map<SessionId, ChatSessionState> _sessions =
      <SessionId, ChatSessionState>{};

  ChatSessionState obtain(SessionId id) =>
      _sessions.putIfAbsent(id, () => ChatSessionState(id));
}

final class ChatSessionState {
  ChatSessionState(this.id);

  final SessionId id;
  String instructions = '';
  int _maxModelInvocations = 8;
  final List<ChatEntry> _entries = <ChatEntry>[];

  int get maxModelInvocations => _maxModelInvocations;

  set maxModelInvocations(int value) {
    if (value < 1) {
      throw ArgumentError.value(
        value,
        'maxModelInvocations',
        'Must be positive.',
      );
    }
    _maxModelInvocations = value;
  }

  void append(ChatEntry entry) => _entries.add(entry);

  ChatSessionSnapshot snapshot() =>
      ChatSessionSnapshot(id: id, entries: _entries);
}

sealed class ChatEntry {
  const ChatEntry(this.content);

  final String content;
}

final class ChatUserMessage extends ChatEntry {
  ChatUserMessage(String content) : super(_requireContent(content));
}

final class ChatAssistantMessage extends ChatEntry {
  ChatAssistantMessage(String content) : super(_requireContent(content));
}

final class ChatSessionSnapshot {
  ChatSessionSnapshot({required this.id, required Iterable<ChatEntry> entries})
    : entries = List<ChatEntry>.unmodifiable(entries);

  final SessionId id;
  final List<ChatEntry> entries;
}

String _requireContent(String content) {
  if (content.trim().isEmpty) {
    throw const FormatException('Chat message content must not be empty.');
  }
  return content;
}

final class _ChatExecution implements OrchestrationExecution {
  _ChatExecution(this.host, this.session)
    : instructions = session.instructions,
      maxModelInvocations = session.maxModelInvocations {
    if (host.sessionId != session.id) {
      throw ArgumentError('Run and Session identities must match.');
    }
  }

  final OrchestrationExecutionHost host;
  final ChatSessionState session;
  final String instructions;
  final int maxModelInvocations;
  final List<SemanticModelInputItem> _runItems = <SemanticModelInputItem>[];
  int _nextModelInvocation = 1;
  bool _busy = false;
  bool _pendingApproval = false;
  _ProposalBatch? _pendingBatch;

  @override
  Future<void> start() async {
    await _exclusive(() async {
      host.start();
      await _advanceModel();
    });
  }

  @override
  Future<void> resolveApproval(ToolApprovalResolution resolution) async {
    await _exclusive(() async {
      if (!_pendingApproval) {
        throw const InvalidRunOperation('No tool approval is pending.');
      }
      final SemanticToolOutcomeInput outcome = await host.resolveApproval(
        resolution,
      );
      _pendingApproval = false;
      _runItems.add(outcome);
      await _advanceProposals();
    });
  }

  Future<void> _advanceModel() async {
    if (host.state != RunState.running) return;
    if (_nextModelInvocation > maxModelInvocations) {
      _fail(ModelInvocationLimitExceeded(maxModelInvocations));
      return;
    }
    _nextModelInvocation++;
    final StrategyModelTurn turn = await host.invokeModel(
      StrategyInferenceMaterial(
        instructions: instructions,
        input: <SemanticModelInputItem>[
          for (final ChatEntry entry in session.snapshot().entries)
            SemanticMessageInput(
              role: switch (entry) {
                ChatUserMessage() => SemanticMessageRole.user,
                ChatAssistantMessage() => SemanticMessageRole.assistant,
              },
              content: entry.content,
            ),
          ..._runItems,
        ],
      ),
    );
    final StringBuffer text = StringBuffer();
    final List<ProviderToolProposal> proposals = <ProviderToolProposal>[];
    for (final ModelOutputItem item in turn.output) {
      switch (item) {
        case ModelNativeOutput():
          break;
        case ModelTextOutput(:final content):
          text.write(content);
        case ModelToolProposalOutput(proposal: final value):
          proposals.add(value);
      }
    }
    if (turn.failure != null) {
      _fail(turn.failure!);
      return;
    }
    switch (turn.settlement!) {
      case ModelSettlement.completed:
        break;
      case ModelSettlement.incomplete:
        _fail(
          ModelInvocationIncomplete(
            reason: turn.incompleteReason!,
            metadata: turn.metadata!,
          ),
        );
        return;
      case ModelSettlement.refused:
        if (text.toString().trim().isEmpty) {
          _fail(StateError('The model refused without assistant output.'));
          return;
        }
        host.validateBinding();
        session.append(ChatAssistantMessage(text.toString()));
        host.complete();
        return;
    }
    if (proposals.isEmpty) {
      if (text.toString().trim().isEmpty) {
        _fail(StateError('The model completed without assistant output.'));
        return;
      }
      host.validateBinding();
      session.append(ChatAssistantMessage(text.toString()));
      host.complete();
      return;
    }
    if (_nextModelInvocation > maxModelInvocations) {
      _fail(ModelInvocationLimitExceeded(maxModelInvocations));
      return;
    }
    for (final ModelOutputItem item in turn.output) {
      switch (item) {
        case ModelNativeOutput(
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          _runItems.add(
            SemanticNativeInput(
              providerItemId: providerItemId,
              providerNativeMetadata: providerNativeMetadata,
            ),
          );
        case ModelTextOutput(
          :final content,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          _runItems.add(
            SemanticMessageInput(
              role: SemanticMessageRole.assistant,
              content: content,
              providerItemId: providerItemId,
              providerNativeMetadata: providerNativeMetadata,
            ),
          );
        case ModelToolProposalOutput(
          :final proposal,
          :final providerItemId,
          :final providerNativeMetadata,
        ):
          _runItems.add(
            SemanticToolProposalInput(
              proposal: proposal,
              providerItemId: providerItemId,
              providerNativeMetadata: providerNativeMetadata,
            ),
          );
      }
    }
    _pendingBatch = _ProposalBatch(proposals: proposals, tools: turn.tools);
    await _advanceProposals();
  }

  Future<void> _advanceProposals() async {
    final _ProposalBatch batch = _pendingBatch!;
    // Drain in proposal order, retaining this exact tool generation across asks.
    // Multiple model proposals do not imply concurrent host execution.
    while (host.state == RunState.running &&
        batch.nextProposal < batch.proposals.length) {
      final StrategyToolResult result = await host.processProposal(
        tools: batch.tools,
        proposal: batch.proposals[batch.nextProposal++],
      );
      switch (result) {
        case StrategyToolContinuation(:final item):
          _runItems.add(item);
        case StrategyToolWaiting():
          _pendingApproval = true;
          return;
      }
    }
    if (host.state != RunState.running) return;
    _pendingBatch = null;
    await _advanceModel();
  }

  void _fail(Object error) {
    if (host.state == RunState.running || host.state == RunState.waiting) {
      host.fail(error);
    }
  }

  Future<void> _exclusive(Future<void> Function() operation) async {
    if (_busy) {
      throw const InvalidRunOperation(
        'The Chat strategy is already advancing this Run.',
      );
    }
    _busy = true;
    try {
      await operation();
    } on InvalidRunOperation {
      rethrow;
    } on Object catch (error, stackTrace) {
      _fail(error);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _busy = false;
    }
  }
}

final class _ProposalBatch {
  _ProposalBatch({required this.proposals, required this.tools});

  final List<ProviderToolProposal> proposals;
  final StrategyToolSnapshot tools;
  int nextProposal = 0;
}

final class ModelInvocationIncomplete implements Exception {
  const ModelInvocationIncomplete({
    required this.reason,
    required this.metadata,
  });

  final ModelIncompleteReason reason;
  final ModelTerminalMetadata metadata;
}

final class ModelInvocationLimitExceeded implements Exception {
  const ModelInvocationLimitExceeded(this.maximum);

  final int maximum;

  @override
  String toString() =>
      'ModelInvocationLimitExceeded: Run exceeded $maximum model invocations.';
}
