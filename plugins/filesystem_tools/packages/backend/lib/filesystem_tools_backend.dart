/// Remote Filesystem Tools over operation-scoped, host-authorized facets.
library;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_product/adele_product.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';

final class FilesystemToolsBackend implements RemoteModelToolService {
  const FilesystemToolsBackend(this._hostRequests);

  final AdeleHostRequestMultiplexer _hostRequests;

  @override
  Future<List<RemoteToolDescriptor>> materialize(String sessionId) async => [
    for (final registration in filesystemToolRegistrations(
      const _IdentityFacets(),
      const _IdentityFacets(),
    ))
      RemoteToolDescriptor.fromLocal(
        registration,
        routeId: registration.definition.id.value,
        executionHostServices: _executionHostServices(registration),
      ),
  ];

  @override
  Future<RemoteCanonicalToolArguments> validateAndNormalize(
    String routeId,
    Map<String, Object?> proposedArguments,
  ) async {
    final tool = _registration(routeId, const _IdentityFacets()).executable;
    final CanonicalToolArguments arguments;
    try {
      arguments = await tool.validateAndNormalize(proposedArguments);
    } on ToolArgumentValidationException catch (error) {
      throw RemoteToolArgumentValidationFailure(
        code: 'invalid_arguments',
        message: error.message,
        details: const <String, Object?>{},
      );
    }
    return RemoteCanonicalToolArguments.fromLocal(arguments);
  }

  @override
  Future<RemoteEffectDescription> describe(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? environmentId,
  ) async {
    final facets = _IdentityFacets(
      sessionId: SessionId(sessionId),
      environmentId: _requireEnvironment(environmentId),
    );
    return RemoteEffectDescription.fromLocal(
      await _registration(routeId, facets).executable.describe(
        arguments.toLocal(),
        ToolExecutionContext(sessionId: facets.sessionId, runId: RunId(runId)),
      ),
    );
  }

  @override
  Stream<RemoteToolExecutionEvent> execute(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? environmentId,
    String? hostInvocationContext,
  ) async* {
    final services = _executionHostServices(
      _registration(routeId, const _IdentityFacets()),
    );
    if (hostInvocationContext == null) {
      throw StateError(
        'Filesystem Tools requires an authorized host invocation context.',
      );
    }
    final facets = _OperationFacets(
      sessionId: SessionId(sessionId),
      environmentId: _requireEnvironment(environmentId),
      read: services.contains(authorizedEnvironmentReadServiceId)
          ? AuthorizedEnvironmentReadServiceClient(
              _hostRequests.bind(
                hostInvocationContext: hostInvocationContext,
                serviceId: authorizedEnvironmentReadServiceId,
              ),
            )
          : null,
      mutation: services.contains(authorizedEnvironmentMutationServiceId)
          ? AuthorizedEnvironmentMutationServiceClient(
              _hostRequests.bind(
                hostInvocationContext: hostInvocationContext,
                serviceId: authorizedEnvironmentMutationServiceId,
              ),
            )
          : null,
    );
    yield* _registration(routeId, facets).executable
        .execute(
          arguments.toLocal(),
          ToolExecutionContext(
            sessionId: facets.sessionId,
            runId: RunId(runId),
          ),
        )
        .map(RemoteToolExecutionEvent.fromLocal);
  }

  ToolRegistration _registration(String routeId, _IdentityFacets facets) {
    for (final registration in filesystemToolRegistrations(facets, facets)) {
      if (registration.definition.id.value == routeId) return registration;
    }
    throw ArgumentError.value(
      routeId,
      'routeId',
      'Unknown Filesystem tool route.',
    );
  }

  List<String> _executionHostServices(ToolRegistration registration) =>
      switch (registration.modelDefinition.alias) {
        'read_file' => const [authorizedEnvironmentReadServiceId],
        'create_file' => const [authorizedEnvironmentMutationServiceId],
        'apply_patch' || 'delete_file' => const [
          authorizedEnvironmentReadServiceId,
          authorizedEnvironmentMutationServiceId,
        ],
        _ => throw StateError('Unknown Filesystem tool dependencies.'),
      };

  EnvironmentId _requireEnvironment(String? environmentId) {
    if (environmentId == null) {
      throw StateError('Filesystem Tools requires Environment identity data.');
    }
    return EnvironmentId(environmentId);
  }
}

// Identity is description data, not authority. Every effect fails unless an
// execution-only subclass supplies the exact invocation's generated clients.
class _IdentityFacets
    implements
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileMutationFacet {
  const _IdentityFacets({SessionId? sessionId, EnvironmentId? environmentId})
    : _sessionId = sessionId,
      _environmentId = environmentId;

  final SessionId? _sessionId;
  final EnvironmentId? _environmentId;

  @override
  SessionId get sessionId =>
      _sessionId ?? (throw StateError('No Session identity supplied.'));

  @override
  EnvironmentId get environmentId =>
      _environmentId ?? (throw StateError('No Environment identity supplied.'));

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) =>
      throw StateError('Identity-only facets cannot read files.');

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      throw StateError('Identity-only facets cannot read directories.');

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) => throw StateError('Identity-only facets cannot create files.');

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => throw StateError('Identity-only facets cannot replace files.');

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) => throw StateError('Identity-only facets cannot delete files.');

  @override
  void validateBinding() =>
      throw StateError('Identity-only facets have no execution binding.');
}

final class _OperationFacets extends _IdentityFacets {
  const _OperationFacets({
    required SessionId super.sessionId,
    required EnvironmentId super.environmentId,
    required this.read,
    required this.mutation,
  });

  final AuthorizedEnvironmentReadServiceClient? read;
  final AuthorizedEnvironmentMutationServiceClient? mutation;

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) => read == null
      ? super.readFile(relativePath)
      : read!.readFile(relativePath);

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      read == null
      ? super.readDirectory(relativePath)
      : read!.readDirectory(relativePath);

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) => mutation == null
      ? super.createTextFile(relativePath, text)
      : mutation!.createTextFile(relativePath, text);

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => mutation == null
      ? super.replaceExistingTextFile(
          relativePath,
          replacementText,
          expectedRevision,
        )
      : mutation!.replaceExistingTextFile(
          relativePath,
          replacementText,
          expectedRevision,
        );

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) => mutation == null
      ? super.deleteExistingTextFile(relativePath, expectedRevision)
      : mutation!.deleteExistingTextFile(relativePath, expectedRevision);

  @override
  void validateBinding() {
    // The host validates exact authority around each call and outer settlement.
    // Transported identity data never selects or renews an execution binding.
  }
}
