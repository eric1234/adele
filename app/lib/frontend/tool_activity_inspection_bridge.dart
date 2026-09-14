import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_ui/adele_ui.dart';
import 'package:adele_ui/tool_activity_inspection_bridge.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';

import 'prepared_frontend.dart';

const String _bridgeLibrary =
    'package:adele_ui/tool_activity_inspection_bridge.dart';

/// Build-time declarations, independent of any source or runtime generation.
class ToolActivityInspectionDeclarations implements EvalPlugin {
  const ToolActivityInspectionDeclarations();

  @override
  String get identifier => _bridgeLibrary;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    registry
      ..defineBridgeClass(_ToolSnapshot.$declaration)
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _bridgeLibrary,
          'readToolActivitySnapshot',
          BridgeFunctionDef(returns: BridgeTypeAnnotation(_ToolSnapshot.$type)),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _bridgeLibrary,
          'subscribeToolActivityChanges',
          BridgeFunctionDef(
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
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _bridgeLibrary,
          'unsubscribeToolActivityChanges',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType)),
          ),
        ),
      );
  }

  @override
  void configureForRuntime(Runtime runtime) {
    throw UnsupportedError(
      'Use a per-presentation ToolActivityInspectionBridge.',
    );
  }
}

/// A read-only adapter for the existing prepared frontend host. No runtime,
/// execution, approval callback or full activity history crosses this boundary.
final class ToolActivityInspectionBridge
    extends ToolActivityInspectionDeclarations
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  ToolActivityInspectionBridge({
    required ToolActivityInspectionSource source,
    required bool Function() isActive,
  }) : _source = source,
       _isActive = isActive;

  final ToolActivityInspectionSource _source;
  final bool Function() _isActive;
  bool _active = true;
  bool _failed = false;
  bool _scheduled = false;
  VoidCallback? _callback;
  VoidCallback? _onFailure;

  @override
  set onFailure(VoidCallback? callback) => _onFailure = callback;

  bool get _available {
    if (!_active) return false;
    try {
      if (_isActive()) return true;
    } on Object {
      // A broken liveness check cannot grant observation access.
      _fail();
      return false;
    }
    invalidate();
    return false;
  }

  @override
  void configureForRuntime(Runtime runtime) {
    runtime
      ..registerBridgeFunc(_bridgeLibrary, 'readToolActivitySnapshot', (
        _,
        _,
        _,
      ) {
        if (!_available) {
          throw StateError('Tool activity inspection is unavailable.');
        }
        try {
          final _ToolSnapshot snapshot = _ToolSnapshot(
            _InspectionData(_source.snapshot),
          );
          if (!_available) {
            throw StateError('Tool activity inspection is unavailable.');
          }
          return snapshot;
        } on Object {
          _fail();
          throw StateError('Tool activity inspection is unavailable.');
        }
      })
      ..registerBridgeFunc(_bridgeLibrary, 'subscribeToolActivityChanges', (
        _,
        _,
        args,
      ) {
        _unsubscribe();
        if (!_available) return null;
        final EvalCallable callback = args.single! as EvalCallable;
        _callback = () => callback.call(runtime, null, const []);
        _source.addListener(_changed);
        return null;
      })
      ..registerBridgeFunc(_bridgeLibrary, 'unsubscribeToolActivityChanges', (
        _,
        _,
        _,
      ) {
        _unsubscribe();
        return null;
      });
  }

  void _changed() {
    if (!_available || _callback == null || _scheduled) return;
    _scheduled = true;
    final VoidCallback callback = _callback!;
    // Never reenter eval during a host build. A replaced subscription must not
    // receive an invalidation queued for its predecessor.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_callback, callback)) return;
      _scheduled = false;
      if (!_available) return;
      final bool owned = _onFailure != null;
      try {
        callback();
      } on Object {
        _fail();
        if (!owned) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: FlutterError('Tool activity inspection failed.'),
              library: 'Tool activity inspection',
            ),
          );
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _unsubscribe() {
    if (_callback == null) return;
    _source.removeListener(_changed);
    _callback = null;
    _scheduled = false;
  }

  void _fail() {
    if (_failed) return;
    _failed = true;
    invalidate();
    _onFailure?.call();
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _unsubscribe();
  }
}

