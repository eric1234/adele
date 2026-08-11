/// Experimental declarations and transport-neutral runtime types for typed
/// ADELE plugin contracts.
library;

import 'dart:async';

final class AdeleService {
  const AdeleService(this.id);

  final String id;
}

final class AdeleValue {
  const AdeleValue(this.id);

  final String id;
}

final class AdeleMethod {
  const AdeleMethod(this.name);

  final String name;
}

final class AdeleField {
  const AdeleField(this.name);

  final String name;
}

final class AdeleFailure {
  const AdeleFailure(this.id);

  final String id;
}

abstract interface class AdeleRequestChannel {
  Future<Object?> request(String method, Map<String, Object?> payload);
}

abstract interface class AdeleStreamChannel implements AdeleRequestChannel {
  Stream<Object?> stream(String method, Map<String, Object?> payload);
}

abstract interface class AdeleBackendDispatcher {
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> request);

  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  );

  Future<void> close();
}

final class AdeleStreamIterator<T> {
  AdeleStreamIterator(Stream<T> stream) : _iterator = StreamIterator<T>(stream);

  final StreamIterator<T> _iterator;

  T get current => _iterator.current;

  Future<bool> moveNext() => _iterator.moveNext();

  Future<void> cancel() => _iterator.cancel();
}

final class AdeleLazyStream<T> extends Stream<T> {
  AdeleLazyStream(this._listen);

  bool _listened = false;

  final StreamSubscription<T> Function(
    void Function(T event)? onData,
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  )
  _listen;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) {
      throw StateError('Stream has already been listened to.');
    }
    _listened = true;
    return _listen(onData, onError, onDone, cancelOnError);
  }
}

Stream<T> adeleDecodedStream<T>(
  Stream<Object?> raw,
  T Function(Object? value) decode,
  Object Function(Object error) mapError,
) {
  late final StreamController<T> controller;
  StreamSubscription<Object?>? subscription;
  bool terminated = false;
  Future<void> terminate(Object error, StackTrace stackTrace) async {
    if (terminated) return;
    terminated = true;
    await subscription?.cancel();
    controller.addError(error, stackTrace);
    await controller.close();
  }

  controller = StreamController<T>(
    sync: true,
    onListen: () {
      subscription = raw.listen(
        (Object? item) {
          if (terminated) return;
          try {
            controller.add(decode(item));
          } on Object catch (error, stackTrace) {
            unawaited(terminate(error, stackTrace));
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (terminated) return;
          try {
            unawaited(terminate(mapError(error), stackTrace));
          } on Object catch (mappedError, mappedStackTrace) {
            unawaited(terminate(mappedError, mappedStackTrace));
          }
        },
        onDone: () {
          if (terminated) return;
          terminated = true;
          unawaited(controller.close());
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      terminated = true;
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

abstract interface class AdeleRemoteFailure implements Exception {
  String? get declaredFailureType;
  String get code;
  String get message;
  Map<String, Object?> get details;
}

final class AdeleProtocolException implements FormatException {
  const AdeleProtocolException(this.message, [this.source, this.offset]);

  @override
  final String message;

  @override
  final Object? source;

  @override
  final int? offset;

  @override
  String toString() => 'AdeleProtocolException: $message';
}
