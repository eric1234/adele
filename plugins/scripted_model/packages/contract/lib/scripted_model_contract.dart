/// Deterministic Phase IV model-provider capability and transport declarations.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'scripted_model_contract.g.dart';

final capabilities.CapabilityKey agentModelCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.agent.model'),
      majorVersion: 1,
    );

final capabilities.ProviderId scriptedModelProviderId = capabilities.ProviderId(
  'dev.adele.agent-model.scripted',
);

enum ScriptedModelMessageRole { user, assistant, tool }

enum ScriptedToolOutcomeStatus { success, error, rejected }

@AdeleValue('agentModel.message')
final class ScriptedModelMessage {
  const ScriptedModelMessage({
    required this.role,
    required this.content,
    required this.toolCallId,
    required this.toolOutcome,
  });

  final ScriptedModelMessageRole role;
  final String content;
  final String? toolCallId;
  final ScriptedToolOutcomeStatus? toolOutcome;
}

@AdeleValue('agentModel.toolDefinition')
final class ScriptedToolDefinition {
  const ScriptedToolDefinition({
    required this.name,
    required this.description,
    required this.argumentsSchema,
  });

  final String name;
  final String description;
  final Map<String, Object?> argumentsSchema;
}

@AdeleValue('agentModel.request')
final class ScriptedModelRequest {
  const ScriptedModelRequest({required this.messages, required this.tools});

  final List<ScriptedModelMessage> messages;
  final List<ScriptedToolDefinition> tools;
}

@AdeleValue('agentModel.toolCall')
final class ScriptedToolCall {
  const ScriptedToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

@AdeleValue('agentModel.response')
final class ScriptedModelResponse {
  const ScriptedModelResponse({required this.content, required this.toolCall});

  final String content;
  final ScriptedToolCall? toolCall;
}

@AdeleService('agentModel')
abstract interface class ScriptedModelService {
  @AdeleMethod('invoke')
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request);
}

@AdeleFailure('agentModel.failure')
final class ScriptedModelFailure implements Exception {
  const ScriptedModelFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'ScriptedModelFailure($code): $message';
}
