enum ModelMessageRole { user, assistant, tool }

enum ToolOutcomeStatus { success, error, rejected }

final class ModelMessage {
  ModelMessage({
    required this.role,
    required this.content,
    this.toolCallId,
    this.toolOutcome,
  });

  final ModelMessageRole role;
  final String content;
  final String? toolCallId;
  final ToolOutcomeStatus? toolOutcome;
}

final class ToolDefinition {
  ToolDefinition({
    required this.name,
    required this.description,
    required Map<String, Object?> argumentsSchema,
  }) : argumentsSchema = Map<String, Object?>.unmodifiable(argumentsSchema);

  final String name;
  final String description;
  final Map<String, Object?> argumentsSchema;
}

final class ModelToolCall {
  ModelToolCall({
    required this.id,
    required this.name,
    required Map<String, Object?> arguments,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

final class ModelRequest {
  ModelRequest({
    required Iterable<ModelMessage> messages,
    required Iterable<ToolDefinition> tools,
  }) : messages = List<ModelMessage>.unmodifiable(messages),
       tools = List<ToolDefinition>.unmodifiable(tools);

  final List<ModelMessage> messages;
  final List<ToolDefinition> tools;
}

final class ModelResponse {
  ModelResponse({
    required this.content,
    Iterable<ModelToolCall> toolCalls = const <ModelToolCall>[],
  }) : toolCalls = List<ModelToolCall>.unmodifiable(toolCalls);

  final String content;
  final List<ModelToolCall> toolCalls;
}

abstract interface class AgentModel {
  Future<ModelResponse> invoke(ModelRequest request);
}
