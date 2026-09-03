import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  test('activation contributes Read File and retirement removes it', () async {
    final ExtensionRegistry extensions = ExtensionRegistry();
    expect(extensions.discover(modelToolContributions), isEmpty);

    final ExtensionRegistration activation = const FilesystemToolsPlugin()
        .activate(extensions);
    final ExtensionBinding<ModelToolContribution> binding = extensions
        .discover(modelToolContributions)
        .single;
    final _FileSystem fileSystem = _FileSystem();
    final ToolRegistration tool = (await binding.value.materialize(
      _Context(fileSystem),
    )).single;

    expect(tool.modelDefinition.alias, 'read_file');
    expect(tool.definition.id.value, contains('filesystem-tools'));
    expect(
      tool.modelDefinition.argumentsSchema['properties'],
      const <String, Object?>{
        'relativePath': <String, Object?>{'type': 'string'},
      },
    );

    await activation.close();
    expect(extensions.discover(modelToolContributions), isEmpty);
    expect(() => binding.value, throwsA(isA<StaleExtensionBinding>()));
  });

  test('Read File uses only Session-authorized filesystem access', () async {
    final _FileSystem fileSystem = _FileSystem(text: 'plugin-owned source');
    final ToolExecutable executable = await _readFile(fileSystem);

    expect(
      () => executable.validateAndNormalize(const <String, Object?>{
        'relativePath': 'source.dart',
        'environmentId': 'forbidden',
      }),
      throwsA(isA<ToolArgumentValidationException>()),
    );
    final CanonicalToolArguments arguments = executable.validateAndNormalize(
      const <String, Object?>{'relativePath': 'source.dart'},
    );
    final ToolOutcome outcome =
        (await executable
                    .execute(
                      arguments,
                      ToolExecutionContext(
                        runId: RunId('run-1'),
                        sessionId: fileSystem.sessionId,
                      ),
                    )
                    .single
                as ToolExecutionTerminal)
            .outcome;

    expect(fileSystem.paths, <String>['source.dart']);
    expect(outcome.disposition, ToolOutcomeDisposition.success);
    expect(outcome.modelContent, contains('plugin-owned source'));
    expect(outcome.hostData['environmentId'], 'environment-1');
  });

  test('Read File describes effects and rejects another Session', () async {
    final ToolExecutable executable = await _readFile(_FileSystem());
    final CanonicalToolArguments arguments = executable.validateAndNormalize(
      const <String, Object?>{'relativePath': 'source.dart'},
    );
    final EffectDescription effects = await executable.describe(
      arguments,
      ToolExecutionContext(
        runId: RunId('run-1'),
        sessionId: SessionId('session-1'),
      ),
    );

    expect(effects.effects, <ToolEffect>{ToolEffect.sourceRead});
    expect(
      effects.targets.single.uri.toString(),
      'adele-environment:/environment-1/source.dart',
    );
    await expectLater(
      executable.describe(
        arguments,
        ToolExecutionContext(
          runId: RunId('run-other'),
          sessionId: SessionId('session-other'),
        ),
      ),
      throwsA(isA<Exception>()),
    );
    final ToolOutcome outcome = await _execute(
      executable,
      arguments,
      SessionId('session-other'),
    );
    expect(outcome.failureKind, ToolFailureKind.infrastructure);
    expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
  });

  test('Read File preserves domain and binding failure classes', () async {
    final _FileSystem domainFileSystem = _FileSystem(
      readError: const EnvironmentFailure(
        code: 'not_found',
        message: 'Missing file.',
        details: <String, Object?>{'path': 'missing.dart'},
      ),
    );
    final ToolExecutable domainTool = await _readFile(domainFileSystem);
    final CanonicalToolArguments arguments = domainTool.validateAndNormalize(
      const <String, Object?>{'relativePath': 'missing.dart'},
    );
    final ToolOutcome domainOutcome = await _execute(
      domainTool,
      arguments,
      domainFileSystem.sessionId,
    );
    expect(domainOutcome.failureKind, ToolFailureKind.domain);
    expect(domainOutcome.hostData['code'], 'not_found');
    expect(domainOutcome.hostData['details'], <String, Object?>{
      'path': 'missing.dart',
    });

    final _FileSystem staleFileSystem = _FileSystem()..stale = true;
    final ToolExecutable staleTool = await _readFile(staleFileSystem);
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
    final ToolExecutable unavailableTool = await _readFile(
      unavailableFileSystem,
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
}

Future<ToolExecutable> _readFile(_FileSystem fileSystem) async {
  final ExtensionRegistry extensions = ExtensionRegistry();
  const FilesystemToolsPlugin().activate(extensions);
  return (await extensions
          .discover(modelToolContributions)
          .single
          .value
          .materialize(_Context(fileSystem)))
      .single
      .executable;
}

Future<ToolOutcome> _execute(
  ToolExecutable executable,
  CanonicalToolArguments arguments,
  SessionId sessionId,
) async =>
    (await executable
                .execute(
                  arguments,
                  ToolExecutionContext(
                    runId: RunId('run-execute'),
                    sessionId: sessionId,
                  ),
                )
                .single
            as ToolExecutionTerminal)
        .outcome;

final class _Context implements ModelToolHostContext {
  const _Context(this.fileSystem);

  final _FileSystem fileSystem;

  @override
  SessionId get sessionId => fileSystem.sessionId;

  @override
  Future<T> requireHostService<T extends Object>() async => fileSystem as T;
}

final class _FileSystem implements AuthorizedEnvironmentFileSystem {
  _FileSystem({this.text = 'source', this.readError});

  final String text;
  final Object? readError;
  final List<String> paths = <String>[];
  bool stale = false;
  bool available = true;

  @override
  final SessionId sessionId = SessionId('session-1');

  @override
  final EnvironmentId environmentId = EnvironmentId('environment-1');

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
    paths.add(relativePath);
    if (readError case final Object error) throw error;
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: text.length,
    );
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
