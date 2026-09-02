/// Stock filesystem model tools for Session-authorized Environments.
library;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';

final PluginId filesystemToolsPluginId = PluginId(
  'dev.adele.plugin.filesystem-tools',
);

final class FilesystemToolsPlugin {
  const FilesystemToolsPlugin();

  ExtensionRegistration activate(ExtensionRegistry extensions) =>
      extensions.register(
        point: modelToolContributions,
        id: ExtensionId('dev.adele.plugin.filesystem-tools.model-tools'),
        value: const _FilesystemModelTools(),
      );
}

final class _FilesystemModelTools implements ModelToolContribution {
  const _FilesystemModelTools();

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    final AuthorizedEnvironmentFileSystem fileSystem = await context
        .requireHostService<AuthorizedEnvironmentFileSystem>();
    if (fileSystem.sessionId != context.sessionId) {
      throw StateError('The filesystem authority belongs to another Session.');
    }
    return <ToolRegistration>[_ReadFileExecutable(fileSystem).registration];
  }
}

final class _ReadFileExecutable implements ToolExecutable {
  const _ReadFileExecutable(this._fileSystem);

  static final ToolId _toolId = ToolId(
    'dev.adele.plugin.filesystem-tools.read-file',
  );

  final AuthorizedEnvironmentFileSystem _fileSystem;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: _toolId,
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
        proposedArguments['relativePath'] is! String ||
        (proposedArguments['relativePath']! as String).isEmpty) {
      throw const ToolArgumentValidationException(
        'read_file requires exactly one non-empty string argument named relativePath.',
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
            path: '/${_fileSystem.environmentId.value}/$relativePath',
          ),
        ),
      ],
      summary: 'Read Environment file $relativePath.',
    );
  }

  @override
  void validateBinding() {
    try {
      _fileSystem.validateBinding();
    } on AuthorizedEnvironmentBindingStale catch (error) {
      throw StaleToolBindingException(
        error.message,
        cause: error.cause ?? error,
      );
    } on AuthorizedEnvironmentBindingUnavailable catch (error) {
      throw ToolBindingUnavailableException(
        error.message,
        cause: error.cause ?? error,
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
      final EnvironmentTextFile file = await _fileSystem.readFile(relativePath);
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: 'File: ${file.relativePath}\n${file.text}',
          hostData: <String, Object?>{
            'environmentId': _fileSystem.environmentId.value,
            'relativePath': file.relativePath,
            'sizeBytes': file.sizeBytes,
            'text': file.text,
          },
        ),
      );
    } on AuthorizedEnvironmentBindingStale catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'The authorized Environment binding is stale.',
          ToolFailureKind.staleBinding,
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on AuthorizedEnvironmentBindingUnavailable catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'The authorized Environment provider is unavailable.',
          ToolFailureKind.infrastructure,
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
            'environmentId': _fileSystem.environmentId.value,
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
        _failure(
          'The Read File tool is not authorized for this Session.',
          ToolFailureKind.infrastructure,
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'Environment file read failed.',
          ToolFailureKind.infrastructure,
          error,
        ),
      );
    }
  }

  void _requireAuthorizedSession(ToolExecutionContext context) {
    if (context.sessionId != _fileSystem.sessionId) {
      throw _SessionAuthorityViolation(context.sessionId.toString());
    }
  }
}

final class _SessionAuthorityViolation implements Exception {
  const _SessionAuthorityViolation(this.message);

  final String message;
}

ToolOutcome _failure(
  String modelContent,
  ToolFailureKind kind,
  Object cause, {
  EffectCertainty certainty = EffectCertainty.uncertain,
}) => ToolOutcome(
  disposition: ToolOutcomeDisposition.failure,
  failureKind: kind,
  effectCertainty: certainty,
  modelContent: modelContent,
  hostDiagnostic: cause.toString(),
  cause: cause,
);
