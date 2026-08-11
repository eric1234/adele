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
  }) => _listen(onData, onError, onDone, cancelOnError);
}

final class AdeleBackendCommandRunner {
  AdeleBackendCommandRunner(
    this.dispatcher,
    this.send, {
    this.maxConcurrentOperations = 16,
  }) : assert(maxConcurrentOperations > 0);

  final AdeleBackendDispatcher dispatcher;
  final void Function(Map<String, Object?> event) send;
  final int maxConcurrentOperations;
  final Set<Future<void>> _operations = <Future<void>>{};
  final List<Completer<void>> _capacityWaiters = <Completer<void>>[];
  bool _closed = false;

  Future<void> add(Map<Object?, Object?> command) async {
    if (_closed) return;
    final Object? kind = command['kind'];
    if (kind == 'streamCredit' || kind == 'streamCancel') {
      await dispatcher.handle(command, send);
      return;
    }
    while (!_closed && _operations.length >= maxConcurrentOperations) {
      final Completer<void> waiter = Completer<void>();
      _capacityWaiters.add(waiter);
      await waiter.future;
    }
    if (_closed) return;
    late final Future<void> operation;
    operation = dispatcher.handle(command, send).whenComplete(() {
      _operations.remove(operation);
      if (_capacityWaiters.isNotEmpty) {
        _capacityWaiters.removeAt(0).complete();
      }
    });
    _operations.add(operation);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final Completer<void> waiter in _capacityWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _capacityWaiters.clear();
    await dispatcher.close();
    await Future.wait<void>(_operations.toList(growable: false));
  }
}

final class AdeleBoundedExecutor {
  AdeleBoundedExecutor({this.maximum = 16}) : assert(maximum > 0);

  final int maximum;
  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_active >= maximum) {
      final Completer<void> waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await operation();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
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
