import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:agent_kernel/agent_kernel.dart';

final ToolId environmentFileReadToolId = ToolId(
  'dev.adele.tool.environment-file-read',
);

Future<ToolCatalog> buildEnvironmentToolCatalogForSession({
  required SessionId sessionId,
  required EnvironmentRuntime environmentRuntime,
}) async {
  final SessionEnvironmentAuthority authority = environmentRuntime.store
      .requireSessionAuthority(sessionId);
  final EnvironmentMaterialization materialization = await environmentRuntime
      .materialize(authority.environmentId);
  if (materialization.environment.taskId != authority.taskId) {
    throw StateError(
      'Session $sessionId has inconsistent Task and Environment authority.',
    );
  }
  return ToolCatalog()..register(
    EnvironmentReadFileToolExecutable._(
      authority: authority,
      materialization: materialization,
    ).registration,
  );
}

final class EnvironmentReadFileToolExecutable implements ToolExecutable {
  EnvironmentReadFileToolExecutable._({
    required SessionEnvironmentAuthority authority,
    required EnvironmentMaterialization materialization,
  }) : _authority = authority,
       _materialization = materialization {
    if (materialization.environment.id != authority.environmentId ||
        materialization.environment.taskId != authority.taskId) {
      throw ArgumentError(
        'The Environment materialization does not match Session authority.',
      );
    }
  }

  final SessionEnvironmentAuthority _authority;
  final EnvironmentMaterialization _materialization;
  int _invocationCount = 0;

  ProviderDescriptor get provider => _materialization.providerDescriptor;
  int get invocationCount => _invocationCount;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: environmentFileReadToolId,
      description: 'Read one file from the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'read_file',
      description:
          'Read one UTF-8 file from the current Session Environment by its relative path.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['relativePath'],
        'properties': <String, Object?>{
          'relativePath': <String, Object?>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
    executable: this,
  );

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) {
    if (proposedArguments.length != 1 ||
        proposedArguments['relativePath'] is! String) {
      throw const ToolArgumentValidationException(
        'read_file requires exactly one string argument named relativePath.',
      );
    }
    return CanonicalToolArguments(<String, Object?>{
      'relativePath': proposedArguments['relativePath']! as String,
    });
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    _requireAuthorizedSession(context);
    final String relativePath = arguments.snapshot['relativePath']! as String;
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.sourceRead],
      targets: <EffectTarget>[
        EffectTarget(
          uri: Uri(
            scheme: 'adele-environment',
            path: '/${_materialization.environment.id.value}/$relativePath',
          ),
        ),
      ],
      summary: 'Read Environment file $relativePath.',
    );
  }

  @override
  void validateBinding() {
    try {
      _materialization.validateBinding();
    } on ProviderUnavailable catch (error) {
      if (error.stale) {
        throw StaleToolBindingException(
          'The materialized Environment provider is stale.',
          cause: error,
        );
      }
      throw ToolBindingUnavailableException(
        'The materialized Environment provider is unavailable.',
        cause: error,
      );
    } on ProviderEndpointUnavailable catch (error) {
      throw ToolBindingUnavailableException(
        'The materialized Environment endpoint is unavailable.',
        cause: error,
      );
    }
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final String relativePath = arguments.snapshot['relativePath']! as String;
    try {
      _requireAuthorizedSession(context);
      _materialization.validateBinding();
      _invocationCount++;
      final EnvironmentTextFile file = await _materialization.provider.readFile(
        _materialization.environment.id,
        relativePath,
      );
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: 'File: ${file.relativePath}\n${file.text}',
          hostData: <String, Object?>{
            'environmentId': _materialization.environment.id.value,
            'relativePath': file.relativePath,
            'sizeBytes': file.sizeBytes,
            'text': file.text,
          },
        ),
      );
    } on ProviderUnavailable catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: error.stale
              ? ToolFailureKind.staleBinding
              : ToolFailureKind.infrastructure,
          effectCertainty: EffectCertainty.knownNotOccurred,
          modelContent: error.stale
              ? 'The authorized Environment binding is stale.'
              : 'The authorized Environment provider is unavailable.',
          hostDiagnostic: error.message,
          cause: error,
        ),
      );
    } on ProviderEndpointUnavailable catch (error) {
      yield ToolExecutionTerminal(
        _infrastructureFailure(
          'The authorized Environment provider endpoint is unavailable.',
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on EnvironmentFailure catch (error) {
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: EffectCertainty.uncertain,
          modelContent: 'Environment read failed: ${error.message}',
          hostData: <String, Object?>{
            'environmentId': _materialization.environment.id.value,
            'relativePath': relativePath,
            'code': error.code,
            'details': error.details,
          },
          hostDiagnostic: error.message,
          cause: error,
        ),
      );
    } on _SessionAuthorityViolation catch (error) {
      yield ToolExecutionTerminal(
        _infrastructureFailure(
          'The Read File tool is not authorized for this Session.',
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _infrastructureFailure('Environment file read failed.', error),
      );
    }
  }

  void _requireAuthorizedSession(ToolExecutionContext context) {
    if (context.sessionId != _authority.sessionId) {
      throw _SessionAuthorityViolation(
        'The Read File tool is not authorized for Session ${context.sessionId}.',
      );
    }
  }
}

final class _SessionAuthorityViolation implements Exception {
  const _SessionAuthorityViolation(this.message);

  final String message;

  @override
  String toString() => 'SessionAuthorityViolation: $message';
}

ToolOutcome _infrastructureFailure(
  String modelContent,
  Object cause, {
  EffectCertainty certainty = EffectCertainty.uncertain,
}) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: ToolFailureKind.infrastructure,
  effectCertainty: certainty,
  modelContent: modelContent,
  hostDiagnostic: cause.toString(),
  cause: cause,
);
