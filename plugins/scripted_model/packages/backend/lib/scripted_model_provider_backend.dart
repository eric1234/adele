import 'package:adele_model_provider/adele_model_provider.dart';

final class ScriptedCommonModelProvider implements ModelProviderService {
  static const String model = 'scripted-v1';
  static const String toolName = 'inspect_resource';
  static const String callId = 'inspect-call-1';
  static const String itemId = 'proposal-item-1';
  static const String initialText =
      'Inspecting the deterministic Phase IV resource.';
  static const String textItemId = 'text-item-1';
  static const String resourceUri = 'file:///tmp/adele-phase-iv.txt';
  static const String nativeKind = 'scripted-item-v1';
  static const Map<String, Object?> nativeCompatibility = <String, Object?>{
    'model': model,
  };
  static const Map<String, Object?> proposalMetadata = <String, Object?>{
    'scriptedProof': 'proposal-native-v1',
  };

  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) async* {
    if (request.model != model) {
      yield _failure(
        ModelProviderFailureKind.unsupportedRequest,
        'unsupported_model',
        'The scripted provider supports only $model.',
      );
      return;
    }
    final List<ModelProviderInput> outcomes = request.input
        .where((ModelProviderInput item) => item.toolOutcome != null)
        .toList(growable: false);
    if (outcomes.length > 1) {
      yield _failure(
        ModelProviderFailureKind.invalidRequest,
        'unsupported_tool_history',
        'The scripted provider supports exactly one continuation outcome.',
      );
      return;
    }
    if (outcomes.isEmpty) {
      if (request.input.any(
        (ModelProviderInput item) => item.toolProposal != null,
      )) {
        yield _failure(
          ModelProviderFailureKind.invalidRequest,
          'orphan_tool_proposal',
          'The scripted provider cannot continue a tool proposal without its outcome.',
        );
        return;
      }
      final List<ModelProviderInput> users = request.input
          .where(
            (ModelProviderInput item) =>
                item.message?.role == ModelProviderMessageRole.user,
          )
          .toList(growable: false);
      if (users.isEmpty) {
        yield _failure(
          ModelProviderFailureKind.invalidRequest,
          'missing_user_context',
          'The scripted provider requires initial user context.',
        );
        return;
      }
      if (request.toolChoice == ModelProviderToolChoice.none) {
        if (_exceedsOutputLimit(request, 5)) {
          yield _outputLimitTerminal('response-none-limit', inputTokens: 6);
          return;
        }
        yield _observation('No tool requested.');
        yield _text('No tool invocation was requested.', 'text-item-none');
        yield _terminal('response-none', inputTokens: 6, outputTokens: 5);
        return;
      }
      if (!request.tools.any(
        (ModelProviderTool tool) => tool.name == toolName,
      )) {
        yield _failure(
          ModelProviderFailureKind.invalidRequest,
          'tool_unavailable',
          'The inspect_resource tool was not offered.',
        );
        return;
      }
      final String userText = users.last.message!.content
          .map((ModelProviderContent content) => content.text)
          .join();
      if (_exceedsOutputLimit(request, 8)) {
        yield _outputLimitTerminal('response-1-limit', inputTokens: 12);
        return;
      }
      yield _observation('Inspecting ');
      yield _text(initialText, textItemId);
      yield _proposal(
        userText == 'fixture:tool-domain-failure'
            ? 'fail:///adele-phase-iv.txt'
            : resourceUri,
      );
      yield _terminal('response-1', inputTokens: 12, outputTokens: 8);
      return;
    }
    final ModelProviderInput outcomeInput = outcomes.last;
    final ModelProviderToolOutcome outcome = outcomeInput.toolOutcome!;
    final int outcomeIndex = request.input.lastIndexOf(outcomeInput);
    final List<ModelProviderInput> matchingProposals = request.input
        .take(outcomeIndex)
        .where(
          (ModelProviderInput item) =>
              item.toolProposal?.callId == outcome.callId,
        )
        .toList(growable: false);
    if (matchingProposals.isEmpty) {
      yield _failure(
        ModelProviderFailureKind.invalidRequest,
        'orphan_tool_outcome',
        'The tool outcome has no preceding correlated proposal.',
      );
      return;
    }
    if (matchingProposals.length > 1) {
      yield _failure(
        ModelProviderFailureKind.invalidRequest,
        'ambiguous_tool_proposal',
        'The tool outcome matches multiple preceding proposals.',
      );
      return;
    }
    final ModelProviderInput proposalInput = matchingProposals.single;
    final int proposalIndex = request.input.lastIndexOf(proposalInput);
    final List<ModelProviderInput> priorUsers = request.input
        .take(proposalIndex)
        .where(
          (ModelProviderInput item) =>
              item.message?.role == ModelProviderMessageRole.user,
        )
        .toList(growable: false);
    if (priorUsers.isEmpty) {
      yield _failure(
        ModelProviderFailureKind.invalidRequest,
        'missing_user_context',
        'The scripted provider requires user context before the proposal.',
      );
      return;
    }
    final String initialUserText = priorUsers.last.message!.content
        .map((ModelProviderContent content) => content.text)
        .join();
    final String expectedUri = initialUserText == 'fixture:tool-domain-failure'
        ? 'fail:///adele-phase-iv.txt'
        : resourceUri;
    if (outcome.callId != callId ||
        proposalInput.toolProposal?.name != toolName ||
        proposalInput.toolProposal?.arguments.length != 1 ||
        proposalInput.toolProposal?.arguments['uri'] != expectedUri ||
        proposalInput.itemId != itemId ||
        proposalInput.nativeMetadata?.kind != nativeKind ||
        proposalInput.nativeMetadata?.compatibility['model'] != model ||
        proposalInput.nativeMetadata?.compatibility.length != 1 ||
        proposalInput.nativeMetadata?.data['scriptedProof'] !=
            proposalMetadata['scriptedProof'] ||
        proposalInput.nativeMetadata?.data.length != 1) {
      yield _failure(
        ModelProviderFailureKind.invalidRequest,
        'missing_replay_metadata',
        'The proposal correlation or native metadata was not replayed.',
      );
      return;
    }
    final int textIndex = proposalIndex - 1;
    final ModelProviderInput? replayedText = textIndex >= 0
        ? request.input[textIndex]
        : null;
    if (replayedText?.message?.role != ModelProviderMessageRole.assistant ||
        replayedText?.message?.content.length != 1 ||
        replayedText?.message?.content.single.kind !=
            ModelProviderContentKind.text ||
        replayedText?.message?.content.single.text != initialText ||
        replayedText?.itemId != textItemId ||
        replayedText?.nativeMetadata != null) {
      yield _failure(
        ModelProviderFailureKind.invalidRequest,
        'missing_replay_text',
        "The scripted provider's completed assistant text was not replayed exactly.",
      );
      return;
    }
    if (outcomeIndex != request.input.length - 1) {
      yield _failure(
        ModelProviderFailureKind.invalidRequest,
        'trailing_tool_history',
        'The scripted provider does not support input after the continuation outcome.',
      );
      return;
    }
    if (_exceedsOutputLimit(request, 10)) {
      yield _outputLimitTerminal('response-2-limit', inputTokens: 24);
      return;
    }
    yield _observation('Inspection received: ');
    final String finalText = switch (outcome.status) {
      ModelProviderToolOutcomeStatus.success =>
        'Inspection received: ${outcome.content}',
      ModelProviderToolOutcomeStatus.rejected =>
        'The inspection was rejected; the run is complete.',
      ModelProviderToolOutcomeStatus.failed =>
        'Inspection failed: ${outcome.content}',
      ModelProviderToolOutcomeStatus.cancelled =>
        'The inspection was cancelled; the run is complete.',
      ModelProviderToolOutcomeStatus.indeterminate =>
        'The inspection result is indeterminate.',
    };
    yield _text(finalText, 'text-item-2');
    yield _terminal('response-2', inputTokens: 24, outputTokens: 10);
  }
}

