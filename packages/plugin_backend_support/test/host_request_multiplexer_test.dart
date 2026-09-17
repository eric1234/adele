import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
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
        'hostInvocationContext': 'opaque',
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
