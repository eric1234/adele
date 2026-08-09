import 'package:scripted_model_contract/scripted_model_contract.dart';

final class ScriptedModelProvider implements ScriptedModelService {
  const ScriptedModelProvider();

  static const String toolName = 'inspect_resource';
  static const String toolCallId = 'inspect-1';
  static const String resourceUri = 'file:///tmp/adele-phase-iv.txt';

  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async {
    if (request.messages.isEmpty ||
        request.messages.first.role != ScriptedModelMessageRole.user) {
      throw const ScriptedModelFailure(
        code: 'invalid_transcript',
        message: 'The scripted model requires an initial user message.',
        details: <String, Object?>{},
      );
    }
    final List<ScriptedModelMessage> outcomes = request.messages
        .where(
          (ScriptedModelMessage message) =>
              message.role == ScriptedModelMessageRole.tool,
        )
        .toList(growable: false);
    if (outcomes.isEmpty) {
      if (!request.tools.any(
        (ScriptedToolDefinition tool) => tool.name == toolName,
      )) {
        throw const ScriptedModelFailure(
          code: 'tool_unavailable',
          message: 'The inspect_resource tool was not offered.',
          details: <String, Object?>{},
        );
      }
      return const ScriptedModelResponse(
        content: 'Inspecting the deterministic Phase IV resource.',
        toolCall: ScriptedToolCall(
          id: toolCallId,
          name: toolName,
          arguments: <String, Object?>{'uri': resourceUri},
        ),
      );
    }
    final ScriptedModelMessage outcome = outcomes.last;
    if (outcome.toolCallId != toolCallId) {
      throw const ScriptedModelFailure(
        code: 'unexpected_tool_result',
        message: 'The tool outcome did not match the scripted call.',
        details: <String, Object?>{},
      );
    }
    if (outcome.toolOutcome == ScriptedToolOutcomeStatus.rejected) {
      return const ScriptedModelResponse(
        content: 'The inspection was rejected; the run is complete.',
        toolCall: null,
      );
    }
    if (outcome.toolOutcome == ScriptedToolOutcomeStatus.error) {
      return ScriptedModelResponse(
        content: 'Inspection failed: ${outcome.content}',
        toolCall: null,
      );
    }
    if (outcome.toolOutcome != ScriptedToolOutcomeStatus.success) {
      throw const ScriptedModelFailure(
        code: 'invalid_tool_outcome',
        message: 'The tool outcome status is missing.',
        details: <String, Object?>{},
      );
    }
    return ScriptedModelResponse(
      content: 'Inspection received: ${outcome.content}',
      toolCall: null,
    );
  }
}
