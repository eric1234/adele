import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/foundation.dart';

import 'prepared_frontend.dart';

const _bridgeLibrary =
    'package:adele_ui/session_content_inspection_bridge.dart';
const _unavailable = 'Session content Inspection is unavailable.';

/// Build-time ABI only; native Session objects never cross this boundary.
class SessionContentInspectionDeclarations implements EvalPlugin {
  const SessionContentInspectionDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'readSessionContentInspectionContext',
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(
            BridgeTypeRef(CoreTypes.map, [
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
              BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a per-presentation SessionContentInspectionBridge.',
  );
}

/// Frozen facts and revocable access for one exact host-owned card context.
/// The native invalidation callback revokes backend observation before unmount.
final class SessionContentInspectionBridge
    extends SessionContentInspectionDeclarations
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  SessionContentInspectionBridge({
    required SessionContentInspectionContext context,
    required bool Function() isActive,
    VoidCallback? onInvalidate,
  }) : _context = context,
       _isActive = isActive,
       _onInvalidate = onInvalidate {
    try {
      validate();
      final session = context.session;
      _snapshot = $Map.wrap(
        Map<$Value, $Value>.unmodifiable({
          $String('sessionId'): $String(session.id.value),
          $String('taskId'): $String(session.taskId.value),
          $String('strategyId'): $String(session.strategyId.value),
          $String('contentKind'): $String(context.kind.value),
          $String('occurrenceId'): $String(context.occurrenceId.value),
        }),
      );
      _listening = true;
      _context.addListener(_changed);
      validate();
    } on Object {
      invalidate();
      throw StateError(_unavailable);
    }
  }

  final SessionContentInspectionContext _context;
  final bool Function() _isActive;
  final VoidCallback? _onInvalidate;
  $Value? _snapshot;
  VoidCallback? _onFailure;
  bool _active = true;
  bool _listening = false;

  @override
  set onFailure(VoidCallback? callback) => _onFailure = callback;

  /// Native-only validation shared with the captured backend bridge.
  void validate() {
    if (_active) {
      try {
        if (_isActive() && _context.isActive) return;
      } on Object {
        // Liveness failures are neither authority nor plugin-visible diagnostics.
      }
    }
    invalidate();
    throw StateError(_unavailable);
  }

  void _changed() {
    try {
      validate();
    } on Object {
      // validate has synchronously revoked this view and its backend access.
    }
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(
      _bridgeLibrary,
      'readSessionContentInspectionContext',
      (_, _, _) {
        validate();
        return _snapshot!;
      },
    );
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _snapshot = null;
    if (_listening) {
      _listening = false;
      try {
        _context.removeListener(_changed);
      } on Object {
        // A broken source must not prevent backend or late-result revocation.
      }
    }
    try {
      _onInvalidate?.call();
    } finally {
      // Fence an asynchronous interpreted entrypoint, even if cleanup fails.
      _onFailure?.call();
    }
  }
}
