import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:test/test.dart';

void main() {
  test('overlapping operations retain independent explicit contexts', () async {
    final sent = <Map<String, Object?>>[];
    late final AdeleHostRequestMultiplexer host;
    host = AdeleHostRequestMultiplexer(
      send: (message) {
        sent.add(message);
        host.handleResponse({
          'kind': 'hostResponse',
          'requestId': message['requestId'],
          'ok': true,
          'payload': message['hostContext'],
        });
      },
    );
    addTearDown(host.close);
    final contexts = <AdeleBackendOperationContext>[];
    final channels = <AdeleRequestChannel>[];
    final releases = [Completer<void>(), Completer<void>()];
    final closed = <int>[];
    final wrapper = AdeleContextualServiceDispatcher(
      hostRequests: host,
      createDispatcher: (context) {
        final index = contexts.length;
        contexts.add(context);
        final channel = context.bind('read');
        channels.add(channel);
        expect(channel, isNot(isA<AdeleStreamChannel>()));
        return _Delegate(
          (command, send) async {
            // Generated dispatchers accept exactly this envelope; no metadata is
            // passed to their schema decoder or the semantic method payload.
            expect(command.keys.toSet(), {
              'kind',
              'requestId',
              'method',
              'payload',
            });
            expect(command['payload'], {'path': 'readme.txt'});
            await releases[index].future;
            final result = await channel.request('read.text', {
              'path': 'readme.txt',
            });
            send(_response(command, result));
          },
          close: () async {
            closed.add(index);
          },
        );
      },
    );
    final router = _router(wrapper);
    addTearDown(router.close);
    final events = <Map<String, Object?>>[];
    final first = router.handle(_request(1, 'first'), events.add);
    final second = router.handle(_request(2, 'second'), events.add);
    expect(contexts, hasLength(2));
    expect(identical(contexts[0], contexts[1]), isFalse);
    releases[1].complete();
    await second;
    expect(events.single['payload'], 'second');
    expect(() => contexts[1].bind('read'), throwsStateError);
    await expectLater(channels[1].request('read.text', {}), throwsStateError);
    expect(await channels[0].request('read.text', {}), 'first');
    releases[0].complete();
    await first;
    expect(events.map((event) => event['payload']), ['second', 'first']);
    expect(closed, [1, 0]);
    expect(sent.map((message) => message['requestId']), [0, 1, 2]);
    expect(sent.map((message) => message['hostContext']), [
      'second',
      'first',
      'first',
    ]);
    expect(
      sent.every((message) => message['hostContextKind'] == 'invocation'),
      isTrue,
    );
    expect(
      sent.every((message) => !message.containsKey('hostInvocationContext')),
      isTrue,
    );
    await expectLater(channels[0].request('read.text', {}), throwsStateError);
    expect(sent, hasLength(3));
  });

  test(
    'missing metadata and contextual streams never construct delegates',
    () async {
      final host = AdeleHostRequestMultiplexer(
        send: (_) => fail('No reverse call'),
      );
      addTearDown(host.close);
      var creations = 0;
      final wrapper = AdeleContextualServiceDispatcher(
        hostRequests: host,
        createDispatcher: (_) {
          creations++;
          throw StateError('Must not create');
        },
      );
      final router = _router(wrapper);
      addTearDown(router.close);
      final events = <Map<String, Object?>>[];
      await router.handle(
        _request(1, 'token')..remove('hostInvocationContext'),
        events.add,
      );
      await router.handle({
        ..._request(2, 'token'),
        'kind': 'streamOpen',
      }, events.add);
      await router.handle(
        {..._request(3, 'token'), 'kind': 'streamOpen'}
          ..remove('hostInvocationContext'),
        events.add,
      );
      await wrapper.handleContextual(_command(4), '', events.add);
      await wrapper.handleContextual(
        {..._command(5), 'kind': 'streamOpen'},
        'token',
        events.add,
      );
      events.add(await wrapper.dispatch(_command(6)));
      expect(creations, 0);
      expect(events, hasLength(6));
      expect(
        events.every(
          (event) =>
              (event['error'] as Map)['code'] ==
              'invalid_host_invocation_context',
        ),
        isTrue,
      );
    },
  );

  for (final outcome in [
    'success',
    'failure',
    'throw',
    'throw-after-response',
    'sync-throw',
    'cleanup-failure',
    'throw-and-cleanup-failure',
    'silent',
  ]) {
    test('$outcome expires context before slow delegate cleanup', () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final cleanupEntered = Completer<void>();
      final cleanupRelease = Completer<void>();
      late AdeleBackendOperationContext context;
      late AdeleRequestChannel channel;
      final wrapper = AdeleContextualServiceDispatcher(
        hostRequests: host,
        createDispatcher: (value) {
          context = value;
          channel = context.bind('read');
          Future<void> handle(
            Map<Object?, Object?> command,
            void Function(Map<String, Object?>) send,
          ) async {
            if (outcome == 'throw' || outcome == 'throw-and-cleanup-failure') {
              throw StateError('private');
            }
            if (outcome == 'silent') return;
            send(
              outcome == 'failure'
                  ? {
                      'kind': 'response',
                      'requestId': command['requestId'],
                      'ok': false,
                      'error': {'code': 'declared', 'message': 'failure'},
                    }
                  : _response(command, null),
            );
            expect(() => context.bind('read'), throwsStateError);
            if (outcome == 'throw-after-response') throw StateError('private');
          }

          return _Delegate(
            (command, send) {
              if (outcome == 'sync-throw') throw StateError('private');
              return handle(command, send);
            },
            close: () async {
              expect(() => context.bind('read'), throwsStateError);
              cleanupEntered.complete();
              await cleanupRelease.future;
              if (outcome == 'cleanup-failure' ||
                  outcome == 'throw-and-cleanup-failure') {
                throw StateError('private cleanup');
              }
            },
          );
        },
      );
      final router = _router(wrapper);
      final events = <Map<String, Object?>>[];
      var handled = false;
      final handling = router
          .handle(_request(1, 'token'), (event) {
            expect(() => context.bind('read'), throwsStateError);
            events.add(event);
          })
          .then((_) {
            handled = true;
          });
      await cleanupEntered.future;
      await expectLater(channel.request('read.text', {}), throwsStateError);
      expect(sent, isEmpty);
      expect(handled, isFalse);
      // Failure delivery, and therefore host-side revocation, cannot wait for
      // the delegate's cleanup gate even when handle throws without a response.
      expect(cleanupRelease.isCompleted, isFalse);
      expect(events, hasLength(1));
      expect(events.single['kind'], 'response');
      expect(events.single['requestId'], 1);
      expect(events.single.toString(), isNot(contains('private')));
      if (outcome == 'throw' ||
          outcome == 'sync-throw' ||
          outcome == 'throw-and-cleanup-failure' ||
          outcome == 'silent') {
        expect(events.single['ok'], isFalse);
        expect((events.single['error'] as Map)['code'], 'internal_error');
      } else {
        expect(events.single['ok'], outcome != 'failure');
      }
      var closed = false;
      final closing = wrapper.close().then((_) {
        closed = true;
      });
      expect(closed, isFalse);
      cleanupRelease.complete();
      await handling;
      await closing;
      expect(events, hasLength(1));
      await router.close();
    });
  }

  test(
    'factory failure expires its captured context without admitting work',
    () async {
      final host = AdeleHostRequestMultiplexer(
        send: (_) => fail('No reverse call'),
      );
      addTearDown(host.close);
      late AdeleBackendOperationContext captured;
      final wrapper = AdeleContextualServiceDispatcher(
        hostRequests: host,
        createDispatcher: (context) {
          captured = context;
          throw StateError('factory failed');
        },
      );
      final events = <Map<String, Object?>>[];
      await _router(wrapper).handle(_request(1, 'token'), (event) {
        expect(() => captured.bind('read'), throwsStateError);
        events.add(event);
      });
      expect(events.single['kind'], 'response');
      expect(events.single['requestId'], 1);
      expect(events.single['ok'], isFalse);
      expect((events.single['error'] as Map)['code'], 'internal_error');
      expect(events.single.toString(), isNot(contains('factory failed')));
      expect(() => captured.bind('read'), throwsStateError);
      await wrapper.close();
    },
  );

  test(
    'close expires immediately and drains every admitted operation and cleanup',
    () async {
      final sent = <Map<String, Object?>>[];
      final host = AdeleHostRequestMultiplexer(send: sent.add);
      addTearDown(host.close);
      final contexts = <AdeleBackendOperationContext>[];
      final work = [Completer<void>(), Completer<void>()];
      final cleanup = [Completer<void>(), Completer<void>()];
      final cleanupEntered = [Completer<void>(), Completer<void>()];
      final wrapper = AdeleContextualServiceDispatcher(
        hostRequests: host,
        createDispatcher: (context) {
          final index = contexts.length;
          contexts.add(context);
          return _Delegate(
            (command, send) async {
              await work[index].future;
              expect(() => context.bind('read'), throwsStateError);
              send(_response(command, index));
            },
            close: () async {
              cleanupEntered[index].complete();
              await cleanup[index].future;
            },
          );
        },
      );
      final events = <Map<String, Object?>>[];
      final first = wrapper.handleContextual(_command(1), 'first', events.add);
      final second = wrapper.handleContextual(
        _command(2),
        'second',
        events.add,
      );
      final pending = contexts[0].bind('read').request('read.text', {});
      final pendingCheck = expectLater(pending, throwsStateError);
      final closing = wrapper.close();
      expect(wrapper.close(), same(closing));
      for (final context in contexts) {
        expect(() => context.bind('read'), throwsStateError);
      }
      host.handleResponse({
        'kind': 'hostResponse',
        'requestId': 0,
        'ok': true,
        'payload': 'late',
      });
      await pendingCheck;
      await wrapper.handleContextual(_command(3), 'third', events.add);
      expect(contexts, hasLength(2));
      expect((events.single['error'] as Map)['code'], 'dispatcher_closed');
      var closed = false;
      final observedClose = closing.then((_) {
        closed = true;
      });
      work[1].complete();
      await cleanupEntered[1].future;
      cleanup[1].complete();
      await second;
      expect(closed, isFalse);
      expect(cleanupEntered[0].isCompleted, isFalse);
      work[0].complete();
      await cleanupEntered[0].future;
      expect(closed, isFalse);
      cleanup[0].complete();
      await first;
      await observedClose;
      expect(events.skip(1).map((event) => event['payload']), [1, 0]);
      expect(sent, hasLength(1));
    },
  );
}

AdeleConfigurationContextRouter _router(AdeleBackendDispatcher dispatcher) =>
    AdeleConfigurationContextRouter.single(
      configurationContext: 'configured',
      serviceId: 'service',
      dispatcher: dispatcher,
    );

Map<Object?, Object?> _request(int id, String token) => {
  ..._command(id),
  'configurationContext': 'configured',
  'serviceId': 'service',
  'hostInvocationContext': token,
};

Map<Object?, Object?> _command(int id) => {
  'kind': 'request',
  'requestId': id,
  'method': 'service.invoke',
  'payload': {'path': 'readme.txt'},
};

Map<String, Object?> _response(Map<Object?, Object?> command, Object? value) =>
    {
      'kind': 'response',
      'requestId': command['requestId'],
      'ok': true,
      'payload': value,
    };

final class _Delegate implements AdeleBackendDispatcher {
  _Delegate(this._handle, {Future<void> Function()? close}) : _close = close;
  final Future<void> Function(
    Map<Object?, Object?>,
    void Function(Map<String, Object?>),
  )
  _handle;
  final Future<void> Function()? _close;

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) => _handle(command, send);
  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    await _close?.call();
  }
}
