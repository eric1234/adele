import 'dart:async';
import 'dart:isolate';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:agents_md_backend/agents_md_backend.dart';
import 'package:test/test.dart';

import '../bin/agents_md_backend.dart' as entrypoint;

void main() {
  test(
    'snapshot reads root with only bound authority and preserves exact material',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.files.text = ' \r\n# Opaque Markdown\r\n  preserve this \n';
      final result = await fixture.backend.snapshot(
        '/not/an/authority/session',
        '/nor/a/run/path',
        'opaque-host-token',
      );
      expect(fixture.requests.single, {
        'kind': 'hostRequest',
        'requestId': isA<int>(),
        'hostInvocationContext': 'opaque-host-token',
        'serviceId': authorizedEnvironmentReadServiceId,
        'method': authorizedEnvironmentReadServiceReadFileId,
        'payload': {'relativePath': 'AGENTS.md'},
      });
      expect(result.map((value) => value.key), ['semantics', 'AGENTS.md']);
      expect(
        result.first.text,
        'The following AGENTS.md material is project guidance from the '
        'Session Environment root. Explicit user instructions and direct '
        'user requests take precedence over AGENTS.md guidance.',
      );
      expect(result.first.revision, isNull);
      expect(result.last.text, fixture.files.text);
      expect(result.last.revision, 'revision-1');
      expect(fixture.files.paths, ['AGENTS.md']);
    },
  );

  test(
    'each inference rereads and leaves previous snapshot unchanged',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.files.text = 'first';
      final first = await fixture.backend.snapshot(
        'session',
        'run',
        'first-context',
      );
      fixture.files.text = 'second';
      fixture.files.revision = 'revision-2';
      final second = await fixture.backend.snapshot(
        'session',
        'run',
        'next-context',
      );
      fixture.files.text = null;
      final third = await fixture.backend.snapshot(
        'session',
        'run',
        'last-context',
      );
      expect(first.last.text, 'first');
      expect(first.last.revision, 'revision-1');
      expect(second.last.text, 'second');
      expect(second.last.revision, 'revision-2');
      expect(third, isEmpty);
      expect(fixture.files.paths, ['AGENTS.md', 'AGENTS.md', 'AGENTS.md']);
      expect(fixture.requests.map((value) => value['hostInvocationContext']), [
        'first-context',
        'next-context',
        'last-context',
      ]);
    },
  );

  for (final text in <String?>[null, '', ' \t\r\n']) {
    test(
      'missing or blank text ($text) is empty over generated host service',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.close);
        fixture.files.text = text;
        expect(
          await fixture.backend.snapshot('session', 'run', 'context'),
          isEmpty,
        );
        expect(fixture.files.paths, ['AGENTS.md']);
      },
    );
  }

  for (final code in ['permission_denied', 'not_a_file', 'binding_stale']) {
    test('declared non-absence failure $code is not swallowed', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.files.failure = EnvironmentFailure(
        code: code,
        message: 'Exact failure',
        details: {'path': 'AGENTS.md'},
      );
      await expectLater(
        fixture.backend.snapshot('session', 'run', 'context'),
        throwsA(
          isA<EnvironmentFailure>()
              .having((value) => value.code, 'code', code)
              .having((value) => value.message, 'message', 'Exact failure')
              .having((value) => value.details, 'details', {
                'path': 'AGENTS.md',
              }),
        ),
      );
    });
  }

  test('undeclared not_found is not treated as a missing file', () async {
    late final AdeleHostRequestMultiplexer host;
    host = AdeleHostRequestMultiplexer(
      send: (request) {
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': request['requestId'],
          'ok': false,
          'error': {'code': 'not_found', 'message': 'Invocation not found'},
        });
      },
    );
    addTearDown(host.close);
    await expectLater(
      AgentsMdBackend(host).snapshot('session', 'run', 'context'),
      throwsA(
        isA<AdeleRemoteFailure>().having(
          (value) => value.code,
          'code',
          'not_found',
        ),
      ),
    );
  });

  test(
    'closed backend host channel rejects snapshot without another read',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      fixture.host.close();
      await expectLater(
        fixture.backend.snapshot('session', 'run', 'context'),
        throwsStateError,
      );
      expect(fixture.files.paths, isEmpty);
    },
  );

  test(
    'entrypoint advertises exactly one required default-context extension',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      expect(backend.ready['pluginBackendProtocolVersion'], 2);
      expect(AdeleCapabilityExposure.fromReady(backend.ready), isEmpty);
      expect(backend.ready['extensionExposures'], [
        {
          'extensionPointId': 'dev.adele.extension.inference-context-sources',
          'extensionId': 'dev.adele.plugin.agents-md.instructions',
          'serviceId': remoteInferenceContextSourceServiceId,
          'configurationContext': 'configured-default',
          'metadata': {'failureMode': 'required'},
        },
      ]);
      backend.snapshot(requestId: 42);
      final hostRequest = await backend.next();
      expect(hostRequest['kind'], 'hostRequest');
      expect(hostRequest['hostInvocationContext'], 'opaque-token');
      expect(hostRequest['serviceId'], authorizedEnvironmentReadServiceId);
      expect(hostRequest['payload'], {'relativePath': 'AGENTS.md'});
      expect(hostRequest.containsKey('pluginId'), isFalse);
      backend.commands.send({
        'kind': 'hostResponse',
        'requestId': hostRequest['requestId'],
        'ok': true,
        'payload': {
          'relativePath': 'AGENTS.md',
          'text': ' exact root text \n',
          'sizeBytes': 17,
          'revision': 'opaque-revision',
        },
      });
      final response = await backend.next();
      expect(response['kind'], 'response');
      expect(response['requestId'], 42);
      expect(response['ok'], isTrue);
      expect(response['payload'], [
        {
          'key': 'semantics',
          'text':
              'The following AGENTS.md material is project guidance from the '
              'Session Environment root. Explicit user instructions and direct '
              'user requests take precedence over AGENTS.md guidance.',
          'revision': null,
        },
        {
          'key': 'AGENTS.md',
          'text': ' exact root text \n',
          'revision': 'opaque-revision',
        },
      ]);
      await backend.shutdown();
    },
  );

  test(
    'entrypoint shutdown settles blocked reverse call before forward drain',
    () async {
      final backend = await _RunningBackend.start();
      addTearDown(backend.close);
      backend.snapshot(requestId: 7);
      expect((await backend.next())['kind'], 'hostRequest');
      backend.commands.send({
        'kind': 'request',
        'requestId': 99,
        'method': 'shutdown',
        'payload': <String, Object?>{},
      });
      final failure = await backend.next();
      expect(failure['requestId'], 7);
      expect(failure['ok'], isFalse);
      final stopped = await backend.next();
      expect(stopped, {
        'kind': 'response',
        'requestId': 99,
        'ok': true,
        'payload': {'stopping': true},
      });
    },
  );
}

