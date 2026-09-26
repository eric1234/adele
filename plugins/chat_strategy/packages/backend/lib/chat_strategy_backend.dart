/// Stock Chat sequencing over the public orchestration execution host.
library;

import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration_backend.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
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

  Future<ChatSessionState> _session(String id) {
    final SessionId sessionId;
    try {
      sessionId = SessionId(id);
    } on FormatException {
      throw const ChatSessionFailure(
        code: 'invalid_session',
        message: 'Session identity must be nonempty with no outer whitespace.',
        details: <String, Object?>{},
      );
    }
    return sessions.load(sessionId);
  }

  @override
  Future<ChatSessionSnapshot> snapshot(String sessionId) async =>
      (await _session(sessionId)).snapshot();

  @override
  Future<ChatEntry> appendUserMessage(String sessionId, String content) async {
    try {
      _requireContent(content);
    } on FormatException {
      throw const ChatSessionFailure(
        code: 'invalid_content',
        message: 'Chat message content must not be empty.',
        details: <String, Object?>{},
      );
    }
    return (await _session(sessionId))._appendUserMessage(content);
  }

  @override
  Future<void> setDraftRequest(String sessionId, String content) async =>
      (await _session(sessionId))._setDraftRequest(content);

  @override
  Future<ChatEntry> submitDraftRequest(String sessionId) async {
    final session = await _session(sessionId);
    return session._appendUserMessage(session.draftRequest, clearDraft: true);
  }

  @override
  Future<void> configureSession(
    String sessionId,
    String instructions,
    int maxModelInvocations,
  ) async {
    if (maxModelInvocations < 1) {
      throw const ChatSessionFailure(
        code: 'invalid_configuration',
        message: 'maxModelInvocations must be positive.',
        details: <String, Object?>{},
      );
    }
    final session = await _session(sessionId);
    await session._configure(instructions, maxModelInvocations);
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
  final Set<Future<void>> _materializations = {};
  Future<void>? _closing;

  @override
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  ) async {
    _requireOpen();
    final settled = Completer<void>();
    _materializations.add(settled.future);
    _ChatHistoryTransaction? transaction;
    String? executionId;
    try {
      final source = await sessions.load(SessionId(session.sessionId));
      _requireOpen();
      transaction = _ChatHistoryTransaction(source);
      _materializing[source.id] = transaction;
      executionId = await _backend.materialize(routeId, session, runId);
      _requireOpen();
      await transaction.associateRun(RunId(runId));
      _requireOpen();
      _executions[executionId] = transaction;
      return executionId;
    } on Object {
      try {
        try {
          if (executionId != null) await _backend.release(executionId);
        } finally {
          await transaction?.finish(commit: false);
        }
      } on Object {
        // Preserve the materialization/association failure over cleanup errors.
      }
      rethrow;
    } finally {
      if (transaction != null) _materializing.remove(transaction.source.id);
      _materializations.remove(settled.future);
      settled.complete();
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
        await transaction.finish(commit: state == RemoteRunState.completed);
        _executions.remove(id);
      }
      return state;
    } on Object {
      // F3f closes after advancement errors, but retains preflight rejections
      // (such as another start while waiting) for a later valid operation.
      if (transaction.execution!._closed) {
        _executions.remove(id);
        await transaction.finish(commit: false);
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
      _executions.remove(id);
      await transaction.finish(commit: false);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final transactions = _executions.values.toList();
    try {
      await _backend.close();
    } finally {
      await Future.wait(_materializations.toList());
      try {
        await Future.wait([
          for (final transaction in transactions)
            () async {
              await transaction.advancing;
              await transaction.finish(commit: false);
            }(),
        ]);
      } finally {
        _executions.clear();
      }
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
        .._draftRequest = source.draftRequest
        .._entries.addAll(source._entries)
        .._nextEntry = source._nextEntry {
    source._acquire(this);
  }

  final ChatSessionState source;
  final ChatSessionState staged;
  _ChatExecution? execution;
  Future<void>? advancing;
  Future<void>? releasing;
  Future<void>? _finishing;

  Future<void> associateRun(RunId runId) async {
    if (source._entries.isEmpty) return;
    final entry = source._entries.last;
    if (entry.role != 'user' || entry.runId != null) return;
    final index = source._entries.length - 1;
    if (source._entries.any((entry) => entry.runId == runId.value)) {
      throw const InvalidRunOperation('The Run already has a Chat user entry.');
    }
    final associated = ChatEntry(
      id: entry.id,
      role: entry.role,
      content: entry.content,
      runId: runId.value,
    );
    if (source._storage case final storage?) {
      _requireReadableRow({
        'session_id': source.id.value,
        'sequence': index,
        'entry_id': associated.id,
        'role': associated.role,
        'content': associated.content,
        'run_id': associated.runId,
      });
      await storage.transactionForSession(source.id.value, [
        RelationalStatement(
          sql:
              'UPDATE adele_chat_sessions SET next_entry = :previousCounter '
              '${ChatSessionState._whereCurrent}',
          parameters: source._preconditions,
          expectedRows: 1,
        ),
        RelationalStatement(
          sql:
              'UPDATE adele_chat_entries SET run_id = :run '
              'WHERE session_id = :session AND sequence = :sequence '
              "AND entry_id = :entry AND role = 'user' AND content = :content "
              'AND run_id IS NULL',
          parameters: {
            ':session': source.id.value,
            ':sequence': index,
            ':entry': entry.id,
            ':content': entry.content,
            ':run': runId.value,
          },
          expectedRows: 1,
        ),
      ]);
    }
    source._entries[index] = associated;
    staged._entries[index] = associated;
  }

  Future<void> finish({required bool commit}) =>
      _finishing ??= _finish(commit: commit);

  Future<void> _finish({required bool commit}) async {
    try {
      if (commit) {
        final entries = staged._entries.skip(source._entries.length).toList();
        await source._persistEntries(entries, staged._nextEntry);
        source._entries.addAll(entries);
        source._nextEntry = staged._nextEntry;
      }
    } finally {
      source._release(this);
    }
  }
}

/// Retains Chat-owned conversation state by canonical product Session identity.
final class ChatSessionStore {
  ChatSessionStore({ProjectStorageService? storage}) : _storage = storage;

  final ProjectStorageService? _storage;
  final Map<SessionId, ChatSessionState> _sessions =
      <SessionId, ChatSessionState>{};
  final Map<SessionId, Future<ChatSessionState>> _loads = {};

  /// Synchronous state access is reserved for explicitly volatile native fixtures.
  ChatSessionState obtain(SessionId id) {
    if (_storage != null) {
      throw StateError(
        'Storage-backed Chat Sessions require asynchronous load.',
      );
    }
    return _sessions.putIfAbsent(id, () => ChatSessionState(id));
  }

  /// One hydration per Session and generation, including a retained load failure.
  Future<ChatSessionState> load(SessionId id) =>
      _loads.putIfAbsent(id, () => _load(id));

  Future<ChatSessionState> _load(SessionId id) async {
    final storage = _storage;
    if (storage == null) return obtain(id);
    if (!await storage.isDurableSession(id.value)) {
      return _sessions.putIfAbsent(id, () => ChatSessionState(id));
    }
    await storage.ensureSchemaForSession(id.value, const [_chatSchema]);
    final parameters = <String, Object?>{':session': id.value};
    final rows = await storage.queryForSession(
      id.value,
      'SELECT session_id, instructions, max_model_invocations, next_entry, '
      'draft_request '
      'FROM adele_chat_sessions WHERE session_id = :session',
      parameters,
    );
    final state = ChatSessionState._durable(id, storage);
    if (rows.length > 1) {
      throw ChatStateCorruption(id, 'Duplicate Session row.');
    }
    if (rows.isNotEmpty) {
      final values = rows.single.values;
      final instructions = values['instructions'];
      final budget = values['max_model_invocations'];
      final counter = values['next_entry'];
      final draft = values['draft_request'];
      if (values['session_id'] != id.value ||
          instructions is! String ||
          budget is! int ||
          budget < 1 ||
          counter is! int ||
          counter < 0 ||
          draft is! String) {
        throw ChatStateCorruption(
          id,
          'Invalid configuration, entry counter, or draft.',
        );
      }
      state
        .._instructions = instructions
        .._maxModelInvocations = budget
        .._nextEntry = counter
        .._draftRequest = draft;
      state._requireReadableConfiguration(instructions, budget, counter, draft);
    }
    final runIds = <RunId>{};
    while (true) {
      final entries = await storage.queryForSession(
        id.value,
        'SELECT session_id, sequence, entry_id, role, content, run_id '
        'FROM adele_chat_entries WHERE session_id = :session '
        'AND sequence = :sequence LIMIT 2',
        {...parameters, ':sequence': state._entries.length},
      );
      if (entries.isEmpty) break;
      if (entries.length > 1) {
        throw ChatStateCorruption(id, 'Duplicate canonical sequence.');
      }
      final values = entries.single.values;
      final sequence = values['sequence'];
      final entryId = values['entry_id'];
      final role = values['role'];
      final content = values['content'];
      final runId = values['run_id'];
      if (values['session_id'] != id.value ||
          sequence != state._entries.length ||
          entryId != 'entry-${state._entries.length}' ||
          (role != 'user' && role != 'assistant') ||
          content is! String ||
          content.trim().isEmpty ||
          (runId != null && (runId is! String || role != 'user'))) {
        throw ChatStateCorruption(id, 'Invalid ordered canonical entry.');
      }
      if (runId is String) {
        final RunId identity;
        try {
          identity = RunId(runId);
        } on FormatException {
          throw ChatStateCorruption(id, 'Invalid associated Run identity.');
        }
        if (!runIds.add(identity)) {
          throw ChatStateCorruption(id, 'Duplicate associated Run identity.');
        }
      }
      state._entries.add(
        ChatEntry(
          id: entryId as String,
          role: role as String,
          content: content,
          runId: runId as String?,
        ),
      );
    }
    if (state._nextEntry != state._entries.length) {
      throw ChatStateCorruption(id, 'Entry counter does not match history.');
    }
    final count = await storage.queryForSession(
      id.value,
      'SELECT COUNT(*) AS entry_count FROM adele_chat_entries '
      'WHERE session_id = :session',
      parameters,
    );
    if (count.length != 1 ||
        count.single.values['entry_count'] != state._entries.length) {
      throw ChatStateCorruption(
        id,
        'Retained entry count does not match history.',
      );
    }
    if (rows.isEmpty) {
      state._requireReadableConfiguration(
        state.instructions,
        state.maxModelInvocations,
        state._nextEntry,
        state.draftRequest,
      );
      await storage.transactionForSession(id.value, [
        RelationalStatement(
          sql:
              'INSERT INTO adele_chat_sessions '
              '(session_id, instructions, max_model_invocations, next_entry, '
              'draft_request) '
              'VALUES (:session, :instructions, :budget, :counter, :draft)',
          parameters: {
            ...parameters,
            ':instructions': state.instructions,
            ':budget': state.maxModelInvocations,
            ':counter': state._nextEntry,
            ':draft': state.draftRequest,
          },
          expectedRows: 1,
        ),
      ]);
    }
    return _sessions[id] = state;
  }
}

const _chatSchema = '''
CREATE TABLE adele_chat_sessions (
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES adele_product_sessions(id),
  instructions TEXT NOT NULL,
  max_model_invocations INTEGER NOT NULL CHECK (max_model_invocations > 0),
  next_entry INTEGER NOT NULL CHECK (next_entry >= 0),
  draft_request TEXT NOT NULL
);
CREATE TABLE adele_chat_entries (
  session_id TEXT NOT NULL REFERENCES adele_chat_sessions(session_id),
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  entry_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  content TEXT NOT NULL,
  run_id TEXT,
  PRIMARY KEY (session_id, sequence),
  UNIQUE (session_id, entry_id),
  UNIQUE (session_id, run_id),
  CHECK (role = 'user' OR run_id IS NULL)
);
''';

final class ChatStateCorruption implements Exception {
  const ChatStateCorruption(this.sessionId, this.message);

  final SessionId sessionId;
  final String message;

  @override
  String toString() => 'ChatStateCorruption(${sessionId.value}): $message';
}

final class ChatSessionState {
  ChatSessionState(this.id) : _storage = null;

  ChatSessionState._durable(this.id, this._storage);

  final SessionId id;
  final ProjectStorageService? _storage;
  String _instructions = chatDefaultInstructions;
  int _maxModelInvocations = 8;
  final List<ChatEntry> _entries = <ChatEntry>[];
  int _nextEntry = 0;
  String _draftRequest = '';
  Object? _execution;

  String get draftRequest => _draftRequest;

  String get instructions => _instructions;

  set instructions(String value) {
    _requireVolatile();
    _requireIdle();
    _instructions = value;
  }

  int get maxModelInvocations => _maxModelInvocations;

  set maxModelInvocations(int value) {
    _requireVolatile();
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
    _requireVolatile();
    _requireIdle();
    return _append('user', content);
  }

  ChatEntry _append(String role, String content) {
    _requireVolatile();
    _requireContent(content);
    final entry = ChatEntry(
      id: ChatEntryId('entry-${_nextEntry++}').value,
      role: role,
      content: content,
      runId: null,
    );
    _entries.add(entry);
    return entry;
  }

  Future<ChatEntry> _appendUserMessage(
    String content, {
    bool clearDraft = false,
  }) async {
    final claim = Object();
    _acquire(claim);
    try {
      if (clearDraft && content.trim().isEmpty) {
        throw const ChatSessionFailure(
          code: 'invalid_content',
          message: 'Chat Draft Request must not be empty.',
          details: <String, Object?>{},
        );
      }
      final entry = ChatEntry(
        id: 'entry-$_nextEntry',
        role: 'user',
        content: content,
        runId: null,
      );
      await _persistEntries([entry], _nextEntry + 1, clearDraft: clearDraft);
      _entries.add(entry);
      _nextEntry++;
      if (clearDraft) _draftRequest = '';
      return entry;
    } finally {
      _release(claim);
    }
  }

  Map<String, Object?> get _preconditions => {
    ':session': id.value,
    ':previousCounter': _nextEntry,
    ':previousInstructions': _instructions,
    ':previousBudget': _maxModelInvocations,
    ':previousDraft': _draftRequest,
  };

  static const _whereCurrent =
      'WHERE session_id = :session AND next_entry = :previousCounter '
      'AND instructions = :previousInstructions '
      'AND max_model_invocations = :previousBudget '
      'AND draft_request = :previousDraft';

  Future<void> _setDraftRequest(String content) async {
    final claim = Object();
    _acquire(claim);
    try {
      if (_storage != null) {
        _requireReadableConfiguration(
          _instructions,
          _maxModelInvocations,
          _nextEntry,
          content,
        );
      }
      await _storage?.transactionForSession(id.value, [
        RelationalStatement(
          sql:
              'UPDATE adele_chat_sessions SET draft_request = :draft $_whereCurrent',
          parameters: {..._preconditions, ':draft': content},
          expectedRows: 1,
        ),
      ]);
      _draftRequest = content;
    } finally {
      _release(claim);
    }
  }

  Future<void> _configure(String instructions, int budget) async {
    final claim = Object();
    _acquire(claim);
    try {
      if (_storage != null) {
        _requireReadableConfiguration(
          instructions,
          budget,
          _nextEntry,
          _draftRequest,
        );
      }
      await _storage?.transactionForSession(id.value, [
        RelationalStatement(
          sql:
              'UPDATE adele_chat_sessions SET instructions = :instructions, '
              'max_model_invocations = :budget $_whereCurrent',
          parameters: {
            ..._preconditions,
            ':instructions': instructions,
            ':budget': budget,
          },
          expectedRows: 1,
        ),
      ]);
      _instructions = instructions;
      _maxModelInvocations = budget;
    } finally {
      _release(claim);
    }
  }

  Future<void> _persistEntries(
    List<ChatEntry> entries,
    int counter, {
    bool clearDraft = false,
  }) async {
    if (_storage == null) return;
    _requireReadableConfiguration(
      _instructions,
      _maxModelInvocations,
      counter,
      clearDraft ? '' : _draftRequest,
    );
    for (var index = 0; index < entries.length; index++) {
      _requireReadableRow({
        'session_id': id.value,
        'sequence': _entries.length + index,
        'entry_id': entries[index].id,
        'role': entries[index].role,
        'content': entries[index].content,
        'run_id': entries[index].runId,
      });
    }
    await _storage.transactionForSession(id.value, [
      RelationalStatement(
        sql:
            'UPDATE adele_chat_sessions SET next_entry = :counter '
            '${clearDraft ? ", draft_request = '' " : ''}$_whereCurrent',
        parameters: {..._preconditions, ':counter': counter},
        expectedRows: 1,
      ),
      for (var index = 0; index < entries.length; index++)
        RelationalStatement(
          sql:
              'INSERT INTO adele_chat_entries '
              '(session_id, sequence, entry_id, role, content, run_id) '
              'VALUES (:session, :sequence, :entry, :role, :content, :run)',
          parameters: {
            ':session': id.value,
            ':sequence': _entries.length + index,
            ':entry': entries[index].id,
            ':role': entries[index].role,
            ':content': entries[index].content,
            ':run': entries[index].runId,
          },
          expectedRows: 1,
        ),
    ]);
  }

  void _requireReadableConfiguration(
    String instructions,
    int budget,
    int counter,
    String draftRequest,
  ) {
    _requireReadableRow({
      'session_id': id.value,
      'instructions': instructions,
      'max_model_invocations': budget,
      'next_entry': counter,
      'draft_request': draftRequest,
    });
  }

  void _requireVolatile() {
    if (_storage != null) {
      throw StateError(
        'Durable Chat state must be mutated through its service.',
      );
    }
  }

  ChatSessionSnapshot snapshot() => ChatSessionSnapshot(
    entries: _entries,
    instructions: instructions,
    maxModelInvocations: maxModelInvocations,
    draftRequest: draftRequest,
  );

  void _requireIdle() {
    if (_execution != null) {
      throw ChatSessionFailure(
        code: 'session_busy',
        message: 'The Chat Session has an active execution or write.',
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

void _requireReadableRow(Map<String, Object?> values) {
  // The host charges two result bytes plus wrapped row bytes and one separator.
  final bytes = 2 + utf8.encode(jsonEncode({'values': values})).length + 1;
  if (bytes > relationalQueryByteLimit) {
    throw StateError(
      'Canonical Chat row exceeds the durable query byte limit.',
    );
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
    session._requireVolatile();
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
