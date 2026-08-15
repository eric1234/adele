/// Experimental declarations and transport-neutral runtime types for typed
/// ADELE plugin contracts.
library;

import 'dart:async';
import 'dart:collection';

const int _adeleJsonMaxDepth = 64;

Map<String, Object?> adeleSnapshotJsonMap(Map<String, Object?> source) =>
    _adeleSnapshotJsonValue(source, 0, HashSet<Object>.identity())!
        as Map<String, Object?>;

Object? _adeleSnapshotJsonValue(Object? value, int depth, Set<Object> active) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const FormatException('JSON-compatible doubles must be finite.');
    }
    return value;
  }
  if (depth >= _adeleJsonMaxDepth) {
    throw const FormatException(
      'JSON-compatible value exceeds maximum depth 64.',
    );
  }
  if (value is List<Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Cyclic JSON-compatible value.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map(
          (Object? item) => _adeleSnapshotJsonValue(item, depth + 1, active),
        ),
      );
    } finally {
      active.remove(value);
    }
  }
  if (value is Map<String, Object?>) {
    if (!active.add(value)) {
      throw const FormatException('Cyclic JSON-compatible value.');
    }
    try {
      return Map<String, Object?>.unmodifiable(
        value.map(
          (String key, Object? item) => MapEntry<String, Object?>(
            key,
            _adeleSnapshotJsonValue(item, depth + 1, active),
          ),
        ),
      );
    } finally {
      active.remove(value);
    }
  }
  throw FormatException(
    'Unsupported JSON-compatible value: ${value.runtimeType}.',
  );
}

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

final class AdeleCompleter<T> {
  final Completer<T> _completer = Completer<T>();

  bool get isCompleted => _completer.isCompleted;
  Future<T> get future => _completer.future;
  void complete([FutureOr<T>? value]) => _completer.complete(value);
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
  bool pausePending = false;
  Future<void>? cancellationFuture;
  Object? primaryError;
  StackTrace? primaryStackTrace;
  Future<void> cancelContained(StreamSubscription<Object?> target) async {
    try {
      await target.cancel();
    } on Object {
      return;
    }
  }

  Future<void> ensureCancellation(StreamSubscription<Object?> target) =>
      cancellationFuture ??= cancelContained(target);

  Future<void> deliverPrimary() async {
    final Object? error = primaryError;
    final StackTrace? stackTrace = primaryStackTrace;
    if (error != null && stackTrace != null) {
      controller.addError(error, stackTrace);
    }
    await controller.close();
  }

  Future<void> terminate(Object error, StackTrace stackTrace) async {
    if (terminated) return;
    terminated = true;
    primaryError = error;
    primaryStackTrace = stackTrace;
    final StreamSubscription<Object?>? current = subscription;
    if (current == null) return;
    await ensureCancellation(current);
    await deliverPrimary();
  }

  controller = StreamController<T>(
    sync: true,
    onListen: () {
      final StreamSubscription<Object?> created = raw.listen(
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
      subscription = created;
      if (terminated) {
        unawaited(() async {
          await ensureCancellation(created);
          await deliverPrimary();
        }());
      } else if (pausePending) {
        created.pause();
      }
    },
    onPause: () {
      final StreamSubscription<Object?>? current = subscription;
      if (current == null) {
        pausePending = true;
      } else {
        current.pause();
      }
    },
    onResume: () {
      final StreamSubscription<Object?>? current = subscription;
      if (current == null) {
        pausePending = false;
      } else {
        current.resume();
      }
    },
    onCancel: () async {
      terminated = true;
      final StreamSubscription<Object?>? current = subscription;
      if (current != null) await ensureCancellation(current);
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
