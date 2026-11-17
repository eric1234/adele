import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_orchestration/remote_tool_authorization.dart';
import 'package:conservative_tool_policy_backend/conservative_tool_policy_backend.dart';

Future<void> main(List<String> arguments, Object? bootstrapMessage) async {
  if (arguments.isNotEmpty || bootstrapMessage is! Map) {
    stderr.writeln('Expected bootstrap metadata and no plugin arguments.');
    exitCode = 64;
    return;
  }
  final Object? bootstrapPort = bootstrapMessage['bootstrapPort'];
  final Object? responsePort = bootstrapMessage['responsePort'];
  final Object? defaultConfigurationContext =
      bootstrapMessage['defaultConfigurationContext'];
  if (bootstrapPort is! SendPort ||
      responsePort is! SendPort ||
      defaultConfigurationContext is! String) {
    throw ArgumentError.value(bootstrapMessage, 'bootstrapMessage');
  }

  final router = AdeleConfigurationContextRouter.single(
    configurationContext: defaultConfigurationContext,
    serviceId: remoteToolAuthorizationPolicyServiceId,
    dispatcher: RemoteToolAuthorizationPolicyServiceDispatcher(
      const ConservativeToolPolicyBackend(),
    ),
  );
  final requests = ReceivePort();
  try {
    bootstrapPort.send(<String, Object?>{
      'kind': 'ready',
      'commandPort': requests.sendPort,
      'pluginBackendProtocolVersion': adelePluginBackendProtocolVersion,
      'extensionExposures': [
        AdeleExtensionExposure(
          extensionPointId: toolAuthorizationPolicies.value,
          extensionId:
              'dev.adele.plugin.conservative-tool-policy.authorization',
          serviceId: remoteToolAuthorizationPolicyServiceId,
          configurationContext: defaultConfigurationContext,
          metadata: const {'routeId': conservativeToolPolicyRouteId},
        ).toMap(),
      ],
    });
    await for (final Object? request in requests) {
      if (request is! Map) continue;
      if (request['kind'] == 'request' &&
          request['method'] == 'shutdown' &&
          request['requestId'] is int) {
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
    requests.close();
    await router.close();
  }
}
