import 'dart:collection';

import 'identifiers.dart';
import 'tool.dart';

enum SemanticMessageRole { user, assistant }

final class ModelNativeEnvelope {
  ModelNativeEnvelope({
    required String kind,
    required Map<String, Object?> compatibility,
    required Map<String, Object?> data,
  }) : kind = _requireNonEmpty(kind, 'Model native envelope kind'),
       compatibility = _freezeMap(compatibility),
       data = _freezeMap(data);

  final String kind;
  final Map<String, Object?> compatibility;
  final Map<String, Object?> data;
}

sealed class SemanticModelInputItem {
  const SemanticModelInputItem();
}

final class SemanticMessageInput extends SemanticModelInputItem {
  SemanticMessageInput({
    required this.role,
    required this.content,
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    if (content.isEmpty) {
      throw const FormatException(
        'Semantic message content must not be empty.',
      );
    }
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final SemanticMessageRole role;
  final String content;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

final class SemanticToolOutcomeInput extends SemanticModelInputItem {
  SemanticToolOutcomeInput({
    required this.providerCallId,
    required this.outcome,
  }) {
    if (providerCallId.trim().isEmpty) {
      throw const FormatException('Provider call ID must not be empty.');
    }
  }

  final String providerCallId;
  final ToolOutcome outcome;
}

final class SemanticToolProposalInput extends SemanticModelInputItem {
  SemanticToolProposalInput({
    required this.proposal,
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final ProviderToolProposal proposal;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

final class SemanticToolProposalFailureInput extends SemanticModelInputItem {
  SemanticToolProposalFailureInput({required this.failure});

  final ToolProposalFailure failure;
}

final class SemanticModelRequest {
  SemanticModelRequest({
    required this.invocationId,
    this.instructions = '',
    required Iterable<SemanticModelInputItem> input,
    required this.tools,
  }) : input = List<SemanticModelInputItem>.unmodifiable(input);

  final ModelInvocationId invocationId;
  final String instructions;
  final List<SemanticModelInputItem> input;
  final MaterializedToolSet tools;
}

sealed class ModelOutputItem {
  const ModelOutputItem();
}

final class ModelTextOutput extends ModelOutputItem {
  ModelTextOutput(
    this.content, {
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    if (content.isEmpty) {
      throw const FormatException('Model text output must not be empty.');
    }
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final String content;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

final class ModelToolProposalOutput extends ModelOutputItem {
  ModelToolProposalOutput(
    this.proposal, {
    this.providerItemId,
    this.providerNativeMetadata,
  }) {
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final ProviderToolProposal proposal;
  final String? providerItemId;
  final ModelNativeEnvelope? providerNativeMetadata;
}

sealed class ModelObservation {
  const ModelObservation();
}

final class ModelTextDeltaObservation extends ModelObservation {
  ModelTextDeltaObservation(this.delta, {this.providerItemId}) {
    if (delta.isEmpty) {
      throw const FormatException('Model text delta must not be empty.');
    }
    _requireOptionalNonEmpty(providerItemId, 'Provider item ID');
  }

  final String delta;
  final String? providerItemId;
}

sealed class ModelEvent {
  const ModelEvent(this.invocationId);

  final ModelInvocationId invocationId;
}

final class ModelOutputItemCompleted extends ModelEvent {
  const ModelOutputItemCompleted({
    required ModelInvocationId invocationId,
    required this.item,
  }) : super(invocationId);

  final ModelOutputItem item;
}

final class ModelObservationEvent extends ModelEvent {
  const ModelObservationEvent({
    required ModelInvocationId invocationId,
    required this.observation,
  }) : super(invocationId);

  final ModelObservation observation;
}

enum ModelSettlement { completed, incomplete, refused }

enum ModelIncompleteReason { outputLimit, contextLimit, other }

enum ModelFailureKind {
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

final class ModelFailure implements Exception {
  ModelFailure({
    required this.kind,
    this.providerCode,
    this.providerMessage,
    Map<String, Object?> providerDetails = const <String, Object?>{},
    this.cause,
  }) : providerDetails = _freezeMap(providerDetails) {
    _requireOptionalNonEmpty(providerCode, 'Provider failure code');
    _requireOptionalNonEmpty(providerMessage, 'Provider failure message');
  }

  final ModelFailureKind kind;
  final String? providerCode;
  final String? providerMessage;
  final Map<String, Object?> providerDetails;
  final Object? cause;
}

final class ModelUsage {
  ModelUsage({
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    Map<String, Object?> providerDetails = const <String, Object?>{},
  }) : providerDetails = _freezeMap(providerDetails) {
    for (final int? value in <int?>[
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheWriteTokens,
    ]) {
      if (value != null && value < 0) {
        throw const FormatException('Model usage counts must not be negative.');
      }
    }
  }

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final Map<String, Object?> providerDetails;
}

final class ModelTerminalMetadata {
  ModelTerminalMetadata({
    this.effectiveModel,
    this.providerResponseId,
    this.providerRequestId,
    this.providerStopReason,
    this.usage,
    this.providerNativeState,
  }) {
    _requireOptionalNonEmpty(effectiveModel, 'Effective model');
    _requireOptionalNonEmpty(providerResponseId, 'Provider response ID');
    _requireOptionalNonEmpty(providerRequestId, 'Provider request ID');
    _requireOptionalNonEmpty(providerStopReason, 'Provider stop reason');
  }

  final String? effectiveModel;
  final String? providerResponseId;
  final String? providerRequestId;
  final String? providerStopReason;
  final ModelUsage? usage;
  final ModelNativeEnvelope? providerNativeState;
}

sealed class ModelTerminalEvent extends ModelEvent {
  const ModelTerminalEvent(super.invocationId);
}

final class ModelInvocationSettledEvent extends ModelTerminalEvent {
  ModelInvocationSettledEvent({
    required ModelInvocationId invocationId,
    this.settlement = ModelSettlement.completed,
    this.incompleteReason,
    ModelTerminalMetadata? metadata,
  }) : metadata = metadata ?? ModelTerminalMetadata(),
       super(invocationId) {
    if ((settlement == ModelSettlement.incomplete) !=
        (incompleteReason != null)) {
      throw const FormatException(
        'Only incomplete settlement requires an incomplete reason.',
      );
    }
  }

  final ModelSettlement settlement;
  final ModelIncompleteReason? incompleteReason;
  final ModelTerminalMetadata metadata;
}

final class ModelInvocationFailedEvent extends ModelTerminalEvent {
  const ModelInvocationFailedEvent({
    required ModelInvocationId invocationId,
    required this.error,
    this.stackTrace,
    this.semanticTerminalMetadata,
  }) : super(invocationId);

  final Object error;
  final StackTrace? stackTrace;
  final ModelTerminalMetadata? semanticTerminalMetadata;
}

abstract interface class ModelPort {
  Stream<ModelEvent> invoke(SemanticModelRequest request);
}

final class ModelInvocationObservation {
  ModelInvocationObservation({
    required Iterable<ModelObservation> observations,
    required Iterable<ModelOutputItem> output,
    required this.terminal,
  }) : observations = List<ModelObservation>.unmodifiable(observations),
       output = List<ModelOutputItem>.unmodifiable(output);

  final List<ModelObservation> observations;
  final List<ModelOutputItem> output;
  final ModelTerminalEvent terminal;
}

Future<ModelInvocationObservation> collectModelInvocation(
  Stream<ModelEvent> events, {
  required ModelInvocationId invocationId,
  void Function(ModelObservation observation)? onObservation,
  void Function(ModelOutputItem item)? onOutput,
}) async {
  final List<ModelOutputItem> output = <ModelOutputItem>[];
  final List<ModelObservation> observations = <ModelObservation>[];
  ModelTerminalEvent? terminal;
  await for (final ModelEvent event in events) {
    if (event.invocationId != invocationId) {
      throw const ModelInvocationContractException(
        'A model event used the wrong invocation identity.',
      );
    }
    if (terminal != null) {
      throw const ModelInvocationContractException(
        'A model event followed the terminal event.',
      );
    }
    switch (event) {
      case ModelObservationEvent(:final observation):
        observations.add(observation);
        onObservation?.call(observation);
      case ModelOutputItemCompleted(:final item):
        output.add(item);
        onOutput?.call(item);
      case ModelTerminalEvent():
        terminal = event;
    }
  }
  if (terminal == null) {
    throw const ModelInvocationContractException(
      'The model stream ended without a terminal event.',
    );
  }
  return ModelInvocationObservation(
    observations: observations,
    output: output,
    terminal: terminal,
  );
}

void _requireOptionalNonEmpty(String? value, String label) {
  if (value != null && value.trim().isEmpty) {
    throw FormatException('$label must not be empty.');
  }
}

String _requireNonEmpty(String value, String label) {
  if (value.trim().isEmpty) throw FormatException('$label must not be empty.');
  return value;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    _freezeValue(source, 0, HashSet<Object>.identity())!
        as Map<String, Object?>;

const int _structuredMaxDepth = 64;

Object? _freezeValue(Object? value, int depth, Set<Object> active) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('Structured values require finite doubles.');
    }
    return value;
  }
  if (depth >= _structuredMaxDepth) {
    throw const FormatException('Structured value exceeds maximum depth 64.');
  }
  if (value is List<Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Cyclic structured value.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((Object? item) => _freezeValue(item, depth + 1, active)),
      );
    } finally {
      active.remove(value);
    }
  }
  if (value is Map<String, Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Cyclic structured value.');
    }
    try {
      return Map<String, Object?>.unmodifiable(
        value.map(
          (String key, Object? item) => MapEntry<String, Object?>(
            key,
            _freezeValue(item, depth + 1, active),
          ),
        ),
      );
    } finally {
      active.remove(value);
    }
  }
  throw FormatException('Unsupported structured value: ${value.runtimeType}.');
}

final class ModelInvocationContractException implements Exception {
  const ModelInvocationContractException(this.message);

  final String message;

  @override
  String toString() => 'ModelInvocationContractException: $message';
}
