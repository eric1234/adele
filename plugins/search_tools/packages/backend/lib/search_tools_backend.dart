/// Remote Search Tools over operation-scoped, host-authorized reads.
library;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_product/adele_product.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

final class SearchToolsBackend implements RemoteModelToolService {
  const SearchToolsBackend(this._hostRequests);

  final AdeleHostRequestMultiplexer _hostRequests;

  @override
  Future<List<RemoteToolDescriptor>> materialize(String sessionId) async {
    final registration = const SearchExecutable.unbound().registration;
    return [
      RemoteToolDescriptor.fromLocal(
        registration,
        routeId: searchToolId.value,
        executionHostServices: const [authorizedEnvironmentReadServiceId],
      ),
    ];
  }

  @override
  Future<RemoteCanonicalToolArguments> validateAndNormalize(
    String routeId,
    Map<String, Object?> proposedArguments,
  ) async {
    _requireRoute(routeId);
    final CanonicalToolArguments arguments;
    try {
      arguments = const SearchExecutable.unbound().validateAndNormalize(
        proposedArguments,
      );
    } on FormatException catch (error) {
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
    _requireRoute(routeId);
    final tool = SearchExecutable(
      _OperationReadFacet(sessionId, environmentId),
    );
    return RemoteEffectDescription.fromLocal(
      await tool.describe(
        arguments.toLocal(),
        ToolExecutionContext(
          sessionId: SessionId(sessionId),
          runId: RunId(runId),
        ),
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
    _requireRoute(routeId);
    final tool = _operationTool(
      sessionId,
      environmentId,
      hostInvocationContext,
    );
    yield* tool
        .execute(
          arguments.toLocal(),
          ToolExecutionContext(
            sessionId: SessionId(sessionId),
            runId: RunId(runId),
          ),
        )
        .map(RemoteToolExecutionEvent.fromLocal);
  }

  void _requireRoute(String routeId) {
    if (routeId != searchToolId.value) {
      throw ArgumentError.value(
        routeId,
        'routeId',
        'Unknown Search tool route.',
      );
    }
  }

  SearchExecutable _operationTool(
    String sessionId,
    String? environmentId,
    String? hostInvocationContext,
  ) {
    if (hostInvocationContext == null) {
      throw StateError(
        'Search requires an authorized host invocation context.',
      );
    }
    final client = AuthorizedEnvironmentReadServiceClient(
      _hostRequests.bind(
        hostInvocationContext: hostInvocationContext,
        serviceId: authorizedEnvironmentReadServiceId,
      ),
    );
    return SearchExecutable(
      _OperationReadFacet(sessionId, environmentId, client: client),
    );
  }
}

final class _OperationReadFacet implements AuthorizedEnvironmentFileReadFacet {
  _OperationReadFacet(
    String sessionId,
    String? environmentId, {
    AuthorizedEnvironmentReadServiceClient? client,
  }) : sessionId = SessionId(sessionId),
       environmentId = EnvironmentId(
         environmentId ??
             (throw StateError('Search requires a captured Environment ID.')),
       ),
       _client = client;

  final AuthorizedEnvironmentReadServiceClient? _client;

  // Description carries identity only and must never issue host reads.
  AuthorizedEnvironmentReadServiceClient get _readClient =>
      _client ??
      (throw StateError('Description has no Environment read authority.'));

  @override
  final SessionId sessionId;

  @override
  final EnvironmentId environmentId;

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      _readClient.readDirectory(relativePath);

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) =>
      _readClient.readFile(relativePath);

  @override
  void validateBinding() {
    // The host validates exact operation authority around every generated call
    // and the outer operation's settlement; there is no local binding to renew.
  }
}
