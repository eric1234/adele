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
      _CreateFileExecutable(mutation).registration,
      _DeleteFileExecutable(read, mutation).registration,
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
    final String relativePath = proposedArguments['relativePath']! as String;
    _requireWellFormedUnicode('relativePath', relativePath);
    return CanonicalToolArguments(<String, Object?>{
      'relativePath': _canonicalFilePath(relativePath),
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
              'File: ${jsonEncode(relativePath)}\n'
              'Revision: ${jsonEncode(file.revision)}\n\n'
              '${file.text}',
          hostData: <String, Object?>{
            'environmentId': _fileSystem.environmentId.value,
            'relativePath': relativePath,
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
          'Patch one existing UTF-8 file in the current Session Environment '
          'using one observed opaque expectedRevision. Apply edits in array '
          'order: each search is an exact, case-sensitive literal that must '
          'occur exactly once when evaluated, and later edits see the in-memory '
          'result of earlier edits. Include enough surrounding function, class, '
          'or test context to make each search unique. Every edit must change '
          'its occurrence, and the final text must differ from the original. '
          'The tool validates the entire sequence before one conditional '
          'filesystem replacement; if any edit fails, no ADELE-requested '
          'filesystem mutation occurs. Normally group multiple changes to the same '
          'observed file into one apply_patch call rather than separate calls.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['relativePath', 'expectedRevision', 'edits'],
        'properties': <String, Object?>{
          'relativePath': <String, Object?>{'type': 'string'},
          'expectedRevision': <String, Object?>{'type': 'string'},
          'edits': <String, Object?>{
            'type': 'array',
            'minItems': 1,
            'items': <String, Object?>{
              'type': 'object',
              'required': <Object?>['search', 'replace'],
              'properties': <String, Object?>{
                'search': <String, Object?>{'type': 'string', 'minLength': 1},
                'replace': <String, Object?>{'type': 'string'},
              },
              'additionalProperties': false,
            },
          },
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
    if (proposedArguments.length != 3 ||
        proposedArguments['relativePath'] is! String ||
        proposedArguments['expectedRevision'] is! String ||
        proposedArguments['edits'] is! List) {
      throw const ToolArgumentValidationException(
        'apply_patch requires exactly relativePath and expectedRevision strings '
        'and a non-empty edits list.',
      );
    }
    final String relativePath = proposedArguments['relativePath']! as String;
    final List<Object?> edits = proposedArguments['edits']! as List;
    if (relativePath.isEmpty || edits.isEmpty) {
      throw const ToolArgumentValidationException(
        'relativePath and edits must not be empty.',
      );
    }
    _requireWellFormedUnicode('relativePath', relativePath);
    final List<Map<String, Object?>> canonicalEdits = <Map<String, Object?>>[];
    for (int index = 0; index < edits.length; index++) {
      final Object? edit = edits[index];
      if (edit is! Map ||
          edit.length != 2 ||
          edit['search'] is! String ||
          edit['replace'] is! String ||
          (edit['search']! as String).isEmpty) {
        throw ToolArgumentValidationException(
          'edits[$index] requires exactly a non-empty search string and a '
          'replace string.',
        );
      }
      final String search = edit['search']! as String;
      final String replace = edit['replace']! as String;
      _requireWellFormedUnicode('edits[$index].search', search);
      _requireWellFormedUnicode('edits[$index].replace', replace);
      canonicalEdits.add(<String, Object?>{
        'search': search,
        'replace': replace,
      });
    }
    return CanonicalToolArguments(<String, Object?>{
      'relativePath': _canonicalFilePath(relativePath),
      'expectedRevision': proposedArguments['expectedRevision']! as String,
      'edits': canonicalEdits,
    });
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async {
    _requireAuthorizedSession(context);
    final String relativePath = arguments.snapshot['relativePath']! as String;
    final int editCount = (arguments.snapshot['edits']! as List).length;
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
      summary:
          'Apply $editCount exact ${editCount == 1 ? 'edit' : 'edits'} to '
          'Environment file $relativePath.',
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
    final List<Object?> edits = arguments.snapshot['edits']! as List;
    final int editCount = edits.length;
    bool mutationAttempted = false;
    try {
      _requireAuthorizedSession(context);
      final EnvironmentTextFile current = await _read.readFile(relativePath);
      if (current.revision != expectedRevision) {
        yield ToolExecutionTerminal(_revisionConflict(relativePath, editCount));
        return;
      }
      String workingText = current.text;
      for (int index = 0; index < editCount; index++) {
        final Map<String, Object?> edit = edits[index]! as Map<String, Object?>;
        final String search = edit['search']! as String;
        final String replace = edit['replace']! as String;
        int matchCount = 0;
        int matchIndex = -1;
        int searchStart = 0;
        while (true) {
          final int candidate = workingText.indexOf(search, searchStart);
          if (candidate < 0) break;
          matchCount++;
          if (matchCount == 1) matchIndex = candidate;
          if (matchCount == 2) break;
          searchStart = candidate + 1;
        }
        if (matchCount == 0) {
          yield ToolExecutionTerminal(
            _patchFailure(
              relativePath: relativePath,
              editCount: editCount,
              failedEditIndex: index,
              code: 'patch_target_not_found',
              modelContent:
                  'Edit ${index + 1} of $editCount failed: no exact match for '
                  'the search text. No changes were made.\n'
                  'Re-read the file and copy the exact current text, including '
                  'whitespace and newlines, accounting for earlier edits.',
            ),
          );
          return;
        }
        if (matchCount > 1) {
          yield ToolExecutionTerminal(
            _patchFailure(
              relativePath: relativePath,
              editCount: editCount,
              failedEditIndex: index,
              code: 'patch_target_ambiguous',
              modelContent:
                  'Edit ${index + 1} of $editCount failed: the search text '
                  'matched multiple locations. No changes were made.\n'
                  'Include more surrounding function, class, or test context '
                  'so the search is unique after earlier edits.',
            ),
          );
          return;
        }
        if (search == replace) {
          yield ToolExecutionTerminal(
            _patchFailure(
              relativePath: relativePath,
              editCount: editCount,
              failedEditIndex: index,
              code: 'no_change',
              modelContent:
                  'Edit ${index + 1} of $editCount failed: the search and '
                  'replacement text are identical. No changes were made.',
            ),
          );
          return;
        }

        workingText = workingText.replaceRange(
          matchIndex,
          matchIndex + search.length,
          replace,
        );
      }
      if (workingText == current.text) {
        yield ToolExecutionTerminal(
          _patchFailure(
            relativePath: relativePath,
            editCount: editCount,
            code: 'no_change',
            modelContent:
                'The $editCount edits leave the file unchanged. '
                'No changes were made.',
          ),
        );
        return;
      }

      mutationAttempted = true;
      final EnvironmentTextFileReplacement replacement = await _mutation
          .replaceExistingTextFile(relativePath, workingText, expectedRevision);
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent:
              'Patched: ${jsonEncode(relativePath)}\n'
              'Edits applied: $editCount\n'
              'Revision: ${jsonEncode(replacement.revision)}',
          hostData: <String, Object?>{
            'environmentId': _read.environmentId.value,
            'relativePath': relativePath,
            'editCount': editCount,
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
        yield ToolExecutionTerminal(
          _revisionConflict(relativePath, editCount, error),
        );
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
            'editCount': editCount,
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

  ToolOutcome _revisionConflict(
    String relativePath,
    int editCount, [
    Object? cause,
  ]) => ToolOutcome(
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
      'editCount': editCount,
      'code': environmentRevisionConflictCode,
    },
    hostDiagnostic: cause?.toString(),
    cause: cause,
  );

  ToolOutcome _patchFailure({
    required String relativePath,
    required int editCount,
    int? failedEditIndex,
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
      'editCount': editCount,
      'failedEditIndex': ?failedEditIndex,
      'code': code,
    },
  );
}

final class _CreateFileExecutable implements ToolExecutable {
  const _CreateFileExecutable(this._mutation);

  static final ToolId _toolId = ToolId(
    'dev.adele.plugin.filesystem-tools.create-file',
  );

  final AuthorizedEnvironmentFileMutationFacet _mutation;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: _toolId,
      description: 'Create one new file in the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'create_file',
      description:
          'Create one new bounded UTF-8 file in the current Session '
          'Environment. The parent directory must already exist and the '
          'target must not exist.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['relativePath', 'content'],
        'properties': <String, Object?>{
          'relativePath': <String, Object?>{'type': 'string'},
          'content': <String, Object?>{'type': 'string'},
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
    if (proposedArguments.length != 2 ||
        proposedArguments['relativePath'] is! String ||
        proposedArguments['content'] is! String ||
        (proposedArguments['relativePath']! as String).isEmpty) {
      throw const ToolArgumentValidationException(
        'create_file requires exactly the string arguments relativePath and '
        'content, with a non-empty relativePath.',
      );
    }
    final String relativePath = proposedArguments['relativePath']! as String;
    final String content = proposedArguments['content']! as String;
    _requireWellFormedUnicode('relativePath', relativePath);
    _requireWellFormedUnicode('content', content);
    return CanonicalToolArguments(<String, Object?>{
      'relativePath': _canonicalFilePath(relativePath),
      'content': content,
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
            path: '/${_mutation.environmentId.value}/$relativePath',
          ),
        ),
      ],
      summary: 'Create Environment file $relativePath.',
    );
  }

  @override
  void validateBinding() => _validateToolBinding(_mutation);

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    final String relativePath = arguments.snapshot['relativePath']! as String;
    final String content = arguments.snapshot['content']! as String;
    bool mutationAttempted = false;
    try {
      _requireAuthorizedSession(context);
      _mutation.validateBinding();
      mutationAttempted = true;
      final EnvironmentTextFileCreation creation = await _mutation
          .createTextFile(relativePath, content);
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent:
              'Created: ${jsonEncode(relativePath)}\n'
              'Revision: ${jsonEncode(creation.revision)}',
          hostData: <String, Object?>{
            'environmentId': _mutation.environmentId.value,
            'relativePath': relativePath,
            'revision': creation.revision,
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
      if (error.code == environmentFileAlreadyExistsCode) {
        yield ToolExecutionTerminal(
          ToolOutcome(
            disposition: ToolOutcomeDisposition.failure,
            failureKind: ToolFailureKind.domain,
            effectCertainty: EffectCertainty.knownNotOccurred,
            modelContent:
                'The target already exists. No file was created or replaced.\n'
                'Read it and use apply_patch if you intend to modify the '
                'existing file.',
            hostData: <String, Object?>{
              'environmentId': _mutation.environmentId.value,
              'relativePath': relativePath,
              'code': environmentFileAlreadyExistsCode,
            },
            hostDiagnostic: error.message,
            cause: error,
          ),
        );
        return;
      }
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.failure,
          failureKind: ToolFailureKind.domain,
          effectCertainty: mutationAttempted
              ? EffectCertainty.uncertain
              : EffectCertainty.knownNotOccurred,
          modelContent: 'Environment file creation failed: ${error.message}',
          hostData: <String, Object?>{
            'environmentId': _mutation.environmentId.value,
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
          'The Create File tool is not authorized for this Session.',
          ToolFailureKind.infrastructure,
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'Environment file creation failed.',
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
    if (context.sessionId != _mutation.sessionId) {
      throw _SessionAuthorityViolation(context.sessionId.toString());
    }
  }
}

final class _DeleteFileExecutable implements ToolExecutable {
  const _DeleteFileExecutable(this._read, this._mutation);

  static final ToolId _toolId = ToolId(
    'dev.adele.plugin.filesystem-tools.delete-file',
  );

  final AuthorizedEnvironmentFileReadFacet _read;
  final AuthorizedEnvironmentFileMutationFacet _mutation;

  ToolRegistration get registration => ToolRegistration(
    definition: ToolDefinition(
      id: _toolId,
      description:
          'Delete one current file from the current Session Environment.',
    ),
    modelDefinition: ModelToolDefinition(
      alias: 'delete_file',
      description:
          'Delete one existing UTF-8 file from the current Session '
          'Environment only if its opaque revision still matches '
          'expectedRevision. Read the file first and copy its exact visible '
          'Revision.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'required': <Object?>['relativePath', 'expectedRevision'],
        'properties': <String, Object?>{
          'relativePath': <String, Object?>{'type': 'string'},
          'expectedRevision': <String, Object?>{'type': 'string'},
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
    if (proposedArguments.length != 2 ||
        proposedArguments['relativePath'] is! String ||
        proposedArguments['expectedRevision'] is! String ||
        (proposedArguments['relativePath']! as String).isEmpty) {
      throw const ToolArgumentValidationException(
        'delete_file requires exactly the string arguments relativePath and '
        'expectedRevision, with a non-empty relativePath.',
      );
    }
    final String relativePath = proposedArguments['relativePath']! as String;
    _requireWellFormedUnicode('relativePath', relativePath);
    return CanonicalToolArguments(<String, Object?>{
      'relativePath': _canonicalFilePath(relativePath),
      'expectedRevision': proposedArguments['expectedRevision']! as String,
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
      summary: 'Delete Environment file $relativePath.',
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
    bool mutationAttempted = false;
    try {
      _requireAuthorizedSession(context);
      final EnvironmentTextFile current = await _read.readFile(relativePath);
      if (current.revision != expectedRevision) {
        yield ToolExecutionTerminal(_revisionConflict(relativePath));
        return;
      }
      _mutation.validateBinding();
      mutationAttempted = true;
      await _mutation.deleteExistingTextFile(relativePath, expectedRevision);
      yield ToolExecutionTerminal(
        ToolOutcome(
          disposition: ToolOutcomeDisposition.success,
          effectCertainty: EffectCertainty.knownOccurred,
          modelContent: 'Deleted: ${jsonEncode(relativePath)}',
          hostData: <String, Object?>{
            'environmentId': _read.environmentId.value,
            'relativePath': relativePath,
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
          modelContent: 'Environment file deletion failed: ${error.message}',
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
          'The Delete File tool is not authorized for this Session.',
          ToolFailureKind.infrastructure,
          error,
          certainty: EffectCertainty.knownNotOccurred,
        ),
      );
    } on Object catch (error) {
      yield ToolExecutionTerminal(
        _failure(
          'Environment file deletion failed.',
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
            'No stale ADELE deletion was performed.\n'
            'Re-read the file before retrying the deletion.',
        hostData: <String, Object?>{
          'environmentId': _read.environmentId.value,
          'relativePath': relativePath,
          'code': environmentRevisionConflictCode,
        },
        hostDiagnostic: cause?.toString(),
        cause: cause,
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

String _canonicalFilePath(String relativePath) {
  if (relativePath.startsWith('/')) {
    throw const ToolArgumentValidationException(
      'relativePath must be an Environment-relative file path.',
    );
  }
  final List<String> segments = <String>[];
  for (final String segment in relativePath.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      throw const ToolArgumentValidationException(
        'relativePath must not contain parent traversal.',
      );
    }
    segments.add(segment);
  }
  if (segments.isEmpty) {
    throw const ToolArgumentValidationException(
      'relativePath must identify a file beneath the Environment root.',
    );
  }
  return segments.join('/');
}

void _requireWellFormedUnicode(String fieldName, String value) {
  for (int index = 0; index < value.length; index++) {
    final int codeUnit = value.codeUnitAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (++index < value.length) {
        final int next = value.codeUnitAt(index);
        if (next >= 0xdc00 && next <= 0xdfff) continue;
      }
      throw ToolArgumentValidationException(
        '$fieldName must contain well-formed Unicode text.',
      );
    }
    if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      throw ToolArgumentValidationException(
        '$fieldName must contain well-formed Unicode text.',
      );
    }
  }
}

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
