import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:test/test.dart';

void main() {
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
