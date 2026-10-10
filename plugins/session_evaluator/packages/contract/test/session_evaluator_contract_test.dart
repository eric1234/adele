import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:session_evaluator_contract/session_evaluator_contract.dart';
import 'package:test/test.dart';

void main() {
  test('identities and collection bounds are explicit', () {
    expect(
      sessionEvaluatorPluginId.value,
      'dev.adele.plugin.session-evaluator',
    );
    expect(sessionEvaluatorServiceId, 'dev.adele.session-evaluator');
    expect(sessionEvidenceSchema, 'dev.adele.session-evidence.v1');
    expect(sessionEvidenceMaxBytes, 16 * 1024 * 1024);
    expect(sessionEvidenceChunkCodeUnits, 16 * 1024);
    expect(sessionEvidenceMaxRows, 100000);
  });

  group('readSessionEvidence', () {
    test(
      'reassembles exact JSON text without imposing undocumented keys',
      () async {
        final document = <String, Object?>{
          'schema': sessionEvidenceSchema,
          'text': 'a\u{1f600}\r\x1b[31m\u0000\n\t',
          'raw_json': '{ "count": 0, "missing": null }',
        };
        final source = jsonEncode(document);
        final service = _Service(
          (_) => Stream.fromIterable([
            source.substring(0, 5),
            source.substring(5, 19),
            source.substring(19),
          ]),
        );
        expect(
          await readSessionEvidence(service, 'selected-session'),
          document,
        );
        expect(service.sessions, ['selected-session']);
      },
    );

    test(
      'waits for successful EOF even after a complete JSON object',
      () async {
        final delivered = Completer<void>();
        final finish = Completer<void>();
        final service = _Service((_) async* {
          yield jsonEncode({'schema': sessionEvidenceSchema});
          delivered.complete();
          await finish.future;
        });
        var returned = false;
        final result = readSessionEvidence(service, 'session').then((document) {
          returned = true;
          return document;
        });
        await delivered.future;
        expect(returned, isFalse);
        finish.complete();
        expect(await result, {'schema': sessionEvidenceSchema});
      },
    );

    test(
      'propagates stream failure instead of returning received JSON',
      () async {
        const failure = SessionEvidenceFailure(
          code: 'unavailable',
          message: 'Retained evidence is unavailable.',
        );
        final service = _Service((_) async* {
          yield jsonEncode({'schema': sessionEvidenceSchema});
          throw failure;
        });
        await expectLater(
          readSessionEvidence(service, 'session'),
          throwsA(same(failure)),
        );
      },
    );

    test(
      'rejects absent truncated multiple and non-map documents or wrong schema',
      () async {
        for (final source in [
          '',
          '{',
          'null',
          '[]',
          '42',
          '{}',
          '{"schema":"other"}',
          '{"schema":"$sessionEvidenceSchema"}{}',
        ]) {
          await expectLater(
            readSessionEvidence(
              _Service((_) => Stream.value(source)),
              'session',
            ),
            throwsFormatException,
            reason: source,
          );
        }
      },
    );

    test(
      'cancels an oversized chunk without reading subsequent chunks',
      () async {
        var cancelled = false;
        var advanced = false;
        final service = _Service((_) async* {
          try {
            yield ' ' * (sessionEvidenceChunkCodeUnits + 1);
            advanced = true;
            yield '{}';
          } finally {
            cancelled = true;
          }
        });
        await expectLater(
          readSessionEvidence(service, 'session'),
          throwsFormatException,
        );
        expect(cancelled, isTrue);
        expect(advanced, isFalse);
      },
    );

    test(
      'accepts the exact byte bound and rejects one additional byte',
      () async {
        final prefix = '{"schema":"$sessionEvidenceSchema","text":"';
        final padding = sessionEvidenceMaxBytes - prefix.length - 2;
        final source = '$prefix${'a' * padding}"}';
        final result = await readSessionEvidence(
          _Service((_) => _chunks(source)),
          'session',
        );
        expect((result['text']! as String).length, padding);
        await expectLater(
          readSessionEvidence(_Service((_) => _chunks('$source ')), 'session'),
          throwsFormatException,
        );
      },
    );

    test('bounds UTF-8 bytes rather than String code units', () async {
      var cancelled = false;
      final service = _Service((_) async* {
        try {
          yield '{"schema":"$sessionEvidenceSchema","text":"';
          final chunk = '\u20ac' * sessionEvidenceChunkCodeUnits;
          for (
            var i = 0;
            i < sessionEvidenceMaxBytes ~/ (chunk.length * 3) + 1;
            i++
          ) {
            yield chunk;
          }
          yield '"}';
        } finally {
          cancelled = true;
        }
      });
      await expectLater(
        readSessionEvidence(service, 'session'),
        throwsFormatException,
      );
      expect(cancelled, isTrue);
    });
  });

  group('generated routing', () {
    late _Service service;
    late AdeleConfigurationContextRouter router;
    late _Channel channel;
    late SessionEvaluatorServiceClient client;

    setUp(() {
      service = _Service(
        (_) => Stream.fromIterable(['one', '\u{1f600}\u0000', 'three']),
      );
      router = AdeleConfigurationContextRouter.single(
        configurationContext: 'selected-context',
        serviceId: sessionEvaluatorServiceId,
        dispatcher: SessionEvaluatorServiceDispatcher(service),
      );
      channel = _Channel(router);
      client = SessionEvaluatorServiceClient(channel);
    });
    tearDown(() => router.close());

    test(
      'lazy stream preserves ordered exact strings on its configured route',
      () async {
        final stream = client.collectSession('selected-session');
        expect(service.sessions, isEmpty);
        expect(await stream.toList(), ['one', '\u{1f600}\u0000', 'three']);
        expect(service.sessions, ['selected-session']);
        expect(channel.opens.single, {
          'kind': 'streamOpen',
          'requestId': 0,
          'configurationContext': 'selected-context',
          'serviceId': sessionEvaluatorServiceId,
          'method': sessionEvaluatorServiceCollectSessionId,
          'payload': {'sessionId': 'selected-session'},
        });
      },
    );

    test(
      'reconstructs declared failures without leaking undeclared diagnostics',
      () async {
        service.produce = (_) => Stream.error(
          const SessionEvidenceFailure(
            code: 'invalid_evidence',
            message: 'Evidence is inconsistent.',
            details: {'source': 'run'},
          ),
        );
        await expectLater(
          client.collectSession('session').toList(),
          throwsA(
            isA<SessionEvidenceFailure>()
                .having((error) => error.code, 'code', 'invalid_evidence')
                .having(
                  (error) => error.message,
                  'message',
                  'Evidence is inconsistent.',
                )
                .having((error) => error.details, 'details', {'source': 'run'}),
          ),
        );
        service.produce = (_) =>
            Stream.error(StateError('private database path'));
        await expectLater(
          client.collectSession('session').toList(),
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

    test('cancellation settles the producer', () async {
      var settled = false;
      service.produce = (_) async* {
        try {
          yield 'first';
          yield 'second';
        } finally {
          settled = true;
        }
      };
      final iterator = StreamIterator(client.collectSession('session'));
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current, 'first');
      await iterator.cancel();
      expect(settled, isTrue);
    });

    test('rejects unknown routes and forged semantic payload fields', () async {
      for (final changes in <Map<String, Object?>>[
        {'configurationContext': 'other'},
        {'serviceId': 'other'},
        {'payload': <String, Object?>{}},
        {
          'payload': {
            'sessionId': 'session',
            'hostInvocationContext': 'forged',
          },
        },
      ]) {
        final frames = <Map<String, Object?>>[];
        await router.handle({
          'kind': 'streamOpen',
          'requestId': 100,
          'configurationContext': 'selected-context',
          'serviceId': sessionEvaluatorServiceId,
          'method': sessionEvaluatorServiceCollectSessionId,
          'payload': {'sessionId': 'session'},
          ...changes,
        }, frames.add);
        expect(frames.single['kind'], 'streamFailure');
      }
      expect(service.sessions, isEmpty);
    });
  });
}

Stream<String> _chunks(String text) async* {
  for (
    var start = 0;
    start < text.length;
    start += sessionEvidenceChunkCodeUnits
  ) {
    final end = start + sessionEvidenceChunkCodeUnits;
    yield text.substring(start, end < text.length ? end : text.length);
  }
}

final class _Service implements SessionEvaluatorService {
  _Service(this.produce);
  Stream<String> Function(String) produce;
  final sessions = <String>[];

  @override
  Stream<String> collectSession(String sessionId) {
    sessions.add(sessionId);
    return produce(sessionId);
  }
}

final class _Channel implements AdeleStreamChannel {
  _Channel(this.router);
  final AdeleConfigurationContextRouter router;
  final opens = <Map<String, Object?>>[];
  int nextId = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      throw UnsupportedError('Only streaming is supported.');

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) async* {
    final id = nextId++;
    final replies = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(replies.stream);
    void send(Map<String, Object?> frame) => replies.add(
      Map<String, Object?>.from(jsonDecode(jsonEncode(frame)) as Map),
    );
    final open = <String, Object?>{
      'kind': 'streamOpen',
      'requestId': id,
      'configurationContext': 'selected-context',
      'serviceId': sessionEvaluatorServiceId,
      'method': method,
      'payload': jsonDecode(jsonEncode(payload)),
    };
    opens.add(open);
    try {
      await router.handle(open, send);
      while (true) {
        await router.handle({
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
      await router.handle({'kind': 'streamCancel', 'requestId': id}, send);
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
