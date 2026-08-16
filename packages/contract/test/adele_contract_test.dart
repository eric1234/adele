import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:test/test.dart';

void main() {
  test('JSON snapshots are deep immutable construction-time values', () {
    final Map<String, Object?> nested = <String, Object?>{'value': 'original'};
    final List<Object?> items = <Object?>['original'];
    final Map<String, Object?> source = <String, Object?>{
      'nested': nested,
      'items': items,
    };
    final Map<String, Object?> snapshot = adeleSnapshotJsonMap(source);
    nested['value'] = 'mutated';
    items.add('mutated');
    expect(snapshot, const <String, Object?>{
      'nested': <String, Object?>{'value': 'original'},
      'items': <Object?>['original'],
    });
    expect(
      () => (snapshot['nested']! as Map<String, Object?>)['value'] = 'late',
      throwsUnsupportedError,
    );
  });

  test('JSON snapshots reject cycles depth and nonfinite doubles', () {
    final Map<String, Object?> cyclic = <String, Object?>{};
    cyclic['self'] = cyclic;
    expect(() => adeleSnapshotJsonMap(cyclic), throwsFormatException);
    final Map<String, Object?> deep = <String, Object?>{};
    Map<String, Object?> cursor = deep;
    for (int i = 0; i < 65; i++) {
      final Map<String, Object?> next = <String, Object?>{};
      cursor['next'] = next;
      cursor = next;
    }
    expect(() => adeleSnapshotJsonMap(deep), throwsFormatException);
    expect(
      () => adeleSnapshotJsonMap(<String, Object?>{'value': double.nan}),
      throwsFormatException,
    );
  });

  test('JSON snapshots accept shared acyclic containers', () {
    final Map<String, Object?> shared = <String, Object?>{'value': true};
    expect(
      adeleSnapshotJsonMap(<String, Object?>{'left': shared, 'right': shared}),
      const <String, Object?>{
        'left': <String, Object?>{'value': true},
        'right': <String, Object?>{'value': true},
      },
    );
  });
  test('remote failure preserves structured details', () {
    const AdeleRemoteFailure failure = _Failure(
      code: 'denied',
      message: 'Denied.',
      details: <String, Object?>{'path': '/tmp/example'},
    );

    expect(failure.code, 'denied');
    expect(failure.details['path'], '/tmp/example');
    expect(failure.toString(), '_Failure(denied): Denied.');
  });

  test('protocol exception implements FormatException', () {
    const AdeleProtocolException error = AdeleProtocolException(
      'Malformed value.',
      'source',
      2,
    );

    expect(error, isA<FormatException>());
    expect(error.source, 'source');
    expect(error.offset, 2);
  });

  test(
    'decoded stream preserves primary error when cancellation fails',
    () async {
      final raw = _SynchronousRawStream(cancelFails: true);
      final errors = <Object>[];
      final done = Completer<void>();
      adeleDecodedStream<int>(
        raw,
        (value) => throw const AdeleProtocolException('Malformed item.'),
        (error) => error,
      ).listen((_) {}, onError: errors.add, onDone: done.complete);
      await done.future;
      expect(errors.single, isA<AdeleProtocolException>());
      expect(raw.subscription.cancelCalls, 1);
      expect(raw.subscription.active, isFalse);
    },
  );

  test(
    'decoded stream cancels subscription returned after sync error',
    () async {
      final raw = _SynchronousRawStream();
      final errors = <Object>[];
      final done = Completer<void>();
      adeleDecodedStream<int>(
        raw,
        (value) => throw const AdeleProtocolException('Malformed item.'),
        (error) => error,
      ).listen((_) {}, onError: errors.add, onDone: done.complete);
      await done.future;
      expect(errors.single, isA<AdeleProtocolException>());
      expect(raw.subscription.cancelCalls, 1);
      expect(raw.subscription.active, isFalse);
    },
  );

  test('decoded cancellation joins in-progress raw cancellation', () async {
    final cancelStarted = Completer<void>();
    final releaseCancel = Completer<void>();
    final raw = _SynchronousRawStream(
      cancelStarted: cancelStarted,
      releaseCancel: releaseCancel,
    );
    final subscription = adeleDecodedStream<int>(
      raw,
      (value) => throw const AdeleProtocolException('Malformed item.'),
      (error) => error,
    ).listen((_) {}, onError: (_) {});
    await cancelStarted.future;
    bool cancelDone = false;
    final cancelling = subscription.cancel().then((_) => cancelDone = true);
    expect(raw.subscription.cancelCalls, 1);
    expect(cancelDone, isFalse);
    releaseCancel.complete();
    await cancelling;
    expect(raw.subscription.cancelCalls, 1);
    expect(raw.subscription.active, isFalse);
  });

  test('decoded stream preserves pause during raw listen assignment', () async {
    final raw = _SynchronousValueStream();
    late final StreamSubscription<int> decodedSubscription;
    final first = Completer<void>();
    decodedSubscription =
        adeleDecodedStream<int>(
          raw,
          (value) => value! as int,
          (error) => error,
        ).listen((value) {
          decodedSubscription.pause();
          first.complete();
        });
    await first.future;
    expect(raw.subscription.pauseCalls, 1);
    expect(raw.subscription.isPaused, isTrue);
    decodedSubscription.resume();
    expect(raw.subscription.resumeCalls, 1);
    expect(raw.subscription.isPaused, isFalse);
    await decodedSubscription.cancel();
  });

  test(
    'configuration router strips context and retains stream ownership',
    () async {
      final _RecordingDispatcher contextA = _RecordingDispatcher('context-a');
      final _RecordingDispatcher contextB = _RecordingDispatcher('context-b');
      final _RecordingDispatcher otherService = _RecordingDispatcher('other');
      final AdeleConfigurationContextRouter router =
          AdeleConfigurationContextRouter(
            contexts: <String, Map<String, AdeleBackendDispatcher>>{
              'a': <String, AdeleBackendDispatcher>{
                'fixture': contextA,
                'other': otherService,
              },
              'b': <String, AdeleBackendDispatcher>{'fixture': contextB},
            },
          );
      final List<Map<String, Object?>> events = <Map<String, Object?>>[];
      await router.handle(<Object?, Object?>{
        'kind': 'request',
        'requestId': 1,
        'configurationContext': 'a',
        'method': 'fixture.invoke',
        'payload': <String, Object?>{'configurationContext': 'b'},
      }, events.add);
      await router.handle(<Object?, Object?>{
        'kind': 'request',
        'requestId': 4,
        'configurationContext': 'a',
        'method': 'other.invoke',
        'payload': <String, Object?>{},
      }, events.add);
      await router.handle(<Object?, Object?>{
        'kind': 'streamOpen',
        'requestId': 2,
        'configurationContext': 'a',
        'method': 'fixture.watch',
        'payload': <String, Object?>{},
      }, events.add);
      await router.handle(<Object?, Object?>{
        'kind': 'streamOpen',
        'requestId': 3,
        'configurationContext': 'b',
        'method': 'fixture.watch',
        'payload': <String, Object?>{},
      }, events.add);
      await router.handle(<Object?, Object?>{
        'kind': 'streamCredit',
        'requestId': 2,
        'credit': 1,
      }, events.add);
      await router.handle(<Object?, Object?>{
        'kind': 'streamCancel',
        'requestId': 3,
      }, events.add);

      expect(events.first['payload'], 'context-a');
      expect(contextA.commands, hasLength(3));
      expect(contextB.commands, hasLength(2));
      expect(otherService.commands, hasLength(1));
      expect(events[1]['payload'], 'other');
      expect(
        contextA.commands.every(
          (Map<Object?, Object?> command) =>
              !command.containsKey('configurationContext'),
        ),
        isTrue,
      );
      expect(contextA.commands.last['kind'], 'streamCredit');
      expect(contextB.commands.last['kind'], 'streamCancel');
      await router.close();
    },
  );

  test('configuration router rejects missing and unknown contexts', () async {
    final _RecordingDispatcher dispatcher = _RecordingDispatcher('default');
    final AdeleConfigurationContextRouter router =
        AdeleConfigurationContextRouter.single(
          configurationContext: 'default',
          serviceId: 'fixture',
          dispatcher: dispatcher,
        );
    final List<Map<String, Object?>> events = <Map<String, Object?>>[];
    await router.handle(<Object?, Object?>{
      'kind': 'request',
      'requestId': 1,
      'method': 'fixture.invoke',
      'payload': <String, Object?>{},
    }, events.add);
    await router.handle(<Object?, Object?>{
      'kind': 'streamOpen',
      'requestId': 2,
      'configurationContext': 'unknown',
      'method': 'fixture.watch',
      'payload': <String, Object?>{},
    }, events.add);
    await router.handle(<Object?, Object?>{
      'kind': 'request',
      'requestId': 3,
      'configurationContext': 7,
      'method': 'fixture.invoke',
      'payload': <String, Object?>{},
    }, events.add);

    expect(dispatcher.commands, isEmpty);
    expect(events[0]['kind'], 'response');
    expect(
      (events[0]['error']! as Map)['code'],
      'invalid_configuration_context',
    );
    expect(events[1]['kind'], 'streamFailure');
    expect(
      (events[1]['error']! as Map)['code'],
      'configuration_context_unavailable',
    );
    expect(
      (events[2]['error']! as Map)['code'],
      'invalid_configuration_context',
    );
    await router.close();
  });

  test(
    'configuration router contains dispatcher stream-open failure',
    () async {
      final _ThrowingDispatcher dispatcher = _ThrowingDispatcher();
      final AdeleConfigurationContextRouter router =
          AdeleConfigurationContextRouter.single(
            configurationContext: 'default',
            serviceId: 'fixture',
            dispatcher: dispatcher,
          );
      final List<Map<String, Object?>> events = <Map<String, Object?>>[];
      await router.handle(<Object?, Object?>{
        'kind': 'streamOpen',
        'requestId': 1,
        'configurationContext': 'default',
        'method': 'fixture.watch',
        'payload': <String, Object?>{},
      }, events.add);
      await router.handle(<Object?, Object?>{
        'kind': 'streamCredit',
        'requestId': 1,
        'credit': 1,
      }, events.add);

      expect(dispatcher.calls, 1);
      expect(events, hasLength(1));
      expect(events.single['kind'], 'streamFailure');
      expect((events.single['error']! as Map)['code'], 'internal_error');
      await router.close();
    },
  );

  test('configuration router does not duplicate a sent terminal', () async {
    final _ThrowingDispatcher dispatcher = _ThrowingDispatcher(
      terminalBeforeThrow: true,
    );
    final AdeleConfigurationContextRouter router =
        AdeleConfigurationContextRouter.single(
          configurationContext: 'default',
          serviceId: 'fixture',
          dispatcher: dispatcher,
        );
    final List<Map<String, Object?>> events = <Map<String, Object?>>[];
    await router.handle(<Object?, Object?>{
      'kind': 'streamOpen',
      'requestId': 1,
      'configurationContext': 'default',
      'method': 'fixture.watch',
      'payload': <String, Object?>{},
    }, events.add);
    await router.handle(<Object?, Object?>{
      'kind': 'streamCredit',
      'requestId': 1,
      'credit': 1,
    }, events.add);

    expect(dispatcher.calls, 1);
    expect(events, hasLength(1));
    expect(events.single['kind'], 'streamDone');
    await router.close();
  });

  test('configuration router falls back when terminal send fails', () async {
    final _ThrowingDispatcher dispatcher = _ThrowingDispatcher(
      terminalBeforeThrow: true,
    );
    final AdeleConfigurationContextRouter router =
        AdeleConfigurationContextRouter.single(
          configurationContext: 'default',
          serviceId: 'fixture',
          dispatcher: dispatcher,
        );
    final List<Map<String, Object?>> events = <Map<String, Object?>>[];
    bool rejectTerminal = true;
    await router.handle(
      <Object?, Object?>{
        'kind': 'streamOpen',
        'requestId': 1,
        'configurationContext': 'default',
        'method': 'fixture.watch',
        'payload': <String, Object?>{},
      },
      (Map<String, Object?> event) {
        if (rejectTerminal && event['kind'] == 'streamDone') {
          rejectTerminal = false;
          throw StateError('fixture send failure');
        }
        events.add(event);
      },
    );

    expect(events, hasLength(1));
    expect(events.single['kind'], 'streamFailure');
    expect((events.single['error']! as Map)['code'], 'internal_error');
    await router.close();
  });
}

