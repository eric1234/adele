import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:test/test.dart';

void main() {
  test('retirement fences admission and drains exact unary handler', () async {
    final gate = Completer<void>();
    final cleanup = Completer<void>();
    final responseSent = Completer<void>();
    final old = _Dispatcher(
      onHandle: (command, send) async {
        await gate.future;
        send({
          'kind': 'response',
          'requestId': command['requestId'],
          'ok': true,
        });
        responseSent.complete();
        await cleanup.future;
      },
    );
    final replacement = _Dispatcher();
    final router = AdeleConfigurationContextRouter(contexts: {});
    addTearDown(router.close);
    final registration = router.registerContext(services: {'fixture': old});
    final events = <Map<String, Object?>>[];
    final handling = router.handle(_request(registration, 1), events.add);
    final retiring = registration.retire();
    expect(identical(registration.retire(), retiring), isTrue);
    final fresh = router.registerContext(services: {'fixture': replacement});

    await router.handle(_request(registration, 2), events.add);
    expect(_error(events.last), 'configuration_context_unavailable');
    await router.handle(_request(fresh, 3), events.add);
    expect(old.commands, hasLength(1));
    expect(replacement.commands, hasLength(1));
    expect(old.closeCalls, 0);

    gate.complete();
    await responseSent.future;
    expect(
      old.closeCalls,
      0,
      reason: 'A sent response is not handler cleanup.',
    );
    cleanup.complete();
    await handling;
    await retiring;
    expect(old.closeCalls, 1);
    expect(events.last['requestId'], 1);
    expect(events.last['ok'], isTrue);
    await registration.retire();
    expect(old.closeCalls, 1);
  });

  test('retired streams retain credit/cancel ownership and cleanup', () async {
    final cleanup = Completer<void>();
    final cancelled = Completer<void>();
    final old = _Dispatcher(
      onHandle: (command, send) async {
        if (command['kind'] == 'streamCredit') {
          send({
            'kind': 'streamItem',
            'requestId': command['requestId'],
            'payload': {'kind': 'completed'},
          });
        } else if (command['kind'] == 'streamCancel') {
          send({'kind': 'streamCancelled', 'requestId': command['requestId']});
          cancelled.complete();
          await cleanup.future;
        }
      },
    );
    final replacement = _Dispatcher();
    final router = AdeleConfigurationContextRouter(contexts: {});
    addTearDown(router.close);
    final registration = router.registerContext(services: {'fixture': old});
    final events = <Map<String, Object?>>[];
    await router.handle(_request(registration, 1, stream: true), events.add);
    final retiring = registration.retire();
    final fresh = router.registerContext(services: {'fixture': replacement});
    await router.handle(_request(fresh, 2, stream: true), events.add);
    await router.handle(_request(registration, 3, stream: true), events.add);
    expect(_error(events.last), 'configuration_context_unavailable');

    await router.handle({
      'kind': 'streamCredit',
      'requestId': 1,
      'credit': 1,
      'configurationContext': fresh.configurationContext,
      'serviceId': 'fixture',
    }, events.add);
    expect(old.commands.last['kind'], 'streamCredit');
    expect(replacement.commands, hasLength(1));
    expect(
      old.closeCalls,
      0,
      reason: 'Domain completion is not transport EOF.',
    );
    final cancelling = router.handle({
      'kind': 'streamCancel',
      'requestId': 1,
    }, events.add);
    await cancelled.future;
    expect(events.last['kind'], 'streamCancelled');
    expect(
      old.closeCalls,
      0,
      reason: 'Cancellation handler cleanup is pending.',
    );
    cleanup.complete();
    await cancelling;
    await retiring;
    expect(old.closeCalls, 1);
    await router.handle({'kind': 'streamCancel', 'requestId': 1}, events.add);
    expect(old.commands, hasLength(3));
    expect(replacement.commands, hasLength(1));
  });

  test(
    'one registration drains every service, including contextual unary',
    () async {
      final unaryGate = Completer<void>();
      final contextual = _ContextualDispatcher(
        onHandle: (_, _) => unaryGate.future,
      );
      final streaming = _Dispatcher();
      final router = AdeleConfigurationContextRouter(contexts: {});
      addTearDown(router.close);
      final registration = router.registerContext(
        services: {'fixture': contextual, 'streaming': streaming},
      );
      final unary = router.handle({
        ..._request(registration, 1),
        'hostInvocationContext': 'operation-authority',
      }, (_) {});
      await router.handle({
        ..._request(registration, 2, stream: true),
        'serviceId': 'streaming',
      }, (_) {});
      var retired = false;
      final retiring = registration.retire().then((_) => retired = true);
      expect(contextual.contexts, ['operation-authority']);
      expect(
        contextual.commands.single.containsKey('hostInvocationContext'),
        isFalse,
      );
      unaryGate.complete();
      await unary;
      expect(streaming.closeCalls, 0);
      expect(retired, isFalse);
      await router.handle({'kind': 'streamCancel', 'requestId': 2}, (_) {});
      await retiring;
      expect([contextual.closeCalls, streaming.closeCalls], [1, 1]);
    },
  );

  for (final terminal in ['streamDone', 'streamFailure', 'streamCancelled']) {
    test('retirement waits for $terminal after stream-open settles', () async {
      late void Function(Map<String, Object?>) emit;
      final dispatcher = _Dispatcher(
        onHandle: (command, send) async => emit = send,
      );
      final router = AdeleConfigurationContextRouter(contexts: {});
      addTearDown(router.close);
      final registration = router.registerContext(
        services: {'fixture': dispatcher},
      );
      await router.handle(_request(registration, 1, stream: true), (_) {});
      final retiring = registration.retire();
      expect(dispatcher.closeCalls, 0);
      emit({'kind': 'streamItem', 'requestId': 1, 'payload': terminal});
      emit({'kind': terminal, 'requestId': 99});
      expect(dispatcher.closeCalls, 0);
      emit({'kind': terminal, 'requestId': 1});
      await retiring;
      expect(dispatcher.closeCalls, 1);
    });
  }

  test(
    'terminal before stream-open future settles still drains handler',
    () async {
      final cleanup = Completer<void>();
      final dispatcher = _Dispatcher(
        onHandle: (command, send) {
          send({'kind': 'streamDone', 'requestId': command['requestId']});
          return cleanup.future;
        },
      );
      final router = AdeleConfigurationContextRouter(contexts: {});
      addTearDown(router.close);
      final registration = router.registerContext(
        services: {'fixture': dispatcher},
      );
      final handling = router.handle(
        _request(registration, 1, stream: true),
        (_) {},
      );
      final retiring = registration.retire();
      expect(dispatcher.closeCalls, 0);
      cleanup.complete();
      await handling;
      await retiring;
      expect(dispatcher.closeCalls, 1);
    },
  );

  test(
    'duplicate IDs cannot steal a stream or lose its owner on unary completion',
    () async {
      final old = _Dispatcher();
      final replacement = _Dispatcher();
      final router = AdeleConfigurationContextRouter(contexts: {});
      addTearDown(router.close);
      final registration = router.registerContext(services: {'fixture': old});
      final fresh = router.registerContext(services: {'fixture': replacement});
      final events = <Map<String, Object?>>[];
      await router.handle(_request(registration, 1, stream: true), events.add);
      await router.handle(_request(fresh, 1, stream: true), events.add);
      expect(_error(events.last), 'invalid_request');
      expect(replacement.commands, isEmpty);
      await router.handle(_request(fresh, 1), events.add);
      await router.handle({'kind': 'streamCredit', 'requestId': 1}, events.add);
      expect(old.commands.last['kind'], 'streamCredit');
      await router.handle({'kind': 'streamCancel', 'requestId': 1}, events.add);
      await registration.retire();
      expect(old.closeCalls, 1);
      expect(replacement.commands.single['kind'], 'request');
    },
  );

  test(
    'unary-only stream rejection is contained and drains handler cleanup',
    () async {
      final cleanup = Completer<void>();
      final dispatcher = _UnaryOnlyDispatcher(cleanup.future);
      final router = AdeleConfigurationContextRouter(contexts: {});
      addTearDown(() {
        if (!cleanup.isCompleted) cleanup.complete();
        return router.close();
      });
      final registration = router.registerContext(
        services: {'fixture': dispatcher},
      );
      final events = <Map<String, Object?>>[];
      final handling = router.handle(
        _request(registration, 1, stream: true),
        events.add,
      );
      await dispatcher.responseSent.future;
      expect(events.single, {
        'kind': 'streamFailure',
        'requestId': 1,
        'error': {
          'code': 'invalid_request',
          'message': 'The service did not accept a streaming operation.',
        },
      });
      final retiring = registration.retire();
      expect(dispatcher.closeCalls, 0);
      for (final kind in ['streamCredit', 'streamCancel']) {
        await router.handle({
          'kind': kind,
          'requestId': 1,
          'credit': 1,
        }, events.add);
      }
      expect(dispatcher.commands, hasLength(1));
      expect(events, hasLength(1));
      cleanup.complete();
      await handling;
      await retiring;
      expect(dispatcher.closeCalls, 1);
      await registration.retire();
      expect(dispatcher.closeCalls, 1);
    },
  );

  for (final kind in ['streamCredit', 'streamCancel']) {
    test(
      'matching response from $kind releases only its stream owner',
      () async {
        final dispatcher = _Dispatcher(
          onHandle: (command, send) async {
            if (command['kind'] == kind) {
              send({
                'kind': 'response',
                'requestId': command['requestId'],
                'ok': false,
                'error': {
                  'code': 'invalid_request',
                  'message': 'private detail',
                },
              });
            }
          },
        );
        final router = AdeleConfigurationContextRouter(contexts: {});
        addTearDown(router.close);
        final registration = router.registerContext(
          services: {'fixture': dispatcher},
        );
        final events = <Map<String, Object?>>[];
        await router.handle(
          _request(registration, 1, stream: true),
          events.add,
        );
        await router.handle(
          _request(registration, 2, stream: true),
          events.add,
        );
        final retiring = registration.retire();
        await router.handle({
          'kind': kind,
          'requestId': 1,
          'credit': 1,
        }, events.add);
        expect(events.single['kind'], 'streamFailure');
        expect(_error(events.single), 'invalid_request');
        expect(events.single.toString(), isNot(contains('private detail')));
        expect(dispatcher.closeCalls, 0);
        await router.handle({
          'kind': kind,
          'requestId': 2,
          'credit': 1,
        }, events.add);
        await retiring;
        expect(events.last['kind'], 'streamFailure');
        expect(events.last['requestId'], 2);
        expect(dispatcher.closeCalls, 1);
      },
    );
  }

  test(
    'unrelated same-ID unary response cannot release a stream owner',
    () async {
      final dispatcher = _Dispatcher();
      final router = AdeleConfigurationContextRouter(contexts: {});
      addTearDown(router.close);
      final registration = router.registerContext(
        services: {'fixture': dispatcher},
      );
      final events = <Map<String, Object?>>[];
      await router.handle(_request(registration, 1, stream: true), events.add);
      await router.handle(_request(registration, 1), events.add);
      expect(events.single, {'kind': 'response', 'requestId': 1, 'ok': true});
      final retiring = registration.retire();
      expect(dispatcher.closeCalls, 0);
      await router.handle({'kind': 'streamCancel', 'requestId': 1}, events.add);
      await retiring;
      expect(events.last['kind'], 'streamCancelled');
      expect(dispatcher.commands.last['kind'], 'streamCancel');
      expect(dispatcher.closeCalls, 1);
    },
  );

  test('late old handler failure cannot remove a reused stream ID', () async {
    final cleanup = Completer<void>();
    final old = _Dispatcher(
      onHandle: (command, send) async {
        send({'kind': 'streamDone', 'requestId': command['requestId']});
        await cleanup.future;
        throw StateError('old handler failed');
      },
    );
    final replacement = _Dispatcher();
    final router = AdeleConfigurationContextRouter(contexts: {});
    addTearDown(router.close);
    final registration = router.registerContext(services: {'fixture': old});
    final fresh = router.registerContext(services: {'fixture': replacement});
    final events = <Map<String, Object?>>[];
    final handling = router.handle(
      _request(registration, 1, stream: true),
      events.add,
    );
    final retiring = registration.retire();
    await router.handle(_request(fresh, 1, stream: true), events.add);
    cleanup.complete();
    await handling;
    await retiring;
    expect(events, hasLength(1));
    await router.handle({'kind': 'streamCancel', 'requestId': 1}, events.add);
    expect(replacement.commands.last['kind'], 'streamCancel');
    await fresh.retire();
    expect(replacement.closeCalls, 1);
  });

  test('context identities skip static routes and are never reused', () async {
    final staticDispatcher = _Dispatcher();
    final router = AdeleConfigurationContextRouter(
      contexts: {
        'dynamic:1': {'fixture': staticDispatcher},
        'dynamic:3': {'fixture': staticDispatcher},
      },
    );
    final first = router.registerContext(services: {'fixture': _Dispatcher()});
    expect(first.configurationContext, 'dynamic:2');
    await first.retire();
    final second = router.registerContext(services: {'fixture': _Dispatcher()});
    expect(second.configurationContext, 'dynamic:4');
    adeleValidateConfigurationContext(second.configurationContext);
    final events = <Map<String, Object?>>[];
    await router.handle(_request(first, 1), events.add);
    expect(_error(events.single), 'configuration_context_unavailable');
    await router.close();
    expect(staticDispatcher.closeCalls, 1);
    await second.retire();
  });

  test(
    'snapshots preserve static sharing and dynamic service selection',
    () async {
      final shared = _Dispatcher();
      final original = _Dispatcher();
      final foreign = _Dispatcher();
      final staticServices = <String, AdeleBackendDispatcher>{
        'fixture': shared,
      };
      final contexts = <String, Map<String, AdeleBackendDispatcher>>{
        'static': staticServices,
        'other': {'fixture': shared},
      };
      final router = AdeleConfigurationContextRouter(contexts: contexts);
      final services = <String, AdeleBackendDispatcher>{'fixture': original};
      final registration = router.registerContext(services: services);
      services['fixture'] = foreign;
      services['other'] = foreign;
      staticServices.clear();
      contexts.clear();
      final events = <Map<String, Object?>>[];
      await router.handle(_request(registration, 1), events.add);
      await router.handle({
        ..._request(registration, 2),
        'serviceId': 'other',
      }, events.add);
      expect(_error(events.last), 'service_unavailable');
      await router.handle({
        ..._request(registration, 3),
        'configurationContext': 'static',
      }, events.add);
      expect(original.commands, hasLength(1));
      expect(shared.commands, hasLength(1));
      expect(foreign.commands, isEmpty);
      final closing = router.close();
      expect(identical(router.close(), closing), isTrue);
      await closing;
      await registration.retire();
      expect(original.closeCalls, 1);
      expect(shared.closeCalls, 1);
      expect(foreign.closeCalls, 0);
    },
  );

  test(
    'malformed/conflicting additions leave existing routes untouched',
    () async {
      final staticDispatcher = _Dispatcher();
      final pending = Completer<void>();
      final active = _Dispatcher(onHandle: (_, _) => pending.future);
      final candidate = _Dispatcher();
      final router = AdeleConfigurationContextRouter.single(
        configurationContext: 'static',
        serviceId: 'fixture',
        dispatcher: staticDispatcher,
      );
      addTearDown(router.close);
      expect(() => router.registerContext(services: {}), throwsArgumentError);
      for (final id in ['', '.bad', 'has space', 'bad\n', 'bad:service']) {
        expect(
          () => router.registerContext(services: {id: candidate}),
          throwsFormatException,
        );
      }
      for (final services in [
        {'fixture': staticDispatcher},
        {'fixture': candidate, 'other': candidate},
      ]) {
        expect(
          () => router.registerContext(services: services),
          throwsArgumentError,
        );
      }
      final registration = router.registerContext(
        services: {'fixture': active},
      );
      expect(
        () => router.registerContext(services: {'fixture': active}),
        throwsArgumentError,
      );
      final handling = router.handle(_request(registration, 1), (_) {});
      final retiring = registration.retire();
      expect(
        () => router.registerContext(services: {'fixture': active}),
        throwsArgumentError,
      );
      expect(candidate.closeCalls, 0);
      final accepted = router.registerContext(services: {'fixture': candidate});
      await router.handle(_request(accepted, 2), (_) {});
      await router.handle({
        ..._request(accepted, 3),
        'configurationContext': 'static',
      }, (_) {});
      expect(candidate.commands, hasLength(1));
      expect(staticDispatcher.commands, hasLength(1));
      pending.complete();
      await handling;
      await retiring;
    },
  );

  test(
    'shutdown forces draining streams but awaits handlers and close cleanup',
    () async {
      final unaryGate = Completer<void>();
      final closeGate = Completer<void>();
      final dispatcher = _Dispatcher(
        onHandle: (command, send) async {
          if (command['kind'] == 'request') await unaryGate.future;
        },
        onClose: () => closeGate.future,
      );
      final router = AdeleConfigurationContextRouter(contexts: {});
      final registration = router.registerContext(
        services: {'fixture': dispatcher},
      );
      await router.handle(_request(registration, 1, stream: true), (_) {});
      final handling = router.handle(_request(registration, 2), (_) {});
      final retiring = registration.retire();
      expect(dispatcher.closeCalls, 0);
      final closing = router.close();
      expect(dispatcher.closeCalls, 1);
      expect(identical(router.close(), closing), isTrue);
      expect(
        () => router.registerContext(services: {'fixture': _Dispatcher()}),
        throwsStateError,
      );
      final events = <Map<String, Object?>>[];
      await router.handle(_request(registration, 3), events.add);
      await router.handle(_request(registration, 4, stream: true), events.add);
      expect(
        events.map(_error),
        everyElement('configuration_context_unavailable'),
      );
      await router.handle({'kind': 'streamCancel', 'requestId': 1}, events.add);
      expect(dispatcher.commands, hasLength(2));
      var closed = false;
      final observedClose = closing.then((_) => closed = true);
      closeGate.complete();
      await closeGate.future;
      expect(closed, isFalse);
      unaryGate.complete();
      await handling;
      await retiring;
      await observedClose;
      expect(closed, isTrue);
      expect(dispatcher.closeCalls, 1);
    },
  );

  test(
    'shutdown invokes every close despite synchronous and async failures',
    () async {
      final sync = _Dispatcher(onClose: () => throw StateError('sync'));
      final async = _Dispatcher(
        onClose: () => Future.error(StateError('async')),
      );
      final healthy = _Dispatcher();
      final router = AdeleConfigurationContextRouter(contexts: {});
      final first = router.registerContext(services: {'fixture': sync});
      final second = router.registerContext(services: {'fixture': async});
      router.registerContext(services: {'fixture': healthy});
      final closing = router.close();
      await expectLater(closing, throwsStateError);
      await expectLater(first.retire(), throwsStateError);
      await expectLater(second.retire(), throwsStateError);
      expect(
        [sync.closeCalls, async.closeCalls, healthy.closeCalls],
        [1, 1, 1],
      );
      expect(identical(router.close(), closing), isTrue);
    },
  );

  test(
    'shutdown is memoized and fenced before reentrant dispatcher close',
    () async {
      late AdeleConfigurationContextRouter router;
      late AdeleConfigurationContextRegistration registration;
      Future<void>? reentrantClose;
      final events = <Map<String, Object?>>[];
      final dispatcher = _Dispatcher(
        onClose: () {
          reentrantClose = router.close();
          expect(
            () => router.registerContext(services: {'fixture': _Dispatcher()}),
            throwsStateError,
          );
          return router.handle(_request(registration, 1), events.add);
        },
      );
      router = AdeleConfigurationContextRouter(contexts: {});
      registration = router.registerContext(services: {'fixture': dispatcher});
      final closing = router.close();
      expect(identical(reentrantClose, closing), isTrue);
      await closing;
      expect(_error(events.single), 'configuration_context_unavailable');
      expect(dispatcher.commands, isEmpty);
      await registration.retire();
      expect(dispatcher.closeCalls, 1);
    },
  );

  test(
    'completed retirement releases ownership without retaining old routes',
    () async {
      final router = AdeleConfigurationContextRouter(contexts: {});
      final dispatcher = _Dispatcher();
      String? previous;
      for (var i = 0; i < 1000; i++) {
        final registration = router.registerContext(
          services: {'fixture': dispatcher},
        );
        expect(registration.configurationContext, isNot(previous));
        previous = registration.configurationContext;
        await registration.retire();
        await registration.retire();
        expect(dispatcher.closeCalls, i + 1);
      }
      await router.close();
      expect(dispatcher.closeCalls, 1000);
    },
  );
}

