import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';

final class CapabilityBackedAgentModel implements AgentModel {
  CapabilityBackedAgentModel(this._binding);

  final ProviderBinding _binding;

  ProviderDescriptor get provider => _binding.provider;

  @override
  Future<ModelResponse> invoke(ModelRequest request) async {
    final ScriptedModelResponse response =
        await ScriptedModelServiceClient(_binding.requestChannel).invoke(
          ScriptedModelRequest(
            messages: request.messages
                .map(
                  (ModelMessage message) => ScriptedModelMessage(
                    role: switch (message.role) {
                      ModelMessageRole.user => ScriptedModelMessageRole.user,
                      ModelMessageRole.assistant =>
                        ScriptedModelMessageRole.assistant,
                      ModelMessageRole.tool => ScriptedModelMessageRole.tool,
                    },
                    content: message.content,
                    toolCallId: message.toolCallId,
                    toolOutcome: switch (message.toolOutcome) {
                      ToolOutcomeStatus.success =>
                        ScriptedToolOutcomeStatus.success,
                      ToolOutcomeStatus.error =>
                        ScriptedToolOutcomeStatus.error,
                      ToolOutcomeStatus.rejected =>
                        ScriptedToolOutcomeStatus.rejected,
                      null => null,
                    },
                  ),
                )
                .toList(growable: false),
            tools: request.tools
                .map(
                  (ToolDefinition tool) => ScriptedToolDefinition(
                    name: tool.name,
                    description: tool.description,
                    argumentsSchema: tool.argumentsSchema,
                  ),
                )
                .toList(growable: false),
          ),
        );
    final ScriptedToolCall? call = response.toolCall;
    return ModelResponse(
      content: response.content,
      toolCalls: call == null
          ? const <ModelToolCall>[]
          : <ModelToolCall>[
              ModelToolCall(
                id: call.id,
                name: call.name,
                arguments: call.arguments,
              ),
            ],
    );
  }
}

final class ResourceInspectorAgentTool implements AgentTool {
  ResourceInspectorAgentTool(this._binding);

  final ProviderBinding _binding;
  int _invocationCount = 0;

  ProviderDescriptor get provider => _binding.provider;
  int get invocationCount => _invocationCount;

  @override
  ToolDefinition get definition => ToolDefinition(
    name: 'inspect_resource',
    description: 'Inspect one resource identified by an absolute URI.',
    argumentsSchema: const <String, Object?>{
      'type': 'object',
      'required': <Object?>['uri'],
      'properties': <String, Object?>{
        'uri': <String, Object?>{'type': 'string', 'format': 'uri'},
      },
      'additionalProperties': false,
    },
  );

  @override
  Future<ToolResult> invoke(Map<String, Object?> arguments) async {
    if (arguments.length != 1 || arguments['uri'] is! String) {
      throw const ToolArgumentValidationException(
        'inspect_resource requires exactly one string argument named uri.',
      );
    }
    final Uri uri = Uri.parse(arguments['uri']! as String);
    if (!uri.isAbsolute) {
      throw const ToolArgumentValidationException(
        'inspect_resource uri must be absolute.',
      );
    }
    _invocationCount++;
    final ResourceInspection inspection = await ResourceInspectorServiceClient(
      _binding.requestChannel,
    ).inspect(ResourceRef(uri: uri));
    return ToolResult(content: inspection.summary);
  }
}

final class ToolArgumentValidationException implements FormatException {
  const ToolArgumentValidationException(this.message);

  @override
  final String message;

  @override
  Object? get source => null;

  @override
  int? get offset => null;

  @override
  String toString() => 'ToolArgumentValidationException: $message';
}
