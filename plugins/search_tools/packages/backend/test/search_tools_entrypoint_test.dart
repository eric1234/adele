import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';
import 'package:test/test.dart';

import '../bin/search_tools_backend.dart' as entrypoint;

void main() {
  test(
    'ready advertises one model-tools extension and no capabilities',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      expect(
        backend.ready['pluginBackendProtocolVersion'],
        adelePluginBackendProtocolVersion,
      );
      expect(AdeleCapabilityExposure.fromReady(backend.ready), isEmpty);
      expect(backend.ready['extensionExposures'], [
        {
          'extensionPointId': 'dev.adele.extension.model-tools',
          'extensionId': 'dev.adele.plugin.search-tools.model-tools',
          'serviceId': remoteModelToolServiceId,
          'configurationContext': 'configured-default',
          'metadata': {
            'hostServices': ['authorizedEnvironmentRead'],
          },
        },
      ]);
      backend.request(remoteModelToolServiceMaterializeId, {
        'sessionId': 'session',
        'hostInvocationContext': null,
      });
      final materialized = await backend.next();
      expect(materialized['ok'], isTrue);
      final descriptor = (materialized['payload']! as List).single! as Map;
      expect(descriptor['toolId'], searchToolId.value);
      expect(descriptor['modelAlias'], 'search');
      expect(descriptor['routeId'], searchToolId.value);
      expect(descriptor.keys.toSet(), {
        'toolId',
        'toolDescription',
        'modelAlias',
        'modelDescription',
        'argumentsSchema',
        'routeId',
      });
      backend.request(remoteModelToolServiceValidateAndNormalizeId, {
        'routeId': searchToolId.value,
        'proposedArguments': {'query': 'needle', 'path': './src//./'},
      });
      expect((await backend.next())['payload'], {
        'snapshot': {'query': 'needle', 'path': 'src'},
      });
      await backend.shutdown();
    },
  );

  test(
    'describe uses a generated no-argument authority response, not input IDs',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      backend.request(remoteModelToolServiceDescribeId, _operationPayload());
      final authority = await backend.next();
      _expectHostRequest(
        authority,
        authorizedEnvironmentReadServiceAuthorityId,
        {},
      );
      backend.respond(authority, {
        'sessionId': 'session',
        'environmentId': 'captured-environment',
      });
      final response = await backend.next();
      expect(response['ok'], isTrue);
      expect(response['payload'], {
        'effects': ['sourceRead'],
        'targetUris': ['adele-environment:/captured-environment/'],
        'summary': 'Search the authorized Environment root.',
        'uncertainty': 'none',
      });
      await backend.shutdown();
    },
  );

  for (final cancel in [false, true]) {
    test(
      'execute streams a semantic terminal and supports ${cancel ? 'cancel' : 'completion'}',
      () async {
        final backend = await _RunningBackend.start();
        addTearDown(backend.close);
        backend.execute(credit: cancel ? 1 : 2);
        final authority = await backend.next();
        _expectHostRequest(
          authority,
          authorizedEnvironmentReadServiceAuthorityId,
          {},
        );
        backend.respond(authority, {
          'sessionId': 'session',
          'environmentId': 'captured-environment',
        });
        final directory = await backend.next();
        _expectHostRequest(
          directory,
          authorizedEnvironmentReadServiceReadDirectoryId,
          {'relativePath': ''},
        );
        backend.respond(directory, {
          'relativePath': '',
          'entries': [
            {'name': 'file.txt', 'relativePath': 'file.txt', 'kind': 'file'},
          ],
        });
        final file = await backend.next();
        _expectHostRequest(file, authorizedEnvironmentReadServiceReadFileId, {
          'relativePath': 'file.txt',
        });
        backend.respond(file, {
          'relativePath': 'file.txt',
          'text': 'Needle\nneedle',
          'sizeBytes': 13,
          'revision': 'opaque-revision',
        });
        final event = await backend.next();
        expect(event['kind'], 'streamItem');
        expect(event['requestId'], 7);
        final payload = event['payload']! as Map;
        expect(payload['kind'], 'terminal');
        expect(payload['progress'], isNull);
        final outcome = payload['outcome']! as Map;
        expect(outcome['disposition'], 'success');
        expect(outcome['failureKind'], isNull);
        expect(outcome['effectCertainty'], 'knownOccurred');
        expect(outcome.containsKey('cause'), isFalse);
        expect(
          (outcome['hostData']! as Map)['environmentId'],
          'captured-environment',
        );
        expect((outcome['hostData']! as Map)['matches'], [
          {'relativePath': 'file.txt', 'lineNumber': 2, 'snippet': 'needle'},
        ]);
        if (cancel) {
          backend.commands.send({'kind': 'streamCancel', 'requestId': 7});
        }
        expect(await backend.next(), {
          'kind': cancel ? 'streamCancelled' : 'streamDone',
          'requestId': 7,
        });
        await backend.shutdown();
      },
    );
  }

  test(
    'execute protocol and authority errors remain stream failures',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      for (final token in <String?>[null, '']) {
        backend.execute(
          payload: {..._operationPayload(), 'hostInvocationContext': token},
        );
        final response = await backend.next();
        expect(response['kind'], 'streamFailure');
        final error = response['error']! as Map;
        expect(error['code'], 'internal_error');
        expect(error.containsKey('declaredFailureType'), isFalse);
      }
      backend.execute(
        payload: {
          ..._operationPayload(),
          'arguments': {'snapshot': 'bad'},
        },
      );
      final response = await backend.next();
      expect(response['kind'], 'streamFailure');
      expect((response['error']! as Map)['code'], 'invalid_request');
      await backend.shutdown();
    },
  );

  test(
    'shutdown settles a blocked host call before draining forward requests',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      backend.request(remoteModelToolServiceDescribeId, _operationPayload());
      expect((await backend.next())['kind'], 'hostRequest');
      backend.commands.send({
        'kind': 'request',
        'requestId': 99,
        'method': 'shutdown',
        'payload': <String, Object?>{},
      });
      final failed = await backend.next();
      expect(failed['kind'], 'response');
      expect(failed['requestId'], 1);
      expect(failed['ok'], isFalse);
      expect(await backend.next(), {
        'kind': 'response',
        'requestId': 99,
        'ok': true,
        'payload': {'stopping': true},
      });
    },
  );
}

