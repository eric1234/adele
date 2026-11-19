import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/foundation.dart';

import 'prepared_frontend.dart';

const _library = 'package:adele_ui/session_accessory_bridge.dart';
const _readId = 'readSessionAccessorySessionId';

/// Compile-only ABI; no Session, backend, or runtime is needed to prepare it.
class SessionAccessoryDeclarations implements EvalPlugin {
  const SessionAccessoryDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _library,
        _readId,
        BridgeFunctionDef(
          returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
        ),
      ),
    );
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a per-presentation SessionAccessoryBridge.');
}

/// Captures the display identity once. Retention leaves only that frozen value,
/// never a native context, callback to the source, or live backend observation.
final class SessionAccessoryBridge extends SessionAccessoryDeclarations
    implements
        PreparedFrontendBridge,
        PreparedFrontendRetainable,
        PreparedFrontendFailureSource {
  SessionAccessoryBridge({
    required String sessionId,
    required VoidCallback validateAccess,
    required VoidCallback onEnd,
  }) : _sessionId = $String(sessionId),
       _validateAccess = validateAccess,
       _onEnd = onEnd;

  $String? _sessionId;
  VoidCallback? _validateAccess;
  VoidCallback? _onEnd;

  @override
  VoidCallback? onFailure;

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_library, _readId, (_, _, _) {
      try {
        _validateAccess?.call();
        if (_sessionId case final id?) return id;
      } on Object {
        invalidate();
      }
      throw StateError('Session accessory is unavailable.');
    });
  }

  @override
  void retainPresentation() {
    _validateAccess = null;
    final end = _onEnd;
    _onEnd = null;
    end?.call();
  }

  @override
  void invalidate() {
    if (_sessionId == null) return;
    _sessionId = null;
    try {
      retainPresentation();
    } finally {
      // Also fence an interpreted entrypoint that has not returned its widget.
      onFailure?.call();
    }
  }
}