final class _ThrowingDispatcher implements AdeleBackendDispatcher {
  _ThrowingDispatcher({this.terminalBeforeThrow = false});

  final bool terminalBeforeThrow;
  int calls = 0;

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) =>
      throw UnimplementedError();

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  ) async {
    calls++;
    if (terminalBeforeThrow) {
      send(<String, Object?>{
        'kind': 'streamDone',
        'requestId': command['requestId'],
      });
    }
    throw StateError('fixture dispatch failure');
  }

  @override
  Future<void> close() async {}
}

final class _RecordingDispatcher implements AdeleBackendDispatcher {
  _RecordingDispatcher(this.label);

  final String label;
  final List<Map<Object?, Object?>> commands = <Map<Object?, Object?>>[];

  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request) async =>
      <String, Object?>{
        'kind': 'response',
        'requestId': request['requestId'],
        'ok': true,
        'payload': label,
      };

  @override
  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  ) async {
    commands.add(command);
    switch (command['kind']) {
      case 'request':
        send(await dispatch(command));
      case 'streamCredit':
        send(<String, Object?>{
          'kind': 'streamItem',
          'requestId': command['requestId'],
          'payload': label,
        });
      case 'streamCancel':
        send(<String, Object?>{
          'kind': 'streamCancelled',
          'requestId': command['requestId'],
        });
    }
  }

  @override
  Future<void> close() async {}
}

