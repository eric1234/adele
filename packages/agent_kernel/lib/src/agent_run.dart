import 'dart:async';

import 'agent_model.dart';
import 'agent_tool.dart';

enum AgentRunState {
  created,
  invokingModel,
  awaitingApproval,
  executingTool,
  completed,
  failed,
}

enum AgentRunEventKind {
  runStarted,
  modelInvocationStarted,
  modelInvocationCompleted,
  toolCallProposed,
  toolCallApproved,
  toolCallRejected,
  toolExecutionStarted,
  toolExecutionCompleted,
  runCompleted,
  runFailed,
}

final class AgentRunEvent {
  AgentRunEvent({
    required this.sequence,
    required this.kind,
    this.toolCallId,
    this.toolName,
    this.content,
    Map<String, Object?> arguments = const <String, Object?>{},
    this.error,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final int sequence;
  final AgentRunEventKind kind;
  final String? toolCallId;
  final String? toolName;
  final String? content;
  final Map<String, Object?> arguments;
  final Object? error;
}

final class PendingToolApproval {
  PendingToolApproval({
    required this.toolCallId,
    required this.toolName,
    required Map<String, Object?> arguments,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final String toolCallId;
  final String toolName;
  final Map<String, Object?> arguments;
}

sealed class AgentRunException implements Exception {
  const AgentRunException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class InvalidAgentRunOperation extends AgentRunException {
  const InvalidAgentRunOperation(super.message);
}

final class UnsupportedModelResponse extends AgentRunException {
  const UnsupportedModelResponse(super.message);
}

final class UnknownAgentTool extends AgentRunException {
  const UnknownAgentTool(this.toolName)
    : super('The model requested unknown tool $toolName.');

  final String toolName;
}

final class AgentRun {
  AgentRun({
    required String userRequest,
    required AgentModel model,
    required Iterable<AgentTool> tools,
  }) : _model = model,
       _messages = <ModelMessage>[
         ModelMessage(role: ModelMessageRole.user, content: userRequest),
       ],
       _tools = _indexTools(tools);

  final AgentModel _model;
  final Map<String, AgentTool> _tools;
  final List<ModelMessage> _messages;
  final List<AgentRunEvent> _events = <AgentRunEvent>[];
  AgentRunState _state = AgentRunState.created;
  _PendingToolCall? _pending;
  String? _result;
  Object? _failure;
  bool _operationActive = false;

  AgentRunState get state => _state;
  PendingToolApproval? get pendingApproval => _pending?.approval;
  String? get result => _result;
  Object? get failure => _failure;
  List<AgentRunEvent> get events => List<AgentRunEvent>.unmodifiable(_events);

  Future<void> start() => _guarded(() async {
    if (_state != AgentRunState.created) {
      throw InvalidAgentRunOperation('Only a created run can be started.');
    }
    _append(AgentRunEventKind.runStarted);
    await _invokeModel();
  });

  Future<void> approve(String toolCallId) => _guarded(() async {
    final _PendingToolCall pending = _requirePending(toolCallId, 'approve');
    _pending = null;
    _append(
      AgentRunEventKind.toolCallApproved,
      toolCallId: pending.call.id,
      toolName: pending.call.name,
    );
    _state = AgentRunState.executingTool;
    _append(
      AgentRunEventKind.toolExecutionStarted,
      toolCallId: pending.call.id,
      toolName: pending.call.name,
    );
    try {
      final ToolResult result = await pending.tool.invoke(
        pending.call.arguments,
      );
      _append(
        AgentRunEventKind.toolExecutionCompleted,
        toolCallId: pending.call.id,
        toolName: pending.call.name,
        content: result.content,
      );
      _messages.add(
        ModelMessage(
          role: ModelMessageRole.tool,
          content: result.content,
          toolCallId: pending.call.id,
          toolOutcome: result.status,
        ),
      );
      await _invokeModel();
    } on Object catch (error) {
      _fail(error);
    }
  });

  Future<void> reject(String toolCallId) => _guarded(() async {
    final _PendingToolCall pending = _requirePending(toolCallId, 'reject');
    _pending = null;
    _append(
      AgentRunEventKind.toolCallRejected,
      toolCallId: pending.call.id,
      toolName: pending.call.name,
    );
    _messages.add(
      ModelMessage(
        role: ModelMessageRole.tool,
        content: 'The user rejected this tool call.',
        toolCallId: pending.call.id,
        toolOutcome: ToolOutcomeStatus.rejected,
      ),
    );
    await _invokeModel();
  });

  Future<void> _invokeModel() async {
    _state = AgentRunState.invokingModel;
    _append(AgentRunEventKind.modelInvocationStarted);
    try {
      final ModelResponse response = await _model.invoke(
        ModelRequest(
          messages: _messages,
          tools: _tools.values.map((AgentTool tool) => tool.definition),
        ),
      );
      _append(
        AgentRunEventKind.modelInvocationCompleted,
        content: response.content,
      );
      if (response.toolCalls.length > 1) {
        throw const UnsupportedModelResponse(
          'Phase IV supports at most one tool call per model response.',
        );
      }
      _messages.add(
        ModelMessage(
          role: ModelMessageRole.assistant,
          content: response.content,
        ),
      );
      if (response.toolCalls.isEmpty) {
        _result = response.content;
        _state = AgentRunState.completed;
        _append(AgentRunEventKind.runCompleted, content: response.content);
        return;
      }
      final ModelToolCall call = response.toolCalls.single;
      if (call.id.isEmpty || call.name.isEmpty) {
        throw const UnsupportedModelResponse(
          'Tool calls require non-empty IDs and names.',
        );
      }
      final AgentTool? tool = _tools[call.name];
      if (tool == null) throw UnknownAgentTool(call.name);
      _pending = _PendingToolCall(call: call, tool: tool);
      _state = AgentRunState.awaitingApproval;
      _append(
        AgentRunEventKind.toolCallProposed,
        toolCallId: call.id,
        toolName: call.name,
        arguments: call.arguments,
      );
    } on Object catch (error) {
      _fail(error);
    }
  }

  _PendingToolCall _requirePending(String toolCallId, String operation) {
    if (_state != AgentRunState.awaitingApproval || _pending == null) {
      throw InvalidAgentRunOperation(
        'Cannot $operation a tool call while the run is $_state.',
      );
    }
    if (_pending!.call.id != toolCallId) {
      throw InvalidAgentRunOperation(
        'Tool call $toolCallId is not pending approval.',
      );
    }
    return _pending!;
  }

  Future<void> _guarded(Future<void> Function() operation) async {
    if (_operationActive) {
      throw const InvalidAgentRunOperation(
        'Another run operation is already in progress.',
      );
    }
    _operationActive = true;
    try {
      await operation();
    } finally {
      _operationActive = false;
    }
  }

  void _fail(Object error) {
    if (_state == AgentRunState.failed) return;
    _failure = error;
    _pending = null;
    _state = AgentRunState.failed;
    _append(AgentRunEventKind.runFailed, error: error);
  }

  void _append(
    AgentRunEventKind kind, {
    String? toolCallId,
    String? toolName,
    String? content,
    Map<String, Object?> arguments = const <String, Object?>{},
    Object? error,
  }) {
    _events.add(
      AgentRunEvent(
        sequence: _events.length + 1,
        kind: kind,
        toolCallId: toolCallId,
        toolName: toolName,
        content: content,
        arguments: arguments,
        error: error,
      ),
    );
  }

  static Map<String, AgentTool> _indexTools(Iterable<AgentTool> tools) {
    final Map<String, AgentTool> result = <String, AgentTool>{};
    for (final AgentTool tool in tools) {
      final String name = tool.definition.name;
      if (name.isEmpty) {
        throw ArgumentError.value(name, 'tools', 'Tool name cannot be empty.');
      }
      if (result.containsKey(name)) {
        throw ArgumentError.value(name, 'tools', 'Tool names must be unique.');
      }
      result[name] = tool;
    }
    return Map<String, AgentTool>.unmodifiable(result);
  }
}

final class _PendingToolCall {
  _PendingToolCall({required this.call, required this.tool});

  final ModelToolCall call;
  final AgentTool tool;

  PendingToolApproval get approval => PendingToolApproval(
    toolCallId: call.id,
    toolName: call.name,
    arguments: call.arguments,
  );
}
