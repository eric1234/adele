import 'dart:async';

import 'package:adele_contract/adele_contract.dart';

import 'backend_connection.dart';

/// A presentation-local channel to one captured backend and context.
/// Neither plugin identity nor configuration selection crosses this boundary.
final class OwningBackendChannel {
  OwningBackendChannel({
    required PluginBackendConnection connection,
    required ConfigurationContextId configurationContext,
    required Iterable<String> backendServices,
    required void Function() validateOwner,
    required void Function() validatePresentation,
    void Function() Function(void Function())? observeOwnerRetirement,
  }) : _connection = connection,
       _validateOwner = validateOwner,
       _observeOwnerRetirement = observeOwnerRetirement,
       _validatePresentation = validatePresentation {
    for (final serviceId in backendServices) {
      adeleValidateServiceId(serviceId);
      if (_channels.containsKey(serviceId)) {
        throw const FormatException(
          'backendServices must not contain duplicates.',
        );
      }
      _channels[serviceId] = connection.channelFor(
        configurationContext,
        serviceId,
      );
    }
    // Validate context ownership even when there are no allowlisted services.
    connection.channelFor(configurationContext, 'context-validation');
    validate();
  }

  final PluginBackendConnection _connection;
  final void Function() _validateOwner;
  final void Function() _validatePresentation;
  final void Function() Function(void Function())? _observeOwnerRetirement;
  final Map<String, AdeleRequestChannel> _channels = {};

  void validate() {
    _validatePresentation();
    _validateOwner();
    if (_connection.isClosed) {
      throw const PluginConnectionClosed('The owning backend is closed.');
    }
  }

  Future<Object?> request(
    String serviceId,
    String method,
    Map<String, Object?> payload,
  ) async {
    validate();
    final channel = _channels[serviceId];
    if (channel == null) {
      throw StateError('Backend service $serviceId is not allowlisted.');
    }
    final snapshot = adeleSnapshotJsonMap(
      payload,
      maxNodes: adelePluginBackendJsonMaxNodes,
    );
    validate();
    final Object? result;
    try {
      result = await channel.request(method, snapshot);
    } finally {
      validate();
    }
    return adeleSnapshotJsonMap({
      'value': result,
    }, maxNodes: adelePluginBackendJsonMaxNodes)['value'];
  }

  /// Opens only on listen. Pausing and cancellation reach the captured transport;
  /// retirement fences delivery before waiting for producer cleanup.
  Stream<Object?> stream(
    String serviceId,
    String method,
    Map<String, Object?> payload,
  ) {
    late final StreamController<Object?> controller;
    StreamSubscription<Object?>? subscription;
    void Function()? detach;
    var ended = false;
    var failed = false;
    Future<void>? cancellation;

    void finish() {
      ended = true;
      detach?.call();
      detach = null;
    }

    Future<void> cancel() {
      finish();
      final current = subscription;
      subscription = null;
      if (current != null) {
        cancellation ??= Future<void>.sync(
          current.cancel,
        ).timeout(const Duration(seconds: 2));
      }
      final pending = cancellation ?? Future<void>.value();
      return failed ? pending.catchError((Object _) {}) : pending;
    }

    void fail(Object error, StackTrace stack) {
      if (ended) return;
      failed = true;
      unawaited(cancel().catchError((Object _) {}));
      // Retirement may run from the consumer's onData callback. Revoke now,
      // but defer terminal delivery until the synchronous item has unwound.
      scheduleMicrotask(() {
        controller.addError(error, stack);
        unawaited(controller.close());
      });
    }

    controller = StreamController<Object?>(
      sync: true,
      onListen: () {
        try {
          validate();
          final channel = _channels[serviceId];
          if (channel is! AdeleStreamChannel) {
            throw StateError(
              'Backend stream service $serviceId is not allowlisted.',
            );
          }
          final snapshot = adeleSnapshotJsonMap(
            payload,
            maxNodes: adelePluginBackendJsonMaxNodes,
          );
          detach = _observeOwnerRetirement?.call(() {
            fail(
              const PluginConnectionClosed('The owning backend is retired.'),
              StackTrace.current,
            );
          });
          validate();
          if (ended) return;
          subscription = channel
              .stream(method, snapshot)
              .listen(
                (item) {
                  if (ended) return;
                  try {
                    validate();
                    final value = adeleSnapshotJsonMap({
                      'value': item,
                    }, maxNodes: adelePluginBackendJsonMaxNodes)['value'];
                    validate();
                    controller.add(value);
                  } on Object catch (error, stack) {
                    fail(error, stack);
                  }
                },
                onError: (Object error, StackTrace stack) {
                  try {
                    validate();
                  } on Object catch (failure, trace) {
                    fail(failure, trace);
                    return;
                  }
                  fail(error, stack);
                },
                onDone: () {
                  if (ended) return;
                  subscription = null;
                  try {
                    validate();
                    finish();
                    unawaited(controller.close());
                  } on Object catch (error, stack) {
                    fail(error, stack);
                  }
                },
              );
          if (ended) {
            unawaited(cancel().catchError((Object _) {}));
          } else if (controller.isPaused) {
            subscription!.pause();
          }
        } on Object catch (error, stack) {
          fail(error, stack);
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () {
        try {
          validate();
          subscription?.resume();
        } on Object catch (error, stack) {
          fail(error, stack);
        }
      },
      onCancel: cancel,
    );
    // Revalidate at delivery too: a consumer may have paused with an already
    // admitted item buffered before retirement.
    return controller.stream.map((item) {
      validate();
      return item;
    });
  }
}
