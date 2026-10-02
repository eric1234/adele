import 'dart:math';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/widgets.dart';

import '../editor/native_code_editor.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/code_editor_bridge.dart';

/// Declares only the interpreted ABI. Compilation neither initializes native
/// code nor constructs or acquires an editor.
class CodeEditorDeclarations implements EvalPlugin {
  const CodeEditorDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const map = BridgeTypeAnnotation(
      BridgeTypeRef(CoreTypes.map, [
        string,
        BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
      ]),
    );
    const voidType = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType));
    const handle = BridgeParameter('handle', string, false);
    const listener = BridgeParameter(
      'listener',
      BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
      false,
    );
    for (final (name, returns, params) in [
      ('requestCodeEditor', string, const <BridgeParameter>[]),
      (
        'buildCodeEditor',
        const BridgeTypeAnnotation($Widget.$type),
        const [handle],
      ),
      ('readCodeEditorState', map, const [handle]),
      ('snapshotCodeEditor', map, const [handle]),
      ('subscribeCodeEditor', voidType, const [handle, listener]),
      ('unsubscribeCodeEditor', voidType, const [handle, listener]),
    ]) {
      registry.defineBridgeTopLevelFunction(
        BridgeFunctionDeclaration(
          _library,
          name,
          BridgeFunctionDef(returns: returns, params: params),
        ),
      );
    }
  }

  @override
  void configureForRuntime(Runtime runtime) =>
      throw UnsupportedError('Use a presentation-scoped CodeEditorBridge.');
}

/// Exactly one host-selected native view and one runtime. Native access, rather
/// than the evaluator or a cached widget, fences every interaction sink.
final class CodeEditorBridge extends CodeEditorDeclarations
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  CodeEditorBridge({
    required NativeCodeView view,
    required bool Function() isActive,
  }) : _owner = view,
       _isActive = isActive;

  final NativeCodeView _owner;
  final bool Function() _isActive;
  final Map<EvalCallable, VoidCallback> _listeners = Map.identity();
  final Map<EvalCallable, VoidCallback> _pending = Map.identity();
  NativeCodeAccess? _access;
  VoidCallback? _detach;
  Widget? _widget;
  String? _handle;
  bool _active = true;
  bool _configured = false;
  bool _scheduled = false;

  @override
  VoidCallback? onFailure;

  bool get _available {
    if (!_active) return false;
    try {
      if (!_owner.isDisposed && _isActive() && _active && !_owner.isDisposed) {
        return true;
      }
    } on Object {
      // A failed liveness predicate retires this access permanently.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!_available) throw StateError('Code editor presentation is retired.');
  }

  NativeCodeAccess _resolve(Object? handle) {
    _validate();
    if (_handle == null || handle != _handle) {
      throw StateError('Editor handle was not issued to this presentation.');
    }
    return _access!;
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Code editor bridge is already bound.');
    _configured = true;
    runtime
      ..registerBridgeFunc(_library, 'requestCodeEditor', (_, _, _) {
        _validate();
        if (_handle == null) {
          final random = Random.secure();
          _access = _owner.createAccess(
            isActive: () => _available,
            onUnavailable: () {
              invalidate();
              onFailure?.call();
            },
          );
          _handle = List.generate(
            24,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
        }
        return $String(_handle!);
      })
      ..registerBridgeFunc(_library, 'buildCodeEditor', (_, _, args) {
        final access = _resolve(args.single!.$value);
        return $Widget.wrap(_widget ??= access.buildView());
      })
      ..registerBridgeFunc(_library, 'readCodeEditorState', (_, _, args) {
        final state = _resolve(args.single!.$value).readState();
        _validate();
        return wrapStructuredBridgeData(state);
      })
      ..registerBridgeFunc(_library, 'snapshotCodeEditor', (_, _, args) {
        final access = _resolve(args.single!.$value);
        final snapshot = access.snapshot();
        _validate();
        return wrapStructuredBridgeData(snapshot);
      })
      ..registerBridgeFunc(_library, 'subscribeCodeEditor', (_, _, args) {
        final access = _resolve(args[0]!.$value);
        final listener = args[1]! as EvalCallable;
        _listeners.putIfAbsent(
          listener,
          () =>
              () => listener.call(runtime, null, const []),
        );
        _detach ??= access.observeChanges(_changed);
        return null;
      })
      ..registerBridgeFunc(_library, 'unsubscribeCodeEditor', (_, _, args) {
        if (!_available) return null;
        _resolve(args[0]!.$value);
        final listener = args[1]! as EvalCallable;
        _listeners.remove(listener);
        _pending.remove(listener);
        if (_listeners.isEmpty) {
          _detach?.call();
          _detach = null;
        }
        return null;
      });
  }

  void _changed() {
    if (!_available || _listeners.isEmpty) return;
    _pending.addAll(_listeners);
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_available) return;
      final pending = Map.of(_pending);
      _pending.clear();
      for (final entry in pending.entries) {
        if (!_available) return;
        if (!identical(_listeners[entry.key], entry.value)) continue;
        try {
          entry.value();
        } on Object {
          invalidate();
          onFailure?.call();
          return;
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void invalidate() {
    if (!_active) return;
    _active = false;
    _listeners.clear();
    _pending.clear();
    _detach?.call();
    _detach = null;
    _access?.revoke();
    _access = null;
    _widget = null;
  }
}