final class _SynchronousValueStream extends Stream<Object?> {
  final _TrackingSubscription subscription = _TrackingSubscription();

  @override
  StreamSubscription<Object?> listen(
    void Function(Object? event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    onData?.call(1);
    return subscription;
  }
}

final class _TrackingSubscription implements StreamSubscription<Object?> {
  int pauseCalls = 0;
  int resumeCalls = 0;
  bool _paused = false;

  @override
  Future<void> cancel() async {}
  @override
  void onData(void Function(Object? data)? handleData) {}
  @override
  void onDone(void Function()? handleDone) {}
  @override
  void onError(Function? handleError) {}
  @override
  void pause([Future<void>? resumeSignal]) {
    pauseCalls++;
    _paused = true;
  }

  @override
  void resume() {
    resumeCalls++;
    _paused = false;
  }

  @override
  bool get isPaused => _paused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue);
}

final class _SynchronousRawStream extends Stream<Object?> {
  _SynchronousRawStream({
    bool cancelFails = false,
    Completer<void>? cancelStarted,
    Completer<void>? releaseCancel,
  }) : subscription = _RawSubscription(
         cancelFails: cancelFails,
         cancelStarted: cancelStarted,
         releaseCancel: releaseCancel,
       );

  final _RawSubscription subscription;

