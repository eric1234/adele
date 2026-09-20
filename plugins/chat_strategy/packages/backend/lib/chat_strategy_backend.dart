/// Stock Chat sequencing over the public orchestration execution host.
library;

import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration_backend.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:chat_strategy_contract/chat_strategy_contract.dart';

export 'package:chat_strategy_contract/chat_strategy_contract.dart';

/// Stock Session instructions belong to Chat, not its host or presentation.
const String chatDefaultInstructions =
    'Inspect source with read/search tools as needed. Source mutations and '
    'commands may be proposed when needed, but they require explicit user '
    'approval before execution.';

/// Chat-owned guidance included once in each Run's inference instructions.
const String chatToolNarrationGuidance =
    'When proposing one or more related tool operations, include one brief '
    'user-facing statement describing their shared purpose. Prefer one concise '
    'summary for the related batch rather than narrating each operation '
    'individually. Explicit user instructions take precedence over this guidance.';

final class ChatStrategyPlugin {
  ChatStrategyPlugin({ChatSessionStore? sessions})
    : sessions = sessions ?? ChatSessionStore();

  final ChatSessionStore sessions;

  OrchestrationStrategyContribution get contribution =>
      OrchestrationStrategyContribution(
        strategyId: chatStrategyId,
        materialize: (OrchestrationStrategyHostContext context) =>
            _ChatExecution(context.host, sessions.obtain(context.session.id)),
      );

  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: orchestrationStrategyContributions,
        id: chatStrategyExtensionId,
        value: contribution,
      );
}

/// The callable service and executable strategy share exactly one store.
final class ChatSessionBackend implements ChatSessionService {
  ChatSessionBackend(this.sessions);

  final ChatSessionStore sessions;

  ChatSessionState _session(String id) {
    try {
      return sessions.obtain(SessionId(id));
    } on FormatException {
      throw const ChatSessionFailure(
        code: 'invalid_session',
        message: 'Session identity must be nonempty with no outer whitespace.',
        details: <String, Object?>{},
      );
    }
  }

  @override
  Future<ChatSessionSnapshot> snapshot(String sessionId) async =>
      _session(sessionId).snapshot();

  @override
  Future<ChatEntry> appendUserMessage(String sessionId, String content) async {
    try {
      return _session(sessionId).appendUserMessage(content);
    } on FormatException {
      throw const ChatSessionFailure(
        code: 'invalid_content',
        message: 'Chat message content must not be empty.',
        details: <String, Object?>{},
      );
    }
  }

  @override
  Future<void> configureSession(
    String sessionId,
    String instructions,
    int maxModelInvocations,
  ) async {
    final session = _session(sessionId);
    session._requireIdle();
    try {
      session.maxModelInvocations = maxModelInvocations;
    } on ArgumentError {
      throw const ChatSessionFailure(
        code: 'invalid_configuration',
        message: 'maxModelInvocations must be positive.',
        details: <String, Object?>{},
      );
    }
    session.instructions = instructions;
  }
}

/// Publishes remote final history only after F3f acknowledges host completion.
final class ChatRemoteOrchestrationBackend
    implements RemoteOrchestrationService {
  ChatRemoteOrchestrationBackend({
    required this.sessions,
    required AdeleRequestChannel Function(String context) hostChannel,
  }) {
    _backend = RemoteOrchestrationBackend(
      routes: {
        chatStrategyRouteId: OrchestrationStrategyContribution(
          strategyId: chatStrategyId,
          materialize: (context) {
            final transaction = _materializing[context.session.id]!;
            return transaction.execution = _ChatExecution(
              context.host,
              transaction.staged,
            );
          },
        ),
      },
      hostChannel: hostChannel,
    );
  }

  final ChatSessionStore sessions;
  late final RemoteOrchestrationBackend _backend;
  final Map<SessionId, _ChatHistoryTransaction> _materializing = {};
  final Map<String, _ChatHistoryTransaction> _executions = {};
  Future<void>? _closing;

  @override
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  ) async {
    _requireOpen();
    final source = sessions.obtain(SessionId(session.sessionId));
    final transaction = _ChatHistoryTransaction(source);
    _materializing[source.id] = transaction;
    try {
      final id = await _backend.materialize(routeId, session, runId);
      if (_closing != null) {
        await _backend.release(id);
        throw StateError('The Chat backend closed during materialization.');
      }
      _executions[id] = transaction;
      return id;
    } on Object {
      transaction.finish(commit: false);
      rethrow;
    } finally {
      _materializing.remove(source.id);
    }
  }

  @override
  Future<RemoteRunState> start(
    String executionId,
    String hostInvocationContext,
  ) => _advance(executionId, hostInvocationContext, null);

  @override
  Future<RemoteRunState> resolveApproval(
    String executionId,
    RemoteApprovalResolution resolution,
    String hostInvocationContext,
  ) => _advance(executionId, hostInvocationContext, resolution);

  Future<RemoteRunState> _advance(
    String id,
    String context,
    RemoteApprovalResolution? resolution,
  ) async {
    _requireOpen();
    final transaction = _executions[id];
    if (transaction == null) {
      throw const InvalidRunOperation('Unknown Chat execution.');
    }
    if (transaction.advancing != null || transaction.releasing != null) {
      throw const InvalidRunOperation('The Chat execution is busy or closed.');
    }
    final settled = Completer<void>();
    transaction.advancing = settled.future;
    try {
      final state = resolution == null
          ? await _backend.start(id, context)
          : await _backend.resolveApproval(id, resolution, context);
      if (state != RemoteRunState.waiting) {
        transaction.finish(commit: state == RemoteRunState.completed);
        _executions.remove(id);
      }
      return state;
    } on Object {
      // F3f closes after advancement errors, but retains preflight rejections
      // (such as another start while waiting) for a later valid operation.
      if (transaction.execution!._closed) {
        transaction.finish(commit: false);
        _executions.remove(id);
      }
      rethrow;
    } finally {
      transaction.advancing = null;
      settled.complete();
    }
  }

  @override
  Future<void> release(String executionId) {
    final transaction = _executions[executionId];
    if (transaction == null) return _backend.release(executionId);
    return transaction.releasing ??= _release(executionId, transaction);
  }

  Future<void> _release(String id, _ChatHistoryTransaction transaction) async {
    await transaction.advancing;
    try {
      await _backend.release(id);
    } finally {
      transaction.finish(commit: false);
      _executions.remove(id);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await _backend.close();
    } finally {
      for (final transaction in {
        ..._materializing.values,
        ..._executions.values,
      }) {
        await transaction.advancing;
        transaction.finish(commit: false);
      }
      _executions.clear();
    }
  }

  void _requireOpen() {
    if (_closing != null) throw StateError('The Chat backend is closed.');
  }
}

