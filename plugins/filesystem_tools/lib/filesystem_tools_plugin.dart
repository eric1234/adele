/// Stock filesystem model tools for Session-authorized Environments.
library;

import 'dart:convert';

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
    final AuthorizedEnvironmentFileReadFacet read = await context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet mutation = await context
        .requireHostService<AuthorizedEnvironmentFileMutationFacet>();
    if (read.sessionId != context.sessionId ||
        mutation.sessionId != context.sessionId) {
      throw StateError('The filesystem authority belongs to another Session.');
    }
    if (read.environmentId != mutation.environmentId) {
      throw StateError(
        'The filesystem facets belong to different Environments.',
      );
    }
    return <ToolRegistration>[
      _ReadFileExecutable(read).registration,
      _ApplyPatchExecutable(read, mutation).registration,
    ];
  }
}

final class _ReadFileExecutable implements ToolExecutable {
  const _ReadFileExecutable(this._fileSystem);

  static final ToolId _toolId = ToolId(
    'dev.adele.plugin.filesystem-tools.read-file',
  );

  final AuthorizedEnvironmentFileReadFacet _fileSystem;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: _toolId,
      description: 'Read one file from the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'read_file',
      description:
          'Read one UTF-8 file and its opaque revision from the current Session '
          'Environment by relative path.',
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
          modelContent:
              'File: ${jsonEncode(file.relativePath)}\n'
              'Revision: ${jsonEncode(file.revision)}\n\n'
              '${file.text}',
          hostData: <String, Object?>{
            'environmentId': _fileSystem.environmentId.value,
            'relativePath': file.relativePath,
            'sizeBytes': file.sizeBytes,
            'revision': file.revision,
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

final class _ApplyPatchExecutable implements ToolExecutable {
  const _ApplyPatchExecutable(this._read, this._mutation);

  static final ToolId _toolId = ToolId(
    'dev.adele.plugin.filesystem-tools.apply-patch',
  );

  final AuthorizedEnvironmentFileReadFacet _read;
  final AuthorizedEnvironmentFileMutationFacet _mutation;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: _toolId,
      description:
          'Patch one existing file in the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'apply_patch',
      description:
          'Replace one exact, case-sensitive, literal search occurrence in an '
          'existing UTF-8 file from the current Session Environment. search '
          'must include enough surrounding function, class, or test context '
          'that it occurs exactly once.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>[
          'relativePath',
          'expectedRevision',
          'search',
          'replace',
        ],
        'properties': <String, Object?>{
          'relativePath': <String, Object?>{'type': 'string'},
          'expectedRevision': <String, Object?>{'type': 'string'},
          'search': <String, Object?>{'type': 'string', 'minLength': 1},
          'replace': <String, Object?>{'type': 'string'},
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
    if (proposedArguments.length != 4 ||
        proposedArguments['relativePath'] is! String ||
        proposedArguments['expectedRevision'] is! String ||
        proposedArguments['search'] is! String ||
        proposedArguments['replace'] is! String) {
      throw const ToolArgumentValidationException(
        'apply_patch requires exactly the string arguments relativePath, '
        'expectedRevision, search, and replace.',
      );
    }
    final String relativePath = proposedArguments['relativePath']! as String;
    final String search = proposedArguments['search']! as String;
    if (relativePath.isEmpty || search.isEmpty) {
      throw const ToolArgumentValidationException(
        'relativePath and search must not be empty.',
      );
    }
    return CanonicalToolArguments(<String, Object?>{
      'relativePath': relativePath,
      'expectedRevision': proposedArguments['expectedRevision']! as String,
      'search': search,
      'replace': proposedArguments['replace']! as String,
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
      effects: const <ToolEffect>[ToolEffect.sourceMutation],
      targets: <EffectTarget>[
        EffectTarget(
          uri: Uri(
            scheme: 'adele-environment',
            path: '/${_read.environmentId.value}/$relativePath',
          ),
        ),
      ],
      summary: 'Patch Environment file $relativePath.',
    );
  }

  @override
  void validateBinding() {
    _validateToolBinding(_read);
    _validateToolBinding(_mutation);
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final String relativePath = arguments.snapshot['relativePath']! as String;
    final String expectedRevision =
        arguments.snapshot['expectedRevision']! as String;
    final String search = arguments.snapshot['search']! as String;
    final String replace = arguments.snapshot['replace']! as String;
    bool mutationAttempted = false;
    try {
      _requireAuthorizedSession(context);
      final EnvironmentTextFile current = await _read.readFile(relativePath);
      if (current.revision != expectedRevision) {
        yield ToolExecutionTerminal(_revisionConflict(relativePath));
        return;
      }
      if (search == replace) {
        yield ToolExecutionTerminal(
          _patchFailure(
            relativePath: relativePath,
            code: 'no_change',
            modelContent:
                'The search and replacement text are identical. No changes '
                'were made.',
          ),
        );
        return;
      }

      int matchCount = 0;
      int matchIndex = -1;
      int searchStart = 0;
      while (true) {
        final int candidate = current.text.indexOf(search, searchStart);
        if (candidate < 0) break;
        matchCount++;
        if (matchCount == 1) matchIndex = candidate;
        searchStart = candidate + 1;
      }
      if (matchCount == 0) {
        yield ToolExecutionTerminal(
          _patchFailure(
            relativePath: relativePath,
            code: 'patch_target_not_found',
            modelContent:
                'No exact match for the search text. No changes were made.\n'
                'Re-read the file and copy the exact current text, including '
                'whitespace and newlines.',
          ),
        );
        return;
      }
      if (matchCount > 1) {
        yield ToolExecutionTerminal(
          _patchFailure(
            relativePath: relativePath,
            code: 'patch_target_ambiguous',
            modelContent:
                'The search text matched $matchCount locations. No changes '
                'were made.\nInclude more surrounding function, class, or test '
                'context so the search is unique.',
          ),
        );
        return;
      }

      final String replacementText = current.text.replaceRange(
        matchIndex,
        matchIndex + search.length,
        replace,
      );
      mutationAttempted = true;
      final EnvironmentTextFileReplacement replacement = await _mutation
          .replaceExistingTextFile(
            relativePath,
            replacementText,
            expectedRevision,
          );
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent:
              'Patched: ${jsonEncode(relativePath)}\n'
              'Revision: ${jsonEncode(replacement.revision)}',
          hostData: <String, Object?>{
            'environmentId': _read.environmentId.value,
            'relativePath': relativePath,
            'newRevision': replacement.revision,
          },
        ),
      );
    } on AuthorizedEnvironmentBindingStale catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'The authorized Environment binding is stale.',
          ToolFailureKind.staleBinding,
          error,
          certainty: mutationAttempted
              ? EffectCertainty.uncertain
              : EffectCertainty.knownNotOccurred,
        ),
      );
    } on AuthorizedEnvironmentBindingUnavailable catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'The authorized Environment provider is unavailable.',
          ToolFailureKind.infrastructure,
          error,
          certainty: mutationAttempted
              ? EffectCertainty.uncertain
              : EffectCertainty.knownNotOccurred,
        ),
      );
    } on EnvironmentFailure catch (error) {
      if (error.code == environmentRevisionConflictCode) {
        yield ToolExecutionTerminal(_revisionConflict(relativePath, error));
        return;
      }
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: mutationAttempted
              ? EffectCertainty.uncertain
              : EffectCertainty.knownNotOccurred,
          modelContent: 'Environment patch failed: ${error.message}',
          hostData: <String, Object?>{
            'environmentId': _read.environmentId.value,
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
          'The Apply Patch tool is not authorized for this Session.',
          ToolFailureKind.infrastructure,
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'Environment file patch failed.',
          ToolFailureKind.infrastructure,
          error,
          certainty: mutationAttempted
              ? EffectCertainty.uncertain
              : EffectCertainty.knownNotOccurred,
        ),
      );
    }
  }

  void _requireAuthorizedSession(ToolExecutionContext context) {
    if (context.sessionId != _read.sessionId ||
        context.sessionId != _mutation.sessionId) {
      throw _SessionAuthorityViolation(context.sessionId.toString());
    }
  }

  ToolOutcome _revisionConflict(String relativePath, [Object? cause]) =>
      ToolOutcome(
        disposition: ToolOutcomeDisposition.failure,
        failureKind: ToolFailureKind.domain,
        effectCertainty: EffectCertainty.knownNotOccurred,
        modelContent:
            'The file changed since the expected revision was observed.\n'
            'No stale ADELE write was performed.\n'
            'Re-read the file before retrying the patch.',
        hostData: <String, Object?>{
          'environmentId': _read.environmentId.value,
          'relativePath': relativePath,
          'code': environmentRevisionConflictCode,
        },
        hostDiagnostic: cause?.toString(),
        cause: cause,
      );

  ToolOutcome _patchFailure({
    required String relativePath,
    required String code,
    required String modelContent,
  }) => ToolOutcome(
    disposition: ToolOutcomeDisposition.failure,
    failureKind: ToolFailureKind.domain,
    effectCertainty: EffectCertainty.knownNotOccurred,
    modelContent: modelContent,
    hostData: <String, Object?>{
      'environmentId': _read.environmentId.value,
      'relativePath': relativePath,
      'code': code,
    },
  );
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

void _validateToolBinding(AuthorizedEnvironmentFileSystem fileSystem) {
  try {
    fileSystem.validateBinding();
  } on AuthorizedEnvironmentBindingStale catch (error) {
    throw StaleToolBindingException(error.message, cause: error.cause ?? error);
  } on AuthorizedEnvironmentBindingUnavailable catch (error) {
    throw ToolBindingUnavailableException(
      error.message,
      cause: error.cause ?? error,
    );
  }
}
