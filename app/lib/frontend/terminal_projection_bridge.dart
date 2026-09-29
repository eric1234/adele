import 'dart:math';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/widgets.dart';

import '../terminal/native_terminal_surface.dart';
import 'prepared_frontend.dart';
import 'structured_bridge_data.dart';

const _library = 'package:adele_ui/terminal_projection_bridge.dart';

/// Bounded native projection data for one retained content owner. No emulator,
/// view, evaluator, or callback survives here between presentations.
final class TerminalProjectionRetention {
  int _epoch = 0;
  bool _closed = false;
  Map<String, Object> _snapshot = const {};

  /// Last native checkpoint, independent of delayed interpreted observation.
  Map<String, Object> get snapshot => _snapshot;

  int _acquire() {
    if (_closed) throw StateError('Terminal projection retention is closed.');
    return ++_epoch;
  }

  bool _isCurrent(int? lease) => !_closed && lease == _epoch;

  /// Permanently revokes all leases and discards removed content's snapshot.
  void clear() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _snapshot = const {};
  }
}

class TerminalProjectionDeclarations implements EvalPlugin {
  const TerminalProjectionDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    const integer = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.int));
    const boolean = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool));
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
        const [
          BridgeParameter('rows', integer, false),
          BridgeParameter('alwaysFollow', boolean, false),
        ],
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
      ('hideTerminalProjection', voidType, const [handle]),
      (
        'revealTerminalProjection',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.future, [
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.bool)),
          ]),
        ),
        const [handle],
      ),
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
        'readRetainedTerminalProjection',
        const BridgeTypeAnnotation(
          BridgeTypeRef(CoreTypes.map, [
            string,
            BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.dynamic)),
          ]),
        ),
        const <BridgeParameter>[],
      ),
      (
        'setTerminalProjectionFollow',
        voidType,
        const [
          handle,
          BridgeParameter('following', boolean, false),
          BridgeParameter('resumeAtEnd', boolean, false),
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
    TerminalProjectionRetention? retention,
  }) : _isActive = isActive,
       _maxLines = maxLines,
       _retention = retention,
       _lease = retention?._acquire(),
       _initialProjection = Map.of(retention?.snapshot ?? const {});

  final bool Function() _isActive;
  final int _maxLines;
  final TerminalProjectionRetention? _retention;
  final int? _lease;
  final Map<String, Object> _initialProjection;
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
    if (_retention != null && !_retention._isCurrent(_lease)) {
      invalidate();
      return false;
    }
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
        final rows = args[0]!.$value as int;
        final alwaysFollow = args[1]!.$value as bool;
        if (_surface case final surface?) {
          final state = surface.readProjection();
          if (state['rows'] != rows || state['alwaysFollow'] != alwaysFollow) {
            throw StateError(
              'Projection geometry and policy are fixed for this presentation.',
            );
          }
        } else {
          _surface = NativeTerminalSurface.projection(
            rows: rows,
            alwaysFollow: alwaysFollow,
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
      ..registerBridgeFunc(_library, 'hideTerminalProjection', (_, _, args) {
        _resolve(args.single!.$value).hideProjection();
        return null;
      })
      ..registerBridgeFunc(_library, 'revealTerminalProjection', (_, _, args) {
        final surface = _resolve(args.single!.$value);
        return $Future.wrap(
          surface.revealProjection().then<$Value>(
            (ready) =>
                $bool(ready && _available && identical(_surface, surface)),
          ),
        );
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
      ..registerBridgeFunc(_library, 'readRetainedTerminalProjection', (
        _,
        _,
        _,
      ) {
        _validate();
        return wrapStructuredBridgeData(_initialProjection);
      })
      ..registerBridgeFunc(_library, 'setTerminalProjectionFollow', (
        _,
        _,
        args,
      ) {
        _resolve(args[0]!.$value).setProjectionFollow(
          args[1]!.$value as bool,
          resumeAtEnd: args[2]!.$value as bool,
        );
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

  void _checkpoint() {
    final retention = _retention;
    final surface = _surface;
    if (!_active ||
        retention == null ||
        !retention._isCurrent(_lease) ||
        surface == null ||
        surface.isDisposed) {
      return;
    }
    // Only already-owned native scalars are copied. External view authority may
    // have retired before interpreted observation or widget teardown can run.
    retention._snapshot = surface.readProjection();
  }

  void _changed() {
    _checkpoint();
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
    _checkpoint();
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