final class _ChatHistoryTransaction {
  _ChatHistoryTransaction(this.source)
    : staged = ChatSessionState(source.id)
        .._instructions = source.instructions
        .._maxModelInvocations = source.maxModelInvocations
        .._entries.addAll(source._entries)
        .._nextEntry = source._nextEntry {
    source._acquire(this);
  }

  final ChatSessionState source;
  final ChatSessionState staged;
  _ChatExecution? execution;
  Future<void>? advancing;
  Future<void>? releasing;
  bool _finished = false;

  void finish({required bool commit}) {
    if (_finished) return;
    if (commit) {
      source._entries.addAll(staged._entries.skip(source._entries.length));
      source._nextEntry = staged._nextEntry;
    }
    _finished = true;
    source._release(this);
  }
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
  String _instructions = chatDefaultInstructions;
  int _maxModelInvocations = 8;
  final List<ChatEntry> _entries = <ChatEntry>[];
  int _nextEntry = 0;
  Object? _execution;

  String get instructions => _instructions;

  set instructions(String value) {
    _requireIdle();
    _instructions = value;
  }

  int get maxModelInvocations => _maxModelInvocations;

  set maxModelInvocations(int value) {
    _requireIdle();
    if (value < 1) {
      throw ArgumentError.value(
        value,
        'maxModelInvocations',
        'Must be positive.',
      );
    }
    _maxModelInvocations = value;
  }

  ChatEntry appendUserMessage(String content) {
    _requireIdle();
    return _append('user', content);
  }

  ChatEntry _append(String role, String content) {
    _requireContent(content);
    final entry = ChatEntry(
      id: ChatEntryId('entry-${_nextEntry++}').value,
      role: role,
      content: content,
    );
    _entries.add(entry);
    return entry;
  }

  ChatSessionSnapshot snapshot() => ChatSessionSnapshot(
    entries: _entries,
    instructions: instructions,
    maxModelInvocations: maxModelInvocations,
  );

  void _requireIdle() {
    if (_execution != null) {
      throw ChatSessionFailure(
        code: 'session_busy',
        message: 'The Chat Session has an active execution.',
        details: <String, Object?>{'sessionId': id.value},
      );
    }
  }

  void _acquire(Object execution) {
    _requireIdle();
    _execution = execution;
  }

  void _release(Object execution) {
    if (identical(_execution, execution)) _execution = null;
  }
}

String _requireContent(String content) {
  if (content.trim().isEmpty) {
    throw const FormatException('Chat message content must not be empty.');
  }
  return content;
}

final class _ChatExecution implements OrchestrationExecution {
  _ChatExecution(this.host, this.session)
    : instructions = session.instructions.isEmpty
          ? chatToolNarrationGuidance
          : '$chatToolNarrationGuidance\n\n${session.instructions}',
      maxModelInvocations = session.maxModelInvocations {
    if (host.sessionId != session.id) {
      throw ArgumentError('Run and Session identities must match.');
    }
    session._acquire(this);
  }

  final OrchestrationExecutionHost host;
  final ChatSessionState session;
  final String instructions;
  final int maxModelInvocations;
  final List<SemanticModelInputItem> _runItems = <SemanticModelInputItem>[];
  int _nextModelInvocation = 1;
  bool _busy = false;
  bool _closed = false;
  Completer<void>? _advanceSettled;
  Future<void>? _closing;
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
              role: switch (entry.role) {
                'user' => SemanticMessageRole.user,
                'assistant' => SemanticMessageRole.assistant,
                _ => throw StateError('Invalid canonical Chat role.'),
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
        session._append('assistant', text.toString());
        host.complete();
        return;
    }
    if (proposals.isEmpty) {
      if (text.toString().trim().isEmpty) {
        _fail(StateError('The model completed without assistant output.'));
        return;
      }
      host.validateBinding();
      session._append('assistant', text.toString());
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
    if (_closed) {
      throw const InvalidRunOperation('The Chat execution is closed.');
    }
    if (_busy) {
      throw const InvalidRunOperation(
        'The Chat strategy is already advancing this Run.',
      );
    }
    _busy = true;
    final Completer<void> settled = Completer<void>();
    _advanceSettled = settled;
    try {
      await operation();
    } on InvalidRunOperation {
      rethrow;
    } on Object catch (error, stackTrace) {
      _fail(error);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _busy = false;
      _advanceSettled = null;
      settled.complete();
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= Future<void>.microtask(() async {
      await _advanceSettled?.future;
      _pendingBatch = null;
      _runItems.clear();
      session._release(this);
    });
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
