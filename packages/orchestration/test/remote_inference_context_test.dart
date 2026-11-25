import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:test/test.dart';

void main() {
  test(
    'captureRun roundtrips ordered instructions with only semantic IDs',
    () async {
      final source = _Source();
      final dispatcher = RemoteRunBoundInferenceContextSourceServiceDispatcher(
        source,
      );
      addTearDown(dispatcher.close);
      final channel = _Channel(dispatcher);
      final client = RemoteRunBoundInferenceContextSourceServiceClient(channel);

      final captured = await client.captureRun('session-1', 'run-1');
      expect(channel.method, 'runBoundInferenceContextSource.captureRun');
      expect(channel.payload, {'sessionId': 'session-1', 'runId': 'run-1'});
      expect(source.capture, ('session-1', 'run-1'));
      expect(channel.response!['payload'], [
        {'key': 'semantics', 'text': 'User first.', 'revision': null},
        {
          'key': 'file',
          'text': '  exact\ntext\n',
          'revision': 'opaque-revision',
        },
      ]);
      expect(captured.map((i) => (i.key, i.text, i.revision)), [
        ('semantics', 'User first.', null),
        ('file', '  exact\ntext\n', 'opaque-revision'),
      ]);
      expect(captured.clear, throwsUnsupportedError);

      source.instructions = [];
      expect(await client.captureRun('session-1', 'run-2'), isEmpty);
    },
  );

  test(
    'run-bound service rejects extra fields and has no snapshot method',
    () async {
      final source = _Source();
      final dispatcher = RemoteRunBoundInferenceContextSourceServiceDispatcher(
        source,
      );
      addTearDown(dispatcher.close);
      const ids = {'sessionId': 'session', 'runId': 'run'};
      Future<String?> errorCode(
        String method,
        Map<String, Object?> payload,
      ) async {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': method,
          'payload': payload,
        });
        expect(response['ok'], isFalse);
        return (response['error']! as Map<Object?, Object?>)['code'] as String?;
      }

      for (final extra in ['hostInvocationContext', 'binding']) {
        expect(
          await errorCode(
            remoteRunBoundInferenceContextSourceServiceCaptureRunId,
            {...ids, extra: 'unexpected'},
          ),
          'invalid_request',
        );
      }
      expect(
        await errorCode('runBoundInferenceContextSource.snapshot', ids),
        'unknown_method',
      );
      expect(source.capture, isNull);
    },
  );

  test('captureRun rejects bindings and malformed instruction lists', () async {
    for (final invalid in <Object?>[
      null,
      'opaque-binding',
      [
        {'key': 'file', 'text': 'text'},
      ],
    ]) {
      final client = RemoteRunBoundInferenceContextSourceServiceClient(
        _ResponseChannel(invalid),
      );
      await expectLater(
        client.captureRun('session', 'run'),
        throwsA(isA<AdeleProtocolException>()),
      );
    }
  });

  test(
    'snapshot roundtrips ordered instructions with only invocation data',
    () async {
      final _Source source = _Source();
      final RemoteInferenceContextSourceServiceDispatcher dispatcher =
          RemoteInferenceContextSourceServiceDispatcher(source);
      addTearDown(dispatcher.close);
      final _Channel channel = _Channel(dispatcher);
      final RemoteInferenceContextSourceServiceClient client =
          RemoteInferenceContextSourceServiceClient(channel);

      final List<RemoteInferenceInstruction> result = await client.snapshot(
        'session-1',
        'run-1',
        'opaque-host-invocation',
      );

      expect(remoteInferenceContextSourceServiceId, 'inferenceContextSource');
      expect(channel.method, 'inferenceContextSource.snapshot');
      expect(channel.payload, <String, Object?>{
        'sessionId': 'session-1',
        'runId': 'run-1',
        'hostInvocationContext': 'opaque-host-invocation',
      });
      expect(source.invocation, (
        'session-1',
        'run-1',
        'opaque-host-invocation',
      ));
      expect(channel.response!['payload'], <Object?>[
        <String, Object?>{
          'key': 'semantics',
          'text': 'User first.',
          'revision': null,
        },
        <String, Object?>{
          'key': 'file',
          'text': '  exact\ntext\n',
          'revision': 'opaque-revision',
        },
      ]);
      expect(
        result.map((RemoteInferenceInstruction item) => item.key),
        <String>['semantics', 'file'],
      );
      expect(result.first.revision, isNull);
      expect(result.last.text, '  exact\ntext\n');
      expect(result.last.revision, 'opaque-revision');
      expect(result.first, isNot(same(source.instructions.first)));
      expect(() => result.clear(), throwsUnsupportedError);

      source.instructions = const <RemoteInferenceInstruction>[];
      expect(
        await client.snapshot('session-1', 'run-2', 'next-context'),
        isEmpty,
      );
    },
  );

  test(
    'snapshot failures remain opaque remote failures, not empty output',
    () async {
      final _Source source = _Source()
        ..failure = StateError('private source detail');
      final RemoteInferenceContextSourceServiceDispatcher dispatcher =
          RemoteInferenceContextSourceServiceDispatcher(source);
      addTearDown(dispatcher.close);
      final _Channel channel = _Channel(dispatcher);
      final RemoteInferenceContextSourceServiceClient client =
          RemoteInferenceContextSourceServiceClient(channel);

      await expectLater(
        client.snapshot('session', 'run', 'context'),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having(
                (AdeleRemoteFailure error) => error.code,
                'code',
                'internal_error',
              )
              .having(
                (AdeleRemoteFailure error) => error.declaredFailureType,
                'type',
                isNull,
              )
              .having(
                (AdeleRemoteFailure error) => error.message,
                'message',
                isNot(contains('private')),
              ),
        ),
      );
      source.failure = null;
      expect(await client.snapshot('session', 'run', 'context'), hasLength(2));
    },
  );

  test(
    'snapshot rejects extra or missing request fields before invocation',
    () async {
      final _Source source = _Source();
      final RemoteInferenceContextSourceServiceDispatcher dispatcher =
          RemoteInferenceContextSourceServiceDispatcher(source);
      addTearDown(dispatcher.close);
      for (final Map<String, Object?> payload in <Map<String, Object?>>[
        <String, Object?>{'sessionId': 'session', 'runId': 'run'},
        <String, Object?>{
          'sessionId': 'session',
          'runId': 'run',
          'hostInvocationContext': 'context',
          'sourceId': 'not-transported',
        },
      ]) {
        final Map<String, Object?> response = await dispatcher
            .dispatch(<Object?, Object?>{
              'kind': 'request',
              'requestId': 1,
              'method': remoteInferenceContextSourceServiceSnapshotId,
              'payload': payload,
            });
        expect(
          (response['error']! as Map<Object?, Object?>)['code'],
          'invalid_request',
        );
      }
      expect(source.invocation, isNull);
    },
  );

  test(
    'instruction revision is nullable but its wire key is required',
    () async {
      for (final Map<String, Object?> instruction in <Map<String, Object?>>[
        <String, Object?>{'key': 'file', 'text': 'text'},
        <String, Object?>{'key': 'file', 'text': 'text', 'revision': 1},
        <String, Object?>{
          'key': 'file',
          'text': 'text',
          'revision': null,
          'sourceId': 'extra',
        },
      ]) {
        await expectLater(
          RemoteInferenceContextSourceServiceClient(
            _ResponseChannel(<Object?>[instruction]),
          ).snapshot('session', 'run', 'context'),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );
}

final class _Source
    implements
        RemoteInferenceContextSourceService,
        RemoteRunBoundInferenceContextSourceService {
  List<RemoteInferenceInstruction> instructions =
      const <RemoteInferenceInstruction>[
        RemoteInferenceInstruction(
          key: 'semantics',
          text: 'User first.',
          revision: null,
        ),
        RemoteInferenceInstruction(
          key: 'file',
          text: '  exact\ntext\n',
          revision: 'opaque-revision',
        ),
      ];
  (String, String, String)? invocation;
  (String, String)? capture;
  Object? failure;

  @override
  Future<List<RemoteInferenceInstruction>> captureRun(
    String sessionId,
    String runId,
  ) async {
    capture = (sessionId, runId);
    return instructions;
  }

  @override
  Future<List<RemoteInferenceInstruction>> snapshot(
    String sessionId,
    String runId,
    String hostInvocationContext,
  ) async {
    invocation = (sessionId, runId, hostInvocationContext);
    if (failure case final Object error) throw error;
    return instructions;
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Map<String, Object?>? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final Map<String, Object?> response = await dispatcher.dispatch(
      <Object?, Object?>{
        'kind': 'request',
        'requestId': 1,
        'method': method,
        'payload': payload,
      },
    );
    this.response = response;
    if (response['ok'] != true) {
      throw _RemoteFailure(response['error']! as Map<Object?, Object?>);
    }
    return response['payload'];
  }
}

final class _ResponseChannel implements AdeleRequestChannel {
  const _ResponseChannel(this.response);
  final Object? response;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      response;
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<Object?, Object?> error;

  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details']! as Map);
}
