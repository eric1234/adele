import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:test/test.dart';

import '../bin/command_tools_backend.dart' as entrypoint;

void main() {
  test(
    'ready exposes one default process-only modelTool extension and no capability',
    () async {
      final bootstrap = ReceivePort();
      final responses = ReceivePort();
      final messages = StreamIterator<Object?>(responses);
      final isolate = await Isolate.spawn(_run, [
        bootstrap.sendPort,
        responses.sendPort,
      ]);
      addTearDown(() async {
        isolate.kill(priority: Isolate.immediate);
        bootstrap.close();
        responses.close();
        await messages.cancel();
      });
      final ready =
          await bootstrap.first.timeout(const Duration(seconds: 5)) as Map;
      expect(
        ready['pluginBackendProtocolVersion'],
        adelePluginBackendProtocolVersion,
      );
      expect(AdeleCapabilityExposure.fromReady(ready), isEmpty);
      expect(ready['extensionExposures'], [
        {
          'extensionPointId': 'dev.adele.extension.model-tools',
          'extensionId': 'dev.adele.plugin.command-tools.model-tools',
          'serviceId': 'modelTool',
          'configurationContext': 'configured-default',
          'metadata': {
            'hostServices': ['authorizedEnvironmentProcess'],
          },
        },
      ]);
      final commands = ready['commandPort']! as SendPort;
      commands.send({
        'kind': 'request',
        'requestId': 1,
        'configurationContext': 'configured-default',
        'serviceId': remoteModelToolServiceId,
        'method': remoteModelToolServiceMaterializeId,
        'payload': {'sessionId': 'session'},
      });
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      final response = messages.current! as Map;
      expect(response['kind'], 'response');
      expect(response['ok'], isTrue);
      final descriptor = (response['payload']! as List).single as Map;
      expect(descriptor['modelAlias'], 'run_command');
      expect(descriptor['executionHostServices'], [
        'authorizedEnvironmentProcess',
      ]);
      commands.send({
        'kind': 'request',
        'requestId': 99,
        'method': 'shutdown',
        'payload': <String, Object?>{},
      });
      expect(
        await messages.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(messages.current, {
        'kind': 'response',
        'requestId': 99,
        'ok': true,
        'payload': {'stopping': true},
      });
    },
  );
}

Future<void> _run(List<SendPort> ports) => entrypoint.main([], {
  'bootstrapPort': ports[0],
  'responsePort': ports[1],
  'defaultConfigurationContext': 'configured-default',
});
