/// Experimental declarations and transport-neutral runtime types for typed
/// ADELE plugin contracts.
library;

import 'dart:async';
import 'dart:collection';

const int _adeleJsonMaxDepth = 64;
const int adelePluginBackendProtocolVersion = 1;

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

final class AdeleConfigurationContextRouter {
  AdeleConfigurationContextRouter({
    required Map<String, Map<String, AdeleBackendDispatcher>> contexts,
  }) : _contexts =
           Map<String, Map<String, AdeleBackendDispatcher>>.unmodifiable(
             contexts.map(
               (String context, Map<String, AdeleBackendDispatcher> services) =>
                   MapEntry<String, Map<String, AdeleBackendDispatcher>>(
                     context,
                     Map<String, AdeleBackendDispatcher>.unmodifiable(services),
                   ),
             ),
           ) {
    if (_contexts.isEmpty ||
        _contexts.entries.any(
          (entry) =>
              entry.key.isEmpty ||
              entry.value.isEmpty ||
              entry.value.keys.any((String serviceId) => serviceId.isEmpty),
        )) {
      throw ArgumentError.value(
        contexts,
        'contexts',
        'Configuration contexts and services must be non-empty.',
      );
    }
  }

  AdeleConfigurationContextRouter.single({
    required String configurationContext,
    required String serviceId,
    required AdeleBackendDispatcher dispatcher,
  }) : this(
         contexts: <String, Map<String, AdeleBackendDispatcher>>{
           configurationContext: <String, AdeleBackendDispatcher>{
             serviceId: dispatcher,
           },
         },
       );

  final Map<String, Map<String, AdeleBackendDispatcher>> _contexts;
  final Map<int, AdeleBackendDispatcher> _streamOwners =
      <int, AdeleBackendDispatcher>{};

  Future<void> handle(
    Map<Object?, Object?> command,
    void Function(Map<String, Object?> event) send,
  ) {
    final Object? kind = command['kind'];
    final Object? requestId = command['requestId'];
    AdeleBackendDispatcher? dispatcher;
    if (kind == 'request' || kind == 'streamOpen') {
      final Object? configurationContext = command['configurationContext'];
      if (configurationContext is! String || configurationContext.isEmpty) {
        _reject(
          kind,
          requestId,
          'invalid_configuration_context',
          'Capability invocation requires a configuration context.',
          send,
        );
        return Future<void>.value();
      }
      final Map<String, AdeleBackendDispatcher>? services =
          _contexts[configurationContext];
      if (services == null) {
        _reject(
          kind,
          requestId,
          'configuration_context_unavailable',
          'The configuration context is not active in this plugin generation.',
          send,
        );
        return Future<void>.value();
      }
      final Object? serviceId = command['serviceId'];
      dispatcher = serviceId is String ? services[serviceId] : null;
      if (dispatcher == null) {
        _reject(
          kind,
          requestId,
          'service_unavailable',
          'The service is not exposed by this configuration context.',
          send,
        );
        return Future<void>.value();
      }
      if (kind == 'streamOpen' && requestId is int) {
        _streamOwners[requestId] = dispatcher;
      }
    } else if (kind == 'streamCredit' || kind == 'streamCancel') {
      dispatcher = requestId is int ? _streamOwners[requestId] : null;
      if (dispatcher == null) return Future<void>.value();
    } else {
      return Future<void>.value();
    }

    final Map<Object?, Object?> generatedCommand =
        Map<Object?, Object?>.of(command)
          ..remove('configurationContext')
          ..remove('serviceId');
    bool terminalSent = false;
    void containFailure(Object _) {
      if (!terminalSent) _dispatchFailure(kind, requestId, send);
    }

    try {
      return dispatcher
          .handle(generatedCommand, (Map<String, Object?> event) {
            final bool terminal =
                event['kind'] == 'response' ||
                event['kind'] == 'streamDone' ||
                event['kind'] == 'streamFailure' ||
                event['kind'] == 'streamCancelled';
            send(event);
            if (terminal) {
              terminalSent = true;
              _streamOwners.remove(requestId);
            }
          })
          .catchError(containFailure);
    } on Object catch (error) {
      containFailure(error);
      return Future<void>.value();
    }
  }

  Future<void> close() async {
    _streamOwners.clear();
    final Set<AdeleBackendDispatcher> unique =
        HashSet<AdeleBackendDispatcher>.identity()
          ..addAll(_contexts.values.expand((services) => services.values));
    await Future.wait<void>(unique.map((dispatcher) => dispatcher.close()));
  }

  void _dispatchFailure(
    Object? kind,
    Object? requestId,
    void Function(Map<String, Object?> event) send,
  ) {
    _streamOwners.remove(requestId);
    send(<String, Object?>{
      'kind': kind == 'request' ? 'response' : 'streamFailure',
      'requestId': requestId,
      if (kind == 'request') 'ok': false,
      'error': const <String, Object?>{
        'code': 'internal_error',
        'message': 'Configuration-scoped backend dispatch failed.',
      },
    });
  }

  void _reject(
    Object? kind,
    Object? requestId,
    String code,
    String message,
    void Function(Map<String, Object?> event) send,
  ) {
    send(<String, Object?>{
      'kind': kind == 'streamOpen' ? 'streamFailure' : 'response',
      'requestId': requestId,
      if (kind != 'streamOpen') 'ok': false,
      'error': <String, Object?>{'code': code, 'message': message},
    });
  }
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