bool _exceedsOutputLimit(ModelProviderRequest request, int requiredTokens) =>
    request.maxOutputTokens != null &&
    request.maxOutputTokens! < requiredTokens;

ModelProviderEvent _observation(String delta) => ModelProviderEvent(
  kind: ModelProviderEventKind.observation,
  observation: ModelProviderObservation(
    kind: ModelProviderObservationKind.textDelta,
    textDelta: delta,
    itemId: null,
  ),
  output: null,
  terminal: null,
);

ModelProviderEvent _text(String text, String itemId) => ModelProviderEvent(
  kind: ModelProviderEventKind.output,
  observation: null,
  output: ModelProviderOutput(
    kind: ModelProviderOutputKind.text,
    text: text,
    toolProposal: null,
    itemId: itemId,
    nativeMetadata: null,
  ),
  terminal: null,
);

ModelProviderEvent _proposal(String uri) => ModelProviderEvent(
  kind: ModelProviderEventKind.output,
  observation: null,
  output: ModelProviderOutput(
    kind: ModelProviderOutputKind.toolProposal,
    text: null,
    toolProposal: ModelProviderToolProposal(
      callId: ScriptedCommonModelProvider.callId,
      name: ScriptedCommonModelProvider.toolName,
      arguments: <String, Object?>{'uri': uri},
    ),
    itemId: ScriptedCommonModelProvider.itemId,
    nativeMetadata: ModelProviderNativeEnvelope(
      kind: ScriptedCommonModelProvider.nativeKind,
      compatibility: ScriptedCommonModelProvider.nativeCompatibility,
      data: ScriptedCommonModelProvider.proposalMetadata,
    ),
  ),
  terminal: null,
);

