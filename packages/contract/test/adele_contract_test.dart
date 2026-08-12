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
}

final class _SynchronousRawStream extends Stream<Object?> {
  _SynchronousRawStream({bool cancelFails = false})
    : subscription = _RawSubscription(cancelFails: cancelFails);

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
  _RawSubscription({required this.cancelFails});

  final bool cancelFails;
  int cancelCalls = 0;
  bool active = true;

  @override
  Future<void> cancel() async {
    cancelCalls++;
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
