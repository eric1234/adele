import 'package:adele_ui/adele_ui.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';

import 'prepared_frontend.dart';

const String _bridgeLibrary =
    'package:adele_ui/model_native_activity_bridge.dart';

/// Build-time declarations with no native output or execution APIs.
class ModelNativeActivityDeclarations implements EvalPlugin {
  const ModelNativeActivityDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry.defineBridgeTopLevelFunction(
      const BridgeFunctionDeclaration(
        _bridgeLibrary,
        'readModelNativeActivityData',
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
  void configureForRuntime(Runtime runtime) {
    throw UnsupportedError('Use a per-presentation ModelNativeActivityBridge.');
  }
}

/// Captures only safe primitive presentation data, never a native envelope.
/// Each view owns one frozen snapshot with no subscription or authority surface.
final class ModelNativeActivityBridge extends ModelNativeActivityDeclarations
    implements PreparedFrontendBridge {
  ModelNativeActivityBridge({
    required ModelNativePresentation presentation,
    required bool Function() isActive,
  }) : _snapshot = _wrapValue(presentation.data),
       _isActive = isActive;

  $Value? _snapshot;
  final bool Function() _isActive;

  @override
  void configureForRuntime(Runtime runtime) {
    runtime.registerBridgeFunc(_bridgeLibrary, 'readModelNativeActivityData', (
      _,
      _,
      _,
    ) {
      try {
        if (_snapshot != null && _isActive()) return _snapshot;
      } on Object {
        // Do not expose liveness errors or restore a failed view's access.
      }
      invalidate();
      throw StateError('Model native activity inspection is unavailable.');
    });
  }

  @override
  void invalidate() => _snapshot = null;
}

// Freeze eval containers too: an immutable native Map alone does not prevent
// interpreted code from mutating a nested eval List or Map wrapper.
$Value _wrapValue(Object? value) => switch (value) {
  null => const $null(),
  final bool value => $bool(value),
  final String value => $String(value),
  final int value => $int(value),
  final double value when value.isFinite => $double(value),
  final List<Object?> value => $List.wrap(
    List<$Value>.unmodifiable(value.map(_wrapValue)),
  ),
  final Map<String, Object?> value => $Map.wrap(
    Map<$Value, $Value>.unmodifiable(
      value.map((key, value) => MapEntry($String(key), _wrapValue(value))),
    ),
  ),
  _ => throw const FormatException(
    'Unsupported model native presentation value.',
  ),
};
