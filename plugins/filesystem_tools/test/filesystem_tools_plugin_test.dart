import 'dart:convert';

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  test(
    'activation contributes exact-generation Read and Apply tools',
    () async {
      final ExtensionRegistry extensions = ExtensionRegistry();
      expect(extensions.discover(modelToolContributions), isEmpty);

      final ExtensionRegistration activation = const FilesystemToolsPlugin()
          .activate(extensions);
      final _FileSystem fileSystem = _FileSystem();
      final ToolCatalog catalog = await ModelToolComposer(
        extensions,
      ).materialize(_Context(fileSystem));
      final MaterializedToolSet tools = catalog.materialize();

      expect(tools.tools.map((tool) => tool.modelDefinition.alias), <String>[
        'read_file',
        'apply_patch',
      ]);
      expect(
        tools.tools.map((tool) => tool.definition.id.value),
        everyElement(contains('filesystem-tools')),
      );

      await activation.close();
      expect(extensions.discover(modelToolContributions), isEmpty);
      for (final MaterializedTool tool in tools.tools) {
        expect(
          tool.executable.validateBinding,
          throwsA(isA<StaleToolBindingException>()),
        );
      }
    },
  );

  test('Read File exposes the opaque revision to model and host', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'plugin-owned source',
      revision: 'opaque "revision"\n2',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'read_file');

    expect(
      () => executable.validateAndNormalize(const <String, Object?>{
        'relativePath': 'source.dart',
        'environmentId': 'forbidden',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
    final ToolOutcome outcome = await _execute(
      executable,
      executable.validateAndNormalize(const <String, Object?>{
        'relativePath': 'source.dart',
      }),
      fileSystem.sessionId,
    );

    expect(fileSystem.readPaths, <String>['source.dart']);
    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(
      outcome.modelContent,
      'File: ${jsonEncode('source.dart')}\n'
      'Revision: ${jsonEncode('opaque "revision"\n2')}\n\n'
      'plugin-owned source',
    );
    expect(outcome.hostData, containsPair('environmentId', 'environment-1'));
    expect(outcome.hostData, containsPair('relativePath', 'source.dart'));
    expect(outcome.hostData, containsPair('revision', 'opaque "revision"\n2'));
    expect(outcome.hostData, containsPair('text', 'plugin-owned source'));
  });

  test('Read File describes effects and preserves failure classes', () async {
    final _FileSystem fileSystem = _FileSystem();
    final ToolExecutable executable = await _tool(fileSystem, 'read_file');
    final CanonicalToolArguments arguments = executable.validateAndNormalize(
      const <String, Object?>{'relativePath': 'source.dart'},
    );
    final EffectDescription effects = await executable.describe(
      arguments,
      _execution(fileSystem.sessionId),
    );

    expect(effects.effects, <ToolEffect>{ToolEffect.sourceRead});
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/environment-1/source.dart',
    );

    final _FileSystem domainFileSystem = _FileSystem(
      readError: const EnvironmentFailure(
        code: 'not_found',
        message: 'Missing file.',
        details: <String, Object?>{'path': 'missing.dart'},
      ),
    );
    final ToolExecutable domainTool = await _tool(
      domainFileSystem,
      'read_file',
    );
    final ToolOutcome domainOutcome = await _execute(
      domainTool,
      domainTool.validateAndNormalize(const <String, Object?>{
        'relativePath': 'missing.dart',
      }),
      domainFileSystem.sessionId,
    );
    expect(domainOutcome.failureKind, ToolFailureKind.domain);
    expect(domainOutcome.hostData['code'], 'not_found');

    final _FileSystem staleFileSystem = _FileSystem()..stale = true;
    final ToolExecutable staleTool = await _tool(staleFileSystem, 'read_file');
    expect(
      staleTool.validateBinding,
      throwsA(isA<StaleToolBindingException>()),
    );
    final ToolOutcome staleOutcome = await _execute(
      staleTool,
      arguments,
      staleFileSystem.sessionId,
    );
    expect(staleOutcome.failureKind, ToolFailureKind.staleBinding);
    expect(staleOutcome.effectCertainty, EffectCertainty.knownNotOccurred);

    final _FileSystem unavailableFileSystem = _FileSystem()..available = false;
    final ToolExecutable unavailableTool = await _tool(
      unavailableFileSystem,
      'read_file',
    );
    expect(
      unavailableTool.validateBinding,
      throwsA(isA<ToolBindingUnavailableException>()),
    );
    final ToolOutcome unavailableOutcome = await _execute(
      unavailableTool,
      arguments,
      unavailableFileSystem.sessionId,
    );
    expect(unavailableOutcome.failureKind, ToolFailureKind.infrastructure);
    expect(
      unavailableOutcome.effectCertainty,
      EffectCertainty.knownNotOccurred,
    );
  });

  test('Apply Patch schema is exact and permits empty replacement', () async {
    final ToolExecutable executable = await _tool(_FileSystem(), 'apply_patch');
    final ToolRegistration registration = await _registration(
      _FileSystem(),
      'apply_patch',
    );
    final Map<String, Object?> schema =
        registration.modelDefinition.argumentsSchema;

    expect(schema['required'], <Object?>[
      'relativePath',
      'expectedRevision',
      'search',
      'replace',
    ]);
    expect((schema['properties']! as Map<String, Object?>).keys, <String>[
      'relativePath',
      'expectedRevision',
      'search',
      'replace',
    ]);
    expect(schema['additionalProperties'], isFalse);
    expect(
      ((schema['properties']! as Map<String, Object?>)['search']!
          as Map<String, Object?>)['minLength'],
      1,
    );

    const Map<String, Object?> valid = <String, Object?>{
      'relativePath': 'source.dart',
      'expectedRevision': 'R1',
      'search': 'source',
      'replace': '',
    };
    expect(executable.validateAndNormalize(valid).snapshot, valid);
    for (final String field in valid.keys) {
      expect(
        () => executable.validateAndNormalize(
          Map<String, Object?>.of(valid)..remove(field),
        ),
        throwsA(isA<ToolArgumentValidationException>()),
      );
    }
    expect(
      () => executable.validateAndNormalize(<String, Object?>{
        ...valid,
        'environmentId': 'forbidden',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
    expect(
      () => executable.validateAndNormalize(<String, Object?>{
        ...valid,
        'search': '',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
  });

  test('Apply Patch describes the authorized source mutation target', () async {
    final _FileSystem fileSystem = _FileSystem();
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final EffectDescription effects = await executable.describe(
      _patchArguments(executable),
      _execution(fileSystem.sessionId),
    );

    expect(effects.effects, <ToolEffect>{ToolEffect.sourceMutation});
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/environment-1/source.dart',
    );
    expect(effects.summary, 'Patch Environment file source.dart.');
  });

  test('Apply Patch replaces one exact occurrence with full text', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'bool first() => false;\nbool second() => true;\n',
      revision: 'R1',
      postWriteRevision: 'R2',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(
        executable,
        search: 'bool second() => true;',
        replace: 'bool second() => false;',
      ),
      fileSystem.sessionId,
    );

    expect(fileSystem.replacements, hasLength(1));
    expect(fileSystem.replacements.single.relativePath, 'source.dart');
    expect(fileSystem.replacements.single.expectedRevision, 'R1');
    expect(
      fileSystem.replacements.single.replacementText,
      'bool first() => false;\nbool second() => false;\n',
    );
    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(outcome.effectCertainty, EffectCertainty.knownOccurred);
    expect(outcome.modelContent, 'Patched: "source.dart"\nRevision: "R2"');
    expect(outcome.hostData, <String, Object?>{
      'environmentId': 'environment-1',
      'relativePath': 'source.dart',
      'newRevision': 'R2',
    });
  });

  test(
    'Apply Patch rejects absent and repeated targets without mutation',
    () async {
      for (final ({String text, String search, String code}) fixture
          in <({String text, String search, String code})>[
            (
              text: 'bool result() => true;\n',
              search: 'return false;',
              code: 'patch_target_not_found',
            ),
            (text: 'Value', search: 'value', code: 'patch_target_not_found'),
            (
              text: 'first\r\nsecond',
              search: 'first\nsecond',
              code: 'patch_target_not_found',
            ),
            (
              text: 'Cafe\u0301',
              search: 'Caf\u00e9',
              code: 'patch_target_not_found',
            ),
            (
              text: 'return false;\nreturn false;\n',
              search: 'return false;',
              code: 'patch_target_ambiguous',
            ),
            (text: 'aaa', search: 'aa', code: 'patch_target_ambiguous'),
          ]) {
        final _FileSystem fileSystem = _FileSystem(
          text: fixture.text,
          revision: 'R1',
        );
        final ToolExecutable executable = await _tool(
          fileSystem,
          'apply_patch',
        );
        final ToolOutcome outcome = await _execute(
          executable,
          _patchArguments(executable, search: fixture.search),
          fileSystem.sessionId,
        );

        expect(outcome.failureKind, ToolFailureKind.domain);
        expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
        expect(outcome.hostData['code'], fixture.code);
        expect(fileSystem.replacements, isEmpty);
      }
    },
  );

  test('surrounding function context disambiguates repeated code', () async {
    final _FileSystem fileSystem = _FileSystem(
      text:
          'bool first() {\n  return false;\n}\n\n'
          'bool second() {\n  return false;\n}\n',
      revision: 'R1',
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(
        executable,
        search: 'bool second() {\n  return false;\n}',
        replace: 'bool second() {\n  return true;\n}',
      ),
      fileSystem.sessionId,
    );

    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(
      fileSystem.replacements.single.replacementText,
      contains('bool second() {\n  return true;\n}'),
    );
  });

  test('Apply Patch rejects no-op and permits empty replacement', () async {
    final _FileSystem noOpFileSystem = _FileSystem(
      text: 'remove me',
      revision: 'R1',
    );
    final ToolExecutable noOp = await _tool(noOpFileSystem, 'apply_patch');
    final ToolOutcome noOpOutcome = await _execute(
      noOp,
      _patchArguments(noOp, search: 'remove me', replace: 'remove me'),
      noOpFileSystem.sessionId,
    );
    expect(noOpOutcome.hostData['code'], 'no_change');
    expect(noOpOutcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(noOpFileSystem.replacements, isEmpty);

    final _FileSystem deletionFileSystem = _FileSystem(
      text: 'before remove me after',
      revision: 'R1',
    );
    final ToolExecutable deletion = await _tool(
      deletionFileSystem,
      'apply_patch',
    );
    final ToolOutcome deletionOutcome = await _execute(
      deletion,
      _patchArguments(deletion, search: 'remove me', replace: ''),
      deletionFileSystem.sessionId,
    );
    expect(deletionOutcome.disposition, ToolOutcomeDisposition.success);
    expect(
      deletionFileSystem.replacements.single.replacementText,
      'before  after',
    );
  });

  test('revision conflict wins before absent or ambiguous matching', () async {
    for (final ({String text, String search}) fixture
        in <({String text, String search})>[
          (text: 'current source', search: 'absent'),
          (text: 'repeat repeat', search: 'repeat'),
        ]) {
      final _FileSystem fileSystem = _FileSystem(
        text: fixture.text,
        revision: 'R2',
      );
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final ToolOutcome outcome = await _execute(
        executable,
        _patchArguments(executable, search: fixture.search),
        fileSystem.sessionId,
      );

      expect(outcome.hostData['code'], environmentRevisionConflictCode);
      expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(outcome.modelContent, contains('Re-read the file'));
      expect(fileSystem.replacements, isEmpty);
    }
  });

  test('conditional replacement conflict is known not occurred', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'old',
      revision: 'R1',
      replacementError: const EnvironmentFailure(
        code: environmentRevisionConflictCode,
        message: 'Changed before promotion.',
        details: <String, Object?>{'relativePath': 'source.dart'},
      ),
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(executable, search: 'old', replace: 'new'),
      fileSystem.sessionId,
    );

    expect(fileSystem.replacements, hasLength(1));
    expect(outcome.failureKind, ToolFailureKind.domain);
    expect(outcome.hostData['code'], environmentRevisionConflictCode);
    expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(outcome.hostData, isNot(contains('details')));
  });

  test(
    'other replacement failure remains uncertain after invocation',
    () async {
      final _FileSystem fileSystem = _FileSystem(
        text: 'old',
        revision: 'R1',
        replacementError: const EnvironmentFailure(
          code: 'unwritable',
          message: 'Post-promotion verification failed.',
          details: <String, Object?>{'relativePath': 'source.dart'},
        ),
      );
      final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
      final ToolOutcome outcome = await _execute(
        executable,
        _patchArguments(executable, search: 'old', replace: 'new'),
        fileSystem.sessionId,
      );

      expect(fileSystem.replacements, hasLength(1));
      expect(outcome.failureKind, ToolFailureKind.domain);
      expect(outcome.hostData['code'], 'unwritable');
      expect(outcome.effectCertainty, EffectCertainty.uncertain);
    },
  );

  test('post-invocation binding failure remains uncertain', () async {
    final _FileSystem fileSystem = _FileSystem(
      text: 'old',
      revision: 'R1',
      replacementError: const AuthorizedEnvironmentBindingUnavailable(
        'Response failed after replacement dispatch.',
      ),
    );
    final ToolExecutable executable = await _tool(fileSystem, 'apply_patch');
    final ToolOutcome outcome = await _execute(
      executable,
      _patchArguments(executable, search: 'old', replace: 'new'),
      fileSystem.sessionId,
    );

    expect(fileSystem.replacements, hasLength(1));
    expect(outcome.failureKind, ToolFailureKind.infrastructure);
    expect(outcome.effectCertainty, EffectCertainty.uncertain);
  });

  test('Session mismatch and stale binding do not reach mutation', () async {
    final _FileSystem wrongSessionFileSystem = _FileSystem(
      text: 'old',
      revision: 'R1',
    );
    final ToolExecutable wrongSession = await _tool(
      wrongSessionFileSystem,
      'apply_patch',
    );
    final ToolOutcome wrongSessionOutcome = await _execute(
      wrongSession,
      _patchArguments(wrongSession),
      SessionId('session-other'),
    );
    expect(wrongSessionOutcome.failureKind, ToolFailureKind.infrastructure);
    expect(
      wrongSessionOutcome.effectCertainty,
      EffectCertainty.knownNotOccurred,
    );
    expect(wrongSessionFileSystem.readPaths, isEmpty);
    expect(wrongSessionFileSystem.replacements, isEmpty);

    final _FileSystem staleFileSystem = _FileSystem(text: 'old', revision: 'R1')
      ..stale = true;
    final ToolExecutable stale = await _tool(staleFileSystem, 'apply_patch');
    expect(stale.validateBinding, throwsA(isA<StaleToolBindingException>()));
    final ToolOutcome staleOutcome = await _execute(
      stale,
      _patchArguments(stale),
      staleFileSystem.sessionId,
    );
    expect(staleOutcome.failureKind, ToolFailureKind.staleBinding);
    expect(staleOutcome.effectCertainty, EffectCertainty.knownNotOccurred);
    expect(staleFileSystem.replacements, isEmpty);
  });

  test('Filesystem Tools rejects facets from different authorities', () async {
    final _FileSystem read = _FileSystem();
    final _FileSystem mutation = _FileSystem(
      environmentId: EnvironmentId('environment-other'),
    );
    final ExtensionRegistry extensions = ExtensionRegistry();
    const FilesystemToolsPlugin().activate(extensions);

    await expectLater(
      extensions
          .discover(modelToolContributions)
          .single
          .value
          .materialize(_Context(read, mutation: mutation)),
      throwsStateError,
    );
  });
}

Future<ToolRegistration> _registration(
  _FileSystem fileSystem,
  String alias,
) async => (await _registrations(
  fileSystem,
)).singleWhere((registration) => registration.modelDefinition.alias == alias);

Future<ToolExecutable> _tool(_FileSystem fileSystem, String alias) async =>
    (await _registration(fileSystem, alias)).executable;

Future<List<ToolRegistration>> _registrations(_FileSystem fileSystem) async {
  final ExtensionRegistry extensions = ExtensionRegistry();
  const FilesystemToolsPlugin().activate(extensions);
  return (await extensions
          .discover(modelToolContributions)
          .single
          .value
          .materialize(_Context(fileSystem)))
      .toList(growable: false);
}

CanonicalToolArguments _patchArguments(
  ToolExecutable executable, {
  String search = 'old',
  String replace = 'new',
}) => executable.validateAndNormalize(<String, Object?>{
  'relativePath': 'source.dart',
  'expectedRevision': 'R1',
  'search': search,
  'replace': replace,
});

ToolExecutionContext _execution(SessionId sessionId) =>
    ToolExecutionContext(runId: RunId('run-execute'), sessionId: sessionId);

Future<ToolOutcome> _execute(
  ToolExecutable executable,
  CanonicalToolArguments arguments,
  SessionId sessionId,
) async =>
    (await executable.execute(arguments, _execution(sessionId)).single
            as ToolExecutionTerminal)
        .outcome;

final class _Context implements ModelToolHostContext {
  const _Context(this.read, {AuthorizedEnvironmentFileMutationFacet? mutation})
    : mutation = mutation ?? read;

  final _FileSystem read;
  final AuthorizedEnvironmentFileMutationFacet mutation;

  @override
  SessionId get sessionId => read.sessionId;

  @override
  Future<T> requireHostService<T extends Object>() async {
    if (T == AuthorizedEnvironmentFileReadFacet) return read as T;
    if (T == AuthorizedEnvironmentFileMutationFacet) return mutation as T;
    throw StateError('Unsupported test host service $T.');
  }
}

final class _ReplacementCall {
  const _ReplacementCall({
    required this.relativePath,
    required this.replacementText,
    required this.expectedRevision,
  });

  final String relativePath;
  final String replacementText;
  final String expectedRevision;
}

final class _FileSystem
    implements
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileMutationFacet {
  _FileSystem({
    this.text = 'source',
    this.revision = 'fixture-revision',
    this.postWriteRevision = 'post-write-revision',
    this.readError,
    this.replacementError,
    EnvironmentId? environmentId,
  }) : environmentId = environmentId ?? EnvironmentId('environment-1');

  String text;
  String revision;
  final String postWriteRevision;
  final Object? readError;
  final Object? replacementError;
  final List<String> readPaths = <String>[];
  final List<_ReplacementCall> replacements = <_ReplacementCall>[];
  bool stale = false;
  bool available = true;

  @override
  final SessionId sessionId = SessionId('session-1');

  @override
  final EnvironmentId environmentId;

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    validateBinding();
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: const <EnvironmentDirectoryEntry>[],
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    validateBinding();
    readPaths.add(relativePath);
    if (readError case final Object error) throw error;
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: utf8.encode(text).length,
      revision: revision,
    );
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    validateBinding();
    replacements.add(
      _ReplacementCall(
        relativePath: relativePath,
        replacementText: replacementText,
        expectedRevision: expectedRevision,
      ),
    );
    if (replacementError case final Object error) throw error;
    text = replacementText;
    revision = postWriteRevision;
    return EnvironmentTextFileReplacement(revision: postWriteRevision);
  }

  @override
  void validateBinding() {
    if (stale) {
      throw const AuthorizedEnvironmentBindingStale('stale generation');
    }
    if (!available) {
      throw const AuthorizedEnvironmentBindingUnavailable('unavailable');
    }
  }
}
