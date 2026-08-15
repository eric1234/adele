/// Common plugin-facing model-provider capability contract.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'adele_model_provider.g.dart';

final capabilities.CapabilityKey modelProviderCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.model.provider'),
      majorVersion: 1,
    );

enum ModelProviderMessageRole { user, assistant }

enum ModelProviderInputKind { message, toolProposal, toolOutcome }

enum ModelProviderContentKind { text }

enum ModelProviderToolOutcomeStatus {
  success,
  rejected,
  failed,
  cancelled,
  indeterminate,
}

enum ModelProviderToolChoice { auto, none }

enum ModelProviderEventKind { observation, output, terminal }

enum ModelProviderObservationKind { textDelta }

enum ModelProviderOutputKind { text, toolProposal }

enum ModelProviderSettlement { completed, incomplete, refused, failed }

enum ModelProviderIncompleteReason { outputLimit, contextLimit, other }

enum ModelProviderFailureKind {
  invalidRequest,
  unsupportedRequest,
  authentication,
  permission,
  rateLimited,
  unavailable,
  capacity,
  transport,
  malformedResponse,
  providerFailure,
  unknown,
}

@AdeleValue('modelProvider.nativeEnvelope')
final class ModelProviderNativeEnvelope {
  ModelProviderNativeEnvelope({
    required this.kind,
    required this.compatibility,
    required this.data,
  }) {
    _requireNonEmpty(kind, 'Native state kind');
  }

  final String kind;
  final Map<String, Object?> compatibility;
  final Map<String, Object?> data;
}

@AdeleValue('modelProvider.content')
final class ModelProviderContent {
  ModelProviderContent({required this.kind, required this.text}) {
    if (kind == ModelProviderContentKind.text) {
      _requireNonEmpty(text, 'Text content');
    }
  }

  final ModelProviderContentKind kind;
  final String text;
}

@AdeleValue('modelProvider.message')
final class ModelProviderMessage {
  ModelProviderMessage({required this.role, required this.content}) {
    if (content.isEmpty) {
      throw const FormatException('A message requires content.');
    }
  }

  final ModelProviderMessageRole role;
  final List<ModelProviderContent> content;
}

@AdeleValue('modelProvider.toolProposal')
final class ModelProviderToolProposal {
  ModelProviderToolProposal({
    required this.callId,
    required this.name,
    required this.arguments,
  }) {
    _requireNonEmpty(callId, 'Provider call ID');
    _requireNonEmpty(name, 'Tool name');
  }

  final String callId;
  final String name;
  final Map<String, Object?> arguments;
}

@AdeleValue('modelProvider.toolOutcome')
final class ModelProviderToolOutcome {
  ModelProviderToolOutcome({
    required this.callId,
    required this.status,
    required this.content,
  }) {
    _requireNonEmpty(callId, 'Provider call ID');
    _requireNonEmpty(content, 'Tool outcome content');
  }

  final String callId;
  final ModelProviderToolOutcomeStatus status;
  final String content;
}

@AdeleValue('modelProvider.input')
final class ModelProviderInput {
  ModelProviderInput({
    required this.kind,
    required this.message,
    required this.toolProposal,
    required this.toolOutcome,
    required this.itemId,
    required this.nativeMetadata,
  }) {
    final int payloads =
        (message == null ? 0 : 1) +
        (toolProposal == null ? 0 : 1) +
        (toolOutcome == null ? 0 : 1);
    if (payloads != 1 ||
        (kind == ModelProviderInputKind.message) != (message != null) ||
        (kind == ModelProviderInputKind.toolProposal) !=
            (toolProposal != null) ||
        (kind == ModelProviderInputKind.toolOutcome) != (toolOutcome != null)) {
      throw const FormatException(
        'Input kind must match exactly one input payload.',
      );
    }
    _requireOptionalNonEmpty(itemId, 'Provider item ID');
  }

  final ModelProviderInputKind kind;
  final ModelProviderMessage? message;
  final ModelProviderToolProposal? toolProposal;
  final ModelProviderToolOutcome? toolOutcome;
  final String? itemId;
  final ModelProviderNativeEnvelope? nativeMetadata;
}

@AdeleValue('modelProvider.tool')
final class ModelProviderTool {
  ModelProviderTool({
    required this.name,
    required this.description,
    required this.argumentsSchema,
  }) {
    _requireNonEmpty(name, 'Tool name');
    _requireNonEmpty(description, 'Tool description');
  }

  final String name;
  final String description;
  final Map<String, Object?> argumentsSchema;
}

@AdeleValue('modelProvider.request')
final class ModelProviderRequest {
  ModelProviderRequest({
    required this.model,
    required this.instructions,
    required this.input,
    required this.tools,
    required this.toolChoice,
    required this.maxOutputTokens,
    required this.providerOptions,
    required this.nativeState,
  }) {
    _requireNonEmpty(model, 'Selected model');
    if (maxOutputTokens != null && maxOutputTokens! <= 0) {
      throw const FormatException('Maximum output tokens must be positive.');
    }
  }

  final String model;
  final String instructions;
  final List<ModelProviderInput> input;
  final List<ModelProviderTool> tools;
  final ModelProviderToolChoice toolChoice;
  final int? maxOutputTokens;
  final Map<String, Object?> providerOptions;
  final ModelProviderNativeEnvelope? nativeState;
}

