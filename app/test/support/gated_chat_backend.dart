import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_orchestration.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:chat_strategy_backend/chat_strategy_backend.dart';

/// Real Chat and host storage with a test-controlled draft transaction barrier.
Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  final bootstrap = bootstrapMessage! as Map;
  final bootstrapPort = bootstrap['bootstrapPort'] as SendPort;
  final responsePort = bootstrap['responsePort'] as SendPort;
  final context = bootstrap['defaultConfigurationContext'] as String;
  final hostRequests = AdeleHostRequestMultiplexer(send: responsePort.send);
  final storage = _GatedStorage(
    ProjectStorageServiceClient(
      hostRequests.bindInfrastructure(
        hostInfrastructureContext:
            bootstrap['hostInfrastructureContext'] as String,
        serviceId: projectStorageServiceId,
      ),
    ),
    Uri.parse(arguments.single),
  );
  final sessions = ChatSessionStore(storage: storage);
  final orchestration = ChatRemoteOrchestrationBackend(
    sessions: sessions,
    hostChannel: (context) => hostRequests.bind(
      hostInvocationContext: context,
      serviceId: remoteOrchestrationHostServiceId,
    ),
  );
  final router = AdeleConfigurationContextRouter(
    contexts: {
      context: {
        chatSessionServiceId: ChatSessionServiceDispatcher(
          ChatSessionBackend(sessions),
        ),
        remoteOrchestrationServiceId: RemoteOrchestrationServiceDispatcher(
          orchestration,
        ),
      },
    },
  );
  final requests = ReceivePort();
  try {
    bootstrapPort.send(<String, Object?>{
      'kind': 'ready',
      'commandPort': requests.sendPort,
      'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
      'extensionExposures': [
        AdeleExtensionExposure(
          extensionPointId: orchestrationStrategyContributions.value,
          extensionId: chatStrategyExtensionId.value,
          serviceId: remoteOrchestrationServiceId,
          configurationContext: context,
          metadata: {
            'strategyId': chatStrategyId.value,
            'routeId': chatStrategyRouteId,
          },
        ).toMap(),
      ],
    });
    await for (final Object? request in requests) {
      if (hostRequests.handleResponse(request)) continue;
      if (request is! Map) continue;
      if (request['kind'] == 'request' && request['method'] == 'shutdown') {
        hostRequests.close();
        await orchestration.close();
        await router.close();
        responsePort.send(<String, Object?>{
          'kind': 'response',
          'requestId': request['requestId'],
          'ok': true,
          'payload': <String, Object?>{'stopping': true},
        });
        break;
      }
      unawaited(router.handle(request, responsePort.send));
    }
  } finally {
    storage.client.close(force: true);
    hostRequests.close();
    requests.close();
    await orchestration.close();
    await router.close();
  }
}

final class _GatedStorage implements ProjectStorageService {
  _GatedStorage(this.delegate, this.endpoint);
  final ProjectStorageService delegate;
  final Uri endpoint;
  final HttpClient client = HttpClient();

  @override
  Future<bool> isDurableSession(String sessionId) =>
      delegate.isDurableSession(sessionId);

  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
  ) => delegate.ensureSchemaForSession(sessionId, migrations);

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
  ) => delegate.queryForSession(sessionId, sql, parameters);

  @override
  Future<void> transactionForSession(
    String sessionId,
    List<RelationalStatement> statements,
  ) async {
    for (final statement in statements) {
      if (!statement.sql.contains('SET draft_request')) continue;
      final request = await client.postUrl(endpoint);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'sessionId': sessionId,
          'parameters': statement.parameters,
        }),
      );
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Draft storage rejected by the navigation fixture.');
      }
    }
    await delegate.transactionForSession(sessionId, statements);
  }
}