  @override
  StreamSubscription<Object?> listen(
    void Function(Object? event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    onData?.call('malformed');
    return subscription;
  }
}

final class _RawSubscription implements StreamSubscription<Object?> {
  _RawSubscription({
    required this.cancelFails,
    this.cancelStarted,
    this.releaseCancel,
  });

  final bool cancelFails;
  final Completer<void>? cancelStarted;
  final Completer<void>? releaseCancel;
  int cancelCalls = 0;
  bool active = true;

  @override
  Future<void> cancel() async {
    cancelCalls++;
    cancelStarted?.complete();
    await releaseCancel?.future;
    active = false;
    if (cancelFails) throw StateError('cleanup failed');
  }

  @override
  void onData(void Function(Object? data)? handleData) {}
  @override
  void onDone(void Function()? handleDone) {}
  @override
  void onError(Function? handleError) {}
  @override
  void pause([Future<void>? resumeSignal]) {}
  @override
  void resume() {}
  @override
  bool get isPaused => false;
  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue);
}

final class _Failure implements AdeleRemoteFailure {
  const _Failure({
    required this.code,
    required this.message,
    this.details = const {},
  });

  @override
  final String code;
  @override
  final String message;
  @override
  final Map<String, Object?> details;
  @override
  String? get declaredFailureType => null;

  @override
  String toString() => '_Failure($code): $message';
}
