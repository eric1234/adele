import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/async.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _bridgeLibrary = 'package:adele_ui/owning_backend_bridge.dart';

/// Build-time ABI only. The public channel is compiled from its Dart source.
class OwningBackendDeclarations implements EvalPlugin {
  const OwningBackendDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'streamOwningBackend',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.stream, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.object),
                nullable: true,
              ),
            ]),
          ),
          params: [
            BridgeParameter(
              'serviceId',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter(
              'method',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter('payload', structuredBridgeMapType, false),
          ],
        ),
      ),
    );
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'requestOwningBackend',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.future, [
              BridgeTypeAnnotation(
                BridgeTypeRef(CoreTypes.object),
                nullable: true,
              ),
            ]),
          ),
          params: [
            BridgeParameter(
              'serviceId',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter(
              'method',
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              false,
            ),
            BridgeParameter('payload', structuredBridgeMapType, false),
          ],
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a presentation-scoped OwningBackendBridge.');
}

/// Channels and their origin are captured once by the native composition owner.
/// Neither plugin payloads nor replacement generations can select another route.
final class OwningBackendBridge extends OwningBackendDeclarations
    implements PreparedFrontendBridge {
  OwningBackendBridge({
    required Map<String, AdeleRequestChannel> channels,
    required void Function() validateBinding,
  }) : _channels = Map.unmodifiable(channels),
       _validateBinding = validateBinding,
       _channel = null;

  OwningBackendBridge.channel(
    OwningBackendChannel channel, {
    required void Function() validateBinding,
  }) : _channel = channel,
       _channels = const {},
       _validateBinding = validateBinding;

  final Map<String, AdeleRequestChannel> _channels;
  final OwningBackendChannel? _channel;
  final void Function() _validateBinding;
  final Zone _nativeZone = Zone.current;
  final Set<void Function()> _streams = {};
  bool _active = true;

  void _validate() {
    if (!_active) throw StateError('The owning backend bridge is retired.');
    _validateBinding();
    _channel?.validate();
  }

  Future<Object?> request(
    String serviceId,
    String method,
    Object? payload,
  ) async {
    _validate();
    final channel = _channels[serviceId];
    if (channel == null && _channel == null) {
      throw StateError('Backend service is not allowlisted.');
    }
    if (method.isEmpty) throw const FormatException('Backend method is empty.');
    final copied = copyStructuredBridgeData(payload);
    if (copied is! Map<String, Object?>) {
      throw const FormatException('Backend request payload must be a map.');
    }
    final result =
        await (_channel?.request(serviceId, method, copied) ??
            channel!.request(method, copied));
    _validate();
    return copyStructuredBridgeData(result);
  }

  Stream<Object?> stream(String serviceId, String method, Object? payload) {
    late final StreamController<Object?> controller;
    StreamSubscription<Object?>? subscription;
    Future<void>? cancellation;
    var ended = false;
    var quietCleanup = false;
    late final void Function() retire;

    Future<void> cancel() {
      ended = true;
      _streams.remove(retire);
      final current = subscription;
      subscription = null;
      if (current != null) {
        cancellation ??= Future<void>.sync(
          current.cancel,
        ).timeout(const Duration(seconds: 2));
      }
      final pending = cancellation ?? Future<void>.value();
      return quietCleanup ? pending.catchError((Object _) {}) : pending;
    }

    void fail(Object error, StackTrace stack) {
      if (ended) return;
      quietCleanup = true;
      unawaited(cancel().catchError((Object _) {}));
      scheduleMicrotask(() {
        controller.addError(error, stack);
        unawaited(controller.close());
      });
    }

    retire = () {
      if (ended) return;
      quietCleanup = true;
      unawaited(cancel().catchError((Object _) {}));
      scheduleMicrotask(() => unawaited(controller.close()));
    };

    controller = StreamController<Object?>(
      sync: true,
      onListen: () {
        _nativeZone.run(() {
          try {
            _validate();
            final channel = _channels[serviceId];
            if (_channel == null && channel is! AdeleStreamChannel) {
              throw StateError('Backend stream service is not allowlisted.');
            }
            if (method.isEmpty) {
              throw const FormatException('Backend method is empty.');
            }
            final copied = copyStructuredBridgeData(payload);
            if (copied is! Map<String, Object?>) {
              throw const FormatException(
                'Backend request payload must be a map.',
              );
            }
            _validate();
            _streams.add(retire);
            final source =
                _channel?.stream(serviceId, method, copied) ??
                (channel as AdeleStreamChannel).stream(method, copied);
            subscription = source.listen(
              (item) {
                if (ended) return;
                try {
                  _validate();
                  final copied = copyStructuredBridgeData(item);
                  _validate();
                  controller.add(copied);
                } on Object catch (error, stack) {
                  fail(error, stack);
                }
              },
              onError: (Object error, StackTrace stack) {
                if (ended) return;
                try {
                  _validate();
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
                  _validate();
                  ended = true;
                  _streams.remove(retire);
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
        });
      },
      onPause: () => subscription?.pause(),
      onResume: () {
        try {
          _validate();
          subscription?.resume();
        } on Object catch (error, stack) {
          fail(error, stack);
        }
      },
      onCancel: cancel,
    );
    return controller.stream.map((item) {
      _validate();
      return item;
    });
  }

  bool get _presentationActive {
    if (!_active) return false;
    try {
      _validateBinding();
      return true;
    } on Object {
      invalidate();
      return false;
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_bridgeLibrary, 'streamOwningBackend', (
      _,
      _,
      args,
    ) {
      final service = args[0]!.$value as String;
      final method = args[1]!.$value as String;
      return _EvalBackendStream(
        stream(service, method, args[2]).map(wrapStructuredBridgeData),
        () => _presentationActive,
      );
    });
    runtime.registerBridgeFunc(_bridgeLibrary, 'requestOwningBackend', (
      _,
      _,
      args,
    ) {
      final completion = Completer<$Value>();
      _nativeZone.run(() {
        request(
          args[0]!.$value as String,
          args[1]!.$value as String,
          args[2],
        ).then(
          (value) => completion.complete(wrapStructuredBridgeData(value)),
          onError: completion.completeError,
        );
      });
      completion.future.ignore();
      return $Future<$Value>.wrap(completion.future);
    });
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    for (final retire in _streams.toList()) {
      retire();
    }
    _streams.clear();
  }
}

/// The evaluator pin reverses listen's error/done callbacks and passes native
/// exceptions into eval. Keep the correction local to this generic data bridge.
final class _EvalBackendStream extends $Stream {
  _EvalBackendStream(super.value, this.isActive) : super.wrap();

  final bool Function() isActive;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) {
    if (identifier == 'map') {
      return $Function((runtime, _, args) {
        final convert = args[0] as EvalCallable;
        return _EvalBackendStream(
          $value.map((event) {
            if (!isActive()) return const $null();
            try {
              return convert.call(runtime, null, [runtime.wrap(event)]);
            } on Object {
              throw $String('Invalid backend stream item.');
            }
          }),
          isActive,
        );
      });
    }
    if (identifier == 'listen') {
      return $Function((runtime, _, args) {
        final onData = args[0] is $null ? null : args[0] as EvalCallable?;
        var onError = args[1] is $null ? null : args[1] as EvalCallable?;
        var onDone = args[2] is $null ? null : args[2] as EvalCallable?;
        final cancelOnError = args[3]?.$value == true;
        StreamSubscription<dynamic>? subscription;
        var ended = false;
        bool call(EvalCallable? callback, List<$Value?> values) {
          if (!isActive()) return false;
          try {
            callback?.call(runtime, null, values);
            return true;
          } on Object {
            // An observer cannot fail its producer or the enclosing presentation.
            return false;
          }
        }

        void done() {
          if (ended) return;
          ended = true;
          call(onDone, []);
        }

        void fail(Object error) {
          if (ended) return;
          unawaited(subscription?.cancel().catchError((Object _) {}));
          call(onError, [
            error is $String ? error : $String('Backend stream unavailable.'),
          ]);
          if (cancelOnError) {
            ended = true;
          } else {
            done();
          }
        }

        subscription = $value.listen(
          (event) {
            if (!ended && !call(onData, [runtime.wrap(event)])) {
              fail($String('Backend stream observer failed.'));
            }
          },
          onError: fail,
          onDone: done,
        );
        return _EvalBackendSubscription(
          subscription,
          onCancel: () {
            ended = true;
          },
          onError: (callback) {
            onError = callback;
          },
          onDone: (callback) {
            onDone = callback;
          },
        );
      });
    }
    return super.$getProperty(runtime, identifier);
  }
}

final class _EvalBackendSubscription extends $StreamSubscription {
  _EvalBackendSubscription(
    super.value, {
    required this.onCancel,
    required this.onError,
    required this.onDone,
  }) : super.wrap();

  final void Function() onCancel;
  final void Function(EvalCallable?) onError;
  final void Function(EvalCallable?) onDone;

  @override
  $Value? $getProperty(Runtime runtime, String identifier) {
    if (identifier == 'pause') {
      return $Function((_, _, args) {
        // The pin's dynamic invocation leaves an omitted optional argument in
        // the argument slot. Only an actual Future is a resume signal.
        final signal = args.isNotEmpty ? args[0]?.$value : null;
        $value.pause(signal is Future<void> ? signal : null);
        return const $null();
      });
    }
    if (identifier == 'cancel') {
      return $Function((_, _, _) {
        onCancel();
        // Observation revocation is immediate; bounded producer cleanup failure
        // must not leak a native diagnostic into the evaluator.
        return $Future.wrap(
          $value.cancel().then<$Value>(
            (_) => const $null(),
            onError: (Object _) => const $null(),
          ),
        );
      });
    }
    if (identifier == 'onError' || identifier == 'onDone') {
      return $Function((_, _, args) {
        final callback = args[0] is $null ? null : args[0] as EvalCallable?;
        (identifier == 'onError' ? onError : onDone)(callback);
        return const $null();
      });
    }
    return super.$getProperty(runtime, identifier);
  }
}