Map<Object?, Object?> _request(
  AdeleConfigurationContextRegistration registration,
  int requestId, {
  bool stream = false,
}) => {
  'kind': stream ? 'streamOpen' : 'request',
  'requestId': requestId,
  'configurationContext': registration.configurationContext,
  'serviceId': 'fixture',
  'method': stream ? 'fixture.watch' : 'fixture.invoke',
  'payload': <String, Object?>{},
};

Object? _error(Map<String, Object?> event) => (event['error'] as Map)['code'];

final class _Dispatcher implements AdeleBackendDispatcher {
  _Dispatcher({this.onHandle, this.onClose});

  final Future<void> Function(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  )?
  onHandle;
  final Future<void> Function()? onClose;
  final commands = <Map<Object?, Object?>>[];
  int closeCalls = 0;

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) =>
      throw UnimplementedError();

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) {
    commands.add(command);
    if (onHandle case final callback?) return callback(command, send);
    if (command['kind'] == 'request') {
      send({'kind': 'response', 'requestId': command['requestId'], 'ok': true});
    } else if (command['kind'] == 'streamCancel') {
      send({'kind': 'streamCancelled', 'requestId': command['requestId']});
    }
    return Future.value();
  }

  @override
  Future<void> close() {
    closeCalls++;
    return onClose?.call() ?? Future.value();
  }
}

final class _ContextualDispatcher extends _Dispatcher
    implements AdeleContextualUnaryDispatcher {
  _ContextualDispatcher({super.onHandle});

  final contexts = <String>[];

  @override
  Future<void> handleContextual(
    Map<Object?, Object?> command,
    String hostInvocationContext,
    void Function(Map<String, Object?>) send,
  ) {
    contexts.add(hostInvocationContext);
    return handle(command, send);
  }
}

final class _UnaryOnlyDispatcher extends _Dispatcher {
  _UnaryOnlyDispatcher(this.cleanup);

  final Future<void> cleanup;
  final responseSent = Completer<void>();

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async =>
      {
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': false,
        'error': {
          'code': 'invalid_request',
          'message': 'Malformed request envelope.',
        },
      };

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?>) send,
  ) async {
    commands.add(command);
    // Match generated unary-only dispatchers: every command uses unary dispatch.
    send(await dispatch(command));
    responseSent.complete();
    await cleanup;
  }
}
