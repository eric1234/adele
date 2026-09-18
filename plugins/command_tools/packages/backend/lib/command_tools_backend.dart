/// Remote Command Tools over operation-scoped, host-authorized processes.
library;

import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_product/adele_product.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';

final class CommandToolsBackend implements RemoteModelToolService {
  const CommandToolsBackend(this._hostRequests);

  final AdeleHostRequestMultiplexer _hostRequests;

  @override
  Future<List<RemoteToolDescriptor>> materialize(String sessionId) async => [
    RemoteToolDescriptor.fromLocal(
      commandToolRegistration(const _IdentityProcessFacet()),
      routeId: runCommandToolId.value,
      executionHostServices: const [authorizedEnvironmentProcessServiceId],
    ),
  ];

  @override
  Future<RemoteCanonicalToolArguments> validateAndNormalize(
    String routeId,
    Map<String, Object?> proposedArguments,
  ) async {
    _requireRoute(routeId);
    final CanonicalToolArguments arguments;
    try {
      arguments = await commandToolRegistration(
        const _IdentityProcessFacet(),
      ).executable.validateAndNormalize(proposedArguments);
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
    _requireRoute(routeId);
    final facet = _IdentityProcessFacet(
      sessionId: SessionId(sessionId),
      environmentId: _requireEnvironment(environmentId),
    );
    return RemoteEffectDescription.fromLocal(
      await commandToolRegistration(facet).executable.describe(
        arguments.toLocal(),
        ToolExecutionContext(sessionId: facet.sessionId, runId: RunId(runId)),
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
    if (hostInvocationContext == null) {
      throw StateError(
        'Command Tools requires an authorized host invocation context.',
      );
    }
    final facet = _OperationProcessFacet(
      sessionId: SessionId(sessionId),
      environmentId: _requireEnvironment(environmentId),
      client: AuthorizedEnvironmentProcessServiceClient(
        _hostRequests.bind(
          hostInvocationContext: hostInvocationContext,
          serviceId: authorizedEnvironmentProcessServiceId,
        ),
      ),
    );
    yield* commandToolRegistration(facet).executable
        .execute(
          arguments.toLocal(),
          ToolExecutionContext(sessionId: facet.sessionId, runId: RunId(runId)),
        )
        .map(RemoteToolExecutionEvent.fromLocal);
  }

  void _requireRoute(String routeId) {
    if (routeId != runCommandToolId.value) {
      throw ArgumentError.value(
        routeId,
        'routeId',
        'Unknown Command tool route.',
      );
    }
  }

  EnvironmentId _requireEnvironment(String? environmentId) {
    if (environmentId == null) {
      throw StateError('Command Tools requires Environment identity data.');
    }
    return EnvironmentId(environmentId);
  }
}

// Description identity is data, not authority. Only execute binds a client.
class _IdentityProcessFacet implements AuthorizedEnvironmentProcessFacet {
  const _IdentityProcessFacet({
    SessionId? sessionId,
    EnvironmentId? environmentId,
  }) : _sessionId = sessionId,
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
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) => throw StateError('Identity-only facets cannot run processes.');

  @override
  void validateBinding() =>
      throw StateError('Identity-only facets have no execution binding.');
}

final class _OperationProcessFacet extends _IdentityProcessFacet {
  const _OperationProcessFacet({
    required SessionId super.sessionId,
    required EnvironmentId super.environmentId,
    required this.client,
  });

  final AuthorizedEnvironmentProcessServiceClient client;

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) => client.runForegroundProcess(request);

  @override
  void validateBinding() {
    // The host validates exact authority around every event and settlement.
    // Transported identities never select or renew an execution binding.
  }
}
