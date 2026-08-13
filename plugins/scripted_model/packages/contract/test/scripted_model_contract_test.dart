import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:scripted_model_contract/scripted_model_contract.dart';
import 'package:test/test.dart';

void main() {
  test('fixture contract invokes its generated unary service', () async {
    final _FixtureChannel channel = _FixtureChannel();
    final ScriptedModelResponse response =
        await ScriptedModelFixtureServiceClient(channel).invoke(
          const ScriptedModelRequest(
            messages: <ScriptedModelMessage>[
              ScriptedModelMessage(
                role: ScriptedModelMessageRole.user,
                content: 'inspect',
                toolCallId: null,
                toolOutcome: null,
                toolProposal: null,
              ),
            ],
            tools: <ScriptedToolDefinition>[],
          ),
        );

    expect(channel.method, scriptedModelFixtureServiceInvokeId);
    expect(response.content, 'fixture complete');
    expect(response.toolCall, isNull);
    expect(scriptedModelFixtureCapability.id.value, contains('fixture'));
  });

  test(
    'generated streaming client is lazy and reconstructs typed items',
    () async {
      final channel = _FixtureChannel();
      final client = ScriptedModelFixtureServiceClient(channel);
      final stream = client.invokeStream(_request());
      expect(channel.streamCalls, 0);
      final items = await stream.toList();
      expect(channel.streamCalls, 1);
      expect(items.single.kind, ScriptedModelStreamItemKind.text);
      expect(items.single.text, 'streamed');
      expect(() => stream.listen((_) {}), throwsStateError);
      expect(channel.streamCalls, 1);
    },
  );

  test('malformed item cancels the raw stream before later items', () async {
    final channel = _MalformedFixtureChannel();
    final client = ScriptedModelFixtureServiceClient(channel);
    final items = <ScriptedModelStreamItem>[];
    final errors = <Object>[];
    final subscription = client
        .invokeStream(_request())
        .listen(items.add, onError: errors.add, cancelOnError: false);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    expect(items.map((item) => item.text), <String?>['valid']);
    expect(errors.single, isA<AdeleProtocolException>());
    expect(channel.cancellations, 1);
  });

  test('generated dispatcher gates producer advancement on credit', () async {
    final service = _StreamingFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final events = <Map<String, Object?>>[];
    await dispatcher.handle({
      'kind': 'streamOpen',
      'requestId': 7,
      'method': scriptedModelFixtureServiceInvokeStreamId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    expect(service.advanced, 0);
    await dispatcher.handle({
      'kind': 'streamCredit',
      'requestId': 7,
      'credit': 1,
    }, events.add);
    await Future<void>.delayed(Duration.zero);
    expect(service.advanced, 1);
    expect(events.single['kind'], 'streamItem');
    await dispatcher.handle({
      'kind': 'streamCancel',
      'requestId': 7,
    }, events.add);
    expect(service.cancelled, isTrue);
    expect(events.last['kind'], 'streamCancelled');
    await dispatcher.handle({
      'kind': 'streamCancel',
      'requestId': 7,
    }, events.add);
    expect(
      events.where((event) => event['kind'] == 'streamCancelled'),
      hasLength(1),
    );
  });

  test(
    'generated dispatcher drops a pull completed after cancellation',
    () async {
      final service = _DelayedStreamingFixtureService();
      final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
      final events = <Map<String, Object?>>[];
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': 8,
        'method': scriptedModelFixtureServiceInvokeStreamId,
        'payload': {'request': _encodedRequest()},
      }, events.add);
      await dispatcher.handle({
        'kind': 'streamCredit',
        'requestId': 8,
        'credit': 1,
      }, events.add);
      final Future<void> cancelling = dispatcher.handle({
        'kind': 'streamCancel',
        'requestId': 8,
      }, events.add);
      service.release.complete();
      await cancelling;
      await Future<void>.delayed(Duration.zero);
      expect(events.map((event) => event['kind']), <Object?>[
        'streamCancelled',
      ]);
    },
  );

  test(
    'stream open retains credit received before source installation',
    () async {
      final service = _DelayedOpenFixtureService();
      final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
      final events = <Map<String, Object?>>[];
      final Future<void> opening = dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': 9,
        'method': scriptedModelFixtureServiceInvokeStreamId,
        'payload': {'request': _encodedRequest()},
      }, events.add);
      await dispatcher.handle({
        'kind': 'streamCredit',
        'requestId': 9,
        'credit': 1,
      }, events.add);
      await opening;
      await Future<void>.delayed(Duration.zero);
      expect(events.single['kind'], 'streamItem');
    },
  );

  test('synchronous declared stream failure retains typed metadata', () async {
    final dispatcher = ScriptedModelFixtureServiceDispatcher(
      _SynchronousFailureFixtureService(),
    );
    final events = <Map<String, Object?>>[];
    await dispatcher.handle({
      'kind': 'streamOpen',
      'requestId': 10,
      'method': scriptedModelFixtureServiceInvokeStreamId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    expect(events.single['kind'], 'streamFailure');
    expect(
      (events.single['error'] as Map)['declaredFailureType'],
      scriptedModelFailureTypeId,
    );
    final error = events.single['error']! as Map<Object?, Object?>;
    final client = ScriptedModelFixtureServiceClient(
      _RemoteFailureChannel(
        _FixtureRemoteFailure(
          declaredFailureType: error['declaredFailureType']! as String,
          code: error['code']! as String,
          message: error['message']! as String,
          details: (error['details']! as Map).cast<String, Object?>(),
        ),
      ),
    );
    await expectLater(
      client.invokeStream(_request()),
      emitsError(
        isA<ScriptedModelFailure>().having(
          (failure) => failure.code,
          'code',
          'declared',
        ),
      ),
    );
  });

  test('close waits for admitted unary work', () async {
    final service = _BlockedUnaryFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final events = <Map<String, Object?>>[];
    final Future<void> unary = dispatcher.handle({
      'kind': 'request',
      'requestId': 11,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await service.started.future;
    bool closed = false;
    final Future<void> closing = dispatcher.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    service.release.complete();
    await unary;
    await closing;
    expect(events.single['kind'], 'response');
  });

  test(
    'stream cancellation remains responsive while unary is blocked',
    () async {
      final service = _BlockedUnaryFixtureService();
      final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
      final events = <Map<String, Object?>>[];
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': 13,
        'method': scriptedModelFixtureServiceInvokeStreamId,
        'payload': {'request': _encodedRequest()},
      }, events.add);
      final Future<void> unary = dispatcher.handle({
        'kind': 'request',
        'requestId': 12,
        'method': scriptedModelFixtureServiceInvokeId,
        'payload': {'request': _encodedRequest()},
      }, events.add);
      await service.started.future;
      await dispatcher
          .handle({'kind': 'streamCancel', 'requestId': 13}, events.add)
          .timeout(const Duration(seconds: 1));
      expect(events.any((event) => event['kind'] == 'streamCancelled'), isTrue);
      service.release.complete();
      await unary;
      await dispatcher.close();
    },
  );

  test('ordinary unary requests execute in admission order', () async {
    final service = _OrderedUnaryFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final events = <Map<String, Object?>>[];
    final first = dispatcher.handle({
      'kind': 'request',
      'requestId': 14,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await service.firstStarted.future;
    final second = dispatcher.handle({
      'kind': 'request',
      'requestId': 15,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await Future<void>.delayed(Duration.zero);
    expect(service.started, 1);
    service.releaseFirst.complete();
    await service.secondStarted.future;
    await Future.wait<void>(<Future<void>>[first, second]);
    expect(service.started, 2);
    expect(events.map((event) => event['requestId']), <int>[14, 15]);
  });

  test('queued stream open retains early credit behind unary', () async {
    final service = _BlockedUnaryFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final events = <Map<String, Object?>>[];
    final unary = dispatcher.handle({
      'kind': 'request',
      'requestId': 16,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await service.started.future;
    final opening = dispatcher.handle({
      'kind': 'streamOpen',
      'requestId': 17,
      'method': scriptedModelFixtureServiceInvokeStreamId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await dispatcher.handle({
      'kind': 'streamCredit',
      'requestId': 17,
      'credit': 1,
    }, events.add);
    service.release.complete();
    await unary;
    await opening;
    await Future<void>.delayed(Duration.zero);
    expect(events.any((event) => event['kind'] == 'streamItem'), isTrue);
    await dispatcher.handle({
      'kind': 'streamCancel',
      'requestId': 17,
    }, events.add);
  });

  test('queued stream cancellation waits and skips backend open', () async {
    final service = _BlockedUnaryFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final events = <Map<String, Object?>>[];
    final unary = dispatcher.handle({
      'kind': 'request',
      'requestId': 20,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await service.started.future;
    final opening = dispatcher.handle({
      'kind': 'streamOpen',
      'requestId': 21,
      'method': scriptedModelFixtureServiceInvokeStreamId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    bool cancelSettled = false;
    final cancelling = dispatcher
        .handle({'kind': 'streamCancel', 'requestId': 21}, events.add)
        .then((_) => cancelSettled = true);
    expect(service.streamInvocations, 0);
    expect(cancelSettled, isFalse);
    expect(events.any((event) => event['kind'] == 'streamCancelled'), isFalse);
    service.release.complete();
    await Future.wait<void>(<Future<void>>[unary, opening, cancelling]);
    expect(service.streamInvocations, 0);
    expect(
      events.where((event) => event['kind'] == 'streamCancelled'),
      hasLength(1),
    );
  });

  test('producer cancellation cleanup errors remain stream-local', () async {
    final service = _ThrowingCancelFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final events = <Map<String, Object?>>[];
    await dispatcher.handle({
      'kind': 'streamOpen',
      'requestId': 22,
      'method': scriptedModelFixtureServiceInvokeStreamId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await dispatcher.handle({
      'kind': 'streamCredit',
      'requestId': 22,
      'credit': 1,
    }, events.add);
    await service.listened.future;
    await dispatcher.handle({
      'kind': 'streamCancel',
      'requestId': 22,
    }, events.add);
    expect(events.any((event) => event['kind'] == 'streamCancelled'), isTrue);
    await dispatcher.handle({
      'kind': 'request',
      'requestId': 23,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    expect(
      events.any(
        (event) => event['kind'] == 'response' && event['requestId'] == 23,
      ),
      isTrue,
    );
    await dispatcher.close();
  });

  test('StreamIterator error automatically cancels producer', () async {
    final service = _IterationErrorFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final events = <Map<String, Object?>>[];
    await dispatcher.handle({
      'kind': 'streamOpen',
      'requestId': 24,
      'method': scriptedModelFixtureServiceInvokeStreamId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    await dispatcher.handle({
      'kind': 'streamCredit',
      'requestId': 24,
      'credit': 1,
    }, events.add);
    await service.iterationCancelled.future;
    expect(events.single['kind'], 'streamFailure');
    expect((events.single['error'] as Map)['code'], 'internal_error');
    await dispatcher.handle({
      'kind': 'request',
      'requestId': 25,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, events.add);
    expect(
      events.any(
        (event) => event['kind'] == 'response' && event['requestId'] == 25,
      ),
      isTrue,
    );
    await dispatcher.close();
  });

  test('concurrent close callers await the same shutdown work', () async {
    final service = _BlockedUnaryFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final unary = dispatcher.handle({
      'kind': 'request',
      'requestId': 18,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    }, (_) {});
    await service.started.future;
    bool firstDone = false;
    bool secondDone = false;
    final first = dispatcher.close().then((_) => firstDone = true);
    final second = dispatcher.close().then((_) => secondDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(firstDone, isFalse);
    expect(secondDone, isFalse);
    service.release.complete();
    await unary;
    await Future.wait<void>(<Future<void>>[first, second]);
    expect(firstDone && secondDone, isTrue);
  });

  test('close waits for admitted direct dispatch', () async {
    final service = _BlockedUnaryFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    final direct = dispatcher.dispatch({
      'kind': 'request',
      'requestId': 26,
      'method': scriptedModelFixtureServiceInvokeId,
      'payload': {'request': _encodedRequest()},
    });
    await service.started.future;
    bool closed = false;
    final closing = dispatcher.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    service.release.complete();
    expect((await direct)['kind'], 'response');
    await closing;
  });

  test('direct dispatch after close rejects without service work', () async {
    final service = _CountingFixtureService();
    final dispatcher = ScriptedModelFixtureServiceDispatcher(service);
    await dispatcher.close();
    await expectLater(
      dispatcher.dispatch({
        'kind': 'request',
        'requestId': 27,
        'method': scriptedModelFixtureServiceInvokeId,
        'payload': {'request': _encodedRequest()},
      }),
      throwsStateError,
    );
    expect(service.invocations, 0);
  });
}

ScriptedModelRequest _request() => const ScriptedModelRequest(
  messages: <ScriptedModelMessage>[],
  tools: <ScriptedToolDefinition>[],
);

Map<String, Object?> _encodedRequest() => {
  'messages': <Object?>[],
  'tools': <Object?>[],
};

final class _FixtureChannel implements AdeleStreamChannel {
  int streamCalls = 0;
  String? method;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    return <String, Object?>{'content': 'fixture complete', 'toolCall': null};
  }

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) => (() {
    streamCalls++;
    return Stream<Object?>.value({
      'kind': 'text',
      'sequence': null,
      'text': 'streamed',
      'toolCall': null,
    });
  })();
}

final class _MalformedFixtureChannel implements AdeleStreamChannel {
  int cancellations = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      null;

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    late final StreamController<Object?> controller;
    controller = StreamController<Object?>(
      onListen: () {
        controller.add({
          'kind': 'text',
          'sequence': null,
          'text': 'valid',
          'toolCall': null,
        });
        controller.add({'kind': 'invalid'});
        controller.add({
          'kind': 'text',
          'sequence': null,
          'text': 'late',
          'toolCall': null,
        });
      },
      onCancel: () => cancellations++,
    );
    return controller.stream;
  }
}

final class _RemoteFailureChannel implements AdeleStreamChannel {
  _RemoteFailureChannel(this.failure);

  final AdeleRemoteFailure failure;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      null;

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      Stream<Object?>.error(failure);
}

final class _FixtureRemoteFailure implements AdeleRemoteFailure {
  const _FixtureRemoteFailure({
    required this.declaredFailureType,
    required this.code,
    required this.message,
    required this.details,
  });

  @override
  final String? declaredFailureType;
  @override
  final String code;
  @override
  final String message;
  @override
  final Map<String, Object?> details;
}

final class _StreamingFixtureService implements ScriptedModelFixtureService {
  int advanced = 0;
  bool cancelled = false;

  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async =>
      const ScriptedModelResponse(content: '', toolCall: null);

  @override
  Stream<ScriptedModelStreamItem> invokeStream(
    ScriptedModelRequest request,
  ) async* {
    try {
      for (int sequence = 0; sequence < 10; sequence++) {
        advanced++;
        yield ScriptedModelStreamItem(
          kind: ScriptedModelStreamItemKind.probe,
          text: null,
          toolCall: null,
          sequence: sequence,
        );
      }
    } finally {
      cancelled = true;
    }
  }

  @override
  Future<ScriptedModelStreamProbe> streamProbe() async =>
      ScriptedModelStreamProbe(
        advanced: advanced,
        cancellations: cancelled ? 1 : 0,
        active: cancelled ? 0 : 1,
      );

  @override
  Future<ScriptedModelStreamProbe> resetStreamProbe() => streamProbe();
}

final class _DelayedStreamingFixtureService extends _StreamingFixtureService {
  final Completer<void> release = Completer<void>();

  @override
  Stream<ScriptedModelStreamItem> invokeStream(
    ScriptedModelRequest request,
  ) async* {
    await release.future;
    yield const ScriptedModelStreamItem(
      kind: ScriptedModelStreamItemKind.probe,
      text: null,
      toolCall: null,
      sequence: 0,
    );
  }
}

final class _DelayedOpenFixtureService extends _StreamingFixtureService {
  @override
  Stream<ScriptedModelStreamItem> invokeStream(
    ScriptedModelRequest request,
  ) async* {
    yield const ScriptedModelStreamItem(
      kind: ScriptedModelStreamItemKind.probe,
      text: null,
      toolCall: null,
      sequence: 0,
    );
  }
}

final class _SynchronousFailureFixtureService extends _StreamingFixtureService {
  @override
  Stream<ScriptedModelStreamItem> invokeStream(ScriptedModelRequest request) =>
      throw const ScriptedModelFailure(
        code: 'declared',
        message: 'Declared creation failure.',
        details: <String, Object?>{},
      );
}

final class _BlockedUnaryFixtureService extends _StreamingFixtureService {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int streamInvocations = 0;

  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async {
    started.complete();
    await release.future;
    return const ScriptedModelResponse(content: 'done', toolCall: null);
  }

  @override
  Stream<ScriptedModelStreamItem> invokeStream(ScriptedModelRequest request) {
    streamInvocations++;
    return super.invokeStream(request);
  }
}

final class _ThrowingCancelFixtureService extends _StreamingFixtureService {
  final Completer<void> listened = Completer<void>();

  @override
  Stream<ScriptedModelStreamItem> invokeStream(ScriptedModelRequest request) {
    late final StreamController<ScriptedModelStreamItem> controller;
    controller = StreamController<ScriptedModelStreamItem>(
      onListen: listened.complete,
      onCancel: () => Future<void>.error(StateError('cleanup failed')),
    );
    return controller.stream;
  }
}

final class _IterationErrorFixtureService extends _StreamingFixtureService {
  final Completer<void> iterationCancelled = Completer<void>();

  @override
  Stream<ScriptedModelStreamItem> invokeStream(ScriptedModelRequest request) {
    late final StreamController<ScriptedModelStreamItem> controller;
    controller = StreamController<ScriptedModelStreamItem>(
      onListen: () => controller.addError(StateError('producer failed')),
      onCancel: iterationCancelled.complete,
    );
    return controller.stream;
  }
}

final class _OrderedUnaryFixtureService extends _StreamingFixtureService {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> secondStarted = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  int started = 0;

  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async {
    started++;
    if (started == 1) {
      firstStarted.complete();
      await releaseFirst.future;
    } else {
      secondStarted.complete();
    }
    return const ScriptedModelResponse(content: 'done', toolCall: null);
  }
}

final class _CountingFixtureService extends _StreamingFixtureService {
  int invocations = 0;

  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async {
    invocations++;
    return super.invoke(request);
  }
}
