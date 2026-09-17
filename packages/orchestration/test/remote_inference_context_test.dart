import 'package:adele_contract/adele_contract.dart';
import 'package:adele_orchestration/remote_inference_context.dart';
import 'package:test/test.dart';

void main() {
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

final class _Source implements RemoteInferenceContextSourceService {
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
  Object? failure;

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