final class _Fixture {
  final files = _Files();
  final requests = <Map<String, Object?>>[];
  late final dispatcher = AuthorizedEnvironmentReadServiceDispatcher(files);
  late final host = AdeleHostRequestMultiplexer(
    send: (request) {
      requests.add(request);
      unawaited(_respond(request));
    },
  );
  late final backend = AgentsMdBackend(host);

  Future<void> _respond(Map<String, Object?> request) async {
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': request['requestId'],
      'method': request['method'],
      'payload': request['payload'],
    });
    host.handleResponse({
      'kind': 'hostResponse',
      'requestId': response['requestId'],
      'ok': response['ok'],
      if (response['ok'] == true)
        'payload': response['payload']
      else
        'error': response['error'],
    });
  }

  Future<void> close() async {
    host.close();
    await dispatcher.close();
  }
}

final class _Files implements AuthorizedEnvironmentReadService {
  String? text;
  String revision = 'revision-1';
  EnvironmentFailure? failure;
  final paths = <String>[];

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    paths.add(relativePath);
    if (failure case final failure?) throw failure;
    if (text == null) {
      throw const EnvironmentFailure(
        code: 'not_found',
        message: 'Absent',
        details: {},
      );
    }
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text!,
      sizeBytes: text!.length,
      revision: revision,
    );
  }
}

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

  void snapshot({required int requestId}) => commands.send({
    'kind': 'request',
    'requestId': requestId,
    'configurationContext': 'configured-default',
    'serviceId': remoteInferenceContextSourceServiceId,
    'method': remoteInferenceContextSourceServiceSnapshotId,
    'payload': {
      'sessionId': 'session',
      'runId': 'run',
      'hostInvocationContext': 'opaque-token',
    },
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
