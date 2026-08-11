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
      final Future<void> unary = dispatcher.handle({
        'kind': 'request',
        'requestId': 12,
        'method': scriptedModelFixtureServiceInvokeId,
        'payload': {'request': _encodedRequest()},
      }, events.add);
      await service.started.future;
      await dispatcher.handle({
        'kind': 'streamOpen',
        'requestId': 13,
        'method': scriptedModelFixtureServiceInvokeStreamId,
        'payload': {'request': _encodedRequest()},
      }, events.add);
      await dispatcher
          .handle({'kind': 'streamCancel', 'requestId': 13}, events.add)
          .timeout(const Duration(seconds: 1));
      expect(events.any((event) => event['kind'] == 'streamCancelled'), isTrue);
      service.release.complete();
      await unary;
      await dispatcher.close();
    },
  );
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

  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async {
    started.complete();
    await release.future;
    return const ScriptedModelResponse(content: 'done', toolCall: null);
  }
}
