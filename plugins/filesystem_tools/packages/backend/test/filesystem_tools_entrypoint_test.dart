import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:test/test.dart';

import '../bin/filesystem_tools_backend.dart' as entrypoint;

const _createRoute = 'dev.adele.plugin.filesystem-tools.create-file';

void main() {
  test(
    'ready exposes one default modelTool extension and no capability',
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
          'extensionId': 'dev.adele.plugin.filesystem-tools.model-tools',
          'serviceId': 'modelTool',
          'configurationContext': 'configured-default',
          'metadata': {
            'hostServices': [
              'authorizedEnvironmentRead',
              'authorizedEnvironmentMutation',
            ],
          },
        },
      ]);
      backend.request(remoteModelToolServiceMaterializeId, {
        'sessionId': 'session',
      });
      final response = await backend.next();
      expect(response['kind'], 'response');
      expect(response['ok'], isTrue);
      final descriptors = (response['payload']! as List)
          .cast<Map<Object?, Object?>>();
      expect(descriptors.map((tool) => tool['modelAlias']), [
        'read_file',
        'apply_patch',
        'create_file',
        'delete_file',
      ]);
      expect(descriptors.map((tool) => tool['executionHostServices']), [
        ['authorizedEnvironmentRead'],
        ['authorizedEnvironmentRead', 'authorizedEnvironmentMutation'],
        ['authorizedEnvironmentMutation'],
        ['authorizedEnvironmentRead', 'authorizedEnvironmentMutation'],
      ]);
      backend.request(remoteModelToolServiceValidateAndNormalizeId, {
        'routeId': _createRoute,
        'proposedArguments': {
          'relativePath': './dir//source.dart',
          'content': 'new\n',
        },
      });
      expect((await backend.next())['payload'], {
        'snapshot': {'relativePath': 'dir/source.dart', 'content': 'new\n'},
      });
      await backend.shutdown();
    },
  );

  test(
    'describe is pure data and wrappers reject invocation authority',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      backend.request(remoteModelToolServiceDescribeId, _descriptionPayload());
      final response = await backend.next();
      expect(response['kind'], 'response');
      expect(response['ok'], isTrue);
      expect(response['payload'], {
        'effects': ['sourceMutation'],
        'targetUris': ['adele-environment:/environment-data/dir/source.dart'],
        'summary': 'Create Environment file dir/source.dart.',
        'uncertainty': 'none',
      });
      for (final (method, payload) in [
        (
          remoteModelToolServiceMaterializeId,
          <String, Object?>{'sessionId': 'session'},
        ),
        (remoteModelToolServiceDescribeId, _descriptionPayload()),
      ]) {
        backend.request(method, {
          ...payload,
          'hostInvocationContext': 'forbidden',
        });
        final response = await backend.next();
        expect(response['kind'], 'response');
        expect(response['ok'], isFalse);
        final error = response['error']! as Map;
        expect(error['code'], 'invalid_request');
        expect(error.containsKey('declaredFailureType'), isFalse);
      }
      await backend.shutdown();
    },
  );

  for (final cancel in [false, true]) {
    test(
      'create executes with mutation only and ${cancel ? 'cancels' : 'completes'} its stream',
      () async {
        final backend = await _RunningBackend.start();
        addTearDown(backend.close);
        backend.execute(credit: cancel ? 1 : 2);
        final request = await backend.next();
        expect(request, {
          'kind': 'hostRequest',
          'requestId': isA<int>(),
          'hostInvocationContext': 'opaque-invocation',
          'serviceId': authorizedEnvironmentMutationServiceId,
          'method': authorizedEnvironmentMutationServiceCreateTextFileId,
          'payload': {'relativePath': 'dir/source.dart', 'text': 'new\n'},
        });
        backend.commands.send({
          'kind': 'hostResponse',
          'requestId': request['requestId'],
          'ok': true,
          'payload': {'revision': 'created-revision'},
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
        expect(outcome['hostData'], {
          'environmentId': 'environment-data',
          'relativePath': 'dir/source.dart',
          'revision': 'created-revision',
        });
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
    'route, identity and protocol errors are stream failures, not domain outcomes',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      for (final override in <Map<String, Object?>>[
        {'routeId': 'create_file'},
        {'environmentId': null},
        {'hostInvocationContext': null},
        {'hostInvocationContext': ''},
        {
          'arguments': {'snapshot': 'bad'},
        },
      ]) {
        backend.execute(payload: {..._executionPayload(), ...override});
        final response = await backend.next();
        expect(response['kind'], 'streamFailure');
        final error = response['error']! as Map;
        expect(
          error['code'],
          override.containsKey('arguments')
              ? 'invalid_request'
              : 'internal_error',
        );
        expect(error.containsKey('declaredFailureType'), isFalse);
      }
      await backend.shutdown();
    },
  );
}

Map<String, Object?> _descriptionPayload() => {
  'routeId': _createRoute,
  'arguments': {
    'snapshot': {'relativePath': 'dir/source.dart', 'content': 'new\n'},
  },
  'sessionId': 'session-data',
  'runId': 'run-data',
  'environmentId': 'environment-data',
};

Map<String, Object?> _executionPayload() => {
  ..._descriptionPayload(),
  'hostInvocationContext': 'opaque-invocation',
};

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
      'payload': payload ?? _executionPayload(),
    });
    commands.send({'kind': 'streamCredit', 'requestId': 7, 'credit': credit});
  }

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
