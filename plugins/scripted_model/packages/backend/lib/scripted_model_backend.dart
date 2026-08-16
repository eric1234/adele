import 'package:scripted_model_contract/scripted_model_contract.dart';

final class ScriptedModelProvider implements ScriptedModelFixtureService {
  ScriptedModelProvider({this.configurationLabel});

  final String? configurationLabel;

  static const String toolName = 'inspect_resource';
  static const String toolCallId = 'inspect-1';
  static const String resourceUri = 'file:///tmp/adele-phase-iv.txt';
  static const String failingResourceRequest = 'fixture:tool-domain-failure';
  static const String longStreamRequest = 'fixture:long-stream';

  int _advanced = 0;
  int _cancellations = 0;
  int _active = 0;

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
        content:
            '${configurationLabel == null ? '' : '[$configurationLabel] '}'
            'Inspecting the deterministic Phase IV resource.',
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

  @override
  Stream<ScriptedModelStreamItem> invokeStream(
    ScriptedModelRequest request,
  ) async* {
    final bool longStream = request.messages.any(
      (ScriptedModelMessage message) => message.content == longStreamRequest,
    );
    _active++;
    bool complete = false;
    try {
      if (longStream) {
        for (int sequence = 0; sequence < 1000000; sequence++) {
          _advanced++;
          yield ScriptedModelStreamItem(
            kind: ScriptedModelStreamItemKind.probe,
            text: null,
            toolCall: null,
            sequence: sequence,
          );
        }
        complete = true;
        return;
      }
      final ScriptedModelResponse response = await invoke(request);
      if (response.content.isNotEmpty) {
        yield ScriptedModelStreamItem(
          kind: ScriptedModelStreamItemKind.text,
          text: response.content,
          toolCall: null,
          sequence: null,
        );
      }
      if (response.toolCall case final ScriptedToolCall toolCall) {
        yield ScriptedModelStreamItem(
          kind: ScriptedModelStreamItemKind.toolCall,
          text: null,
          toolCall: toolCall,
          sequence: null,
        );
      }
      complete = true;
    } finally {
      _active--;
      if (!complete) _cancellations++;
    }
  }

  @override
  Future<ScriptedModelStreamProbe> streamProbe() async =>
      ScriptedModelStreamProbe(
        advanced: _advanced,
        cancellations: _cancellations,
        active: _active,
      );

  @override
  Future<ScriptedModelStreamProbe> resetStreamProbe() async {
    if (_active != 0) {
      throw const ScriptedModelFailure(
        code: 'stream_active',
        message: 'Cannot reset the stream probe while a producer is active.',
        details: <String, Object?>{},
      );
    }
    _advanced = 0;
    _cancellations = 0;
    return streamProbe();
  }
}
