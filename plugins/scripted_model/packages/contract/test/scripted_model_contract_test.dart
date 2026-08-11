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
    },
  );

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
