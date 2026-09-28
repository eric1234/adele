import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:command_tools_contract/command_tools_contract.dart';
import 'package:test/test.dart';

void main() {
  late _Service service;
  late CommandOutputServiceDispatcher dispatcher;
  late _Channel channel;
  late CommandOutputServiceClient client;
  setUp(() {
    service = _Service();
    dispatcher = CommandOutputServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = CommandOutputServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'native generated state codec retains all associations extent metadata and outcome',
    () async {
      final state = await client.getState('session', 'run', 'invocation');
      expect(state.sessionId, 'session');
      expect(state.runId, 'run');
      expect(state.toolInvocationId, 'invocation');
      expect(state.state, 'complete');
      expect(state.version, 4);
      expect(state.highWater, 2);
      expect(state.totalCodeUnits, 16);
      expect(state.program, 'fixture');
      expect(state.argumentsJson, '["two words",""]');
      expect(state.workingDirectory, 'src');
      expect(state.environmentId, 'environment');
      expect(state.timeoutSeconds, 30);
      expect(state.termination, 'exited');
      expect(state.exitCode, 23);
      expect(state.failure, isNull);
      expect(channel.payloads.single, {
        'sessionId': 'session',
        'runId': 'run',
        'toolInvocationId': 'invocation',
      });
      expect(service.calls.single, (
        'getState',
        'session',
        'run',
        'invocation',
        null,
        null,
        null,
      ));
    },
  );

  test(
    'forward and nullable tail cursor roundtrip exact ordered Unicode control chunks',
    () async {
      final forward = await client.readAfter(
        'session',
        'run',
        'invocation',
        0,
        7,
        32768,
      );
      final tail = await client.readBefore(
        'session',
        'run',
        'invocation',
        null,
        2,
        8192,
      );
      expect(service.calls, [
        ('readAfter', 'session', 'run', 'invocation', 0, 7, 32768),
        ('readBefore', 'session', 'run', 'invocation', null, 2, 8192),
      ]);
      for (final page in [forward, tail]) {
        expect(page.state.toolInvocationId, 'invocation');
        expect(
          page.chunks.map((chunk) => (chunk.cursor, chunk.stream, chunk.text)),
          [
            (1, 'stdout', 'a\u{1f600}\r\x1b[31m\u0000'),
            (2, 'stderr', '\tlate\n'),
          ],
        );
        expect(() => page.chunks.clear(), throwsUnsupportedError);
      }
      expect(channel.payloads.last.containsKey('beforeCursor'), isTrue);
      expect(channel.payloads.last['beforeCursor'], isNull);
      expect(
        channel.payloads.every(
          (payload) => !payload.containsKey('hostInvocationContext'),
        ),
        isTrue,
      );
      expect(commandOutputChunkCodeUnits, 4096);
      expect(commandOutputPageChunks, 16);
      expect(commandOutputPageCodeUnits, 65536);
    },
  );

  test('page detaches its immutable chunk list from caller ownership', () {
    final source = <CommandOutputChunk>[
      const CommandOutputChunk(cursor: 1, stream: 'stdout', text: 'one'),
    ];
    final page = CommandOutputPage(state: service.state, chunks: source);
    source.clear();
    expect(page.chunks.single.text, 'one');
    expect(
      () => page.chunks.add(
        const CommandOutputChunk(cursor: 2, stream: 'stderr', text: 'two'),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'generated decoder rejects malformed exact state page and chunk wire shapes',
    () async {
      await client.getState('session', 'run', 'invocation');
      final state = Map<String, Object?>.from(channel.responses.last! as Map);
      for (final invalid in <Map<String, Object?>>[
        {...state}..remove('toolInvocationId'),
        {...state}..remove('failure'),
        {...state, 'highWater': '2'},
        {...state, 'version': 1.5},
        {...state, 'exitCode': true},
        {...state, 'program': 2},
        {...state, 'extra': 'not allowed'},
      ]) {
        await expectLater(
          CommandOutputServiceClient(
            _Response(invalid),
          ).getState('session', 'run', 'invocation'),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
      await client.readAfter('session', 'run', 'invocation', 0, 16, 65536);
      final page = Map<String, Object?>.from(channel.responses.last! as Map);
      final chunk = Map<String, Object?>.from(
        (page['chunks']! as List).first as Map,
      );
      for (final invalid in <Map<String, Object?>>[
        {...page}..remove('state'),
        {...page, 'chunks': null},
        {
          ...page,
          'chunks': [
            {...chunk}..remove('text'),
          ],
        },
        {
          ...page,
          'chunks': [
            {...chunk, 'cursor': '1'},
          ],
        },
        {
          ...page,
          'chunks': [
            {...chunk, 'text': 42},
          ],
        },
        {
          ...page,
          'chunks': [
            {
              ...chunk,
              'rawBytes': [1, 2],
            },
          ],
        },
      ]) {
        await expectLater(
          CommandOutputServiceClient(
            _Response(invalid),
          ).readAfter('session', 'run', 'invocation', 0, 16, 65536),
          throwsA(isA<AdeleProtocolException>()),
        );
      }
    },
  );

  test(
    'dispatcher requires explicit identities and rejects authority or unknown keys',
    () async {
      for (final payload in <Map<String, Object?>>[
        {'sessionId': 'session', 'runId': 'run'},
        {'sessionId': 'session', 'runId': 'run', 'toolInvocationId': null},
        {
          'sessionId': 'session',
          'runId': 'run',
          'toolInvocationId': 'invocation',
          'hostInvocationContext': 'forged',
        },
      ]) {
        final response = await dispatcher.dispatch({
          'kind': 'request',
          'requestId': 1,
          'method': commandOutputServiceGetStateId,
          'payload': payload,
        });
        expect(response['ok'], isFalse);
        expect((response['error']! as Map)['code'], 'invalid_request');
      }
      expect(service.calls, isEmpty);
      final response = await dispatcher.dispatch({
        'kind': 'request',
        'requestId': 1,
        'method': commandOutputServiceWatchId,
        'payload': {
          'sessionId': 'session',
          'runId': 'run',
          'toolInvocationId': 'invocation',
        },
      });
      expect((response['error']! as Map)['code'], 'wrong_method_kind');
    },
  );

  test(
    'native generated watch is lazy typed state-only and cancellation settles service',
    () async {
      final stream = client.watch('session', 'run', 'invocation');
      expect(service.watches, 0);
      expect(channel.frames, isEmpty);
      final iterator = StreamIterator(stream);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.state, 'complete');
      expect(iterator.current.highWater, 2);
      expect(service.watches, 1);
      final frame = channel.frames.single;
      expect(frame['kind'], 'streamItem');
      final payload = frame['payload']! as Map;
      expect(payload['toolInvocationId'], 'invocation');
      expect(payload.keys, isNot(contains('chunks')));
      expect(payload.keys, isNot(contains('text')));
      await iterator.cancel();
      expect(service.settled, 1);
      expect(channel.cancellations, 1);
    },
  );

  test(
    'declared read and watch failures preserve typed details while internals stay private',
    () async {
      service.failure = const CommandOutputFailure(
        code: 'association_mismatch',
        message: 'Wrong Run.',
        details: {'expected': 'run'},
      );
      final matcher = isA<CommandOutputFailure>()
          .having((error) => error.code, 'code', 'association_mismatch')
          .having((error) => error.details, 'details', {'expected': 'run'});
      await expectLater(
        client.getState('session', 'wrong', 'invocation'),
        throwsA(matcher),
      );
      await expectLater(
        client.watch('session', 'wrong', 'invocation'),
        emitsInOrder([emitsError(matcher), emitsDone]),
      );
      service.failure = StateError('private database path');
      await expectLater(
        client.getState('session', 'run', 'invocation'),
        throwsA(
          isA<AdeleRemoteFailure>()
              .having((error) => error.code, 'code', 'internal_error')
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private database path')),
              ),
        ),
      );
    },
  );
}

final class _Service implements CommandOutputService {
  final calls = <(String, String, String, String, int?, int?, int?)>[];
  int watches = 0;
  int settled = 0;
  Object? failure;
  final state = const CommandCaptureState(
    sessionId: 'session',
    runId: 'run',
    toolInvocationId: 'invocation',
    state: 'complete',
    version: 4,
    highWater: 2,
    totalCodeUnits: 16,
    program: 'fixture',
    argumentsJson: '["two words",""]',
    workingDirectory: 'src',
    environmentId: 'environment',
    timeoutSeconds: 30,
    termination: 'exited',
    exitCode: 23,
    failure: null,
  );
  CommandOutputPage get page => CommandOutputPage(
    state: state,
    chunks: const [
      CommandOutputChunk(
        cursor: 1,
        stream: 'stdout',
        text: 'a\u{1f600}\r\x1b[31m\u0000',
      ),
      CommandOutputChunk(cursor: 2, stream: 'stderr', text: '\tlate\n'),
    ],
  );

  @override
  Future<CommandCaptureState> getState(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) async {
    calls.add((
      'getState',
      sessionId,
      runId,
      toolInvocationId,
      null,
      null,
      null,
    ));
    if (failure case final error?) throw error;
    return state;
  }

  @override
  Future<CommandOutputPage> readAfter(
    String sessionId,
    String runId,
    String toolInvocationId,
    int afterCursor,
    int maxChunks,
    int maxCodeUnits,
  ) async {
    calls.add((
      'readAfter',
      sessionId,
      runId,
      toolInvocationId,
      afterCursor,
      maxChunks,
      maxCodeUnits,
    ));
    return page;
  }

  @override
  Future<CommandOutputPage> readBefore(
    String sessionId,
    String runId,
    String toolInvocationId,
    int? beforeCursor,
    int maxChunks,
    int maxCodeUnits,
  ) async {
    calls.add((
      'readBefore',
      sessionId,
      runId,
      toolInvocationId,
      beforeCursor,
      maxChunks,
      maxCodeUnits,
    ));
    return page;
  }

  @override
  Stream<CommandCaptureState> watch(
    String sessionId,
    String runId,
    String toolInvocationId,
  ) async* {
    watches++;
    try {
      if (failure case final error?) throw error;
      yield state;
      yield state;
    } finally {
      settled++;
    }
  }
}

final class _Response implements AdeleRequestChannel {
  const _Response(this.value);
  final Object? value;
  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      value;
}

final class _Channel implements AdeleStreamChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  final payloads = <Map<String, Object?>>[];
  final responses = <Object?>[];
  final frames = <Map<String, Object?>>[];
  int nextId = 0;
  int cancellations = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    payloads.add(payload);
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': nextId++,
      'method': method,
      'payload': jsonDecode(jsonEncode(payload)),
    });
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    final result = jsonDecode(jsonEncode(response['payload']));
    responses.add(result);
    return result;
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    final id = nextId++;
    final replies = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(replies.stream);
    void send(Map<String, Object?> frame) {
      frames.add(frame);
      replies.add(
        Map<String, Object?>.from(jsonDecode(jsonEncode(frame)) as Map),
      );
    }

    try {
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': id,
        'method': method,
        'payload': jsonDecode(jsonEncode(payload)),
      }, send);
      while (true) {
        await dispatcher.handle({
          'kind': 'streamCredit',
          'requestId': id,
          'credit': 1,
        }, send);
        if (!await iterator.moveNext()) break;
        final frame = iterator.current;
        if (frame['kind'] == 'streamDone') break;
        if (frame['kind'] == 'streamFailure') {
          throw _RemoteFailure(frame['error']! as Map);
        }
        yield frame['payload'];
      }
    } finally {
      cancellations++;
      await dispatcher.handle({'kind': 'streamCancel', 'requestId': id}, send);
      await iterator.cancel();
      await replies.close();
    }
  }
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
      Map<String, Object?>.from(error['details'] as Map? ?? {});
}
