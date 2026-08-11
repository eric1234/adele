import 'package:scripted_model_contract/scripted_model_contract.dart';

final class ScriptedModelProvider implements ScriptedModelFixtureService {
  const ScriptedModelProvider();

  static const String toolName = 'inspect_resource';
  static const String toolCallId = 'inspect-1';
  static const String resourceUri = 'file:///tmp/adele-phase-iv.txt';
  static const String failingResourceRequest = 'fixture:tool-domain-failure';

  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async {
    final List<ScriptedModelMessage> users = request.messages
        .where(
          (ScriptedModelMessage message) =>
              message.role == ScriptedModelMessageRole.user,
        )
        .toList(growable: false);
    if (users.isEmpty) {
      throw const ScriptedModelFailure(
        code: 'invalid_context',
        message: 'The scripted model requires initial user context.',
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
          message: 'The inspect_resource fixture tool was not offered.',
          details: <String, Object?>{},
        );
      }
      final String currentInput = users.last.content;
      return ScriptedModelResponse(
        content: 'Inspecting the deterministic Phase IV resource.',
        toolCall: ScriptedToolCall(
          id: toolCallId,
          name: toolName,
          arguments: <String, Object?>{
            'uri': currentInput == failingResourceRequest
                ? 'fail:///adele-phase-iv.txt'
                : resourceUri,
          },
        ),
      );
    }
    final ScriptedModelMessage outcome = outcomes.last;
    final int outcomeIndex = request.messages.lastIndexOf(outcome);
    final bool hasProposal = request.messages
        .take(outcomeIndex)
        .any(
          (ScriptedModelMessage message) =>
              message.toolProposal?.id == outcome.toolCallId &&
              message.toolProposal?.name == toolName,
        );
    if (outcome.toolCallId != toolCallId ||
        outcome.toolOutcome == null ||
        !hasProposal) {
      throw const ScriptedModelFailure(
        code: 'unexpected_tool_outcome',
        message: 'The tool outcome did not match the scripted proposal.',
        details: <String, Object?>{},
      );
    }
    return switch (outcome.toolOutcome!) {
      ScriptedToolOutcomeStatus.success => ScriptedModelResponse(
        content: 'Inspection received: ${outcome.content}',
        toolCall: null,
      ),
      ScriptedToolOutcomeStatus.userRejected => const ScriptedModelResponse(
        content: 'The inspection was rejected; the run is complete.',
        toolCall: null,
      ),
      ScriptedToolOutcomeStatus.policyDenied => const ScriptedModelResponse(
        content: 'Policy denied the inspection; the run is complete.',
        toolCall: null,
      ),
      ScriptedToolOutcomeStatus.failure => ScriptedModelResponse(
        content: 'Inspection failed: ${outcome.content}',
        toolCall: null,
      ),
      ScriptedToolOutcomeStatus.cancelled => const ScriptedModelResponse(
        content: 'The inspection was cancelled; the run is complete.',
        toolCall: null,
      ),
      ScriptedToolOutcomeStatus.indeterminate => const ScriptedModelResponse(
        content: 'The inspection result is indeterminate.',
        toolCall: null,
      ),
    };
  }
}
