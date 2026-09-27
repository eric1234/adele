import 'dart:math';

import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/stdlib/core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_eval/widgets.dart';

import '../terminal/native_terminal_surface.dart';
import 'prepared_frontend.dart';

const _library = 'package:adele_ui/terminal_surface_bridge.dart';

/// Compilation declares the ABI without constructing or acquiring a surface.
class TerminalSurfaceDeclarations implements EvalPlugin {
  const TerminalSurfaceDeclarations();

  @override
  String get identifier => _library;

  @override
  void configureForCompile(BridgeDeclarationRegistry registry) {
    const string = BridgeTypeAnnotation(BridgeTypeRef(CoreTypes.string));
    registry
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _library,
          'requestTerminalSurface',
          BridgeFunctionDef(returns: string),
        ),
      )
      ..defineBridgeTopLevelFunction(
        const BridgeFunctionDeclaration(
          _library,
          'buildTerminalSurface',
          BridgeFunctionDef(
            returns: BridgeTypeAnnotation($Widget.$type),
            params: [BridgeParameter('handle', string, false)],
          ),
        ),
      );
  }

  @override
  void configureForRuntime(Runtime runtime) => throw UnsupportedError(
    'Use a presentation-scoped TerminalSurfaceBridge.',
  );
}

/// One host-selected surface, one exact presentation, and no resource lookup.
final class TerminalSurfaceBridge extends TerminalSurfaceDeclarations
    implements PreparedFrontendBridge, PreparedFrontendFailureSource {
  TerminalSurfaceBridge({
    required NativeTerminalSurface surface,
    required bool Function() isActive,
  }) : _surface = surface,
       _isActive = isActive;

  final NativeTerminalSurface _surface;
  final bool Function() _isActive;
  bool _active = true;
  bool _configured = false;
  String? _handle;
  Widget? _view;

  @override
  VoidCallback? onFailure;

  bool get _available {
    if (!_active || _surface.isDisposed) return false;
    try {
      if (_isActive()) return true;
    } on Object {
      // Failed liveness checks revoke access just like retirement.
    }
    invalidate();
    return false;
  }

  void _validate() {
    if (!_available) throw StateError('Terminal presentation is retired.');
  }

  @override
  void configureForRuntime(Runtime runtime) {
    if (_configured) throw StateError('Terminal bridge is already bound.');
    _configured = true;
    runtime
      ..registerBridgeFunc(_library, 'requestTerminalSurface', (_, _, _) {
        _validate();
        final random = Random.secure();
        _handle ??= List.generate(
          24,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        return $String(_handle!);
      })
      ..registerBridgeFunc(_library, 'buildTerminalSurface', (_, _, args) {
        _validate();
        if (_handle == null || args.single!.$value != _handle) {
          throw StateError(
            'Terminal handle was not issued to this presentation.',
          );
        }
        return $Widget.wrap(
          _view ??= _surface.buildView(
            isActive: () => _available,
            onUnavailable: () {
              invalidate();
              onFailure?.call();
            },
          ),
        );
      });
  }

  // PreparedFrontend also calls this during exit retention. Cached widgets keep
  // this exact access check, never a replacement bridge or surface lookup.
  @override
  void invalidate() {
    _active = false;
    _view = null;
  }
}
