import 'dart:math';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/widgets.dart';

import '../terminal/native_terminal_surface.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/terminal_projection_bridge.dart';

class TerminalProjectionDeclarations implements EvalPlugin {
  const TerminalProjectionDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const integer = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int));
    const voidType = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.voidType));
    const handle = BridgeParameter('handle', string, false);
    const listener = BridgeParameter(
      'listener',
      BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.function)),
      false,
    );
    for (final (name, returns, params) in [
      (
        'requestTerminalProjection',
        string,
        const [BridgeParameter('rows', integer, false)],
      ),
      (
        'buildTerminalProjection',
        const BridgeTypeAnnotation($Widget.$type),
        const [handle],
      ),
      (
        'feedTerminalProjection',
        integer,
        const [
          handle,
          BridgeParameter('text', string, false),
          BridgeParameter('lineBudget', integer, false),
        ],
      ),
      ('resetTerminalProjection', voidType, const [handle]),
      (
        'yieldTerminalProjection',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.future, [
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
          ]),
        ),
        const [handle],
      ),
      (
        'readTerminalProjection',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.map, [
            string,
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
          ]),
        ),
        const [handle],
      ),
      (
        'setTerminalProjectionFollow',
        voidType,
        const [
          handle,
          BridgeParameter(
            'following',
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
            false,
          ),
        ],
      ),
      (
        'scrollTerminalProjection',
        voidType,
        const [
          handle,
          BridgeParameter(
            'offset',
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.double)),
            false,
          ),
        ],
      ),
      ('subscribeTerminalProjection', voidType, const [handle, listener]),
      ('unsubscribeTerminalProjection', voidType, const [handle, listener]),
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
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a presentation-scoped TerminalProjectionBridge.',
  );
}

/// Independent projection ownership, never access to an interactive surface,
/// execution resource, history store, or backend channel.
final class TerminalProjectionBridge extends TerminalProjectionDeclarations
    implements
        PreparedFrontendBridge,
        PreparedFrontendFailureSource,
        PreparedFrontendRetainable {
  TerminalProjectionBridge({
    required bool Function() isActive,
    int maxLines = 200,
  }) : _isActive = isActive,
       _maxLines = maxLines;

  final bool Function() _isActive;
  final int _maxLines;
  final Map<EvalCallable, VoidCallback> _listeners = Map.identity();
  NativeTerminalSurface? _surface;
  VoidCallback? _detach;
  String? _handle;
  Widget? _view;
  bool _active = true;
  bool _configured = false;
  bool _scheduled = false;

  @override
  VoidCallback? onFailure;

  bool get _available {
    if (!_active) return false;
    try {
      if (_isActive()) return true;
    } on Object {
      // A failing liveness check revokes this exact presentation.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!_available) throw StateError('Terminal projection is retired.');
  }

  NativeTerminalSurface _resolve(Object? handle) {
    _validate();
    if (_handle == null || _handle != handle) {
      throw StateError(
        'Projection handle was not issued to this presentation.',
      );
    }
    return _surface!;
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Projection bridge is already bound.');
    _configured = true;
    runtime
      ..registerBridgeFunc(_library, 'requestTerminalProjection', (_, _, args) {
        _validate();
        final rows = args.single!.$value as int;
        if (_surface case final surface?) {
          if (surface.readProjection()['rows'] != rows) {
            throw StateError(
              'Projection geometry is fixed for this presentation.',
            );
          }
        } else {
          _surface = NativeTerminalSurface.projection(
            rows: rows,
            maxLines: _maxLines,
          );
          final random = Random.secure();
          _handle = List.generate(
            24,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          _detach = _surface!.observeProjection(_changed);
        }
        return $String(_handle!);
      })
      ..registerBridgeFunc(_library, 'buildTerminalProjection', (_, _, args) {
        final surface = _resolve(args.single!.$value);
        return $Widget.wrap(
          _view ??= surface.buildView(
            isActive: () => _available,
            onUnavailable: () {
              invalidate();
              onFailure?.call();
            },
          ),
        );
      })
      ..registerBridgeFunc(_library, 'feedTerminalProjection', (_, _, args) {
        final surface = _resolve(args[0]!.$value);
        final accepted = surface.feedProjection(
          args[1]!.$value as String,
          args[2]!.$value as int,
        );
        if (accepted < 0) {
          invalidate();
          onFailure?.call();
        }
        return $int(accepted);
      })
      ..registerBridgeFunc(_library, 'resetTerminalProjection', (_, _, args) {
        _resolve(args.single!.$value).resetProjection();
        return null;
      })
      ..registerBridgeFunc(_library, 'yieldTerminalProjection', (_, _, args) {
        final handle = args.single!.$value;
        final surface = _resolve(handle);
        return $Future.wrap(
          Future<$Value>.delayed(
            Duration.zero,
            () => $bool(
              _available && identical(_surface, surface) && _handle == handle,
            ),
          ),
        );
      })
      ..registerBridgeFunc(_library, 'readTerminalProjection', (_, _, args) {
        return wrapStructuredBridgeData(
          _resolve(args.single!.$value).readProjection(),
        );
      })
      ..registerBridgeFunc(_library, 'setTerminalProjectionFollow', (
        _,
        _,
        args,
      ) {
        _resolve(args[0]!.$value).setProjectionFollow(args[1]!.$value as bool);
        return null;
      })
      ..registerBridgeFunc(_library, 'scrollTerminalProjection', (_, _, args) {
        _resolve(
          args[0]!.$value,
        ).scrollProjection((args[1]!.$value as num).toDouble());
        return null;
      })
      ..registerBridgeFunc(_library, 'subscribeTerminalProjection', (
        _,
        _,
        args,
      ) {
        _resolve(args[0]!.$value);
        final listener = args[1]! as EvalCallable;
        _listeners.putIfAbsent(
          listener,
          () =>
              () => listener.call(runtime, null, const []),
        );
        return null;
      })
      ..registerBridgeFunc(_library, 'unsubscribeTerminalProjection', (
        _,
        _,
        args,
      ) {
        if (!_active) return null;
        _resolve(args[0]!.$value);
        _listeners.remove(args[1]! as EvalCallable);
        return null;
      });
  }

  void _changed() {
    if (!_available || _scheduled || _listeners.isEmpty) return;
    _scheduled = true;
    final queued = Map.of(_listeners);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_available) return;
      for (final entry in queued.entries) {
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
  void retainPresentation() {
    _active = false;
    _listeners.clear();
    _detach?.call();
    _detach = null;
  }

  @override
  void invalidate() {
    retainPresentation();
    _surface?.dispose();
    _surface = null;
    _view = null;
  }
}
