/// Deterministic unary transport declarations for the Phase IV model fixture.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';

part 'scripted_model_contract.g.dart';

final capabilities.CapabilityKey scriptedModelFixtureCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.fixture.scripted-model'),
      majorVersion: 1,
    );

final capabilities.ProviderId scriptedModelFixtureProviderId =
    capabilities.ProviderId('dev.adele.fixture.scripted-model.provider');

enum ScriptedModelMessageRole { user, assistant, tool }

enum ScriptedToolOutcomeStatus {
  success,
  userRejected,
  policyDenied,
  failure,
  cancelled,
  indeterminate,
}

@AdeleValue('scriptedModelFixture.message')
final class ScriptedModelMessage {
  const ScriptedModelMessage({
    required this.role,
    required this.content,
    required this.toolCallId,
    required this.toolOutcome,
    required this.toolProposal,
  });

  final ScriptedModelMessageRole role;
  final String content;
  final String? toolCallId;
  final ScriptedToolOutcomeStatus? toolOutcome;
  final ScriptedToolCall? toolProposal;
}

@AdeleValue('scriptedModelFixture.toolDefinition')
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

@AdeleValue('scriptedModelFixture.request')
final class ScriptedModelRequest {
  const ScriptedModelRequest({required this.messages, required this.tools});

  final List<ScriptedModelMessage> messages;
  final List<ScriptedToolDefinition> tools;
}

@AdeleValue('scriptedModelFixture.toolCall')
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

@AdeleValue('scriptedModelFixture.response')
final class ScriptedModelResponse {
  const ScriptedModelResponse({required this.content, required this.toolCall});

  final String content;
  final ScriptedToolCall? toolCall;
}

@AdeleService('scriptedModelFixture')
abstract interface class ScriptedModelFixtureService {
  @AdeleMethod('invoke')
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request);
}

@AdeleFailure('scriptedModelFixture.failure')
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
