import 'agent_model.dart';

final class ToolResult {
  ToolResult({required this.content, this.status = ToolOutcomeStatus.success});

  final String content;
  final ToolOutcomeStatus status;
}

abstract interface class AgentTool {
  ToolDefinition get definition;

  Future<ToolResult> invoke(Map<String, Object?> arguments);
}