final class _InspectionData implements ToolActivityInspectionSnapshot {
  _InspectionData(ToolInvocationActivity activity)
    : canonicalArguments = activity.canonicalArguments,
      hostData = activity.outcome?.hostData ?? const {},
      lifecycle =
          activity.changes.reversed
              .where((change) => change.kind != ToolActivityKind.progress)
              .firstOrNull
              ?.kind
              .name ??
          ToolActivityKind.prepared.name,
      disposition = activity.outcome?.disposition.name,
      failureKind = activity.outcome?.failureKind?.name,
      modelContent = activity.outcome?.modelContent ?? '';

  @override
  final Map<String, dynamic> canonicalArguments;
  @override
  final Map<String, dynamic> hostData;
  @override
  final String lifecycle;
  @override
  final String? disposition;
  @override
  final String? failureKind;
  @override
  final String modelContent;
}

final class _ToolSnapshot implements $Instance {
  _ToolSnapshot(this.data);

  static const BridgeTypeRef $type = BridgeTypeRef(
    BridgeTypeSpec(_bridgeLibrary, 'ToolActivityInspectionSnapshot'),
  );
  static const BridgeMethodDef _mapGetter = BridgeMethodDef(
    BridgeFunctionDef(
      returns: BridgeTypeAnnotation(
        BridgeTypeRef(CoreTypes.map, [
          BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
          BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
        ]),
      ),
    ),
  );
  static const BridgeMethodDef _stringGetter = BridgeMethodDef(
    BridgeFunctionDef(
      returns: BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string)),
    ),
  );
  static const BridgeMethodDef _nullableStringGetter = BridgeMethodDef(
    BridgeFunctionDef(
      returns: BridgeTypeAnnotation(
        BridgeTypeRef(CoreTypes.string),
        nullable: true,
      ),
    ),
  );
  static const BridgeClassDef $declaration = BridgeClassDef(
    BridgeClassType($type),
    constructors: {},
    getters: {
      'canonicalArguments': _mapGetter,
      'hostData': _mapGetter,
      'lifecycle': _stringGetter,
      'disposition': _nullableStringGetter,
      'failureKind': _nullableStringGetter,
      'modelContent': _stringGetter,
    },
    wrap: true,
  );

  final _InspectionData data;
  late final $Instance _superclass = $Object(data);
  late final $Value _arguments = _wrapValue(data.canonicalArguments);
  late final $Value _hostData = _wrapValue(data.hostData);

  @override
  Object get $value => data;
  @override
  Object get $reified => data;
  @override
  int $getRuntimeType(Runtime runtime) => runtime.lookupType($type.spec!);
  @override
  $Value? $getProperty(Runtime runtime, String identifier) =>
      switch (identifier) {
        'canonicalArguments' => _arguments,
        'hostData' => _hostData,
        'lifecycle' => $String(data.lifecycle),
        'disposition' =>
          data.disposition == null ? const $null() : $String(data.disposition!),
        'failureKind' =>
          data.failureKind == null ? const $null() : $String(data.failureKind!),
        'modelContent' => $String(data.modelContent),
        _ => _superclass.$getProperty(runtime, identifier),
      };
  @override
  void $setProperty(Runtime runtime, String identifier, $Value value) {
    throw UnsupportedError('Tool activity inspection snapshots are immutable.');
  }
}

// Canonical activity already validates/freezes structured data. Eval containers
// must also be recursively frozen, not just their outer Map wrapper.
$Value _wrapValue(Object? value) => switch (value) {
  null => const $null(),
  final bool value => $bool(value),
  final String value => $String(value),
  final int value => $int(value),
  final double value => $double(value),
  final List<Object?> value => $List.wrap(
    List<$Value>.unmodifiable(value.map(_wrapValue)),
  ),
  final Map<String, Object?> value => $Map.wrap(
    Map<$Value, $Value>.unmodifiable(
      value.map((key, value) => MapEntry($String(key), _wrapValue(value))),
    ),
  ),
  _ => throw const FormatException(
    'Unsupported Tool activity inspection value.',
  ),
};
