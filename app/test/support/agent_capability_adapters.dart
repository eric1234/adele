import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:resource_inspector_contract/resource_inspector_contract.dart';

final ToolId resourceInspectionToolId = ToolId(
  'dev.adele.tool.resource-inspection',
);

final class ResourceInspectorToolExecutable implements ToolExecutable {
  ResourceInspectorToolExecutable(this._binding);

  final ProviderBinding _binding;
  int _invocationCount = 0;

  ProviderDescriptor get provider => _binding.provider;
  int get invocationCount => _invocationCount;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: resourceInspectionToolId,
      description: 'Inspect one resource.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'inspect_resource',
      description: 'Inspect one resource identified by an absolute URI.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['uri'],
        'properties': <String, Object?>{
          'uri': <String, Object?>{'type': 'string', 'format': 'uri'},
        },
        'additionalProperties': false,
      },
    ),
    executable: this,
  );

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    final Uri uri = _resourceUri(arguments);
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.resourceInspection],
      targets: <EffectTarget>[EffectTarget(uri: uri)],
      summary: 'Inspect $uri.',
    );
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final Uri uri = _resourceUri(arguments);
    try {
      final ResourceInspectorService client = ResourceInspectorServiceClient(
        _binding.requestChannel,
      );
      _invocationCount++;
      final ResourceInspection inspection = await client.inspect(
        ResourceRef(uri: uri),
      );
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: inspection.summary,
          hostData: <String, Object?>{
            'resource': <String, Object?>{
              'uri': inspection.resource.uri.toString(),
              'mediaType': inspection.resource.mediaType,
            },
            'providerLabel': inspection.providerLabel,
            'summary': inspection.summary,
          },
        ),
      );
    } on ProviderUnavailable catch (error) {
      yield ToolExecutionTerminal(_bindingFailureOutcome(error));
    } on ProviderEndpointUnavailable catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.infrastructure,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent:
              'The resource-inspection provider endpoint is unavailable.',
          hostDiagnostic: error.toString(),
          cause: error,
        ),
      );
    } on ResourceInspectorFailure catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: EffectCertainty.uncertain,
          modelContent: 'Resource inspection failed: ${error.message}',
          hostData: <String, Object?>{
            'resource': <String, Object?>{'uri': uri.toString()},
            'code': error.code,
            'details': error.details,
          },
          hostDiagnostic: error.message,
          cause: error,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _infrastructureOutcome('Resource inspection transport failed.', error),
      );
    }
  }

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    if (proposedArguments.length != 1 || proposedArguments['uri'] is! String) {
      throw const ToolArgumentValidationException(
        'inspect_resource requires exactly one string argument named uri.',
      );
    }
    final Uri uri;
    try {
      uri = Uri.parse(proposedArguments['uri']! as String);
    } on FormatException catch (error) {
      throw ToolArgumentValidationException(
        'inspect_resource uri is invalid: ${error.message}',
      );
    }
    if (!uri.isAbsolute) {
      throw const ToolArgumentValidationException(
        'inspect_resource uri must be absolute.',
      );
    }
    return CanonicalToolArguments(<String, Object?>{'uri': uri.toString()});
  }

  @override
  void validateBinding() {
    try {
      _binding.requestChannel;
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw StaleToolBindingException(
          'The materialized ResourceInspector provider is stale.',
          cause: error,
        );
      }
      throw ToolBindingUnavailableException(
        'The materialized ResourceInspector provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw ToolBindingUnavailableException(
        'The materialized ResourceInspector endpoint is unavailable.',
        cause: error,
      );
    }
  }
}

ToolOutcome _bindingFailureOutcome(ProviderUnavailable error) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: error.stale
      ? ToolFailureKind.staleBinding
      : ToolFailureKind.infrastructure,
  effectCertainty: EffectCertainty.knownNotOccurred,
  modelContent: error.stale
      ? 'The approved resource-inspection binding is stale.'
      : 'The resource-inspection provider is unavailable.',
  hostDiagnostic: error.message,
  cause: error,
);

ToolOutcome _infrastructureOutcome(String content, Object cause) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: ToolFailureKind.infrastructure,
  effectCertainty: EffectCertainty.uncertain,
  modelContent: content,
  hostDiagnostic: cause.toString(),
  cause: cause,
);

Uri _resourceUri(CanonicalToolArguments arguments) =>
    Uri.parse(arguments.snapshot['uri']! as String);
