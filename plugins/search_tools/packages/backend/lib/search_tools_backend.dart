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
  Future<List<RemoteToolDescriptor>> materialize(
    String sessionId,
    String? hostInvocationContext,
  ) async {
    final registration = const SearchExecutable.unbound().registration;
    return [
      RemoteToolDescriptor.fromLocal(registration, routeId: searchToolId.value),
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
    String? hostInvocationContext,
  ) async {
    _requireRoute(routeId);
    final tool = await _operationTool(hostInvocationContext);
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
    String? hostInvocationContext,
  ) async* {
    _requireRoute(routeId);
    final tool = await _operationTool(hostInvocationContext);
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

  Future<SearchExecutable> _operationTool(String? hostInvocationContext) async {
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
    final identity = await client.authority();
    return SearchExecutable(_OperationReadFacet(client, identity));
  }
}

final class _OperationReadFacet implements AuthorizedEnvironmentFileReadFacet {
  _OperationReadFacet(this._client, AuthorizedEnvironmentIdentity identity)
    : sessionId = SessionId(identity.sessionId),
      environmentId = EnvironmentId(identity.environmentId);

  final AuthorizedEnvironmentReadServiceClient _client;

  @override
  final SessionId sessionId;

  @override
  final EnvironmentId environmentId;

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      _client.readDirectory(relativePath);

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) =>
      _client.readFile(relativePath);

  @override
  void validateBinding() {
    // The host validates exact operation authority around every generated call
    // and the outer operation's settlement; there is no local binding to renew.
  }
}
