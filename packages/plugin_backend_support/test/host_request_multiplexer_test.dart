import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
  test(
    'generated-style stream is lazy, ordered, one-credit and pausable',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final AdeleStreamChannel channel = host.bind(
        hostInvocationContext: 'scope',
        serviceId: 'events',
      );
      final stream = adeleDecodedStream<int>(
        channel.stream('events.watch', {}),
        (value) => value! as int,
        (error) => error,
      );
      expect(sent, isEmpty);
      final values = <int>[];
      late StreamSubscription<int> subscription;
      subscription = stream.listen((value) {
        values.add(value);
        subscription.pause();
      });
      expect(sent, [
        {
          'kind': 'hostStreamOpen',
          'requestId': 0,
          'hostContextKind': 'invocation',
          'hostContext': 'scope',
          'serviceId': 'events',
          'method': 'events.watch',
          'payload': <String, Object?>{},
        },
        {'kind': 'hostStreamCredit', 'requestId': 0, 'credit': 1},
      ]);
      host.handleResponse({
        'kind': 'hostStreamItem',
        'requestId': 0,
        'payload': 1,
      });
      expect(values, [1]);
      expect(sent, hasLength(2));
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(sent.last, {
        'kind': 'hostStreamCredit',
        'requestId': 0,
        'credit': 1,
      });
      host.handleResponse({
        'kind': 'hostStreamItem',
        'requestId': 0,
        'payload': 2,
      });
      expect(values, [1, 2]);
      var cancelled = false;
      final cancelling = subscription.cancel().then((_) => cancelled = true);
      expect(sent.last, {'kind': 'hostStreamCancel', 'requestId': 0});
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isFalse);
      host.handleResponse({'kind': 'hostStreamCancelled', 'requestId': 0});
      await cancelling;
      expect(sent.last, {'kind': 'hostStreamAck', 'requestId': 0});
      final unary = channel.request('events.read', {});
      expect(sent.last['requestId'], 1);
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': 1,
        'ok': true,
        'payload': 'still unary',
      });
      expect(await unary, 'still unary');
    },
  );

  test(
    'resume before first item does not duplicate credit; done acknowledges',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final done = Completer<void>();
      final subscription = host
          .bind(hostInvocationContext: 'scope', serviceId: 'events')
          .stream('events.watch', {})
          .listen((_) {}, onDone: done.complete);
      subscription.pause();
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(2));
      host.handleResponse({'kind': 'hostStreamDone', 'requestId': 0});
      await done.future;
      expect(sent.last['kind'], 'hostStreamAck');
    },
  );

  test(
    'credited item arriving while paused stays buffered until resume',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final values = <int>[];
      final done = Completer<void>();
      final subscription = adeleDecodedStream<int>(
        host
            .bind(hostInvocationContext: 'scope', serviceId: 'events')
            .stream('events.watch', {}),
        (value) => value! as int,
        (error) => error,
      ).listen(values.add, onDone: done.complete);
      expect(sent, hasLength(2));
      expect(sent.last, {
        'kind': 'hostStreamCredit',
        'requestId': 0,
        'credit': 1,
      });
      subscription.pause();
      host.handleResponse({
        'kind': 'hostStreamItem',
        'requestId': 0,
        'payload': 7,
      });
      await Future<void>.delayed(Duration.zero);
      expect(values, isEmpty);
      expect(
        sent,
        hasLength(2),
        reason: 'Paused delivery must not grant credit.',
      );

      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(values, [7]);
      expect(sent, hasLength(3));
      expect(sent.last, {
        'kind': 'hostStreamCredit',
        'requestId': 0,
        'credit': 1,
      });
      subscription.pause();
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(values, [7]);
      expect(
        sent,
        hasLength(3),
        reason: 'The replacement credit is still outstanding.',
      );
      host.handleResponse({'kind': 'hostStreamDone', 'requestId': 0});
      await done.future;
      expect(sent.last, {'kind': 'hostStreamAck', 'requestId': 0});
    },
  );

  test(
    'generated decode failure cancels and preserves its original error',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final failure = StateError('decode failed');
      final check = expectLater(
        adeleDecodedStream<int>(
          host
              .bind(hostInvocationContext: 'scope', serviceId: 'events')
              .stream('watch', {}),
          (_) => throw failure,
          (error) => error,
        ),
        emitsError(same(failure)),
      );
      host.handleResponse({
        'kind': 'hostStreamItem',
        'requestId': 0,
        'payload': 'invalid',
      });
      expect(sent.last['kind'], 'hostStreamCancel');
      host.handleResponse({'kind': 'hostStreamCancelled', 'requestId': 0});
      await check;
      expect(sent.last['kind'], 'hostStreamAck');
    },
  );

  for (final error in <Object?>[
    {
      'code': 'failed',
      'message': 'exact',
      'declaredFailureType': 'events.failure',
      'details': {'reason': 'test'},
    },
    {'code': 'failed', 'message': 'exact'},
    {'code': 'failed', 'message': 'exact', 'declaredFailureType': null},
    {
      'code': 'failed',
      'message': 'exact',
      'declaredFailureType': 'events.failure',
    },
    {'code': 'failed', 'message': 'exact', 'details': null},
    'invalid',
  ]) {
    test('stream failure parsing: $error', () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final valid =
          error is Map && error.length <= 2 ||
          error is Map && error['details'] is Map;
      final check = expectLater(
        host
            .bind(hostInvocationContext: 'scope', serviceId: 'events')
            .stream('watch', {}),
        emitsError(
          valid
              ? isA<AdeleRemoteFailure>().having(
                  (e) => e.code,
                  'code',
                  'failed',
                )
              : isA<AdeleProtocolException>(),
        ),
      );
      host.handleResponse({
        'kind': 'hostStreamFailure',
        'requestId': 0,
        'error': error,
      });
      await check;
      expect(sent.last['kind'], 'hostStreamAck');
    });
  }

  test(
    'malformed stream item cancels, settles parsing error, then acknowledges',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final check = expectLater(
        host
            .bind(hostInvocationContext: 'scope', serviceId: 'events')
            .stream('watch', {}),
        emitsError(isA<AdeleProtocolException>()),
      );
      host.handleResponse({'kind': 'hostStreamItem', 'requestId': 0});
      expect(sent.last['kind'], 'hostStreamCancel');
      host.handleResponse({'kind': 'hostStreamCancelled', 'requestId': 0});
      await check;
      expect(sent.last['kind'], 'hostStreamAck');
    },
  );

  test(
    'close settles active streams and pending cancellation without replies',
    () async {
      final host = AdeleHostRequestMultiplexer(send: (_) {});
      final channel = host.bind(
        hostInvocationContext: 'scope',
        serviceId: 'events',
      );
      final check = expectLater(
        channel.stream('watch', {}),
        emitsError(isA<StateError>()),
      );
      final subscription = channel.stream('watch', {}).listen((_) {});
      final cancelling = subscription.cancel();
      host.close();
      await check;
      await cancelling.timeout(const Duration(seconds: 1));
      await expectLater(
        channel.stream('late', {}),
        emitsError(isA<StateError>()),
      );
    },
  );

  test(
    'bound calls use exact host wire without plugin or semantic authority',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final channel = host.bind(
        hostInvocationContext: 'opaque',
        serviceId: 'read',
      );
      final result = channel.request('read.file', {
        'relativePath': 'AGENTS.md',
      });
      expect(sent.single, {
        'kind': 'hostRequest',
        'requestId': isA<int>(),
        'hostContextKind': 'invocation',
        'hostContext': 'opaque',
        'serviceId': 'read',
        'method': 'read.file',
        'payload': {'relativePath': 'AGENTS.md'},
      });
      expect(
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': sent.single['requestId'],
          'ok': true,
          'payload': null,
        }),
        isTrue,
      );
      expect(await result, isNull);
    },
  );

  test(
    'concurrent contexts/services correlate out of order, not by method',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final first = host
          .bind(hostInvocationContext: 'first', serviceId: 'read')
          .request('same.method', {});
      final second = host
          .bind(hostInvocationContext: 'second', serviceId: 'other')
          .request('same.method', {});
      expect(sent[0]['requestId'], isNot(sent[1]['requestId']));
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': sent[1]['requestId'],
        'ok': true,
        'payload': 'second result',
      });
      expect(await second, 'second result');
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': sent[0]['requestId'],
        'ok': true,
        'payload': 'first result',
      });
      expect(await first, 'first result');
    },
  );

  test(
    'invocation and infrastructure unary/streams share one ID sequence',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final invocation = host.bind(
        hostInvocationContext: 'operation',
        serviceId: 'read',
      );
      final infrastructure = host.bindInfrastructure(
        hostInfrastructureContext: 'generation',
        serviceId: 'storage',
      );
      final first = invocation.request('same.method', {});
      final second = infrastructure.request('same.method', {});
      final third = invocation.stream('same.method', {}).toList();
      final fourth = infrastructure.stream('same.method', {}).toList();
      final opens = sent
          .where((message) => message.containsKey('hostContext'))
          .toList();
      expect(opens.map((message) => message['requestId']), [0, 1, 2, 3]);
      expect(opens.map((message) => message['hostContextKind']), [
        'invocation',
        'infrastructure',
        'invocation',
        'infrastructure',
      ]);
      expect(opens.map((message) => message['hostContext']), [
        'operation',
        'generation',
        'operation',
        'generation',
      ]);
      expect(opens[1], {
        'kind': 'hostRequest',
        'requestId': 1,
        'hostContextKind': 'infrastructure',
        'hostContext': 'generation',
        'serviceId': 'storage',
        'method': 'same.method',
        'payload': <String, Object?>{},
      });
      for (final id in [3, 2]) {
        host.handleResponse({
          'kind': 'hostStreamItem',
          'requestId': id,
          'payload': id,
        });
        host.handleResponse({'kind': 'hostStreamDone', 'requestId': id});
      }
      for (final id in [1, 0]) {
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': id,
          'ok': true,
          'payload': id,
        });
      }
      expect(await first, 0);
      expect(await second, 1);
      expect(await third, [2]);
      expect(await fourth, [3]);
      for (final value in ['', 'generation']) {
        expect(
          () => host.bindInfrastructure(
            hostInfrastructureContext: value,
            serviceId: value == '' ? 'storage' : '',
          ),
          throwsArgumentError,
        );
      }
      final pending = infrastructure.request('pending', {});
      final check = expectLater(pending, throwsStateError);
      host.close();
      await check;
      expect(
        () => host.bindInfrastructure(
          hostInfrastructureContext: 'generation',
          serviceId: 'storage',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'forward commands and responses are not consumed by reverse requests',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final result = host
          .bind(hostInvocationContext: 'scope', serviceId: 'read')
          .request('read.file', {});
      for (final kind in [
        'request',
        'response',
        'streamOpen',
        'streamCancel',
      ]) {
        expect(
          host.handleResponse({
            'kind': kind,
            'requestId': sent.single['requestId'],
            'ok': true,
            'payload': 'not a reverse response',
          }),
          isFalse,
        );
      }
      expect(host.handleResponse(null), isFalse);
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': sent.single['requestId'],
        'ok': true,
        'payload': 'reverse',
      });
      expect(await result, 'reverse');
      expect(
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': sent.single['requestId'],
          'ok': true,
          'payload': 'duplicate',
        }),
        isTrue,
      );
      expect(
        host.handleResponse({'kind': 'hostResponse', 'requestId': 999}),
        isTrue,
      );
    },
  );

  test(
    'declared remote failure fields and structured details are preserved',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final result = host
          .bind(hostInvocationContext: 'scope', serviceId: 'read')
          .request('read.file', {});
      final details = <String, Object?>{
        'path': 'AGENTS.md',
        'nested': <Object?>[
          null,
          true,
          2,
          {'revision': 'opaque'},
        ],
      };
      final check = expectLater(
        result,
        throwsA(
          isA<AdeleRemoteFailure>()
              .having(
                (error) => error.declaredFailureType,
                'declared type',
                'read.failure',
              )
              .having((error) => error.code, 'code', 'not_found')
              .having((error) => error.message, 'message', 'Exact host message')
              .having((error) => error.details, 'details', {
                'path': 'AGENTS.md',
                'nested': [
                  null,
                  true,
                  2,
                  {'revision': 'opaque'},
                ],
              }),
        ),
      );
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': sent.single['requestId'],
        'ok': false,
        'error': {
          'declaredFailureType': 'read.failure',
          'code': 'not_found',
          'message': 'Exact host message',
          'details': details,
        },
      });
      details['path'] = 'changed after response';
      await check;
    },
  );

  test('undeclared host failure remains a remote failure', () async {
    final host = AdeleHostRequestMultiplexer(send: (_) {});
    addTearDown(host.close);
    final result = host
        .bind(hostInvocationContext: 'scope', serviceId: 'read')
        .request('read.file', {});
    final check = expectLater(
      result,
      throwsA(
        isA<AdeleRemoteFailure>()
            .having(
              (error) => error.declaredFailureType,
              'declared type',
              isNull,
            )
            .having((error) => error.code, 'code', 'host_invocation_closed')
            .having((error) => error.details, 'details', isEmpty),
      ),
    );
    host.handleResponse({
      'kind': 'hostResponse',
      'requestId': 0,
      'ok': false,
      'error': {'code': 'host_invocation_closed', 'message': 'Retired'},
    });
    await check;
  });

  for (final fields in <Map<String, Object?>>[
    {'ok': true, 'result': 'wrong payload key'},
    {'ok': 'true', 'payload': null},
    {'ok': false, 'error': 'not a failure map'},
    {
      'ok': false,
      'error': {'code': 12, 'message': 'invalid'},
    },
    {
      'ok': false,
      'error': {'code': 'bad', 'message': 'invalid', 'details': <Object?>[]},
    },
    {
      'ok': false,
      'error': {
        'code': 'bad',
        'message': 'invalid',
        'declaredFailureType': 'read.failure',
      },
    },
  ]) {
    test('malformed correlated response settles the call: $fields', () async {
      final host = AdeleHostRequestMultiplexer(send: (_) {});
      addTearDown(host.close);
      final result = host
          .bind(hostInvocationContext: 'scope', serviceId: 'read')
          .request('read.file', {});
      final check = expectLater(result, throwsA(isA<AdeleProtocolException>()));
      host.handleResponse({'kind': 'hostResponse', 'requestId': 0, ...fields});
      await check;
    });
  }

  test(
    'close settles all calls, rejects retained/new channels, ignores late replies',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      final channel = host.bind(
        hostInvocationContext: 'scope',
        serviceId: 'read',
      );
      final first = channel.request('read.file', {});
      final second = channel.request('read.file', {});
      final checks = [
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ];
      host.close();
      host.close();
      await Future.wait(checks);
      await expectLater(channel.request('read.file', {}), throwsStateError);
      expect(
        () => host.bind(hostInvocationContext: 'new', serviceId: 'read'),
        throwsStateError,
      );
      expect(sent, hasLength(2));
      expect(
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': sent.first['requestId'],
          'ok': true,
          'payload': 'too late',
        }),
        isTrue,
      );
    },
  );

  test(
    'synchronous send failure settles and removes the pending call',
    () async {
      final failure = StateError('port failed');
      final host = AdeleHostRequestMultiplexer(send: (_) => throw failure);
      final channel = host.bind(
        hostInvocationContext: 'scope',
        serviceId: 'read',
      );
      await expectLater(
        channel.request('read.file', {}),
        throwsA(same(failure)),
      );
      host.close();
    },
  );

  test(
    'closing reverse requests before forward drain cannot deadlock',
    () async {
      final host = AdeleHostRequestMultiplexer(send: (_) {});
      final dispatcher = _WaitingDispatcher(
        host.bind(hostInvocationContext: 'scope', serviceId: 'read'),
      );
      final router = AdeleConfigurationContextRouter.single(
        configurationContext: 'default',
        serviceId: 'source',
        dispatcher: dispatcher,
      );
      final events = <Map<String, Object?>>[];
      final handling = router.handle({
        'kind': 'request',
        'requestId': 7,
        'configurationContext': 'default',
        'serviceId': 'source',
        'method': 'snapshot',
        'payload': <String, Object?>{},
      }, events.add);
      host.close();
      await router.close().timeout(const Duration(seconds: 1));
      await handling;
      expect(dispatcher.settled, isTrue);
      expect(events.single['ok'], isFalse);
    },
  );
}

final class _WaitingDispatcher implements AdeleBackendDispatcher {
  _WaitingDispatcher(this.channel);

  final AdeleRequestChannel channel;
  Future<void>? _operation;
  bool settled = false;

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async {
    try {
      await channel.request('read.file', {});
      return {
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
      };
    } on StateError {
      return {
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': false,
      };
    } finally {
      settled = true;
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) => _operation = dispatch(command).then(send);

  @override
  Future<void> close() async => await _operation;
}
