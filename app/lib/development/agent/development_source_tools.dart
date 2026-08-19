import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:development_source_contract/development_source_contract.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

final ToolId sourceTextSearchToolId = ToolId(
  'dev.adele.tool.source-text-search',
);
final ToolId sourceFileReadToolId = ToolId('dev.adele.tool.source-file-read');

final class DevelopmentSourceSearchToolExecutable implements ToolExecutable {
  DevelopmentSourceSearchToolExecutable(this._binding);

  final ProviderBinding _binding;
  int _invocationCount = 0;

  ProviderDescriptor get provider => _binding.provider;
  int get invocationCount => _invocationCount;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: sourceTextSearchToolId,
      description: 'Search configured development source text.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'search_source_text',
      description:
          'Search the configured development source for literal text and return matching root-relative paths and lines.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['literalText'],
        'properties': <String, Object?>{
          'literalText': <String, Object?>{'type': 'string'},
        },
        'additionalProperties': false,
      },
    ),
    executable: this,
  );

  @override
  CanonicalToolArguments validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) => _oneStringArgument(
    proposedArguments,
    alias: 'search_source_text',
    name: 'literalText',
  );

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    final String literalText = arguments.snapshot['literalText']! as String;
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.sourceRead],
      targets: <EffectTarget>[EffectTarget(uri: _sourceTarget())],
      summary: 'Search configured source for "$literalText".',
    );
  }

  @override
  void validateBinding() => _validateDevelopmentSourceBinding(_binding);

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final String literalText = arguments.snapshot['literalText']! as String;
    try {
      final DevelopmentSourceService client = DevelopmentSourceServiceClient(
        _binding.requestChannel,
      );
      _invocationCount++;
      final DevelopmentSourceSearchResult result = await client.searchText(
        literalText,
      );
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: _searchModelContent(result),
          hostData: <String, Object?>{
            'literalText': literalText,
            'matches': <Object?>[
              for (final DevelopmentSourceSearchMatch match in result.matches)
                <String, Object?>{
                  'relativePath': match.relativePath,
                  'lineNumber': match.lineNumber,
                  'snippet': match.snippet,
                },
            ],
            'truncated': result.truncated,
          },
        ),
      );
    } on ProviderUnavailable catch (error) {
      yield ToolExecutionTerminal(_sourceBindingFailureOutcome(error));
    } on ProviderEndpointUnavailable catch (error) {
      yield ToolExecutionTerminal(
        _sourceInfrastructureOutcome(
          'The development-source provider endpoint is unavailable.',
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on DevelopmentSourceFailure catch (error) {
      yield ToolExecutionTerminal(
        _sourceDomainFailureOutcome(error, arguments.snapshot),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _sourceInfrastructureOutcome(
          'Development source search transport failed.',
          error,
        ),
      );
    }
  }
}

final class DevelopmentSourceReadToolExecutable implements ToolExecutable {
  DevelopmentSourceReadToolExecutable(this._binding);

  final ProviderBinding _binding;
  int _invocationCount = 0;

  ProviderDescriptor get provider => _binding.provider;
  int get invocationCount => _invocationCount;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: sourceFileReadToolId,
      description: 'Read one configured development source file.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'read_source_file',
      description:
          'Read one UTF-8 development source file by its root-relative path.',
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
  ) => _oneStringArgument(
    proposedArguments,
    alias: 'read_source_file',
    name: 'relativePath',
  );

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    final String relativePath = arguments.snapshot['relativePath']! as String;
    return EffectDescription(
      effects: const <ToolEffect>[ToolEffect.sourceRead],
      targets: <EffectTarget>[EffectTarget(uri: _sourceTarget(relativePath))],
      summary: 'Read configured source file $relativePath.',
    );
  }

  @override
  void validateBinding() => _validateDevelopmentSourceBinding(_binding);

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final String relativePath = arguments.snapshot['relativePath']! as String;
    try {
      final DevelopmentSourceService client = DevelopmentSourceServiceClient(
        _binding.requestChannel,
      );
      _invocationCount++;
      final DevelopmentSourceTextFile file = await client.readTextFile(
        relativePath,
      );
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: 'File: ${file.relativePath}\n${file.text}',
          hostData: <String, Object?>{
            'relativePath': file.relativePath,
            'sizeBytes': file.sizeBytes,
            'text': file.text,
          },
        ),
      );
    } on ProviderUnavailable catch (error) {
      yield ToolExecutionTerminal(_sourceBindingFailureOutcome(error));
    } on ProviderEndpointUnavailable catch (error) {
      yield ToolExecutionTerminal(
        _sourceInfrastructureOutcome(
          'The development-source provider endpoint is unavailable.',
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on DevelopmentSourceFailure catch (error) {
      yield ToolExecutionTerminal(
        _sourceDomainFailureOutcome(error, arguments.snapshot),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _sourceInfrastructureOutcome(
          'Development source read transport failed.',
          error,
        ),
      );
    }
  }
}

CanonicalToolArguments _oneStringArgument(
  Map<String, Object?> proposedArguments, {
  required String alias,
  required String name,
}) {
  if (proposedArguments.length != 1 || proposedArguments[name] is! String) {
    throw ToolArgumentValidationException(
      '$alias requires exactly one string argument named $name.',
    );
  }
  return CanonicalToolArguments(<String, Object?>{
    name: proposedArguments[name]! as String,
  });
}

void _validateDevelopmentSourceBinding(ProviderBinding binding) {
  try {
    binding.requestChannel;
  } on ProviderUnavailable catch (error) {
    if (error.stale) {
      throw StaleToolBindingException(
        'The materialized DevelopmentSource provider is stale.',
        cause: error,
      );
    }
    throw ToolBindingUnavailableException(
      'The materialized DevelopmentSource provider is unavailable.',
      cause: error,
    );
  } on ProviderEndpointUnavailable catch (error) {
    throw ToolBindingUnavailableException(
      'The materialized DevelopmentSource endpoint is unavailable.',
      cause: error,
    );
  }
}

Uri _sourceTarget([String? relativePath]) => Uri(
  scheme: 'adele-source',
  path: relativePath == null ? '/' : '/$relativePath',
);

String _searchModelContent(DevelopmentSourceSearchResult result) {
  final StringBuffer content = StringBuffer('Search results:');
  if (result.matches.isEmpty) {
    content.write('\nNo matches.');
  } else {
    for (final DevelopmentSourceSearchMatch match in result.matches) {
      content.write(
        '\n${match.relativePath}:${match.lineNumber}: ${match.snippet}',
      );
    }
  }
  if (result.truncated) content.write('\nResult set truncated.');
  return content.toString();
}

ToolOutcome _sourceBindingFailureOutcome(ProviderUnavailable error) =>
    ToolOutcome(
      disposition: ToolOutcomeDisposition.failure,
      failureKind: error.stale
          ? ToolFailureKind.staleBinding
          : ToolFailureKind.infrastructure,
      effectCertainty: EffectCertainty.knownNotOccurred,
      modelContent: error.stale
          ? 'The approved development-source binding is stale.'
          : 'The development-source provider is unavailable.',
      hostDiagnostic: error.message,
      cause: error,
    );

ToolOutcome _sourceDomainFailureOutcome(
  DevelopmentSourceFailure error,
  Map<String, Object?> arguments,
) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: ToolFailureKind.domain,
  effectCertainty: EffectCertainty.uncertain,
  modelContent: 'Development source operation failed: ${error.message}',
  hostData: <String, Object?>{
    'arguments': arguments,
    'code': error.code,
    'details': error.details,
  },
  hostDiagnostic: error.message,
  cause: error,
);

ToolOutcome _sourceInfrastructureOutcome(
  String content,
  Object cause, {
  EffectCertainty certainty = EffectCertainty.uncertain,
}) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: ToolFailureKind.infrastructure,
  effectCertainty: certainty,
  modelContent: content,
  hostDiagnostic: cause.toString(),
  cause: cause,
);
