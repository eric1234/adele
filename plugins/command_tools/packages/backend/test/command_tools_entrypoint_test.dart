import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:command_tools_backend/command_tools_backend.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:test/test.dart';

import '../../../test/support/command_storage.dart';
import '../bin/command_tools_backend.dart' as entrypoint;

void main() {
  test(
    'ready exposes exact separate run and search contexts without process launches',
    () async {
      final bootstrap = ReceivePort();
      final responses = ReceivePort();
      final messages = StreamIterator<Object?>(responses);
      final storage = CommandTestStorage();
      final storageDispatcher = ProjectStorageServiceDispatcher(storage);
      final hostRequests = <Map<Object?, Object?>>[];
      final isolate = await Isolate.spawn(_run, [
        bootstrap.sendPort,
        responses.sendPort,
      ]);
      addTearDown(() async {
        isolate.kill(priority: Isolate.immediate);
        bootstrap.close();
        responses.close();
        await messages.cancel();
        await storageDispatcher.close();
        storage.close();
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
        {
          'extensionPointId': 'dev.adele.extension.model-tools',
          'extensionId': commandOutputSearchExtensionId.value,
          'serviceId': remoteModelToolServiceId,
          'configurationContext': commandOutputSearchConfigurationContext,
          'metadata': {'hostServices': <String>[]},
        },
      ]);
      final commands = ready['commandPort']! as SendPort;
      Future<Map<Object?, Object?>> next() async {
        while (true) {
          expect(
            await messages.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
          final message = messages.current! as Map;
          if (message['kind'] != 'hostRequest') {
            expect(message['kind'], isNot(startsWith('host')));
            return message;
          }
          hostRequests.add(message);
          expect(message['hostContextKind'], 'infrastructure');
          expect(message['hostContext'], 'infrastructure');
          expect(message['serviceId'], projectStorageServiceId);
          final response = await storageDispatcher.dispatch({
            'kind': 'request',
            'requestId': message['requestId'],
            'method': message['method'],
            'payload': message['payload'],
          });
          commands.send({...response, 'kind': 'hostResponse'});
        }
      }

      var requestId = 0;
      Future<Map<Object?, Object?>> request(
        String context,
        String method,
        Map<String, Object?> payload, {
        String serviceId = remoteModelToolServiceId,
      }) async {
        commands.send({
          'kind': 'request',
          'requestId': ++requestId,
          'configurationContext': context,
          'serviceId': serviceId,
          'method': method,
          'payload': payload,
        });
        final response = await next();
        expect(response['kind'], 'response');
        expect(response['requestId'], requestId);
        return response;
      }

      for (final (context, route, alias, services) in [
        (
          'configured-default',
          runCommandToolId.value,
          'run_command',
          ['authorizedEnvironmentProcess'],
        ),
        (
          commandOutputSearchConfigurationContext,
          searchCommandOutputToolId.value,
          'search_command_output',
          <String>[],
        ),
      ]) {
        final response = await request(
          context,
          remoteModelToolServiceMaterializeId,
          {'sessionId': 'session'},
        );
        expect(response['ok'], isTrue);
        final descriptor = (response['payload']! as List).single as Map;
        expect(descriptor['toolId'], route);
        expect(descriptor['routeId'], route);
        expect(descriptor['modelAlias'], alias);
        expect(descriptor['executionHostServices'], services);
      }

      final validated = await request(
        commandOutputSearchConfigurationContext,
        remoteModelToolServiceValidateAndNormalizeId,
        {
          'routeId': searchCommandOutputToolId.value,
          'proposedArguments': {
            'runId': 'retained-run',
            'toolInvocationId': 'retained-command',
            'pattern': 'needle',
          },
        },
      );
      expect(validated['ok'], isTrue);
      final operation = <String, Object?>{
        'routeId': searchCommandOutputToolId.value,
        'arguments': validated['payload'],
        'sessionId': 'session',
        'runId': 'current-run',
        'toolInvocationId': 'current-search',
        'environmentId': null,
      };
      final description = await request(
        commandOutputSearchConfigurationContext,
        remoteModelToolServiceDescribeId,
        operation,
      );
      expect(description['ok'], isTrue);
      expect((description['payload']! as Map)['effects'], [
        'resourceInspection',
      ]);

      for (final (context, rejectedRoute) in [
        ('configured-default', searchCommandOutputToolId.value),
        (commandOutputSearchConfigurationContext, runCommandToolId.value),
      ]) {
        final rejected = await request(
          context,
          remoteModelToolServiceValidateAndNormalizeId,
          {'routeId': rejectedRoute, 'proposedArguments': <String, Object?>{}},
        );
        expect(rejected['ok'], isFalse);
        expect((rejected['error']! as Map)['code'], 'internal_error');
        expect((rejected['error']! as Map)['declaredFailureType'], isNull);
      }
      final unknown = await request(
        'unknown-context',
        remoteModelToolServiceMaterializeId,
        {'sessionId': 'session'},
      );
      expect(
        (unknown['error']! as Map)['code'],
        'configuration_context_unavailable',
      );
      final wrongService = await request(
        commandOutputSearchConfigurationContext,
        commandOutputServiceGetStateId,
        {
          'sessionId': 'session',
          'runId': 'run',
          'toolInvocationId': 'invocation',
        },
        serviceId: commandOutputServiceId,
      );
      expect((wrongService['error']! as Map)['code'], 'service_unavailable');

      final outputResponse = await request(
        'configured-default',
        commandOutputServiceGetStateId,
        {'sessionId': '', 'runId': 'run', 'toolInvocationId': 'invocation'},
        serviceId: commandOutputServiceId,
      );
      expect(outputResponse['ok'], isFalse);
      expect((outputResponse['error']! as Map)['code'], 'invalid_identity');
      expect(
        (outputResponse['error']! as Map)['declaredFailureType'],
        commandOutputFailureTypeId,
      );
      expect(hostRequests, isEmpty);
      expect(storage.schemaChecks, 0);

      final transcripts = CommandTranscriptStore(storage);
      addTearDown(transcripts.close);
      final writer = await transcripts.begin(
        context: ToolExecutionContext(
          sessionId: SessionId('session'),
          runId: RunId('retained-run'),
          toolInvocationId: 'retained-command',
        ),
        environmentId: 'retired-environment',
        request: EnvironmentForegroundProcessRequest(
          program: 'fixture',
          arguments: [],
          relativeWorkingDirectory: '',
          timeoutSeconds: 30,
        ),
      );
      await writer.append(
        EnvironmentProcessOutput(
          stream: EnvironmentProcessOutputStream.stdout,
          text: 'needle retained output\n',
        ),
      );
      await writer.seal(
        EnvironmentProcessCompleted(
          termination: EnvironmentProcessTermination.exited,
          exitCode: 7,
          stdoutTruncated: false,
          stderrTruncated: false,
        ),
      );
      final writes = storage.transactions;

      commands.send({
        'kind': 'streamOpen',
        'requestId': ++requestId,
        'configurationContext': commandOutputSearchConfigurationContext,
        'serviceId': remoteModelToolServiceId,
        'method': remoteModelToolServiceExecuteId,
        'payload': {...operation, 'hostInvocationContext': null},
      });
      commands.send({
        'kind': 'streamCredit',
        'requestId': requestId,
        'credit': 2,
      });
      final event = await next();
      expect(event['kind'], 'streamItem');
      expect(event['requestId'], requestId);
      final payload = event['payload']! as Map;
      expect(payload['kind'], 'terminal');
      expect(payload['progress'], isNull);
      final outcome = payload['outcome']! as Map;
      expect(outcome['disposition'], 'success');
      expect((outcome['hostData']! as Map)['captureState'], 'complete');
      expect(outcome['modelContent'], contains('needle retained output'));
      expect(await next(), {'kind': 'streamDone', 'requestId': requestId});
      expect(hostRequests, isNotEmpty);
      expect(storage.transactions, writes);

      commands.send({
        'kind': 'request',
        'requestId': 99,
        'method': 'shutdown',
        'payload': <String, Object?>{},
      });
      expect(await next(), {
        'kind': 'response',
        'requestId': 99,
        'ok': true,
        'payload': {'stopping': true},
      });
    },
  );

  test('a colliding default context cannot replace either route', () async {
    final bootstrap = ReceivePort();
    final responses = ReceivePort();
    addTearDown(bootstrap.close);
    addTearDown(responses.close);
    await expectLater(
      entrypoint.main([], {
        'bootstrapPort': bootstrap.sendPort,
        'responsePort': responses.sendPort,
        'defaultConfigurationContext': commandOutputSearchConfigurationContext,
        'hostInfrastructureContext': 'infrastructure',
      }),
      throwsStateError,
    );
  });
}

Future<void> _run(List<SendPort> ports) => entrypoint.main([], {
  'bootstrapPort': ports[0],
  'responsePort': ports[1],
  'defaultConfigurationContext': 'configured-default',
  'hostInfrastructureContext': 'infrastructure',
});