ModelProviderEvent _terminal(
  String responseId, {
  required int inputTokens,
  required int outputTokens,
}) => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.completed,
    incompleteReason: null,
    failure: null,
    providerStopReason: 'scripted_complete',
    usage: ModelProviderUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      providerDetails: const <String, Object?>{'fixture': true},
    ),
    effectiveModel: ScriptedCommonModelProvider.model,
    responseId: responseId,
    requestId: 'request-$responseId',
    nativeState: ModelProviderNativeEnvelope(
      kind: 'scripted-invocation-v1',
      compatibility: const <String, Object?>{
        'model': ScriptedCommonModelProvider.model,
      },
      data: <String, Object?>{'response': responseId},
    ),
  ),
);

ModelProviderEvent _outputLimitTerminal(
  String responseId, {
  required int inputTokens,
}) => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.incomplete,
    incompleteReason: ModelProviderIncompleteReason.outputLimit,
    failure: null,
    providerStopReason: 'scripted_output_limit',
    usage: ModelProviderUsage(
      inputTokens: inputTokens,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      providerDetails: const <String, Object?>{'fixture': true},
    ),
    effectiveModel: ScriptedCommonModelProvider.model,
    responseId: responseId,
    requestId: 'request-$responseId',
    nativeState: null,
  ),
);

ModelProviderEvent _failure(
  ModelProviderFailureKind kind,
  String code,
  String message,
) => ModelProviderEvent(
  kind: ModelProviderEventKind.terminal,
  observation: null,
  output: null,
  terminal: ModelProviderTerminal(
    settlement: ModelProviderSettlement.failed,
    incompleteReason: null,
    failure: ModelProviderFailure(
      kind: kind,
      providerCode: code,
      providerMessage: message,
      providerDetails: const <String, Object?>{},
    ),
    providerStopReason: 'scripted_failure',
    usage: null,
    effectiveModel: ScriptedCommonModelProvider.model,
    responseId: null,
    requestId: null,
    nativeState: null,
  ),
);