Map<String, Object?> _operationPayload() => {
  'routeId': searchToolId.value,
  'arguments': {
    'snapshot': {'query': 'needle', 'path': ''},
  },
  'sessionId': 'session',
  'runId': 'semantic-run-only',
  'hostInvocationContext': 'opaque-operation-token',
};

void _expectHostRequest(
  Map<String, Object?> request,
  String method,
  Map<String, Object?> payload,
) => expect(request, {
  'kind': 'hostRequest',
  'requestId': isA<int>(),
  'hostInvocationContext': 'opaque-operation-token',
  'serviceId': authorizedEnvironmentReadServiceId,
  'method': method,
  'payload': payload,
});

final class _RunningBackend {
  _RunningBackend(this.isolate, this.responses, this.messages, this.ready)
    : commands = ready['commandPort']! as SendPort;

  final Isolate isolate;
  final ReceivePort responses;
  final StreamIterator<Object?> messages;
  final Map<String, Object?> ready;
  final SendPort commands;

  static Future<_RunningBackend> start() async {
    final bootstrap = ReceivePort();
    final responses = ReceivePort();
    final messages = StreamIterator<Object?>(responses);
    final isolate = await Isolate.spawn(_runBackend, [
      bootstrap.sendPort,
      responses.sendPort,
    ]);
    try {
      final ready = await bootstrap.first.timeout(const Duration(seconds: 5));
      return _RunningBackend(
        isolate,
        responses,
        messages,
        Map<String, Object?>.from(ready! as Map),
      );
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      await messages.cancel();
      rethrow;
    } finally {
      bootstrap.close();
    }
  }

  void request(String method, Map<String, Object?> payload) => commands.send({
    'kind': 'request',
    'requestId': 1,
    'configurationContext': 'configured-default',
    'serviceId': remoteModelToolServiceId,
    'method': method,
    'payload': payload,
  });

  void execute({Map<String, Object?>? payload, int credit = 2}) {
    commands.send({
      'kind': 'streamOpen',
      'requestId': 7,
      'configurationContext': 'configured-default',
      'serviceId': remoteModelToolServiceId,
      'method': remoteModelToolServiceExecuteId,
      'payload': payload ?? _operationPayload(),
    });
    commands.send({'kind': 'streamCredit', 'requestId': 7, 'credit': credit});
  }

  void respond(Map<String, Object?> request, Object? payload) => commands.send({
    'kind': 'hostResponse',
    'requestId': request['requestId'],
    'ok': true,
    'payload': payload,
  });

  Future<Map<String, Object?>> next() async {
    expect(
      await messages.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    return Map<String, Object?>.from(messages.current! as Map);
  }

  Future<void> shutdown() async {
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
  }

  Future<void> close() async {
    isolate.kill(priority: Isolate.immediate);
    responses.close();
    await messages.cancel();
  }
}

Future<void> _runBackend(List<SendPort> ports) => entrypoint.main([], {
  'bootstrapPort': ports[0],
  'responsePort': ports[1],
  'defaultConfigurationContext': 'configured-default',
});
