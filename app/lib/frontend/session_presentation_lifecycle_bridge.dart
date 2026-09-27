import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

import 'prepared_frontend.dart';

const _bridgeLibrary =
    'package:adele_ui/session_presentation_lifecycle_bridge.dart';

class SessionPresentationLifecycleDeclarations implements EvalPlugin {
  const SessionPresentationLifecycleDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    for (final name in [
      'registerSessionPrepareToDeactivate',
      'unregisterSessionPrepareToDeactivate',
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _bridgeLibrary,
          name,
          const BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
            params: [
              BridgeParameter(
                'callback',
                BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
                false,
              ),
            ],
          ),
        ),
      );
    }
  }

  @override
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a presentation-scoped SessionPresentationLifecycleBridge.',
  );
}

final class SessionPresentationLifecycleBridge
    extends SessionPresentationLifecycleDeclarations
    implements PreparedFrontendBridge {
  SessionPresentationLifecycleBridge({
    required bool Function() isActive,
    void Function()? onInvalidate,
  }) : _isActive = isActive,
       _onInvalidate = onInvalidate;

  final bool Function() _isActive;
  final void Function()? _onInvalidate;
  EvalCallable? _callback;
  Future<Object?> Function()? _prepare;
  bool _active = true;

  void _validate() {
    if (_active) {
      try {
        if (_isActive()) return;
      } on Object {
        // A failed liveness check revokes this exact hook.
      }
    }
    invalidate();
    throw StateError('Session presentation is retired.');
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(
        _bridgeLibrary,
        'registerSessionPrepareToDeactivate',
        (_, _, args) {
          _validate();
          final callback = args.single! as EvalCallable;
          if (_callback != null) {
            if (!identical(_callback, callback)) {
              throw StateError(
                'A Session deactivation hook is already registered.',
              );
            }
            return null;
          }
          _callback = callback;
          _prepare = () async {
            final pending = callback.call(runtime, null, const []);
            if (pending is! $Future) {
              throw StateError('The Session deactivation hook must be async.');
            }
            // Await the native future, not recursive evaluator reification. No
            // native failure is sent back through an interpreted await boundary.
            return await pending.$value;
          };
          return null;
        },
      )
      ..registerBridgeFunc(
        _bridgeLibrary,
        'unregisterSessionPrepareToDeactivate',
        (_, _, args) {
          if (identical(_callback, args.single)) {
            _callback = null;
            _prepare = null;
          }
          return null;
        },
      );
  }

  /// Failure is recoverable: do not invalidate or dispose a still-live view.
  Future<void> prepareToDeactivate() async {
    try {
      _validate();
      final prepare = _prepare;
      if (prepare == null) return;
      final result = await prepare();
      _validate();
      if (!identical(prepare, _prepare) ||
          (result is $bool ? result.$value : result) != true) {
        throw StateError('The Session deactivation hook did not accept.');
      }
    } on Object {
      throw StateError('Session presentation could not prepare to deactivate.');
    }
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _callback = null;
    _prepare = null;
    _onInvalidate?.call();
  }
}
