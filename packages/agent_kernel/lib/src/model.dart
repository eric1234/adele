import 'identifiers.dart';
import 'tool.dart';

enum SemanticMessageRole { user, assistant }

sealed class SemanticModelInputItem {
  const SemanticModelInputItem();
}

final class SemanticMessageInput extends SemanticModelInputItem {
  SemanticMessageInput({required this.role, required this.content}) {
    if (content.trim().isEmpty) {
      throw const FormatException(
        'Semantic message content must not be empty.',
      );
    }
  }

  final SemanticMessageRole role;
  final String content;
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
  const SemanticToolProposalInput({required this.proposal});

  final ProviderToolProposal proposal;
}

final class SemanticToolProposalFailureInput extends SemanticModelInputItem {
  SemanticToolProposalFailureInput({required this.failure});

  final ToolProposalFailure failure;
}

final class SemanticModelRequest {
  SemanticModelRequest({
    required this.invocationId,
    required Iterable<SemanticModelInputItem> input,
    required this.tools,
  }) : input = List<SemanticModelInputItem>.unmodifiable(input);

  final ModelInvocationId invocationId;
  final List<SemanticModelInputItem> input;
  final MaterializedToolSet tools;
}

sealed class ModelOutputItem {
  const ModelOutputItem();
}

final class ModelTextOutput extends ModelOutputItem {
  ModelTextOutput(this.content) {
    if (content.isEmpty) {
      throw const FormatException('Model text output must not be empty.');
    }
  }

  final String content;
}

final class ModelToolProposalOutput extends ModelOutputItem {
  const ModelToolProposalOutput(this.proposal);

  final ProviderToolProposal proposal;
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

sealed class ModelTerminalEvent extends ModelEvent {
  const ModelTerminalEvent(super.invocationId);
}

final class ModelInvocationCompletedEvent extends ModelTerminalEvent {
  const ModelInvocationCompletedEvent({required ModelInvocationId invocationId})
    : super(invocationId);
}

final class ModelInvocationFailedEvent extends ModelTerminalEvent {
  const ModelInvocationFailedEvent({
    required ModelInvocationId invocationId,
    required this.error,
    this.stackTrace,
  }) : super(invocationId);

  final Object error;
  final StackTrace? stackTrace;
}

abstract interface class ModelPort {
  Stream<ModelEvent> invoke(SemanticModelRequest request);
}

final class ModelInvocationObservation {
  ModelInvocationObservation({
    required Iterable<ModelOutputItem> output,
    required this.terminal,
  }) : output = List<ModelOutputItem>.unmodifiable(output);

  final List<ModelOutputItem> output;
  final ModelTerminalEvent terminal;
}

Future<ModelInvocationObservation> collectModelInvocation(
  Stream<ModelEvent> events, {
  required ModelInvocationId invocationId,
  void Function(ModelOutputItem item)? onOutput,
}) async {
  final List<ModelOutputItem> output = <ModelOutputItem>[];
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
  return ModelInvocationObservation(output: output, terminal: terminal);
}

final class ModelInvocationContractException implements Exception {
  const ModelInvocationContractException(this.message);

  final String message;

  @override
  String toString() => 'ModelInvocationContractException: $message';
}
