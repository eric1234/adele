import 'dart:collection';

import 'package:adele_orchestration/adele_orchestration.dart';

import 'identifiers.dart';
import 'tool.dart';

export 'package:adele_orchestration/adele_orchestration.dart'
    show
        SemanticMessageRole,
        ModelNativeEnvelope,
        SemanticModelInputItem,
        SemanticNativeInput,
        SemanticMessageInput,
        SemanticToolOutcomeInput,
        SemanticToolProposalInput,
        SemanticToolProposalFailureInput,
        ModelOutputItem,
        ModelNativeOutput,
        ModelTextOutput,
        ModelToolProposalOutput,
        ModelSettlement,
        ModelIncompleteReason,
        ModelUsage,
        ModelTerminalMetadata;

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