@AdeleValue('modelProvider.observation')
final class ModelProviderObservation {
  ModelProviderObservation({
    required this.kind,
    required this.textDelta,
    required this.itemId,
  }) {
    if (kind == ModelProviderObservationKind.textDelta) {
      if (textDelta.isEmpty) {
        throw const FormatException('Text delta must not be empty.');
      }
    }
    _requireOptionalNonEmpty(itemId, 'Provider item ID');
  }

  final ModelProviderObservationKind kind;
  final String textDelta;
  final String? itemId;
}

@AdeleValue('modelProvider.output')
final class ModelProviderOutput {
  ModelProviderOutput({
    required this.kind,
    required this.text,
    required this.toolProposal,
    required this.itemId,
    required this.nativeMetadata,
  }) {
    final bool textMatches =
        kind == ModelProviderOutputKind.text && text != null;
    final bool proposalMatches =
        kind == ModelProviderOutputKind.toolProposal && toolProposal != null;
    if ((textMatches ? 1 : 0) + (proposalMatches ? 1 : 0) != 1 ||
        (text != null && !textMatches) ||
        (toolProposal != null && !proposalMatches)) {
      throw const FormatException(
        'Output kind must match exactly one output payload.',
      );
    }
    if (text != null) _requireNonEmpty(text!, 'Completed text');
    _requireOptionalNonEmpty(itemId, 'Provider item ID');
  }

  final ModelProviderOutputKind kind;
  final String? text;
  final ModelProviderToolProposal? toolProposal;
  final String? itemId;
  final ModelProviderNativeEnvelope? nativeMetadata;
}

@AdeleValue('modelProvider.failure')
final class ModelProviderFailure {
  ModelProviderFailure({
    required this.kind,
    required this.providerCode,
    required this.providerMessage,
    required this.providerDetails,
  }) {
    _requireOptionalNonEmpty(providerCode, 'Provider failure code');
    _requireOptionalNonEmpty(providerMessage, 'Provider failure message');
  }

  final ModelProviderFailureKind kind;
  final String? providerCode;
  final String? providerMessage;
  final Map<String, Object?> providerDetails;
}

@AdeleValue('modelProvider.usage')
final class ModelProviderUsage {
  ModelProviderUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.providerDetails,
  }) {
    for (final int? count in <int?>[
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheWriteTokens,
    ]) {
      if (count != null && count < 0) {
        throw const FormatException('Usage counts must not be negative.');
      }
    }
  }

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final Map<String, Object?> providerDetails;
}

@AdeleValue('modelProvider.terminal')
final class ModelProviderTerminal {
  ModelProviderTerminal({
    required this.settlement,
    required this.incompleteReason,
    required this.failure,
    required this.providerStopReason,
    required this.usage,
    required this.effectiveModel,
    required this.responseId,
    required this.requestId,
    required this.nativeState,
  }) {
    if ((settlement == ModelProviderSettlement.failed) != (failure != null)) {
      throw const FormatException(
        'Only failed settlement requires a failure classification.',
      );
    }
    if ((settlement == ModelProviderSettlement.incomplete) !=
        (incompleteReason != null)) {
      throw const FormatException(
        'Only incomplete settlement requires an incomplete reason.',
      );
    }
    _requireOptionalNonEmpty(providerStopReason, 'Provider stop reason');
    _requireOptionalNonEmpty(effectiveModel, 'Effective model');
    _requireOptionalNonEmpty(responseId, 'Provider response ID');
    _requireOptionalNonEmpty(requestId, 'Provider request ID');
  }

  final ModelProviderSettlement settlement;
  final ModelProviderIncompleteReason? incompleteReason;
  final ModelProviderFailure? failure;
  final String? providerStopReason;
  final ModelProviderUsage? usage;
  final String? effectiveModel;
  final String? responseId;
  final String? requestId;
  final ModelProviderNativeEnvelope? nativeState;
}

@AdeleValue('modelProvider.event')
final class ModelProviderEvent {
  ModelProviderEvent({
    required this.kind,
    required this.observation,
    required this.output,
    required this.terminal,
  }) {
    final int payloads =
        (observation == null ? 0 : 1) +
        (output == null ? 0 : 1) +
        (terminal == null ? 0 : 1);
    if (payloads != 1 ||
        (kind == ModelProviderEventKind.observation) != (observation != null) ||
        (kind == ModelProviderEventKind.output) != (output != null) ||
        (kind == ModelProviderEventKind.terminal) != (terminal != null)) {
      throw const FormatException(
        'Event kind must match exactly one category payload.',
      );
    }
  }

  final ModelProviderEventKind kind;
  final ModelProviderObservation? observation;
  final ModelProviderOutput? output;
  final ModelProviderTerminal? terminal;
}

@AdeleService('modelProvider')
abstract interface class ModelProviderService {
  @AdeleMethod('invoke')
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request);
}

/// Contract/backend failure only; provider API outcomes use failed terminals.
@AdeleFailure('modelProvider.contractFailure')
final class ModelProviderContractFailure implements Exception {
  const ModelProviderContractFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ModelProviderContractFailure($code): $message';
}

void _requireNonEmpty(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
}

void _requireOptionalNonEmpty(String? value, String label) {
  if (value != null) _requireNonEmpty(value, label);
}
